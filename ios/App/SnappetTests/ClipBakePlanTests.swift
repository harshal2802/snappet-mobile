import XCTest
import SwiftData
@testable import Snappet

/// Unit tests for the bake lane's pure decisions (prompt 117): when a bake is offered, and how a
/// destructive bake re-points the app's records at the replacement asset. The Photos writes
/// themselves are device-only (`ClipBakeService`).
final class ClipBakePlanTests: XCTestCase {

    private func tclip(local: String, photo: Bool = false, order: Int = 0,
                       trimStart: Double = 0, trimEnd: Double? = nil) -> TimelineClip {
        TimelineClip(sessionMediaID: UUID(), localIdentifier: local, isPhoto: photo,
                     order: order, trimStart: trimStart, trimEnd: trimEnd)
    }

    /// A bake writes the composition into ONE asset — offered only for a VIDEO-ONLY visible timeline
    /// whose clips all reference the same source (split parts count as one), and only when the scope
    /// covers every part of that asset in the full project.
    func testBakeTargetRequiresSingleSourceVideoOnlyCoveredAsset() {
        let a = tclip(local: "A")
        XCTAssertEqual(ClipBakePlan.bakeTarget(visible: [a], all: [a]), "A")
        let split = [tclip(local: "A", order: 0, trimEnd: 10), tclip(local: "A", order: 1, trimStart: 20)]
        XCTAssertEqual(ClipBakePlan.bakeTarget(visible: split, all: split), "A")
        // Multi-asset / empty → no bake.
        XCTAssertNil(ClipBakePlan.bakeTarget(visible: [a, tclip(local: "B", order: 1)],
                                             all: [a, tclip(local: "B", order: 1)]))
        XCTAssertNil(ClipBakePlan.bakeTarget(visible: [], all: []))
        // A photo segment anywhere in the visible timeline → no bake (its pixels have no "original").
        let photo = tclip(local: "P", photo: true, order: 1)
        XCTAssertNil(ClipBakePlan.bakeTarget(visible: [photo], all: [photo]))
        XCTAssertNil(ClipBakePlan.bakeTarget(visible: [a, photo], all: [a, photo]))
        // A scoped studio hiding another part of the SAME asset → no bake (the render wouldn't
        // contain the hidden part's footage, but the re-point would swallow it).
        let hidden = tclip(local: "A", order: 1, trimStart: 20)
        XCTAssertNil(ClipBakePlan.bakeTarget(visible: [a], all: [a, hidden]))
        // A hidden clip of a DIFFERENT asset doesn't block.
        XCTAssertEqual(ClipBakePlan.bakeTarget(visible: [a], all: [a, tclip(local: "B", order: 1)]), "A")
    }

