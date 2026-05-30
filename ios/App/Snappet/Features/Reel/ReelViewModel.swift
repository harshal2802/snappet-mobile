import Foundation
import Observation
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

    init(summary: WorkoutSummary, model: AppModel) {
        self.summary = summary
        self.model = model
    }

    var keptHighlights: [Highlight] { highlights.filter { !removed.contains($0.id) } }

    func generate() async {
        state = .loading
        removed.removeAll()
        do {
            let wk = try await model.buildWorkout(summary)
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

    func regenerate() async {
        log(.regenerated, highlight: nil)
        await generate()
    }

    func remove(_ h: Highlight) {
        removed.insert(h.id)
        log(.removed, highlight: h)
    }

    func restore(_ h: Highlight) { removed.remove(h.id) }

    func export(using exporter: ReelExporter = ReelExporter()) async {
        guard let wk = workout, let res = result else { return }
        state = .exporting
        // Survivors are positive signal; log them as kept + exported.
        for h in keptHighlights { log(.kept, highlight: h) }
        let plan = model.reelPlan(for: keptHighlights, media: wk.media)
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
