import XCTest
@testable import Snappet

/// Unit tests for **device feedback round 1** (issue #438, prompts 244 / 246): what the recording screen shows
/// (Dim · Camera · Stats), the split review's segmented timeline (layout, time ↔ x), seek targets and scrubbing,
/// the film strip's times, "Split here" at the playhead, and the iCloud / missing load states. No device.
final class RacketVideoScrubTests: XCTestCase {

    private func part(_ kind: RacketPartKind, _ a: Double, _ b: Double, belongs: RacketPartBelongs? = nil) -> RacketVideoPart {
        RacketVideoPart(kind: kind, startSec: a, endSec: b, belongs: belongs)
    }

    // MARK: Recording screen

    func testRecordingOpensOnTheCamera() {
        XCTAssertEqual(RacketRecordingShow.initial, .camera)
        XCTAssertEqual(RacketRecordingShow.allCases.map(\.label), ["Dim", "Camera", "Stats"])
    }

    func testPreviewFollowsTheSwitcherButTheCameraStepAlwaysShowsIt() {
        XCTAssertTrue(RacketRecordingShow.showsPreview(.camera, phase: .recordingMatch))
        XCTAssertFalse(RacketRecordingShow.showsPreview(.dim, phase: .recordingMatch))
        XCTAssertFalse(RacketRecordingShow.showsPreview(.stats, phase: .recordingMatch))
        // The drill's camera step before block 1 is for framing.
        XCTAssertTrue(RacketRecordingShow.showsPreview(.stats, phase: .ready))
        XCTAssertTrue(RacketRecordingShow.showsPreview(.dim, phase: .ready))
        XCTAssertFalse(RacketRecordingShow.showsPreview(.camera, phase: .ended(.drillReview)))
        XCTAssertTrue(RacketRecordingShow.showsPreview(.camera, phase: .block(0, startedAt: .now)))
    }

    func testSwitcherShowsWhileRecordingOnly() {
        XCTAssertTrue(RacketRecordingShow.showsSwitcher(phase: .recordingMatch))
        XCTAssertTrue(RacketRecordingShow.showsSwitcher(phase: .rest(after: 0, endsAt: .now)))
        XCTAssertTrue(RacketRecordingShow.showsSwitcher(phase: .countdown(block: 0, endsAt: .now)))
        XCTAssertFalse(RacketRecordingShow.showsSwitcher(phase: .ready))
        XCTAssertFalse(RacketRecordingShow.showsSwitcher(phase: .ended(.splitPrompt)))
    }

    func testCompactOnlyUnderThePreview() {
        XCTAssertTrue(RacketRecordingShow.compact(.camera, phase: .recordingMatch))
        XCTAssertFalse(RacketRecordingShow.compact(.dim, phase: .recordingMatch), "Dim is TtRecordAll, full size")
        XCTAssertFalse(RacketRecordingShow.compact(.stats, phase: .recordingMatch))
        XCTAssertTrue(RacketRecordingShow.compact(.stats, phase: .ready), "the camera step shows the preview")
        XCTAssertFalse(RacketRecordingShow.compact(.camera, phase: .ended(.drillReview)))
    }

    // MARK: Match numbers (TtRecordAll · LiveStatsOff)

    private let ttRules = RacketLiveRules(format: RacketFormat(sport: .tableTennis, bestOf: 5, pointsTo: nil, superTiebreak: false),
                                          unitIndex: 0)

    func testBigScoreIsTheWatchGameOnceItHasPoints() {
        var live = RacketLiveScore(rules: ttRules)
        XCTAssertEqual(RacketRecordStats.bigScore(live: live, won: 1, lost: 0, unit: .game).value, "1 – 0")
        XCTAssertEqual(RacketRecordStats.bigScore(live: live, won: 1, lost: 0, unit: .game).caption, "Games")
        XCTAssertEqual(RacketRecordStats.bigScore(live: nil, won: 2, lost: 1, unit: .set).caption, "Sets")
        for side in [RacketLiveScore.Side.us, .us, .them, .us, .them, .us, .them] { live.point(side) }
        let big = RacketRecordStats.bigScore(live: live, won: 1, lost: 0, unit: .game)
        XCTAssertEqual(big.value, "4 – 3")
        XCTAssertEqual(big.caption, "Score from Watch")
        XCTAssertEqual(RacketRecordStats.pointsPlayed(live), 7, "LiveStatsOff: 4 – 3 ⇒ 7 points played")
        XCTAssertNil(RacketRecordStats.pointsPlayed(RacketLiveScore(rules: ttRules)))
        XCTAssertNil(RacketRecordStats.pointsPlayed(nil))
    }

