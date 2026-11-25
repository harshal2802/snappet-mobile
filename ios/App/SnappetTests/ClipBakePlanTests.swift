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

    /// The amount the offset moves by is the earliest footage the bake kept, read from the
    /// bake's time map (prompt 305; `earliestTrimStart` is gone). Parts of other assets are not
    /// in the bake.
    func testTheOffsetMovesToTheEarliestKeptFootage() {
        let parts = [tclip(local: "A", order: 1, trimStart: 20),
                     tclip(local: "A", order: 0, trimStart: 8, trimEnd: 12)]
        let map = ClipBakePlan.timeMap(parts: parts,
                                       sourceDurations: Dictionary(uniqueKeysWithValues: parts.map { ($0.id, 60.0) }),
                                       transitions: [])
        XCTAssertEqual(map?.earliestSourceSec, 8)
        XCTAssertEqual(ClipBakePlan.replacedMediaUpdate(oldOffsetSec: 100, renderedDurationSec: 44,
                                                        timeMap: map).offsetSec, 108)
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

    /// The composer mixes the added music into every render (prompt 300), so a whole-project bake
    /// removes it whatever else the project has: a transition, a cut, a filter, a
    /// picture-in-picture.
    func testFlattenRemovesMusicWithAnyCombination() {
        let a1 = tclip(local: "A", order: 0, trimEnd: 10)
        let a2 = tclip(local: "A", order: 1, trimStart: 20)
        var s = snap([a1, a2])
        s.audioTracks = [AudioTrack(kind: .music, sourceRef: "m.m4a")]
        s.transitions = [StudioTransition(afterClipID: a1.id, kind: .dissolve)]
        XCTAssertTrue(ClipBakePlan.flattened(s, target: "A").audioTracks.isEmpty)
        var cut = s
        cut.transitions = [StudioTransition(afterClipID: a1.id, kind: .none)]
        XCTAssertTrue(ClipBakePlan.flattened(cut, target: "A").audioTracks.isEmpty)
        var pip = s
        pip.overlays = [OverlayItem(kind: .video, content: "A")]
        XCTAssertTrue(ClipBakePlan.flattened(pip, target: "A").audioTracks.isEmpty)
        // The clip's own audio entry is not added music and stays.
        var original = s
        original.audioTracks.append(AudioTrack(kind: .original, sourceRef: "A"))
        XCTAssertEqual(ClipBakePlan.flattened(original, target: "A").audioTracks.map(\.kind), [.original])
    }

    /// A target that is not in the project changes nothing.
    func testFlattenWithNoPartsIsANoOp() {
        var s = snap([tclip(local: "B")])
        s.hrOverlay = tile
        XCTAssertEqual(ClipBakePlan.flattened(s, target: "A"), s)
    }

    // MARK: A bake does not make a clip look deleted (prompt 296)

    /// Merging split parts and re-pointing the asset keep the surviving clip's media id and leave
    /// the record of deleted clips as it was — so the next open neither adds the baked clip a
    /// second time nor brings the deleted one back.
    func testFlattenKeepsTheDeletedClipRecordAndTheSurvivingMediaID() {
        let mediaA = UUID(), deleted = UUID()
        var a1 = tclip(local: "A", order: 0, trimEnd: 10)
        var a2 = tclip(local: "A", order: 1, trimStart: 20)
        a1.sessionMediaID = mediaA
        a2.sessionMediaID = mediaA
        let b = tclip(local: "B", order: 2)
        var s = snap([a1, a2, b])
        s.removedMediaIDs = [deleted]

        let out = ClipBakePlan.flattened(s, target: "A", replacedBy: "NEW")
        XCTAssertEqual(out.clips.map(\.sessionMediaID), [mediaA, b.sessionMediaID])
        XCTAssertEqual(out.removedMediaIDs, [deleted])

        let sid = UUID()
        let footage = [(mediaA, "NEW", 0.0), (b.sessionMediaID!, "B", 30.0), (deleted, "D", 60.0)].map {
            SessionMedia(id: $0.0, sessionID: sid, localIdentifier: $0.1, kind: .video, offsetSec: $0.2)
        }
        XCTAssertNil(StudioEntry.reconciled(clips: out.clips, removedMediaIDs: out.removedMediaIDs,
                                            footage: footage, scope: nil),
                     "the next open changes nothing")
        XCTAssertNil(StudioEntry.reconciled(clips: out.clips, removedMediaIDs: out.removedMediaIDs,
                                            footage: footage, scope: [mediaA]))
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

    // MARK: Studio stand-down for baked clips (prompt 295)

    private var tileConfig: HROverlayConfig {
        var cfg = HROverlayConfig.default
        cfg.tile = HRTile.make(template: .hero)
        return cfg
    }

    private struct Shared {
        var s: StudioProjectSnapshot
        var a: TimelineClip, b: TimelineClip
        var tagB: OverlayItem, text: OverlayItem, pip: OverlayItem
        var music: AudioTrack
    }

    /// A project with two clips, one of every project-wide item, and one tag bound to each clip.
    private func sharedProject() -> Shared {
        let a = tclip(local: "A", order: 0, trimEnd: 5)
        let b = tclip(local: "B", order: 1, trimEnd: 5)
        var s = snap([a, b])
        let tagB = OverlayItem(kind: .climbName, content: "Slab", clipID: b.id)
        let text = OverlayItem(kind: .text, content: "Tuesday")
        let pip = OverlayItem(kind: .video, content: "B")
        let music = AudioTrack(kind: .music, sourceRef: "m.m4a")
        s.overlays = [OverlayItem(kind: .climbName, content: "Cave Roof", clipID: a.id), tagB, text, pip]
        s.hrOverlay = tileConfig
        s.baseFrame = StudioFrameRect(centerX: 0.5, centerY: 0.3, width: 0.8, height: 0.5)
        s.audioTracks = [music]
        return Shared(s: s, a: a, b: b, tagB: tagB, text: text, pip: pip, music: music)
    }

    /// A bake of one clip in a session with others records, on that clip, the project-wide items
    /// it kept in the project although they are now in the clip's pixels. The other clip has no
    /// record. A whole-project bake removed those items, so it records nothing.
    func testFlattenRecordsTheKeptItemsThatAreInThePixels() {
        let p = sharedProject()
        let out = ClipBakePlan.flattened(p.s, target: "A")
        XCTAssertEqual(out.clips[0].baked,
                       BakedItems(overlayIDs: BakedItems.sorted([p.text.id, p.pip.id]),
                                  audioTrackIDs: [p.music.id], hrTile: true, baseFrame: true))
        XCTAssertNil(out.clips[1].baked)

        // The render had no heart-rate data to draw: the tile is not claimed.
        let noHR = ClipBakePlan.flattened(p.s, target: "A", hrTileDrawn: false)
        XCTAssertEqual(noHR.clips[0].baked?.hrTile, false)
        XCTAssertEqual(noHR.clips[0].baked?.baseFrame, true)

        // With a transition and no picture-in-picture the music is in the pixels too (prompt 300:
        // one compositor, the music is always mixed).
        var dissolve = p.s
        dissolve.overlays.removeAll { $0.kind == .video }
        dissolve.transitions = [StudioTransition(afterClipID: p.a.id, kind: .dissolve)]
        XCTAssertEqual(ClipBakePlan.flattened(dissolve, target: "A").clips[0].baked?.audioTrackIDs, [p.music.id])

        // Whole project, and a project with nothing project-wide: no record.
        var one = p.s
        one.clips = [p.a]
        XCTAssertNil(ClipBakePlan.flattened(one, target: "A").clips[0].baked)
        XCTAssertNil(ClipBakePlan.flattened(snap([p.a, p.b]), target: "A").clips[0].baked)
    }

    /// "Edit this clip" on the baked clip: exactly the recorded items are left out of the snapshot
    /// to render. A text, a tag and a music track added after the bake are drawn.
    func testStandDownHidesOnlyWhatTheBakeRecorded() {
        let p = sharedProject()
        var after = ClipBakePlan.flattened(p.s, target: "A")
        let bakedA = after.clips[0]
        let newText = OverlayItem(kind: .text, content: "Sent!")
        let newTag = OverlayItem(kind: .climbName, content: "Cave Roof", clipID: bakedA.id)
        let newMusic = AudioTrack(kind: .music, sourceRef: "n.m4a")
        after.overlays += [newText, newTag]
        after.audioTracks.append(newMusic)

        var scoped = after
        scoped.clips = [bakedA]
        scoped.overlays.removeAll { $0.id == p.tagB.id }        // what the scope filter leaves
        let out = ClipBakePlan.standingDown(scoped, visible: [bakedA])
        XCTAssertEqual(out.overlays.map(\.id), [newText.id, newTag.id])
        XCTAssertEqual(out.audioTracks.map(\.id), [newMusic.id])
        XCTAssertNil(out.hrOverlay)
        XCTAssertNil(out.baseFrame)
        XCTAssertEqual(out.clips, [bakedA])
        // Nothing is removed from the project the other clips use.
        XCTAssertEqual(scoped.overlays.count, 4)
        XCTAssertNotNil(scoped.hrOverlay)

        // The other clip's scope, an empty timeline, and a clip with no record: unchanged.
        XCTAssertEqual(ClipBakePlan.standingDown(after, visible: [p.b]), after)
        XCTAssertEqual(ClipBakePlan.standingDown(after, visible: []), after)
        XCTAssertEqual(ClipBakePlan.standingDown(p.s, visible: [p.a]), p.s)
    }

    /// After a whole-project bake nothing is recorded, so everything added afterwards is drawn —
    /// including a new HR tile and a new base frame.
    func testNothingIsHiddenAfterAWholeProjectBake() {
        var one = sharedProject().s
        one.clips = [one.clips[0]]
        var after = ClipBakePlan.flattened(one, target: "A")
        after.overlays = [OverlayItem(kind: .text, content: "Sent!")]
        after.hrOverlay = tileConfig
        after.baseFrame = .half
        after.audioTracks = [AudioTrack(kind: .music, sourceRef: "n.m4a")]
        XCTAssertEqual(ClipBakePlan.standingDown(after, visible: after.clips), after)
        XCTAssertFalse(ClipBakePlan.hidesHRTile(over: after.clips[0]))
        XCTAssertTrue(ClipBakePlan.allowsSessionWideTile(visible: after.clips))
    }

    /// A timeline with a baked and an unbaked clip keeps the project-wide items (they span the
    /// whole output). The HR tile is held back over the clip that has one in its pixels, and the
    /// session-wide tile is refused. Two baked clips hide only what both recorded.
    func testMixedTimelineHoldsBackOnlyTheHRTilePerClip() {
        let p = sharedProject()
        let after = ClipBakePlan.flattened(p.s, target: "A")
        let bakedA = after.clips[0]
        XCTAssertEqual(ClipBakePlan.standingDown(after, visible: after.clips), after)
        XCTAssertTrue(ClipBakePlan.hidesHRTile(over: bakedA))
        XCTAssertFalse(ClipBakePlan.hidesHRTile(over: p.b))
        XCTAssertFalse(ClipBakePlan.hidesHRTile(over: nil))
        XCTAssertFalse(ClipBakePlan.allowsSessionWideTile(visible: after.clips))
        XCTAssertTrue(ClipBakePlan.allowsSessionWideTile(visible: [p.b]))
        let photo = tclip(local: "P", photo: true, order: 2)
        XCTAssertTrue(ClipBakePlan.bakedInEveryClip([bakedA, photo]).isEmpty)

        // B is baked later, after a second text was added: A's pixels do not have that text.
        var later = after
        let second = OverlayItem(kind: .text, content: "Sent!")
        later.overlays.append(second)
        let both = ClipBakePlan.flattened(later, target: "B")
        XCTAssertEqual(both.clips[1].baked?.overlayIDs.contains(second.id), true)
        let out = ClipBakePlan.standingDown(both, visible: both.clips)
        XCTAssertEqual(out.overlays.map(\.id), [second.id])
        XCTAssertNil(out.hrOverlay)
        XCTAssertTrue(out.audioTracks.isEmpty)
    }

    /// A second bake of the same clip adds to its record, split parts carry it into the merged
    /// clip, and an item that left the project leaves the record.
    func testASecondBakeAddsToTheRecord() {
        let p = sharedProject()
        var after = ClipBakePlan.flattened(p.s, target: "A")
        let first = after.clips[0].baked
        XCTAssertEqual(ClipBakePlan.neutralizedClips(after.clips, localIdentifier: "A")[0].baked, first)

        // Split the baked clip (both parts carry the record), add a text, remove the HR tile.
        var part2 = after.clips[0]
        part2.id = UUID()
        part2.order = 1
        after.clips[1].order = 2
        after.clips.insert(part2, at: 1)
        let newText = OverlayItem(kind: .text, content: "Sent!")
        after.overlays.append(newText)
        after.hrOverlay = nil

        let again = ClipBakePlan.flattened(after, target: "A", replacedBy: "NEW")
        XCTAssertEqual(again.clips.map(\.localIdentifier), ["NEW", "B"])
        let record = again.clips[0].baked
        XCTAssertEqual(record?.overlayIDs, BakedItems.sorted([p.text.id, p.pip.id, newText.id]))
        XCTAssertEqual(record?.audioTrackIDs, [p.music.id])
        XCTAssertEqual(record?.hrTile, false)       // no tile in the project any more
        XCTAssertEqual(record?.baseFrame, true)
    }

    /// Photos reverted the asset: its clips lose the record, by media row or by asset identifier.
    func testAPhotosRevertClearsTheRecord() {
        let p = sharedProject()
        let after = ClipBakePlan.flattened(ClipBakePlan.flattened(p.s, target: "A"), target: "B")
        XCTAssertNotNil(after.clips[0].baked)
        XCTAssertNotNil(after.clips[1].baked)
        let byRow = ClipBakePlan.clearingBakeRecords(after, mediaIDs: [p.a.sessionMediaID!],
                                                     localIdentifiers: [])
        XCTAssertNil(byRow.clips[0].baked)
        XCTAssertNotNil(byRow.clips[1].baked)
        let byAsset = ClipBakePlan.clearingBakeRecords(after, mediaIDs: [], localIdentifiers: ["B"])
        XCTAssertNotNil(byAsset.clips[0].baked)
        XCTAssertNil(byAsset.clips[1].baked)
        XCTAssertEqual(ClipBakePlan.clearingBakeRecords(after, mediaIDs: [], localIdentifiers: []), after)
        XCTAssertEqual(ClipBakePlan.standingDown(byRow, visible: [byRow.clips[0]]), byRow)
    }

    /// The record is an optional field: a clip stored before it existed has no key and decodes.
    func testAClipStoredBeforeTheRecordStillDecodes() throws {
        let old = tclip(local: "A")
        let json = try JSONEncoder().encode(old)
        XCTAssertFalse(String(decoding: json, as: UTF8.self).contains("\"baked\""))
        XCTAssertNil(try JSONDecoder().decode(TimelineClip.self, from: json).baked)

        var baked = old
        baked.baked = BakedItems(overlayIDs: [UUID()], audioTrackIDs: [UUID()], hrTile: true)
        let back = try JSONDecoder().decode(TimelineClip.self, from: JSONEncoder().encode(baked))
        XCTAssertEqual(back, baked)
    }

    /// The view model applies the rule to what the canvas and the overlay lane show, per scope.
    /// The stored project keeps every item, and a text added after the bake is shown.
    @MainActor
    func testTheEditorHidesOnlyTheBakedItemsInTheBakedClipsScope() throws {
        let container = try ModelContainer(
            for: Schema(SnappetSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = container.mainContext
        let a = tclip(local: "A", order: 0, trimEnd: 5)
        let b = tclip(local: "B", order: 1, trimEnd: 5)
        let project = StudioProject(sessionID: UUID(), title: "Session")
        project.clips = [a, b]
        context.insert(project)

        // The whole session: add one of each item the canvas draws, then bake clip A.
        let before = StudioEditorViewModel(project: project, context: context)
        before.addText("Tuesday")
        before.toggleHROverlay()
        before.toggleBaseFrame()
        XCTAssertNotNil(before.canvasHRTile)
        ClipBakePlan.flattened(StudioProjectSnapshot(project), target: "A").apply(to: project)

        let all = StudioEditorViewModel(project: project, context: context)
        XCTAssertEqual(all.canvasOverlays.map(\.content), ["Tuesday"])
        XCTAssertNotNil(all.baseFrame)          // a mixed timeline keeps the project-wide items

        // "Edit this clip" on the other clip: everything is drawn.
        let otherScope = StudioEditorViewModel(project: project, context: context,
                                               visibleClipMediaIDs: [b.sessionMediaID!])
        XCTAssertEqual(otherScope.canvasOverlays.map(\.content), ["Tuesday"])
        XCTAssertNotNil(otherScope.baseFrame)
        XCTAssertNotNil(otherScope.canvasHRTile)

        // "Edit this clip" on the baked clip: what the bake rendered is not drawn again.
        let bakedScope = StudioEditorViewModel(project: project, context: context,
                                               visibleClipMediaIDs: [a.sessionMediaID!])
        XCTAssertTrue(bakedScope.canvasOverlays.isEmpty)
        XCTAssertTrue(bakedScope.timelineOverlays.isEmpty)
        XCTAssertNil(bakedScope.baseFrame)
        XCTAssertNil(bakedScope.canvasHRTile)
        XCTAssertNotNil(bakedScope.hrTile)      // the builder still shows the stored tile
        XCTAssertTrue(bakedScope.baseFramed)
        // A text added after the bake is drawn.
        bakedScope.addText("Sent!")
        XCTAssertEqual(bakedScope.canvasOverlays.map(\.content), ["Sent!"])
        XCTAssertEqual(bakedScope.timelineOverlays.map(\.content), ["Sent!"])

        // Nothing was removed from the stored project.
        XCTAssertEqual(project.overlays.map(\.content), ["Tuesday", "Sent!"])
        XCTAssertNotNil(project.hrOverlay)
        XCTAssertNotNil(project.baseFrame)
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

    // MARK: "Save to original" keeps the offset (prompt 303)

    /// The recorded length becomes the rendered one; the capture offset does not move (Photos can
    /// bring the original back). An unreadable rendered length keeps the recorded one.
    func testSaveToOriginalRecordsTheRenderedLengthAndKeepsTheOffset() {
        let update = ClipBakePlan.revertibleMediaUpdate(oldOffsetSec: 100, oldDurationSec: 60,
                                                        renderedDurationSec: 10)
        XCTAssertEqual(update.offsetSec, 100)
        XCTAssertEqual(update.durationSec, 10)
        for unreadable in [nil, 0, -1, Double.nan] as [Double?] {
            XCTAssertEqual(ClipBakePlan.revertibleMediaUpdate(oldOffsetSec: 100, oldDurationSec: 60,
                                                              renderedDurationSec: unreadable).durationSec, 60)
        }
    }

    /// After "Revert to Original" the recorded length is the asset's again.
    func testARevertRecordsTheAssetsLength() {
        XCTAssertEqual(ClipBakePlan.revertedDuration(recorded: 10, asset: 60), 60)
        XCTAssertEqual(ClipBakePlan.revertedDuration(recorded: 10, asset: nil), 10)
        XCTAssertEqual(ClipBakePlan.revertedDuration(recorded: 10, asset: 0), 10)
        XCTAssertNil(ClipBakePlan.revertedDuration(recorded: nil, asset: nil))
    }
}
