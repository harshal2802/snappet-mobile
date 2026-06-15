import Foundation
import Observation
import AVFoundation
import HighlightEngine

/// Drives B4 highlight generation in `SessionDetailView`: from the session's HR + tagged clips +
/// the user's selection, run the **existing** engine (`AppModel.engine`, UNCHANGED) → `[Highlight]`
/// → `ReelPlanner.plan(…pinnedIds:)` → a `ReelPlan`, then render a previewable reel by **reusing**
/// `ReelExporter` (the same composition the flagship reel preview uses). All logic lives here so
/// the view stays thin (conventions.md "no business logic in views").
///
/// The non-Sendable SwiftData `@Model`s never cross into the engine/exporter: the caller snapshots
/// the session into plain `[HRPoint]` + `[SessionHighlightInput.Clip]` on the `@MainActor`, and the
/// bridge (`SessionHighlightInput`) maps those to engine value types.
@MainActor
@Observable
final class SessionHighlightViewModel {
    enum State: Equatable { case idle, generating, ready, empty, error(String) }

    private(set) var state: State = .idle
    /// In-app preview of the generated reel (built from the composition — no export round-trip).
    private(set) var previewPlayer: AVPlayer?

    /// B5: the export → share / save-to-Photos flow for the generated reel (the rendered `.mp4` is
    /// carried in `.exported` so share + save reuse the single render).
    private(set) var exportState: ExportShareState = .idle

    /// The plan from the most recent successful generation, kept so **Export** can render the same
    /// reel to a file URL via `ReelExporter.export` (the VM already builds a `ReelPlan` to preview).
    private var lastPlan: ReelPlan?

    private let app: AppModel
    private let exporter: ReelExporter
    private let library: MediaLibraryService

    /// All video clips available to generate from (photos are mapped too but only videos are
    /// shown as selectable, since the reel stitch is video-first). Identified by `localIdentifier`.
    let clips: [SessionHighlightInput.Clip]
    private let hrSeries: [HRPoint]
    private let duration: Double
    private let sport: SportTag?
    private let category: ExerciseCategory?
    /// Peak-effort set windows to boost when ranking (fitness-band Phase 4); empty ⇒ HR-only.
    private let boostWindows: [ClosedRange<Double>]

    /// The user's current selection (clip `localIdentifier`s). Default = all video clips (the
    /// casual one-tap path keeps everything; power users deselect). Selected clips become the
    /// engine's budget-exempt `pinnedIds` (the 2026-05-30 pin decision).
    var selectedIds: Set<String>

    init(app: AppModel,
         hrSeries: [HRPoint],
         clips: [SessionHighlightInput.Clip],
         duration: Double,
         sport: SportTag?,
         category: ExerciseCategory?,
         boostWindows: [ClosedRange<Double>] = [],
         exporter: ReelExporter = ReelExporter(),
         library: MediaLibraryService = MediaLibraryService()) {
        self.app = app
        self.hrSeries = hrSeries
        self.clips = clips
        self.duration = duration
        self.sport = sport
        self.category = category
        self.boostWindows = boostWindows
        self.exporter = exporter
        self.library = library
        // Default selection = every video clip (auto-generate-then-edit default).
        self.selectedIds = Set(clips.filter(\.isVideo).map(\.localIdentifier))
    }

    /// Whether there's anything to generate from (gates the entry point in the UI).
    var hasVideo: Bool { clips.contains(where: \.isVideo) }

    func toggle(_ clip: SessionHighlightInput.Clip) {
        if selectedIds.contains(clip.localIdentifier) {
            selectedIds.remove(clip.localIdentifier)
        } else {
            selectedIds.insert(clip.localIdentifier)
        }
    }

    func isSelected(_ clip: SessionHighlightInput.Clip) -> Bool {
        selectedIds.contains(clip.localIdentifier)
    }

    /// Generate the reel: bridge → engine (UNCHANGED) → `ReelPlanner` → render preview.
    func generate() async {
        state = .generating
        previewPlayer = nil
        lastPlan = nil
        exportState = .idle   // a new generation invalidates any prior export

        // 1. Bridge mapping (pure): session → engine Workout; selection → pinned clip ids.
        let workout = SessionHighlightInput.makeWorkout(
            hrSeries: hrSeries, clips: clips, duration: duration,
            sport: sport, category: category)
        let selectedClips = clips.filter { selectedIds.contains($0.localIdentifier) }
        let pinnedClipIds = SessionHighlightInput.pinnedIds(forSelected: selectedClips)

        guard !workout.media.isEmpty else { state = .empty; return }

        // 2. Run the selector pipeline → highlights. The effort-aligned selector boosts peak-effort
        // set windows (Phase 4); empty windows ⇒ HR-only ranking (gated, unchanged). The Vision scene
        // term (#83 Step 1) only enters once replayed feedback has tuned in a scene weight.
        let scene = await app.sceneSelector(for: workout)
        let highlights = app.engine(boosting: boostWindows, scene: scene).selector.select(
            workout: workout, config: .preset(for: workout.activity))
        guard !highlights.isEmpty else { state = .empty; return }

        // The planner pins by *highlight* id; expand the user's selected *clip* ids into the
        // highlight ids whose source media is a selected clip (their picks are budget-exempt).
        let pinnedHighlightIds = Set(
            highlights.filter { pinnedClipIds.contains($0.mediaItemId) }.map(\.id))

        // 3. Plan the reel with the selected clips pinned (reuse AppModel's planner access).
        let plan = app.reelPlan(for: highlights, media: workout.media,
                                pinnedIds: pinnedHighlightIds)

        // 4. Render a previewable reel by REUSING ReelExporter (no reel-stitch reimplementation).
        do {
            let (composition, videoComposition) = try await exporter.makeComposition(for: plan)
            let item = AVPlayerItem(asset: composition)
            item.videoComposition = videoComposition   // orient + fit, matching the exported reel
            previewPlayer = AVPlayer(playerItem: item)
            lastPlan = plan   // keep it so B5 Export can render the same reel to a file URL
            state = .ready
        } catch {
            // On the simulator there's no real video to stitch, so the composition has no
            // renderable segments — surface it as an honest, non-fatal message.
            previewPlayer = nil
            state = .error((error as? LocalizedError)?.errorDescription
                           ?? "Couldn't build a highlight reel from these clips yet.")
        }
    }

    // MARK: - B5: Export → share / save to Photos

    /// Whether the reel has been generated and can be exported (gates the Export action).
    var canExport: Bool { lastPlan != nil && state == .ready }

    /// Render the generated reel to a temp `.mp4` by **reusing** `ReelExporter.export` on the plan
    /// the VM already built, leaving the result in `.exported(url)` so the view can share it or save
    /// it to Photos. On-device only.
    func export() async {
        guard let plan = lastPlan else { return }
        exportState = exportState.beginningExport()
        do {
            let url = try await exporter.export(plan)
            exportState = exportState.exportSucceeded(url)
        } catch {
            exportState = exportState.failed(
                (error as? LocalizedError)?.errorDescription ?? "Couldn't export this reel.")
        }
    }

    /// Save the already-exported reel to the user's Photos library (add-only, on-device).
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
}