    /// Flattening (the double-apply fix): after a bake the pixels carry the edit, so every baked
    /// per-clip control resets on the target's parts — other clips untouched.
    func testNeutralizedClipsResetBakedEditState() {
        var edited = tclip(local: "A", trimStart: 8, trimEnd: 31)
        edited.speed = 2
        edited.filter = StudioFilter.allCases.first { $0 != .none } ?? .none
        edited.adjust = ClipAdjust(brightness: 0.4, contrast: 1.2, saturation: 0.8)
        edited.cropRect = CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        edited.volume = 0.2
        let other = tclip(local: "B", order: 1, trimStart: 3)
        let out = ClipBakePlan.neutralizedClips([edited, other], localIdentifier: "A")
        XCTAssertEqual(out[0].trimStart, 0)
        XCTAssertNil(out[0].trimEnd)
        XCTAssertEqual(out[0].speed, 1)
        XCTAssertEqual(out[0].filter, .none)
        XCTAssertNil(out[0].adjust)
        XCTAssertEqual(out[0].cropRect, CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertNil(out[0].volume)
        XCTAssertEqual(out[1].trimStart, 3)      // untouched
    }

    /// The replacement asset IS the rendered (trimmed) composition: its capture offset shifts to
    /// where the kept footage started, and its duration becomes the rendered length.
    func testMediaUpdateShiftsOffsetAndDuration() {
        let update = ClipBakePlan.mediaUpdate(oldOffsetSec: 100, earliestTrimStart: 8,
                                              renderedDurationSec: 23.4)
        XCTAssertEqual(update.offsetSec, 108, accuracy: 0.0001)
        XCTAssertEqual(update.durationSec, 23.4)
        // Untrimmed bake: offset unchanged; negative trims never pull the offset backwards.
        XCTAssertEqual(ClipBakePlan.mediaUpdate(oldOffsetSec: 100, earliestTrimStart: 0,
                                                renderedDurationSec: 41).offsetSec, 100)
        XCTAssertEqual(ClipBakePlan.mediaUpdate(oldOffsetSec: 100, earliestTrimStart: -3,
                                                renderedDurationSec: 41).offsetSec, 100)
    }

    func testEarliestTrimStart() {
        let clips = [tclip(local: "A", order: 1, trimStart: 20),
                     tclip(local: "A", order: 0, trimStart: 8, trimEnd: 12),
                     tclip(local: "B", order: 2, trimStart: 1)]
        XCTAssertEqual(ClipBakePlan.earliestTrimStart(clips: clips, localIdentifier: "A"), 8)
        XCTAssertEqual(ClipBakePlan.earliestTrimStart(clips: clips, localIdentifier: "missing"), 0)
    }

    /// Re-pointing swaps the identifier and resets trims (they're in the pixels now) on the target
    /// asset's parts only; other clips are untouched.
    func testRepointedClipsSwapAndResetTrims() {
        let clips = [tclip(local: "A", trimStart: 8, trimEnd: 31),
                     tclip(local: "B", order: 1, trimStart: 2)]
        let out = ClipBakePlan.repointedClips(clips, from: "A", to: "NEW")
        XCTAssertEqual(out[0].localIdentifier, "NEW")
        XCTAssertEqual(out[0].trimStart, 0)
        XCTAssertNil(out[0].trimEnd)
        XCTAssertEqual(out[1].localIdentifier, "B")     // untouched
        XCTAssertEqual(out[1].trimStart, 2)
    }

    // MARK: Flatten (prompt 294)

    private func snap(_ clips: [TimelineClip]) -> StudioProjectSnapshot {
        StudioProjectSnapshot(title: "T", aspectRaw: "portrait9x16", backgroundRaw: "black",
                              clips: clips, transitions: [], overlays: [], audioTracks: [])
    }
    private var tile: HROverlayConfig {
        HROverlayConfig(normalizedX: 0.5, normalizedY: 0.8, scale: 0.4, colorHex: "#FF0000",
                        showBPM: true, zoneColored: false)
    }

    /// The scoped "Edit this clip" bake of one clip in a session with others: only what is bound
    /// to the baked clip leaves. The other clip's tag, the unbound text, the HR tile, the base
    /// frame and the music all stay, because the other clips still use them.
    func testFlattenKeepsWhatBelongsToOtherClips() {
        var a = tclip(local: "A", order: 0, trimStart: 4, trimEnd: 9)
        a.speed = 2
        let b = tclip(local: "B", order: 1, trimStart: 3)
        var s = snap([a, b])
        let tagA = OverlayItem(kind: .climbName, content: "Cave Roof", clipID: a.id)
        let tagB = OverlayItem(kind: .climbName, content: "Slab", clipID: b.id)
        let title = OverlayItem(kind: .text, content: "Tuesday")
        s.overlays = [tagA, tagB, title]
        s.hrOverlay = tile
        s.baseFrame = StudioFrameRect(centerX: 0.5, centerY: 0.3, width: 0.8, height: 0.5)
        s.audioTracks = [AudioTrack(kind: .music, sourceRef: "m.m4a")]

        XCTAssertFalse(ClipBakePlan.coversWholeProject(s, target: "A"))
        let out = ClipBakePlan.flattened(s, target: "A")
        XCTAssertEqual(out.overlays.map(\.id), [tagB.id, title.id])
        XCTAssertEqual(out.hrOverlay, s.hrOverlay)
        XCTAssertEqual(out.baseFrame, s.baseFrame)
        XCTAssertEqual(out.audioTracks, s.audioTracks)
        // The baked clip is neutral; the other clip is untouched.
        XCTAssertEqual(out.clips.count, 2)
        XCTAssertEqual(out.clips[0].id, a.id)
        XCTAssertEqual(out.clips[0].trimStart, 0)
        XCTAssertNil(out.clips[0].trimEnd)
        XCTAssertEqual(out.clips[0].speed, 1)
        XCTAssertEqual(out.clips[1], b)
    }

    /// A bake of the whole project: everything was rendered, so everything project-wide leaves —
    /// including picture-in-picture, music and the base frame, which used to stay and be applied a
    /// second time on the next export.
    func testFlattenOfTheWholeProjectRemovesEverythingRendered() {
        let a = tclip(local: "A", trimStart: 2)
        var s = snap([a])
        s.overlays = [OverlayItem(kind: .text, content: "Hi"),
                      OverlayItem(kind: .video, content: "A"),
                      OverlayItem(kind: .climbName, content: "Cave Roof", clipID: a.id)]
        s.hrOverlay = tile
        s.baseFrame = StudioFrameRect(centerX: 0.5, centerY: 0.3, width: 0.8, height: 0.5)
        s.audioTracks = [AudioTrack(kind: .music, sourceRef: "m.m4a")]

        XCTAssertTrue(ClipBakePlan.coversWholeProject(s, target: "A"))
        let out = ClipBakePlan.flattened(s, target: "A", replacedBy: "NEW")
        XCTAssertTrue(out.overlays.isEmpty)
        XCTAssertNil(out.hrOverlay)
        XCTAssertNil(out.baseFrame)
        XCTAssertTrue(out.audioTracks.isEmpty)
        XCTAssertEqual(out.clips.map(\.localIdentifier), ["NEW"])
        XCTAssertEqual(out.clips[0].trimStart, 0)
    }

    /// Split parts of the baked asset become ONE clip (two neutral parts would each play the whole
    /// baked video), the transition between them leaves, and the transition out of the last part
    /// moves to the merged clip.
    func testFlattenMergesSplitPartsAndTheirTransitions() {
        let a1 = tclip(local: "A", order: 0, trimEnd: 10)
        let a2 = tclip(local: "A", order: 1, trimStart: 20)
        let b = tclip(local: "B", order: 2)
        var s = snap([a2, b, a1])                       // array order is not timeline order
        s.transitions = [StudioTransition(afterClipID: a1.id, kind: .dissolve),
                         StudioTransition(afterClipID: a2.id, kind: .slideLeft),
                         StudioTransition(afterClipID: b.id, kind: .zoomIn)]
        s.overlays = [OverlayItem(kind: .climbName, content: "x", clipID: a2.id)]

        let out = ClipBakePlan.flattened(s, target: "A")
        XCTAssertEqual(out.clips.map(\.id), [a1.id, b.id])
        XCTAssertEqual(out.clips.map(\.order), [0, 1])
        XCTAssertNil(out.clips[0].trimEnd)
        XCTAssertEqual(out.transitions.map(\.afterClipID), [a1.id, b.id])
        XCTAssertEqual(out.transitions.map(\.kind), [.slideLeft, .zoomIn])
        XCTAssertTrue(out.overlays.isEmpty)

        // The whole project is the two parts: no clip follows, so no transition is left.
        var whole = snap([a1, a2])
        whole.transitions = [StudioTransition(afterClipID: a1.id, kind: .dissolve)]
        let flat = ClipBakePlan.flattened(whole, target: "A")
        XCTAssertEqual(flat.clips.map(\.id), [a1.id])
        XCTAssertTrue(flat.transitions.isEmpty)
    }

    /// After "Replace original" in a session with other clips, a picture-in-picture that showed the
    /// replaced asset follows it to the new one instead of pointing at a deleted video.
    func testFlattenRepointsAPictureInPictureOfTheReplacedAsset() {
        var s = snap([tclip(local: "A", order: 0), tclip(local: "B", order: 1)])
        let pipA = OverlayItem(kind: .video, content: "A")
        let pipB = OverlayItem(kind: .video, content: "B")
        s.overlays = [pipA, pipB]
        let out = ClipBakePlan.flattened(s, target: "A", replacedBy: "NEW")
        XCTAssertEqual(out.overlays.map(\.content), ["NEW", "B"])
        XCTAssertEqual(out.clips.map(\.localIdentifier), ["NEW", "B"])
        // A revertible bake keeps the identifier, so nothing is re-pointed.
        XCTAssertEqual(ClipBakePlan.flattened(s, target: "A").overlays, s.overlays)
    }

    /// The composer's transition path does not mix the music, so the file has none and the track
    /// must not be removed from the project.
    func testFlattenKeepsMusicTheRenderDidNotMix() {
        let a1 = tclip(local: "A", order: 0, trimEnd: 10)
        let a2 = tclip(local: "A", order: 1, trimStart: 20)
        var s = snap([a1, a2])
        s.audioTracks = [AudioTrack(kind: .music, sourceRef: "m.m4a")]
        s.transitions = [StudioTransition(afterClipID: a1.id, kind: .dissolve)]
        XCTAssertFalse(ClipBakePlan.rendersMusic(s))
        XCTAssertEqual(ClipBakePlan.flattened(s, target: "A").audioTracks.count, 1)
        // A "cut" is not a transition; a filter or a picture-in-picture forces the single-track
        // path, which does mix the music.
        var cut = s
        cut.transitions = [StudioTransition(afterClipID: a1.id, kind: .none)]
        XCTAssertTrue(ClipBakePlan.rendersMusic(cut))
        var pip = s
        pip.overlays = [OverlayItem(kind: .video, content: "A")]
        XCTAssertTrue(ClipBakePlan.rendersMusic(pip))
        XCTAssertTrue(ClipBakePlan.flattened(pip, target: "A").audioTracks.isEmpty)
    }

    /// A target that is not in the project changes nothing.
    func testFlattenWithNoPartsIsANoOp() {
        var s = snap([tclip(local: "B")])
        s.hrOverlay = tile
        XCTAssertEqual(ClipBakePlan.flattened(s, target: "A"), s)
    }

    // MARK: The project is locked while a bake renders (prompt 294)

    /// Every edit path refuses while a bake is in flight: the bake ends by replacing the project
    /// with a flattened copy of what it rendered, so an edit in between would be lost or reset.
    @MainActor
    func testEditsAreRefusedWhileABakeRenders() throws {
        let container = try ModelContainer(
            for: Schema(SnappetSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let project = StudioProject(sessionID: UUID(), title: "Before")
        let clip = tclip(local: "A")
        project.clips = [clip]
        container.mainContext.insert(project)
        let vm = StudioEditorViewModel(project: project, context: container.mainContext)

        vm.rename("One")                       // an edit before the bake, so there is an undo step
        XCTAssertEqual(vm.title, "One")
        vm.bakeState = .baking
        XCTAssertTrue(vm.isBaking)
        vm.rename("During")
        vm.select(clip.id)
        vm.deleteSelected()
        vm.addPiP(localIdentifier: "A")
        vm.undoEdit()
        XCTAssertEqual(vm.title, "One")
        XCTAssertEqual(vm.clips.map(\.id), [clip.id])
        XCTAssertTrue(vm.overlays.isEmpty)
        XCTAssertEqual(project.title, "One")

        vm.bakeState = .idle                   // the lock ends with the bake
        vm.rename("After")
        XCTAssertEqual(vm.title, "After")
    }

    // MARK: Feed stand-down (the isBaked contract)

    /// A baked clip draws NO live HR overlay (the tile is in the pixels) and never live-reflects an
    /// edit (MediaInput.from strips it) — nothing double-renders.
    func testBakedClipStandsDownInTheFeed() {
        let series = (0...60).map { HRPoint(t: Double($0), bpm: 120) }
        var clip = MediaInput(id: UUID(), kind: "video", offsetSec: 10, durationSec: 30,
                              exerciseId: nil, setIndex: nil, climbUUID: nil, localIdentifier: "a")
        XCTAssertNotNil(ClipHROverlay.make(clip: clip, hrSeries: series, maxHR: 190, restHR: nil))
        clip.isBaked = true
        XCTAssertNil(ClipHROverlay.make(clip: clip, hrSeries: series, maxHR: 190, restHR: nil))
        // Baked ⇒ raw playback regardless of any edit that leaked in.
        clip.edit = ClipStudioEdit(trimStart: 8, trimEnd: 20)
        XCTAssertEqual(ClipHROverlay.playedRange(clip).start, 8)   // edit still read here…
        // …which is why `MediaInput.from` is the gate: it strips the edit for a baked row (verified
        // by the from() contract below via a SessionMedia-shaped fixture in integration tests; the
        // pure guarantee here is the overlay's nil).
    }
}
