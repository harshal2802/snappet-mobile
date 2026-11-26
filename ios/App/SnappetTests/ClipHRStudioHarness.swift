import XCTest
import SwiftData
@testable import Snappet

/// A running Studio view model over one clip of a made-up session, for the heart-rate tests of
/// prompt 309: an in-memory store, no Photos, no player. The clip's row is what a real session
/// would hold (offset, length, the map of a bake), and the Studio is opened on it as "Edit this
/// clip" opens it.
@MainActor
struct ClipHRStudioHarness {

    private final class Availability: StudioMediaAvailabilityChecking, @unchecked Sendable {
        func statuses(for localIdentifiers: [String]) async -> [String: StudioAssetStatus] {
            Dictionary(uniqueKeysWithValues: localIdentifiers.map { ($0, StudioAssetStatus.available) })
        }
        func download(localIdentifier: String,
                      progress: @escaping @MainActor @Sendable (Double) -> Void) async throws {}
    }

    let vm: StudioEditorViewModel
    let clipID: UUID
    let media: SessionMedia
    /// Kept alive for as long as the view model is used.
    let container: ModelContainer

    /// `durationSec` is the length of the video the asset plays now. `leadSec` / `tailSec` /
    /// `scope` are stored on the clip only when given (`nil` = the Studio's defaults).
    static func make(series: [HRPoint], offsetSec: Double, durationSec: Double,
                     timeMap: BakedTimeMap? = nil, trimStart: Double = 0, trimEnd: Double? = nil,
                     leadSec: Double? = nil, tailSec: Double? = nil, scope: HRMetricsScope? = nil,
                     maxHR: Double? = 190, restHR: Double? = 60) async throws -> ClipHRStudioHarness {
        let container = try ModelContainer(
            for: Schema(SnappetSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let session = WorkoutSession(routineName: "HR", startedAt: start,
                                     completedAt: start.addingTimeInterval(series.last?.t ?? 0),
                                     hrSeries: series, maxHR: maxHR, restHR: restHR)
        let media = SessionMedia(sessionID: session.id, localIdentifier: "CLIP-309", kind: .video,
                                 offsetSec: offsetSec, durationSec: durationSec)
        media.bakeTimeMap = timeMap
        let project = StudioProject(sessionID: session.id, title: "HR")
        var clip = TimelineClip(sessionMediaID: media.id, localIdentifier: media.localIdentifier,
                                isPhoto: false, order: 0, trimStart: trimStart, trimEnd: trimEnd)
        clip.hrLeadSec = leadSec
        clip.hrTailSec = tailSec
        clip.hrMetricsScopeRaw = scope?.rawValue
        project.clips = [clip]
        container.mainContext.insert(session)
        container.mainContext.insert(media)
        container.mainContext.insert(project)
        try container.mainContext.save()

        let vm = StudioEditorViewModel(project: project, context: container.mainContext,
                                       visibleClipMediaIDs: nil, availability: Availability())
        vm.bakedAssetProbe = { _ in BakedAssetProbe(hasEditedRendition: nil, currentDuration: nil) }
        vm.sourceDurationLoader = { _ in durationSec }
        await vm.onAppear()
        vm.loadOverlayContext(profile: UserHRProfile.empty)
        vm.toggleHROverlay()
        return ClipHRStudioHarness(vm: vm, clipID: clip.id, media: media, container: container)
    }

    /// The tile's values and the bpm it shows with the playhead `seconds` into the clip.
    func preview(at seconds: Double) -> (values: HROverlayValues, bpm: Double?) {
        vm.seek(to: seconds)
        let tile = vm.previewTile
        return (tile.values, tile.values.bpm(atFraction: tile.fraction))
    }

    /// The tile the export burns, built as the export builds it: the view model's per-clip heart
    /// rate placed on the render plan's clips.
    func exported() -> PlacedClipHR? {
        let canvas = CGSize(width: 90, height: 160)
        let plan = StudioRenderPlan.make(
            clips: vm.clips, sourceDurations: vm.sourceDurations,
            orientedSizes: Dictionary(uniqueKeysWithValues: vm.clips.map { ($0.id, canvas) }),
            canvas: canvas)
        return StudioComposer.placedHR(clips: plan.clips, clipHRByID: vm.clipHRContent()).first
    }
}
