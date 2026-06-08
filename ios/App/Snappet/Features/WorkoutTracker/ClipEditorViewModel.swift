import Foundation
import Observation
import AVKit
import CoreGraphics
import HighlightEngine

/// View model for the CapCut-style clip editor (B3). Owns the non-destructive `ClipEdit`,
/// rebuilds the live `AVPlayer` preview off the shared `VideoStudio` composition whenever an
/// edit changes, and persists. **All business/render logic lives here** — `ClipEditorView` is
/// thin (conventions.md "no business logic in views"). The pure geometry/timing math is in
/// `ClipEditGeometry`; this VM just drives it through `VideoStudio`.
@MainActor
@Observable
final class ClipEditorViewModel {
    enum State: Equatable { case idle, building, ready, error(String) }

    /// The edit being authored (a SwiftData `@Model`, inserted/saved by the caller).
    let edit: ClipEdit
    /// The source clip's full duration (seconds), loaded once so trim handles have a range.
    private(set) var sourceDuration: Double = 0

    private(set) var state: State = .idle
    private(set) var previewPlayer: AVPlayer?
    /// Playhead seconds (for the live HR-chart overlay dot), updated by a periodic observer.
    private(set) var currentTime: Double = 0
    private var timeObserver: Any?
    /// The session's HR samples sliced to this clip's capture window (rebased to 0), set by the view.
    private(set) var hrSamples: [HRPoint] = []
    /// Profile/session bounds for the configurable HR/fitness overlays (prompt 28), set by the view
    /// from the session + `UserHRProfile`: max/rest HR (zones, %HRR, recovery), the clip's calorie
    /// estimate, and its HRV. Drive the resolved overlay readings on export + preview.
    private(set) var hrMaxHR: Double?
    private(set) var hrRestHR: Double?
    private(set) var hrKcal: Double?
    private(set) var hrHRV: HRVMetrics = .empty

    /// B5: the export → share / save-to-Photos flow (the rendered `.mp4` is carried in `.exported`
    /// so share + save reuse the single render). Drives the editor's bottom action bar.
    private(set) var exportState: ExportShareState = .idle

    private let studio: VideoStudio
    private let library: MediaLibraryService
    private let save: () -> Void
    private let insert: (ClipEdit) -> Void
    private var buildToken = 0

    init(edit: ClipEdit, studio: VideoStudio,
         insert: @escaping (ClipEdit) -> Void, save: @escaping () -> Void,
         library: MediaLibraryService = MediaLibraryService()) {
        self.edit = edit
        self.studio = studio
        self.library = library
        self.insert = insert
        self.save = save
    }

    // The periodic time observer is removed before each `rebuild` reattaches one; at dealloc the
    // player and its `[weak self]` observer block are released together (a nonisolated `deinit` can't
    // touch these @MainActor properties under Swift 6), so it doesn't accumulate or dangle.

    // MARK: - Lifecycle

    /// Load the source duration (for the trim handles) and build the first preview.
    func load() async {
        if let d = await studio.sourceDuration(localIdentifier: edit.localIdentifier), d > 0 {
            sourceDuration = d
        }
        await rebuild()
    }

    /// Rebuild the live preview from the current `ClipEdit` (called after every edit).
    func rebuild() async {
        buildToken += 1
        let token = buildToken
        state = .building
        // The preview composition does NOT include the HR chart (Core Animation overlays are
        // export-only — AVPlayerItem rejects them); the HR chart previews as a SwiftUI layer. So
        // build the player WITHOUT hrSamples; export passes them.
        let plan = EditPlan(edit)   // snapshot on the MainActor; the @Model never crosses actors
        do {
            let (composition, videoComposition) = try await studio.makeComposition(for: plan, forPlayback: true)
            guard token == buildToken else { return }   // a newer edit superseded this build
            let item = AVPlayerItem(asset: composition)
            // `AVPlayerItem.setVideoComposition` raises an ObjC NSException (uncatchable by Swift) for a
            // composition it rejects — guard via the ObjC bridge so the editor never aborts; fall back
            // to the raw composition (the preview omits the offline-only animation tool already).
            if let videoComposition, ObjCException.catching({ item.videoComposition = videoComposition }) != nil {
                item.videoComposition = nil
            }
            previewPlayer?.pause()
            if let timeObserver { previewPlayer?.removeTimeObserver(timeObserver); self.timeObserver = nil }
            let player = AVPlayer(playerItem: item)
            timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { [weak self] t in
                MainActor.assumeIsolated { self?.currentTime = t.seconds }
            }
            previewPlayer = player
            currentTime = 0
            state = .ready
        } catch {
            guard token == buildToken else { return }
            previewPlayer = nil
            state = .error((error as? LocalizedError)?.errorDescription ?? "Couldn't build the preview.")
        }
    }

    // MARK: - Edits (each persists + invalidates the preview)

    /// The effective trim end (resolving `nil` to the source duration).
    var effectiveTrimEnd: Double { edit.trimEnd ?? sourceDuration }

