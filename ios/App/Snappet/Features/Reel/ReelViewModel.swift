import Foundation
import Observation
import AVFoundation
import Photos
import HighlightEngine

/// What the reel flow needs from its source, generalized beyond a HealthKit `WorkoutSummary` so a
/// **Kilter climbing session** can reuse the same auto-generate-then-edit UI (preview / pin / remove
/// / reorder / export). `makeWorkout` receives the `AppModel` as a parameter so a source can be
/// constructed without one in hand (a SwiftUI `View.init` has no environment yet).
struct ReelSource {
    /// Feedback / `logShown` id (e.g. the workout or Kilter-session UUID string).
    let id: String
    let activity: Activity
    /// Navigation title, e.g. "Climbing reel".
    let title: String
    /// Session start — used to offset manually-picked media (limited Photos access).
    let start: Date
    /// Build the engine input. `manualMedia` (from the limited-access picker) overrides
    /// auto-discovery when provided.
    let makeWorkout: @MainActor (_ model: AppModel, _ manualMedia: [MediaItem]?) async throws -> Workout
    /// Achievement windows to boost when ranking highlights (fitness-band Phase 4): sent-climb
    /// windows (Kilter) in seconds from session start. Empty ⇒ pure HR ranking (today's behavior).
    var boostWindows: [ClosedRange<Double>] = []

    /// The flagship workout source: builds via `AppModel.buildWorkout` (HealthKit HR + Photos). The
    /// HealthKit path has no per-set effort data, so it boosts nothing (HR-only) — the WorkoutTracker
    /// peak-effort boost lives in the session-based `SessionHighlightViewModel` path instead.
    static func workout(_ summary: WorkoutSummary) -> ReelSource {
        ReelSource(id: summary.id.uuidString, activity: summary.activity,
                   title: "\(summary.activity.rawValue.capitalized) reel", start: summary.start,
                   makeWorkout: { model, manual in try await model.buildWorkout(summary, manualMedia: manual) })
    }
}

/// Drives the auto-generate-then-edit flow (#60 §B): generate a good reel
/// automatically, then let the user keep/remove/regenerate. Every edit is logged as
/// training data via the engine's feedback sink.
@MainActor
@Observable
final class ReelViewModel {
    /// `.exportFailed` is distinct from `.error` (a failed *build*): the curated edit is still
    /// here, so the screen offers Retry / back-to-edit instead of a terminal wall (issue #72).
    enum State: Equatable { case loading, ready, empty, error(String), exporting, exported(URL), exportFailed(String) }

    /// Saving the exported file to Photos (add-only, `MediaLibraryService`) — separate from
    /// `State` so a failed save doesn't knock the screen out of `.exported`.
    enum SaveState: Equatable { case idle, saving, saved, failed(String) }

    let source: ReelSource
    private let model: AppModel
    private let library = MediaLibraryService()

    var state: State = .loading
    var saveState: SaveState = .idle
    var highlights: [Highlight] = []
    private(set) var workout: Workout?
    private(set) var result: HighlightEngine.Result?
    /// User-removed highlight ids (kept out of the reel; logged as negatives).
    private var removed: Set<String> = []
    /// User-pinned highlight ids — force-included in the reel, budget-exempt (strong
    /// positive signal). Pin/order are app composition state, passed into the planner.
    private(set) var pinnedIds: Set<String> = []
    /// Manual reel order (highlight ids). `nil` = chronological default.
    private var orderedIds: [String]?

    /// In-app preview of the CURRENT cut (built from the composition, no export needed).
    /// Invalidated whenever the edit set changes so the next preview reflects edits.
    var previewPlayer: AVPlayer?
    var previewError: String?

    /// Set when a manual pick resolved to NOTHING (the picks aren't in the Photos selection
    /// Snappet may read): `emptySpec` then explains the cause instead of showing the generic
    /// no-clips copy, so the pick doesn't look like a silent no-op (review fix). Cleared by
    /// the next `generate()`.
    private(set) var pickedClipsUnresolved = false
    /// Honest footnote when SOME picked clips couldn't be resolved — the reel built with the
    /// rest, and the edit list says so. `nil` when the last build dropped nothing.
    private(set) var pickShortfallNote: String?

    init(source: ReelSource, model: AppModel) {
        self.source = source
        self.model = model
    }

    /// Back-compat convenience for the workout path (keeps `ReelView(summary:)` call sites).
    convenience init(summary: WorkoutSummary, model: AppModel) {
        self.init(source: .workout(summary), model: model)
    }

