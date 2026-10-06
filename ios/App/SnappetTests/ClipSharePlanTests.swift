import XCTest
@testable import Snappet

/// Unit tests for "Share with heart rate" (prompt 160): which share actions a clip offers, and that the
/// burned render reuses the poster's payload over the kept range (WYSIWYG) — no second derivation.
final class ClipSharePlanTests: XCTestCase {

    private let series = (0...40).map { HRPoint(t: Double($0), bpm: 110 + Double($0)) }

    private func clip(kind: String = "video", offset: Double = 10, dur: Double? = 8,
                      edit: ClipStudioEdit? = nil) -> MediaInput {
        MediaInput(id: UUID(), kind: kind, offsetSec: offset, durationSec: dur,
                   exerciseId: nil, setIndex: nil, climbUUID: nil, localIdentifier: "asset", edit: edit)
    }

    private func payload(_ c: MediaInput) -> ClipHROverlay.Payload? {
        ClipHROverlay.make(clip: c, hrSeries: series, maxHR: 190, restHR: 60)
    }

    // MARK: offer

    func testVideoWithHROffersBurnedAndRaw() {
        let c = clip()
        XCTAssertEqual(ClipSharePlan.offer(for: c, payload: payload(c)), .burnedAndRaw)
    }

    func testVideoWithoutHROffersRawOnly() {
        XCTAssertEqual(ClipSharePlan.offer(for: clip(), payload: nil), .raw)
    }

    func testPhotoOffersNothing() {
        XCTAssertEqual(ClipSharePlan.offer(for: clip(kind: "photo", dur: nil), payload: nil), .none)
    }

    /// A reel / baked clip carries its HR in the pixels — its raw share IS the burned share, so no
    /// second (double-drawn) option, even if a stale payload were passed in.
    func testReelAndBakedOfferRawOnly() {
        let plain = clip()
        let p = payload(plain)
        var reel = plain; reel.reelTitle = "Push Day — Highlights"
        var baked = plain; baked.isBaked = true
        XCTAssertEqual(ClipSharePlan.offer(for: reel, payload: p), .raw)
        XCTAssertEqual(ClipSharePlan.offer(for: baked, payload: p), .raw)
    }

    // MARK: plan

    func testPlanBurnsThePosterPayloadOverTheWholeRawClip() throws {
        let c = clip()
        let p = try XCTUnwrap(payload(c))
        let plan = try XCTUnwrap(ClipSharePlan.plan(clip: c, payload: p, title: "Crimp Line",
                                                    detail: "6C · 40°", attemptLabel: "Attempt 2"))
        XCTAssertEqual(plan.localIdentifier, "asset")
        XCTAssertEqual(plan.start, 0)
        XCTAssertEqual(plan.duration, 8, accuracy: 0.0001)
        XCTAssertEqual(plan.hr.startSec, 0)
        XCTAssertEqual(plan.hr.durationSec, 8, accuracy: 0.0001)
        XCTAssertEqual(plan.hr.samples, p.values.samples)                 // the SAME window the poster draws
        XCTAssertEqual(plan.hr.tile, p.values.resolveTile(p.tile))        // the SAME tile, resolved
        XCTAssertEqual(plan.caption, "Crimp Line · 6C · 40° · Attempt 2")
    }

    /// A Studio-trimmed clip shares exactly what the feed PLAYS — the kept range, not the raw clip.
    func testPlanHonoursTheStudioTrim() throws {
        let c = clip(dur: 10, edit: ClipStudioEdit(trimStart: 2, trimEnd: 7))
        let plan = try XCTUnwrap(ClipSharePlan.plan(clip: c, payload: payload(c), title: "Squat",
                                                    detail: "", attemptLabel: nil))
        XCTAssertEqual(plan.start, 2, accuracy: 0.0001)
        XCTAssertEqual(plan.duration, 5, accuracy: 0.0001)
        XCTAssertEqual(plan.hr.durationSec, 5, accuracy: 0.0001)
    }

    func testPlanIsNilForPhotosReelsBakedAndNoHR() {
        let plain = clip()
        let p = payload(plain)
        var reel = plain; reel.reelTitle = "R"
        var baked = plain; baked.isBaked = true
        XCTAssertNil(ClipSharePlan.plan(clip: plain, payload: nil, title: "x", detail: "", attemptLabel: nil))
        XCTAssertNil(ClipSharePlan.plan(clip: reel, payload: p, title: "x", detail: "", attemptLabel: nil))
        XCTAssertNil(ClipSharePlan.plan(clip: baked, payload: p, title: "x", detail: "", attemptLabel: nil))
        XCTAssertNil(ClipSharePlan.plan(clip: clip(kind: "photo", dur: nil), payload: p,
                                        title: "x", detail: "", attemptLabel: nil))
    }

    // MARK: caption

    func testCaptionDropsBlankParts() {
        XCTAssertEqual(ClipSharePlan.caption(title: "Bench", detail: "", attemptLabel: "Set 3"), "Bench · Set 3")
        XCTAssertEqual(ClipSharePlan.caption(title: "  ", detail: "", attemptLabel: nil), nil)
    }

    // MARK: clamped

    /// The stored duration is approximate; the render re-slots the tile to what the asset really holds.
    func testClampShortensToTheAssetAndReslotsTheTile() throws {
        let c = clip()
        let plan = try XCTUnwrap(ClipSharePlan.plan(clip: c, payload: payload(c), title: "x",
                                                    detail: "", attemptLabel: nil))
        let clamped = try XCTUnwrap(ClipSharePlan.clamped(plan, assetDuration: 7.5))
        XCTAssertEqual(clamped.duration, 7.5, accuracy: 0.0001)
        XCTAssertEqual(clamped.hr.durationSec, 7.5, accuracy: 0.0001)
        // A longer asset never extends past the kept range.
        XCTAssertEqual(try XCTUnwrap(ClipSharePlan.clamped(plan, assetDuration: 20)).duration, 8, accuracy: 0.0001)
        // Nothing left after the trim start → no render.
        XCTAssertNil(ClipSharePlan.clamped(plan, assetDuration: 0.05))
    }
}
