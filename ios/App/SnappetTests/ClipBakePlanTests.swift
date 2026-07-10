import XCTest
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