    /// Highlights in the reel, minus removed, in manual order when the user set one.
    var keptHighlights: [Highlight] {
        let kept = highlights.filter { !removed.contains($0.id) }
        guard let orderedIds else { return kept }
        let rank = Dictionary(orderedIds.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return kept.sorted { (rank[$0.id] ?? Int.max, $0.atOffset) < (rank[$1.id] ?? Int.max, $1.atOffset) }
    }

    /// Highlights the user removed — surfaced so they can be restored.
    var removedHighlights: [Highlight] { highlights.filter { removed.contains($0.id) } }

    func isPinned(_ h: Highlight) -> Bool { pinnedIds.contains(h.id) }

    /// Current Photo access as the policy's platform-free mirror — read live (not cached at
    /// bootstrap) so the empty state reflects a Settings change the moment the user returns.
    var photoAccess: ReelFlowPolicy.PhotoAccess {
        switch model.photos.currentStatus {
        case .authorized: return .authorized
        case .limited: return .limited
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    /// The `.empty` surface's spec: the access-shaped policy pick, or the picked-clips
    /// explanation when the last manual pick resolved to nothing (review fix).
    var emptySpec: ReelFlowPolicy.RecoverySpec {
        pickedClipsUnresolved ? ReelFlowPolicy.pickedClipsUnavailableSpec()
                              : ReelFlowPolicy.emptyReelSpec(access: photoAccess)
    }

    /// The warning to confirm a regenerate with, or `nil` when nothing of the user's is lost
    /// (pure decision in `ReelFlowPolicy`). `exportedUnsaved` = called from the success screen
    /// with a cut that hasn't been saved to Photos.
    func regenerateConfirmation(exportedUnsaved: Bool) -> String? {
        ReelFlowPolicy.regenerateConfirmation(
            pinnedCount: pinnedIds.count, removedCount: removed.count,
            hasCustomOrder: orderedIds != nil, exportedUnsaved: exportedUnsaved)
    }

    /// Generate the reel. `manualMedia` (from the limited-access picker) overrides
    /// time-window auto-discovery when provided.
    func generate(manualMedia: [MediaItem]? = nil) async {
        state = .loading
        saveState = .idle
        // A rebuilt cut must not keep showing the discarded cut's player (review fix) or a
        // stale pick footnote/explanation — these reset with the rest of the per-cut state.
        invalidatePreview()
        pickedClipsUnresolved = false
        pickShortfallNote = nil
        removed.removeAll()
        pinnedIds.removeAll()
        orderedIds = nil
        do {
            let wk = try await source.makeWorkout(model, manualMedia)
            workout = wk
            // Full-length clips (no per-clip trim); the planner is uncapped (AppModel) so nothing is
            // dropped for length — the user didn't want a limit on session videos.
            // Boost the source's achievement windows (Phase 4) when present; empty ⇒ HR-only.
            // Score the footage with Vision (#83 Step 1) — a no-op unless replayed feedback has tuned in
            // a scene weight, so this neither costs nor changes anything until the data earns it.
            let scene = await model.sceneSelector(for: wk)
            let res = model.engine(boosting: source.boostWindows, scene: scene)
                .generate(for: wk, config: .preset(for: wk.activity).fullLength())
            result = res
            highlights = res.highlights
            model.engine.logShown(res, workoutId: source.id,
                                   activity: source.activity, now: Date().timeIntervalSince1970)
            state = res.highlights.isEmpty ? .empty : .ready
        } catch PhotoLibraryService.PhotoError.denied {
            // Denied is the no-clips case, not a wall: the `.empty` surface picks the
            // denied-aware spec (Open Settings, no dead-end "Select clips") via `photoAccess`.
            state = .empty
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    /// First-ask path (`.notDetermined`): request Photos access, then build with whatever the
    /// user granted (denied falls back into the denied-aware empty state).
    func requestPhotoAccessAndGenerate() async {
        model.photoAccess = await model.photos.requestAccess()
        await generate()
    }

    /// Manual-pick fallback: build the reel from hand-picked assets (#60 §C). Resolution runs
    /// through the pure `pickedMediaResolution` because `PHAsset.fetchAssets` silently drops
    /// picks the app can't read (e.g. outside a limited grant): all dropped → an explanatory
    /// spec instead of a silent loop back to `.empty`; partially dropped → build with what
    /// resolved and record an honest footnote (review fix).
    func usePickedMedia(identifiers ids: [String]) async {
        let media = model.media(forIdentifiers: ids, workoutStart: source.start)
        switch ReelFlowPolicy.pickedMediaResolution(pickedCount: ids.count, resolvedCount: media.count) {
        case .allDropped:
            pickedClipsUnresolved = true
            state = .empty
        case .proceed(let droppedCount):
            await generate(manualMedia: media)   // clears the note; re-set it for THIS cut below
            pickShortfallNote = ReelFlowPolicy.pickedMediaShortfallNote(droppedCount: droppedCount)
        }
    }

    func regenerate() async {
        log(.regenerated, highlight: nil)
        await generate()
    }

    func remove(_ h: Highlight) {
        removed.insert(h.id)
        pinnedIds.remove(h.id)        // removing overrides a pin
        invalidatePreview()
        log(.removed, highlight: h)
    }

    /// Undo a remove — return the highlight to the kept list.
    func restore(_ h: Highlight) { removed.remove(h.id); invalidatePreview() }

    /// Pin/unpin a highlight. Pinning a removed one restores it. A pin is the
    /// strongest positive training signal (#60 §E) → logged when enabled.
    func togglePin(_ h: Highlight) {
        if pinnedIds.contains(h.id) {
            pinnedIds.remove(h.id)
        } else {
            pinnedIds.insert(h.id)
            removed.remove(h.id)      // pinning implies keep
            log(.pinned, highlight: h)
        }
        invalidatePreview()
    }

    /// Manual reorder of the kept highlights (from the edit list). Persists the new
    /// order and logs it as a (weak) curation signal.
    func move(from offsets: IndexSet, to destination: Int) {
        var ids = keptHighlights.map(\.id)
        ids.move(fromOffsets: offsets, toOffset: destination)
        orderedIds = ids
        invalidatePreview()
        log(.reordered, highlight: nil)
    }

    // MARK: preview (#60 §B — see the cut before you commit)

    /// Build a player for the CURRENT cut from the composition — no export needed.
    func buildPreview(using exporter: ReelExporter = ReelExporter()) async {
        guard let wk = workout else { return }
        previewError = nil
        let plan = model.reelPlan(for: keptHighlights, media: wk.media,
                                  pinnedIds: pinnedIds, order: orderedIds)
        do {
            let (composition, videoComposition) = try await exporter.makeComposition(for: plan)
            let item = AVPlayerItem(asset: composition)
            // Same orientation/fit normalization the export uses, so preview matches the saved reel
            // (and mixed-orientation clips render upright instead of sideways).
            item.videoComposition = videoComposition
            previewPlayer = AVPlayer(playerItem: item)
        } catch {
            previewPlayer = nil
            previewError = (error as? LocalizedError)?.errorDescription
                ?? "This reel has no video to preview yet."
        }
    }

    private func invalidatePreview() {
        previewPlayer?.pause()
        previewPlayer = nil
        previewError = nil
    }

    func export(using exporter: ReelExporter = ReelExporter()) async {
        guard let wk = workout, let res = result else { return }
        // Reentrancy guard: a double-tap on Share must not run two exports concurrently
        // (both racing the sweep + the `.exported` landing) — review fix.
        guard state != .exporting else { return }
        state = .exporting
        saveState = .idle
        let plan = model.reelPlan(for: keptHighlights, media: wk.media,
                                  pinnedIds: pinnedIds, order: orderedIds)
        do {
            let url = try await exporter.export(plan)
            // Survivors are positive signal — kept + exported are logged HERE, after success,
            // so a failed attempt doesn't re-log `.kept` on every retry (review fix): both
            // land exactly once per successful export.
            for h in keptHighlights { log(.kept, highlight: h) }
            for h in keptHighlights { log(.exported, highlight: h) }
            state = .exported(url)
            _ = res
        } catch {
            // NOT `.error`: pins/removals/order are intact, so the failure surface offers
            // Retry (re-export with them) and back-to-edit instead of discarding the work.
            state = .exportFailed(error.localizedDescription)
        }
    }

    /// Leave the export-failed surface without re-exporting — the curated list is unchanged.
    func backToEdit() {
        guard !highlights.isEmpty else { return }
        state = .ready
    }

    /// Save the exported reel into the user's Photos library (add-only — the payoff's durable
    /// home; the on-disk copy in Application Support is just the safety net).
    func saveToPhotos() async {
        guard case .exported(let url) = state, saveState != .saving else { return }
        saveState = .saving
        do {
            try await library.saveVideoToPhotos(url)
            saveState = .saved
        } catch {
            saveState = .failed((error as? LocalizedError)?.errorDescription
                                ?? "Couldn’t save to Photos.")
        }
    }

    private func log(_ action: HighlightFeedbackEvent.Action, highlight h: Highlight?) {
        guard let res = result else { return }
        model.feedback.record(.init(
            workoutId: source.id, activity: source.activity, action: action,
            atOffset: h?.atOffset, score: h?.score, highlightKind: h?.kind,
            selectorName: res.selectorName, configFingerprint: res.config.fingerprint,
            timestamp: Date().timeIntervalSince1970
        ))
    }
}