    func setTrim(start: Double, end: Double) {
        let dur = sourceDuration > 0 ? sourceDuration : max(start, end)
        if let w = ClipEditGeometry.trimWindow(start: start, end: end, assetDuration: dur) {
            edit.trimStart = w.start
            edit.trimEnd = w.end
            commit()
        }
    }

    func setAspect(_ aspect: ClipEditGeometry.OutputAspect) {
        edit.aspect = aspect
        commit()
    }

    func setCrop(_ rect: CGRect) {
        edit.cropRect = ClipEditGeometry.sanitizedCropRect(rect)
        commit()
    }

    func setSpeed(_ speed: Double) {
        edit.speed = ClipEditGeometry.clampSpeed(speed)
        commit()
    }

    func setMuted(_ muted: Bool) {
        edit.mutedOriginalAudio = muted
        commit()
    }

    func addOverlay(_ overlay: TextOverlay) {
        edit.textOverlays.append(overlay)
        commit()
    }

    func updateOverlay(_ overlay: TextOverlay) {
        if let i = edit.textOverlays.firstIndex(where: { $0.id == overlay.id }) {
            edit.textOverlays[i] = overlay
            commit()
        }
    }

    func removeOverlay(_ overlay: TextOverlay) {
        edit.textOverlays.removeAll { $0.id == overlay.id }
        commit()
    }

    /// **Split** the current trim at `second` into two adjacent, non-overlapping clips: this
    /// edit keeps the first half, a new sibling `ClipEdit` (inserted via the `insert` closure)
    /// gets the second half. Returns `false` if the trim is too short to split (pure split math
    /// is `ClipEditGeometry.split`).
    @discardableResult
    func split(at second: Double) -> Bool {
        let dur = sourceDuration > 0 ? sourceDuration : effectiveTrimEnd
        guard let window = ClipEditGeometry.trimWindow(
            start: edit.trimStart, end: effectiveTrimEnd, assetDuration: dur),
              let (first, secondWin) = ClipEditGeometry.split(window, at: second) else { return false }

        edit.trimStart = first.start
        edit.trimEnd = first.end

        let sibling = ClipEdit(
            sessionMediaID: edit.sessionMediaID, localIdentifier: edit.localIdentifier,
            trimStart: secondWin.start, trimEnd: secondWin.end, splitOrder: edit.splitOrder + 1,
            cropRect: edit.cropRect, aspect: edit.aspect, speed: edit.speed,
            textOverlays: edit.textOverlays, mutedOriginalAudio: edit.mutedOriginalAudio,
            musicTrackName: edit.musicTrackName)
        insert(sibling)
        commit()
        return true
    }

    // MARK: - B5: Export → share / save to Photos

    /// Render the current edit to a temp `.mp4` via the shared `VideoStudio` (the same composition
    /// the preview uses), leaving the result in `.exported(url)` so the view can share it or save it
    /// to Photos. Re-exporting from any state is allowed (a later edit produces a fresh render).
    func export() async {
        exportState = exportState.beginningExport()
        // Resolve the configurable HR/fitness overlay elements to render-ready badges (prompt 28) —
        // computed here where the bounds/profile live, so the AVFoundation render stays dumb.
        let resolved = resolvedOverlayElements()
        let plan = EditPlan(edit, hrSamples: hrSamples, resolvedHRElements: resolved)   // snapshot on the MainActor
        do {
            let url = try await studio.export(plan)
            exportState = exportState.exportSucceeded(url)
        } catch {
            exportState = exportState.failed(
                (error as? LocalizedError)?.errorDescription ?? "Couldn't export this clip.")
        }
    }

    /// Save the already-exported file to the user's Photos library as a **new copy** (add-only).
    func saveToPhotos() async {
        guard let url = exportState.exportedURL else { return }
        exportState = exportState.beginningSave()
        do {
            try await library.saveVideoToPhotos(url)
            exportState = exportState.saveSucceeded()
        } catch {
            exportState = exportState.failed(
                (error as? LocalizedError)?.errorDescription ?? "Couldn't save to Photos.")
        }
    }

    /// **Overwrite the original** video in Photos with the edited render (reversible in Photos).
    /// Destructive — the view confirms before calling this.
    func overwriteOriginal() async {
        guard let url = exportState.exportedURL else { return }
        exportState = exportState.beginningSave()
        do {
            try await library.overwriteVideoAsset(localIdentifier: edit.localIdentifier, with: url)
            exportState = exportState.saveSucceeded()
        } catch {
            exportState = exportState.failed(
                (error as? LocalizedError)?.errorDescription ?? "Couldn't overwrite the original.")
        }
    }

    // MARK: - Heart-rate chart overlay (preview = SwiftUI layer; export = Core Animation)

    /// The clip's output duration (trimmed span ÷ speed) — the HR chart maps over this.
    var outputDuration: Double {
        ClipEditGeometry.scaledDuration(sourceDuration: max(0, effectiveTrimEnd - edit.trimStart), speed: edit.speed)
    }

