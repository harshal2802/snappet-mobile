import Foundation
import Observation
import AVFoundation
import Photos
import SwiftData
import HighlightEngine

/// What the reel flow needs from its source. Every reel goes through this one seam (highlights
/// convergence): a **Kilter session** (`.kilterSession`), a **gym / Apple-Watch session**
/// (`.workoutSession`), and the **stitched week** (`.week`) all feed the same
/// auto-generate-then-edit UI (preview / pin / remove / reorder / format / overlay / export /
/// Post to Clips). `makeWorkout` receives the `AppModel` as a parameter so a source can be
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
    /// The session a finished reel can be posted back into the Clips feed under (highlights P2).
    /// `nil` = no Post-to-Clips offer (Save/Share only).
    var postSessionID: UUID? = nil
    /// The posted reel's feed title, e.g. "Push Day — Highlights". Ignored when `postSessionID` is nil.
    var postTitle: String? = nil
    /// `true` = plan TRIMMED highlight windows instead of full-length clips — the Weekly Highlight
    /// Reel's montage style (P4). Session reels keep today's uncapped full-length behavior.
    var trimToHighlights = false

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

    /// Posting the exported reel into the Clips feed (highlights P2) — like `SaveState`, separate
    /// from `State` so a failed post keeps the screen on `.exported` with Retry available.
    enum PostState: Equatable { case idle, posting, posted, failed(String) }

    let source: ReelSource
    private let model: AppModel
    private let library = MediaLibraryService()

    var state: State = .loading
    var saveState: SaveState = .idle
    var postState: PostState = .idle
    /// Export canvas preset (highlights P1). Changing it invalidates the preview so the next
    /// build shows the new framing — preview and export share `makeComposition(renderAspect:)`.
    var format: ReelFormat = .native {
        didSet { if format != oldValue { invalidatePreview() } }
    }
    /// Burn the glass HR scorebug into the export (highlights P1) — the same overlay the Studio
    /// and the feed's Animate path ship. Export-only: the Core-Animation tool can't render in an
    /// in-app AVPlayer, so the preview never shows it either way.
    var overlayEnabled = true
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
    /// Per-clip trims (reel editor redesign): highlight id → user-adjusted window on the
    /// workout timeline, clamped inside the source video (`ReelTrim`). Per-cut state like
    /// pins/order — deliberately NOT persisted; `generate()` clears it.
    private(set) var trims: [String: ClosedRange<Double>] = [:]
    /// Total planned duration of the last successful export — persisted onto the posted
    /// `SessionMedia` row so the feed can label the reel without loading the asset.
    private var exportedDuration: Double?

    /// In-app preview of the CURRENT cut (built from the composition, no export needed).
    /// Invalidated whenever the edit set changes so the next preview reflects edits.
    var previewPlayer: AVPlayer?
    var previewError: String?
    /// Bumped by every preview invalidation — the view's `.task(id:)` hook for AUTO-rebuilding
    /// the preview after any edit (the reel IS the screen; there is no "Preview reel" button).
    private(set) var previewEpoch = 0
    /// The last successfully planned cut — duration + the filmstrip's reel-timeline map.
    private(set) var lastPlan: ReelPlan?
    /// Reel-timeline map for the last plan (current-frame ring, "Play from here").
    private(set) var timelineMap: ReelTimelineMap?

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

    /// Highlights in the reel, minus removed, in manual order when the user set one.
    var keptHighlights: [Highlight] {
        let kept = highlights.filter { !removed.contains($0.id) }
        guard let orderedIds else { return kept }
        let rank = Dictionary(orderedIds.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return kept.sorted { (rank[$0.id] ?? Int.max, $0.atOffset) < (rank[$1.id] ?? Int.max, $1.atOffset) }
    }

    /// Highlights the user removed — surfaced so they can be restored.
    var removedHighlights: [Highlight] { highlights.filter { removed.contains($0.id) } }

    /// The kept cut WITH per-clip trims applied — the one list `buildPreview` and `export`
    /// both plan from, so a dragged trim is exactly what ships (WYSIWYG).
    var plannedHighlights: [Highlight] { ReelTrim.apply(trims, to: keptHighlights) }

    // MARK: per-clip trim (reel editor redesign)

    /// The window this highlight's trim may move within (its source video's span), or `nil`
    /// when it isn't trimmable (photo / missing media).
    func trimBounds(for h: Highlight) -> ClosedRange<Double>? {
        ReelTrim.bounds(for: h, media: workout?.media ?? [])
    }

    /// The highlight's EFFECTIVE window — the user trim when set, else the auto-cut.
    func effectiveWindow(for h: Highlight) -> ClosedRange<Double> {
        trims[h.id] ?? (h.clipStart...max(h.clipStart, h.clipEnd))
    }

    func isTrimmed(_ h: Highlight) -> Bool { trims[h.id] != nil }

    /// Apply a dragged trim (clamped into the source video, ≥ `ReelTrim.minLength`). Setting
    /// a trim identical to the auto-cut clears it, so "trimmed" always means "differs".
    func setTrim(_ proposed: ClosedRange<Double>, for h: Highlight) {
        guard let bounds = trimBounds(for: h) else { return }
        let clamped = ReelTrim.clamp(proposed, bounds: bounds)
        if abs(clamped.lowerBound - h.clipStart) < 0.01, abs(clamped.upperBound - h.clipEnd) < 0.01 {
            trims[h.id] = nil
        } else {
            trims[h.id] = clamped
        }
        pendingSeekID = h.id   // the rebuilt preview resumes AT this clip, not from 0:00
        invalidatePreview()
    }

    /// Return the clip to its auto-cut window.
    func resetTrim(for h: Highlight) {
        guard trims[h.id] != nil else { return }
        trims[h.id] = nil
        pendingSeekID = h.id
        invalidatePreview()
    }

    /// After a trim commit, the preview rebuild should resume at the EDITED clip — replaying
    /// the whole reel from 0:00 made verifying a trim miserable (device feedback). Set by
    /// `setTrim`/`resetTrim`, consumed once by the editor's rebuild task.
    private(set) var pendingSeekID: String?
    func consumePendingSeek() -> String? {
        defer { pendingSeekID = nil }
        return pendingSeekID
    }

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
        postState = .idle
        // A rebuilt cut must not keep showing the discarded cut's player (review fix) or a
        // stale pick footnote/explanation — these reset with the rest of the per-cut state.
        invalidatePreview()
        pickedClipsUnresolved = false
        pickShortfallNote = nil
        removed.removeAll()
        pinnedIds.removeAll()
        orderedIds = nil
        trims.removeAll()
        do {
            let wk = try await source.makeWorkout(model, manualMedia)
            workout = wk
            // Full-length clips (no per-clip trim); the planner is uncapped (AppModel) so nothing is
            // dropped for length — the user didn't want a limit on session videos.
            // Boost the source's achievement windows (Phase 4) when present; empty ⇒ HR-only.
            // Score the footage with Vision (#83 Step 1) — a no-op unless replayed feedback has tuned in
            // a scene weight, so this neither costs nor changes anything until the data earns it.
            let scene = await model.sceneSelector(for: wk)
            // Weekly montage sources (P4) keep the engine's TRIMMED highlight windows so a whole
            // week cuts down to moments; session reels stay full-length + uncapped as before.
            let baseConfig = HighlightConfig.preset(for: wk.activity)
            let res = model.engine(boosting: source.boostWindows, scene: scene)
                .generate(for: wk, config: source.trimToHighlights ? baseConfig : baseConfig.fullLength())
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

    /// Build a player for the CURRENT cut from the composition — no export needed. Plans from
    /// `plannedHighlights` (trims included), and keeps the plan + its timeline map for the
    /// editor chrome (duration line, filmstrip ring, play-from-here).
    func buildPreview(using exporter: ReelExporter = ReelExporter()) async {
        guard let wk = workout else { return }
        previewError = nil
        let plan = model.reelPlan(for: plannedHighlights, media: wk.media,
                                  pinnedIds: pinnedIds, order: orderedIds)
        do {
            let (composition, videoComposition) = try await exporter.makeComposition(
                for: plan, renderAspect: format.aspect)
            let item = AVPlayerItem(asset: composition)
            // Same orientation/fit normalization the export uses, so preview matches the saved reel
            // (and mixed-orientation clips render upright instead of sideways).
            item.videoComposition = videoComposition
            lastPlan = plan
            timelineMap = ReelTimelineMap(plan: plan)
            previewPlayer = AVPlayer(playerItem: item)
        } catch {
            previewPlayer = nil
            previewError = (error as? LocalizedError)?.errorDescription
                ?? "This reel has no video to preview yet."
        }
    }

    /// The live preview scorebug (reel editor redesign): the SAME `.feedClipScorebug` tile the
    /// export burns, over the same whole-session series mapped linearly across the reel — so
    /// the SwiftUI overlay on the preview IS the burn, previewed. `nil` when the HR chip is
    /// off or the session has no HR. (The CA burn itself can't render in an in-app player.)
    var previewHRTile: (tile: HRTile, values: HROverlayValues)? {
        guard overlayEnabled, let wk = workout, !wk.hr.isEmpty, let map = timelineMap,
              map.totalDuration > 0 else { return nil }
        let values = HROverlayValues(samples: wk.hr.map { HRPoint(t: $0.t, bpm: $0.bpm) },
                                     durationSec: map.totalDuration,
                                     maxHR: wk.maxBpm, restHR: wk.restBpm)
        // `resolveTile` is the renderability gate (the same one the burn runs) — the view
        // draws the HRTile itself, exactly like the feed poster does.
        let tile = HRTile.feedClipScorebug(restHR: wk.restBpm)
        guard values.resolveTile(tile) != nil else { return nil }
        return (tile, values)
    }

    private func invalidatePreview() {
        previewPlayer?.pause()
        previewPlayer = nil
        previewError = nil
        lastPlan = nil
        timelineMap = nil
        previewEpoch += 1   // the view's auto-rebuild hook (.task(id:))
    }

    func export(using exporter: ReelExporter = ReelExporter()) async {
        guard let wk = workout, let res = result else { return }
        // Reentrancy guard: a double-tap on Share must not run two exports concurrently
        // (both racing the sweep + the `.exported` landing) — review fix.
        guard state != .exporting else { return }
        state = .exporting
        saveState = .idle
        postState = .idle
        // Trims included — the export ships exactly the cut the preview showed (WYSIWYG).
        let plan = model.reelPlan(for: plannedHighlights, media: wk.media,
                                  pinnedIds: pinnedIds, order: orderedIds)
        do {
            // Burn the glass HR scorebug (highlights P1) — the SAME overlay path the feed's Animate
            // uses (`HROverlayValues` → `feedClipScorebug` → `StudioOverlays.makeAnimationTool`),
            // with the whole session's series across the reel, so every video surface matches.
            let overlay: ReelExporter.HROverlay? = (overlayEnabled && !wk.hr.isEmpty)
                ? ReelExporter.HROverlay(hrSeries: wk.hr.map { HRPoint(t: $0.t, bpm: $0.bpm) },
                                         maxHR: wk.maxBpm, restHR: wk.restBpm)
                : nil
            let url = try await exporter.export(plan, hrOverlay: overlay, renderAspect: format.aspect)
            exportedDuration = plan.totalDuration
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

    // MARK: - Intensity badges (highlights P1)

    /// Peak BPM inside a highlight's EFFECTIVE clip window (the user trim when set — the badge
    /// must describe the footage that ships). `nil` (no HR sample in the window) falls the row
    /// back to a neutral caption.
    func peakBpm(for h: Highlight) -> Double? {
        let window = effectiveWindow(for: h)
        return ReelIntensity.peakBpm(hr: workout?.hr ?? [],
                                     start: window.lowerBound, end: window.upperBound)
    }

    /// The badge's performance-ramp fraction (%HRR) for a highlight's peak.
    func intensityFraction(forPeak peak: Double) -> Double {
        ReelIntensity.fraction(peakBpm: peak, restBpm: workout?.restBpm, maxBpm: workout?.maxBpm)
    }

    // MARK: - Post to Clips (highlights P2)

    /// Whether the payoff screen offers "Post to Clips": the source names a session to post
    /// under (Kilter / gym / weekly sources do; a manual-media one-off may not).
    var canPostToClips: Bool { source.postSessionID != nil }

    /// Post the exported reel into the Clips feed: save the file to Photos (the bytes' one durable
    /// home — same policy as every clip), then insert a reel-marked `SessionMedia` row on the source
    /// session. The feed composes it into its own ✦ REEL post. Posting implies the Photos save, so
    /// `saveState` lands `.saved` too (the Save button collapses to its done state).
    func postToClips() async {
        guard case .exported(let url) = state, postState != .posting else { return }
        guard let sessionID = source.postSessionID,
              let context = model.modelContainer?.mainContext else {
            postState = .failed("This reel has no session to post under.")
            return
        }
        postState = .posting
        do {
            guard let localIdentifier = try await library.saveVideoToPhotos(url) else {
                postState = .failed("Couldn’t save the reel to Photos.")
                return
            }
            saveState = .saved
            // A reel isn't captured during the session — offset 0 is a placement, not a claim; the
            // composer gives reel rows their own post, so it never sorts inside a set's carousel.
            // The burned overlay means the feed plays it raw (no live HR overlay on top).
            let row = SessionMedia(sessionID: sessionID, localIdentifier: localIdentifier,
                                   kind: .video, offsetSec: 0,
                                   durationSec: exportedDuration,
                                   aspectRatio: format.aspect,
                                   addedManually: true, source: .general)
            row.reelTitle = source.postTitle ?? "Highlights"
            context.insert(row)
            try context.save()
            postState = .posted
        } catch {
            postState = .failed((error as? LocalizedError)?.errorDescription
                                ?? "Couldn’t post this reel to Clips.")
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
