import Foundation
import Observation
import AVFoundation
import HighlightEngine

/// Drives the auto-generate-then-edit flow (#60 §B): generate a good reel
/// automatically, then let the user keep/remove/regenerate. Every edit is logged as
/// training data via the engine's feedback sink.
@MainActor
@Observable
final class ReelViewModel {
    enum State: Equatable { case loading, ready, empty, error(String), exporting, exported(URL) }

    let summary: WorkoutSummary
    private let model: AppModel

    var state: State = .loading
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

    init(summary: WorkoutSummary, model: AppModel) {
        self.summary = summary
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

    func isPinned(_ h: Highlight) -> Bool { pinnedIds.contains(h.id) }

    /// Generate the reel. `manualMedia` (from the limited-access picker) overrides
    /// time-window auto-discovery when provided.
    func generate(manualMedia: [MediaItem]? = nil) async {
        state = .loading
        removed.removeAll()
        pinnedIds.removeAll()
        orderedIds = nil
        do {
            let wk = try await model.buildWorkout(summary, manualMedia: manualMedia)
            workout = wk
            let res = model.engine.generate(for: wk)
            result = res
            highlights = res.highlights
            model.engine.logShown(res, workoutId: summary.id.uuidString,
                                   activity: summary.activity, now: Date().timeIntervalSince1970)
            state = res.highlights.isEmpty ? .empty : .ready
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    /// Limited-access fallback: build the reel from hand-picked assets (#60 §C).
    func usePickedMedia(identifiers ids: [String]) async {
        let media = model.media(forIdentifiers: ids, workoutStart: summary.start)
        await generate(manualMedia: media)
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
            let composition = try await exporter.makeComposition(for: plan)
            previewPlayer = AVPlayer(playerItem: AVPlayerItem(asset: composition))
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
        state = .exporting
        // Survivors are positive signal; log them as kept + exported.
        for h in keptHighlights { log(.kept, highlight: h) }
        let plan = model.reelPlan(for: keptHighlights, media: wk.media,
                                  pinnedIds: pinnedIds, order: orderedIds)
        do {
            let url = try await exporter.export(plan)
            for h in keptHighlights { log(.exported, highlight: h) }
            state = .exported(url)
            _ = res
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    private func log(_ action: HighlightFeedbackEvent.Action, highlight h: Highlight?) {
        guard let res = result else { return }
        model.feedback.record(.init(
            workoutId: summary.id.uuidString, activity: summary.activity, action: action,
            atOffset: h?.atOffset, score: h?.score, highlightKind: h?.kind,
            selectorName: res.selectorName, configFingerprint: res.config.fingerprint,
            timestamp: Date().timeIntervalSince1970
        ))
    }
}
