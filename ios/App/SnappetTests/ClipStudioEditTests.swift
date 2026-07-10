import XCTest
@testable import Snappet

/// Unit tests for the feed ⇄ Studio convergence model (prompt 116): the per-clip edit info the feed
/// live-reflects — the kept-trim envelope resolved from a project's timeline clips, and the kept-range
/// validity rule shared by the looper, the fullscreen transport, the poster, and the HR window.
final class ClipStudioEditTests: XCTestCase {

    private func tclip(media: UUID?, local: String = "A", photo: Bool = false, order: Int = 0,
                       trimStart: Double = 0, trimEnd: Double? = nil,
                       lead: Double? = nil, tail: Double? = nil, scope: HRMetricsScope? = nil) -> TimelineClip {
        var c = TimelineClip(sessionMediaID: media, localIdentifier: local, isPhoto: photo,
                             order: order, trimStart: trimStart, trimEnd: trimEnd)
        c.hrLeadSec = lead; c.hrTailSec = tail
        c.hrMetricsScopeRaw = scope?.rawValue
        return c
    }

    // MARK: keptRange — ONE validity rule for playback, poster, and HR window

    func testKeptRangeValidity() {
        // Untrimmed identity.
        XCTAssertNil(ClipStudioEdit().keptRange(rawDurationSec: 40))
        // A plain trim.
        XCTAssertEqual(ClipStudioEdit(trimStart: 8, trimEnd: 31).keptRange(rawDurationSec: 41), 8...31)
        // trimEnd nil = to the natural end; a >0 start alone is still a trim.
        XCTAssertEqual(ClipStudioEdit(trimStart: 8).keptRange(rawDurationSec: 41), 8...41)
        // Clamped into the real duration (stale trims from a since-shortened source).
        XCTAssertEqual(ClipStudioEdit(trimStart: 8, trimEnd: 90).keptRange(rawDurationSec: 41), 8...41)
        // Degenerate (< minKeptSec) → play raw, never loop a blink.
        XCTAssertNil(ClipStudioEdit(trimStart: 8, trimEnd: 8.2).keptRange(rawDurationSec: 41))
        // A trim spanning (effectively) the whole clip is the untrimmed identity.
        XCTAssertNil(ClipStudioEdit(trimStart: 0.005, trimEnd: 40.995).keptRange(rawDurationSec: 41))
        // Unknown duration → raw.
        XCTAssertNil(ClipStudioEdit(trimStart: 8, trimEnd: 31).keptRange(rawDurationSec: 0))
    }

    func testIsTrimmed() {
        XCTAssertFalse(ClipStudioEdit().isTrimmed)
        XCTAssertFalse(ClipStudioEdit(trimStart: 0.005).isTrimmed)   // ~0 start alone isn't a trim
        XCTAssertTrue(ClipStudioEdit(trimStart: 8).isTrimmed)
        XCTAssertTrue(ClipStudioEdit(trimEnd: 31).isTrimmed)
    }

    // MARK: byMedia — resolving a project's timeline into one edit per physical asset

    func testByMediaResolvesTrimAndWindowPerMedia() {
        let mediaA = UUID(), mediaB = UUID()
        let clips = [
            tclip(media: mediaA, trimStart: 8, trimEnd: 31, lead: 0, tail: 45, scope: .clip),
            tclip(media: mediaB, order: 1)   // untrimmed, defaults
        ]
        let out = ClipStudioEdit.byMedia(clips: clips)
        XCTAssertEqual(out[mediaA]?.trimStart, 8)
        XCTAssertEqual(out[mediaA]?.trimEnd, 31)
        XCTAssertEqual(out[mediaA]?.hrLeadSec, 0)
        XCTAssertEqual(out[mediaA]?.hrTailSec, 45)
        XCTAssertEqual(out[mediaA]?.hrMetricsScope, .clip)
        XCTAssertEqual(out[mediaB]?.isTrimmed, false)
        XCTAssertEqual(out[mediaB]?.hrLeadSec, HRClipWindow.defaultLeadSec)   // nil stored → defaults
        XCTAssertEqual(out[mediaB]?.hrMetricsScope, .window)
    }

    /// Split clips (one asset → two timeline clips with adjacent trims) collapse to the kept ENVELOPE;
    /// a part reaching the natural end (nil trimEnd) makes the envelope end nil; the HR window comes
    /// from the earliest part.
    func testByMediaCollapsesSplitClipsToEnvelope() {
        let media = UUID()
        let out = ClipStudioEdit.byMedia(clips: [
            tclip(media: media, order: 1, trimStart: 20, trimEnd: 35, lead: 10),
            tclip(media: media, order: 0, trimStart: 5, trimEnd: 12, lead: 2, tail: 60)
        ])
        XCTAssertEqual(out[media]?.trimStart, 5)
        XCTAssertEqual(out[media]?.trimEnd, 35)
        XCTAssertEqual(out[media]?.hrLeadSec, 2)      // earliest (order 0) part's window
        XCTAssertEqual(out[media]?.hrTailSec, 60)
        let openEnded = ClipStudioEdit.byMedia(clips: [
            tclip(media: media, order: 0, trimStart: 5, trimEnd: 12),
            tclip(media: media, order: 1, trimStart: 20, trimEnd: nil)
        ])
        XCTAssertNil(openEnded[media]?.trimEnd)       // a part reaches the natural end
        XCTAssertEqual(openEnded[media]?.trimStart, 5)
    }

    /// Photos never carry an edit; a clip resolvable by neither media id nor localIdentifier is
    /// skipped; an UNLINKED clip heals via the localIdentifier map (the prompt-115 offset-recovery
    /// policy, applied to the feed).
    func testByMediaSkipsPhotosAndHealsUnlinkedClips() {
        let media = UUID()
        let out = ClipStudioEdit.byMedia(
            clips: [
                tclip(media: nil, local: "asset-1", trimStart: 3, trimEnd: 9),   // unlinked, healable
                tclip(media: nil, local: "unknown"),                             // resolvable by neither
                tclip(media: UUID(), local: "p", photo: true, trimStart: 1)      // photo → skipped
            ],
            mediaIDByLocalID: ["asset-1": media])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[media]?.trimStart, 3)
        XCTAssertEqual(out[media]?.trimEnd, 9)
    }
}
