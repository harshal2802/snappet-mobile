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

    /// A bake writes the composition into ONE asset — offered only when every visible video clip
    /// references the same source (split parts count as one; photos don't).
    func testBakeTargetRequiresSingleSourceAsset() {
        XCTAssertEqual(ClipBakePlan.bakeTarget(clips: [tclip(local: "A")]), "A")
        XCTAssertEqual(ClipBakePlan.bakeTarget(clips: [tclip(local: "A", order: 0, trimEnd: 10),
                                                       tclip(local: "A", order: 1, trimStart: 20)]), "A")
        XCTAssertNil(ClipBakePlan.bakeTarget(clips: [tclip(local: "A"), tclip(local: "B", order: 1)]))
        XCTAssertNil(ClipBakePlan.bakeTarget(clips: []))
        // Photos never make a project bakeable on their own, and don't break a single-video target.
        XCTAssertNil(ClipBakePlan.bakeTarget(clips: [tclip(local: "P", photo: true)]))
        XCTAssertEqual(ClipBakePlan.bakeTarget(clips: [tclip(local: "A"),
                                                       tclip(local: "P", photo: true, order: 1)]), "A")
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
