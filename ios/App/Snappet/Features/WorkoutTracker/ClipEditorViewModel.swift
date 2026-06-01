import Foundation
import Observation
import AVKit
import CoreGraphics

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
        let plan = EditPlan(edit)   // snapshot on the MainActor; the @Model never crosses actors
        do {
            let (composition, videoComposition) = try await studio.makeComposition(for: plan)
            guard token == buildToken else { return }   // a newer edit superseded this build
            let item = AVPlayerItem(asset: composition)
            item.videoComposition = videoComposition
            previewPlayer?.pause()
            previewPlayer = AVPlayer(playerItem: item)
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
        let plan = EditPlan(edit)   // snapshot on the MainActor; the @Model never crosses actors
        do {
            let url = try await studio.export(plan)
            exportState = exportState.exportSucceeded(url)
        } catch {
            exportState = exportState.failed(
                (error as? LocalizedError)?.errorDescription ?? "Couldn't export this clip.")
        }
    }

    /// Save the already-exported file to the user's Photos library (add-only, on-device).
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

    // MARK: - Persist + invalidate

    private func commit() {
        edit.updatedAt = .now
        save()
        // A new edit invalidates any prior export (the rendered file no longer matches).
        if !exportState.isBusy { exportState = .idle }
        Task { await rebuild() }
    }
}