    /// Set the HR samples for this clip's capture window (the view slices them from the session).
    func setHRSamples(_ samples: [HRPoint]) { hrSamples = samples }

    /// Set the profile/session bounds the configurable overlays need (prompt 28).
    func setOverlayContext(maxHR: Double?, restHR: Double?, kcal: Double?, hrv: HRVMetrics) {
        hrMaxHR = maxHR; hrRestHR = restHR; hrKcal = kcal; hrHRV = hrv
    }

    /// The pure value resolver over this clip's window — feeds both the export and the live preview.
    var overlayValues: HROverlayValues {
        HROverlayValues(samples: hrSamples, durationSec: outputDuration,
                        maxHR: hrMaxHR, restHR: hrRestHR, kcal: hrKcal, hrv: hrHRV)
    }
    private func resolvedOverlayElements() -> [ResolvedHROverlay] {
        guard let els = edit.hrOverlay?.elements, !els.isEmpty else { return [] }
        return overlayValues.resolve(els)
    }

    // MARK: - Configurable HR/fitness overlay elements (prompt 28)

    /// The metrics with usable data right now (so the builder only offers what will actually show).
    var availableOverlayMetrics: [HROverlayMetric] {
        let v = overlayValues
        return HROverlayMetric.allCases.filter { m in
            v.staticValue(m, fallbackHex: "#FFFFFF") != nil
                || v.live(m, atFraction: 0.5, fallbackHex: "#FFFFFF") != nil
        }
    }
    var overlayElements: [HROverlayElement] { edit.hrOverlay?.elements ?? [] }

    /// Add an overlay element for a metric (creating the overlay container if needed; the chart stays
    /// off unless the user turns it on, so "add a number" doesn't force the chart line on).
    func addOverlayElement(_ metric: HROverlayMetric) {
        var config = edit.hrOverlay ?? HROverlayConfig(normalizedX: 0.5, normalizedY: 0.80, scale: 0.86,
                                                       colorHex: "#FF3B30", showBPM: false,
                                                       zoneColored: false, showChart: false)
        // Stagger new badges so they don't stack exactly on top of each other.
        let y = 0.12 + Double(config.elements.count) * 0.08
        config.elements.append(HROverlayElement(metric: metric, normalizedX: 0.5,
                                                normalizedY: min(0.9, y)))
        updateHROverlay(config)
    }
    func removeOverlayElement(_ id: UUID) {
        guard var c = edit.hrOverlay else { return }
        c.elements.removeAll { $0.id == id }
        updateHROverlay(c)
    }
    func setElementLive(_ id: UUID, _ live: Bool) { mutateElement(id) { $0.live = live } }
    func setElementAnimated(_ id: UUID, _ animated: Bool) { mutateElement(id) { $0.animated = animated } }
    func setElementColor(_ id: UUID, hex: String) { mutateElement(id) { $0.colorHex = hex } }
    func setElementPosition(_ id: UUID, _ p: CGPoint) {
        mutateElement(id) { $0.position = CGPoint(x: min(max(p.x, 0), 1), y: min(max(p.y, 0), 1)) }
    }
    private func mutateElement(_ id: UUID, _ change: (inout HROverlayElement) -> Void) {
        guard var c = edit.hrOverlay, let i = c.elements.firstIndex(where: { $0.id == id }) else { return }
        change(&c.elements[i]); updateHROverlay(c)
    }
    /// Toggle the chart line independently of the number/badge elements.
    func setShowChart(_ show: Bool) {
        var c = edit.hrOverlay ?? .default
        c.showChart = show; updateHROverlay(c)
    }

    func toggleHROverlay() { edit.hrOverlay = edit.hrOverlay == nil ? .default : nil; persistHRChange() }
    func updateHROverlay(_ config: HROverlayConfig) { edit.hrOverlay = config; persistHRChange() }
    func setHRPosition(_ normalized: CGPoint) {
        guard var c = edit.hrOverlay else { return }
        c.position = CGPoint(x: min(max(normalized.x, 0), 1), y: min(max(normalized.y, 0), 1))
        updateHROverlay(c)
    }
    func setHRScale(_ scale: Double) {
        guard var c = edit.hrOverlay else { return }
        c.scale = min(1, max(0.3, scale)); updateHROverlay(c)
    }

    /// HR config isn't in the preview composition (it's a SwiftUI overlay), so persist WITHOUT a
    /// player rebuild — but invalidate any prior export (the rendered file no longer matches).
    private func persistHRChange() {
        edit.updatedAt = .now
        save()
        if !exportState.isBusy { exportState = .idle }
    }

    // MARK: - Persist + invalidate

    private func commit() {
        edit.updatedAt = .now
        save()
        // A new edit invalidates any prior export (the rendered file no longer matches).
        if !exportState.isBusy { exportState = .idle }
        Task { await rebuild() }
    }
}
