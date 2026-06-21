import Foundation
import SwiftData
import HighlightEngine

// MARK: - Recap Feed — clip export coordinator (F4 Animate · R4)
//
// The real render→Save pipeline behind the "Animate" offer. Mirrors `SessionHighlightViewModel`'s
// generate→export flow: bridge the session snapshot → engine (UNCHANGED) → `ReelPlanner` →
// `ReelExporter.export(hrOverlay:)`, burning the EDITOR's scorebug HR overlay (single source of
// truth), then save to Photos. Records the share intent (append-only `FeedShareEvent`). Never a dead
// button or a crash: Photos-denied still returns `.rendered`, an empty/unrenderable reel is honest.
//
// Non-Sendable SwiftData `@Model`s never cross into the engine/exporter — the caller snapshots the
// session into a plain `Context` (`[HRPoint]` + `[SessionHighlightInput.Clip]` + scalars).

enum ClipExportCoordinator {

    /// A plain-value snapshot of the session the card points at — built on the `@MainActor` by the
    /// view from its `@Model`s, then handed across to the engine/exporter with no SwiftData inside.
    struct Context {
        var hrSeries: [HRPoint]
        var clips: [SessionHighlightInput.Clip]
        var duration: Double
        var maxHR: Double?
        var restHR: Double?
        var clipName: String?
    }

    /// The user-facing result of an Animate run. `Equatable` so the view's state machine + tests can
    /// compare without inspecting the URL contents.
    enum Outcome: Equatable {
        case saved(URL)       // rendered AND written to Photos
        case rendered(URL)    // rendered but not saved (Photos denied) — file is still on disk
        case empty            // nothing to render (no media / no highlights)
        case failed(String)   // render/export error
        case cancelled        // the user cancelled mid-render
    }

    /// Animate is offered only for a climb session that actually has video clips.
    static func canAnimate(_ card: FeedCard) -> Bool {
        if case .climbSession(let p) = card.payload { return p.clipCount > 0 }
        return false
    }

    /// Run the real pipeline: bridge → engine (UNCHANGED) → `ReelPlanner` → `ReelExporter.export`
    /// (with the editor HR overlay) → save to Photos. Records the share intent. Returns the outcome.
    @MainActor
    static func animate(card: FeedCard,
                        app: AppModel,
                        context: Context,
                        in modelContext: ModelContext,
                        exporter: ReelExporter = ReelExporter(),
                        library: MediaLibraryService = MediaLibraryService()) async -> Outcome {
        // 1. Bridge mapping (pure): session snapshot → engine Workout. Kilter climbing presets handle
        // sport/category (pass nil; engine presets cover it).
        let workout = SessionHighlightInput.makeWorkout(
            hrSeries: context.hrSeries, clips: context.clips, duration: context.duration,
            sport: nil, category: nil)
        guard !workout.media.isEmpty else { return .empty }

        // 2. Run the selector pipeline → highlights (the same engine access the studio uses).
        // Use the SAME `.fullLength()` config the flagship reel path (`ReelViewModel`) uses: HR still
        // chooses WHICH clip to feature, but each plays in FULL (no per-clip trim) — matching the
        // uncapped `ReelPlanner(targetDuration: nil)` behind `app.reelPlan`. Without `.fullLength()` the
        // trimmed window is biased earlier by `hrLagSec`+`clipLeadSec` and, for a short clip captured
        // early in the session, collapses to ~0s — the planner then drops it (`dur <= 0`) and the export
        // throws `noVideoSegments`. That broke R4 Animate for any real short PHAsset clip, not just the seed.
        let scene = await app.sceneSelector(for: workout)
        let highlights = app.engine(boosting: [], scene: scene).selector.select(
            workout: workout, config: .preset(for: workout.activity).fullLength())
        guard !highlights.isEmpty else { return .empty }

        // 3. Plan the reel (no pins — the casual one-tap share path keeps the engine's pick).
        let plan = app.reelPlan(for: highlights, media: workout.media, pinnedIds: [])

        if Task.isCancelled { return .cancelled }

        // 4. Render → export, burning the editor's scorebug HR overlay.
        let outcome: Outcome
        do {
            let url = try await exporter.export(
                plan,
                hrOverlay: ReelExporter.HROverlay(hrSeries: context.hrSeries,
                                                  maxHR: context.maxHR,
                                                  restHR: context.restHR,
                                                  clipName: context.clipName))
            if Task.isCancelled { return .cancelled }
            // Save to Photos; a denial is non-fatal — the file is still rendered on disk.
            do {
                try await library.saveVideoToPhotos(url)
                outcome = .saved(url)
            } catch {
                outcome = .rendered(url)
            }
        } catch {
            if Task.isCancelled { return .cancelled }
            return .failed((error as? LocalizedError)?.errorDescription
                           ?? "Couldn't render this clip.")
        }

        // 5. Record the share intent (append-only ShareEvent) on success.
        if !card.contentId.isEmpty {
            modelContext.insert(FeedShareEvent(activityContentId: card.contentId,
                                               channel: ShareTemplateModel.Channel.clip))
            try? modelContext.save()
        }
        return outcome
    }
}