    func testGameTimeRunsFromTheLastNewGameMark() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var l = RacketRecordingLog(startedAt: t0)
        XCTAssertEqual(RacketRecordStats.gameSec(l, now: t0.addingTimeInterval(581)), 581)
        l.marks = [.init(kindRaw: RacketRecordingLog.MarkKind.newGame.rawValue, index: nil, startSec: 500, endSec: nil),
                   .init(kindRaw: RacketRecordingLog.MarkKind.moment.rawValue, index: nil, startSec: 560, endSec: nil)]
        XCTAssertEqual(RacketRecordStats.gameSec(l, now: t0.addingTimeInterval(581)), 81)
    }

    func testTagsLine() {
        let s = RacketTagSummary(marked: 7, tagged: 5, longestSec: nil, averageSec: nil, wonUs: 4, wonThem: 3, endings: [])
        XCTAssertEqual(RacketRecordStats.tagsLine(s, sides: ("You", "Alex")), "You 4 · Alex 3")
        XCTAssertEqual(s.sourceLine, "From your tags, 5 of 7")
    }

    // MARK: Segmented timeline

    func testSegmentsTileTheBarColouredByKind() {
        let ps = [part(.warmup, 0, 100), part(.game, 100, 300), part(.unsure, 300, 350),
                  part(.unsure, 350, 380, belongs: .practice), part(.notPlay, 380, 400)]
        let segs = RacketSplitTimeline.layout(ps, total: 400, width: 400, gap: 2, minWidth: 3)
        XCTAssertEqual(segs.map(\.tone), [.grey, .game, .unsure, .grey, .grey])
        XCTAssertEqual(segs.map(\.x), [0, 100, 300, 350, 380])
        XCTAssertEqual(segs.map(\.width), [98, 198, 48, 28, 20], "a gap after each but the last")
        XCTAssertEqual(segs.map(\.index), [0, 1, 2, 3, 4])
    }

    func testATinyPartStaysVisible() {
        let ps = [part(.game, 0, 3995), part(.breakTime, 3995, 4000)]
        let segs = RacketSplitTimeline.layout(ps, total: 4000, width: 300, gap: 2, minWidth: 3)
        XCTAssertEqual(segs[1].width, 3)
    }

    func testTimeAndXRoundTripAndClamp() {
        XCTAssertEqual(RacketSplitTimeline.x(at: 2220, total: 4440, width: 300), 150)
        XCTAssertEqual(RacketSplitTimeline.time(atX: 150, total: 4440, width: 300), 2220)
        XCTAssertEqual(RacketSplitTimeline.x(at: -5, total: 100, width: 300), 0)
        XCTAssertEqual(RacketSplitTimeline.x(at: 500, total: 100, width: 300), 300)
        XCTAssertEqual(RacketSplitTimeline.time(atX: 900, total: 100, width: 300), 100)
        XCTAssertEqual(RacketSplitTimeline.time(atX: 10, total: 100, width: 0), 0)
    }

    func testPartUnderAPosition() {
        let ps = [part(.warmup, 0, 100), part(.game, 100, 300)]
        XCTAssertEqual(RacketSplitTimeline.partIndex(at: 0, in: ps), 0)
        XCTAssertEqual(RacketSplitTimeline.partIndex(at: 100, in: ps), 1)
        XCTAssertEqual(RacketSplitTimeline.partIndex(at: 300, in: ps), 1, "the very end is the last part")
        XCTAssertNil(RacketSplitTimeline.partIndex(at: 301, in: ps))
    }

    // MARK: Seek targets and scrubbing

    func testSeekTargetSkipsAGapAtThePartStart() {
        let sources = [RacketVideoMap.Source(localIdentifier: "a", startSec: 0, endSec: 600),
                       RacketVideoMap.Source(localIdentifier: "b", startSec: 640, endSec: 1240)]
        XCTAssertEqual(RacketScrub.seekTarget(part(.game, 100, 300), sources: sources), 100)
        // The part starts inside the 600–640 interruption: play from where video resumes.
        XCTAssertEqual(RacketScrub.seekTarget(part(.game, 610, 900), sources: sources), 640)
        // No video at all (the stand-in camera): its start.
        XCTAssertEqual(RacketScrub.seekTarget(part(.game, 610, 900), sources: []), 610)
    }

    func testToleranceIsAboutOnePoint() {
        XCTAssertEqual(RacketScrub.tolerance(windowSec: 300, widthPoints: 300), 1)
        XCTAssertEqual(RacketScrub.tolerance(windowSec: 4440, widthPoints: 350), 2, "capped")
        XCTAssertEqual(RacketScrub.tolerance(windowSec: 3, widthPoints: 300), 0.04, "floored")
        XCTAssertEqual(RacketScrub.tolerance(windowSec: 3, widthPoints: 0), 0.5)
    }

    func testSeekOnlyWhenMovedEnough() {
        XCTAssertTrue(RacketScrub.shouldSeek(last: nil, to: 10, tolerance: 1))
        XCTAssertFalse(RacketScrub.shouldSeek(last: 10, to: 10.4, tolerance: 1))
        XCTAssertTrue(RacketScrub.shouldSeek(last: 10, to: 10.5, tolerance: 1))
    }

    func testFilmStripTimesAreTileCentres() {
        XCTAssertEqual(RacketScrub.thumbnailTimes(start: 100, end: 200, count: 4), [112.5, 137.5, 162.5, 187.5])
        XCTAssertEqual(RacketScrub.thumbnailTimes(start: 100, end: 100, count: 4), [])
        XCTAssertEqual(RacketScrub.thumbnailTimes(start: 0, end: 10, count: 0), [])
        XCTAssertEqual(RacketScrub.thumbnailCount(width: 350, height: 56), 4)
        XCTAssertEqual(RacketScrub.thumbnailCount(width: 5000, height: 56), 12)
        XCTAssertEqual(RacketScrub.thumbnailCount(width: 0, height: 56), 1)
    }

    func testSplitHereNeedsThePlayheadInsideThePart() {
        let p = part(.unsure, 3990, 4320)
        XCTAssertEqual(RacketScrub.splitPoint(playhead: 4100, part: p), 4100)
        XCTAssertNil(RacketScrub.splitPoint(playhead: 3990, part: p), "at the start, the first half would be empty")
        XCTAssertNil(RacketScrub.splitPoint(playhead: 4317, part: p), "under 5 s from the end")
        XCTAssertEqual(RacketScrub.splitPoint(playhead: 3995, part: p), 3995)
        XCTAssertNil(RacketScrub.splitPoint(playhead: 5000, part: p))
        // It agrees with the editor: a split at the playhead actually splits.
        let ps = RacketSplitEditor.split([p], id: p.id, at: 4100)
        XCTAssertEqual(ps.map { [$0.startSec, $0.endSec] }, [[3990, 4100], [4100, 4320]])
    }

    // MARK: Loading the original

    func testLoadStates() {
        XCTAssertEqual(RacketVideoLoad.initial(needed: [], found: [], cloudOnly: []), .noVideo)
        XCTAssertEqual(RacketVideoLoad.initial(needed: ["a", "b"], found: [], cloudOnly: []), .missing(count: 2))
        XCTAssertEqual(RacketVideoLoad.initial(needed: ["a", "b"], found: ["a", "b"], cloudOnly: []), .ready(missing: 0))
        XCTAssertEqual(RacketVideoLoad.initial(needed: ["a", "b"], found: ["a"], cloudOnly: []), .ready(missing: 1))
        XCTAssertEqual(RacketVideoLoad.initial(needed: ["a", "b"], found: ["a", "b"], cloudOnly: ["b"]), .downloading(0))
    }

    func testDownloadProgressAveragesTheCloudVideos() {
        XCTAssertEqual(RacketVideoLoad.overall(["a": 0.5], ids: ["a", "b"]), 0.25)
        XCTAssertEqual(RacketVideoLoad.overall(["a": 1, "b": 1.4], ids: ["a", "b"]), 1)
        XCTAssertEqual(RacketVideoLoad.overall([:], ids: []), 1)
    }

    func testLoadLines() {
        XCTAssertNil(RacketVideoLoad.ready(missing: 0).line)
        XCTAssertEqual(RacketVideoLoad.downloading(0.4).line, "Downloading from iCloud… 40 %")
        XCTAssertEqual(RacketVideoLoad.ready(missing: 1).line, "1 part of the original isn’t on this phone; that stretch stays black")
        XCTAssertEqual(RacketVideoLoad.ready(missing: 2).line, "2 parts of the original aren’t on this phone; those stretches stay black")
        XCTAssertEqual(RacketVideoLoad.noVideo.line, "No video saved for this recording")
        XCTAssertTrue(RacketVideoLoad.downloadFailed.canRetry)
        XCTAssertFalse(RacketVideoLoad.missing(count: 1).canRetry)
        XCTAssertTrue(RacketVideoLoad.downloading(0).isCloud)
        XCTAssertFalse(RacketVideoLoad.noVideo.isCloud)
    }
}
