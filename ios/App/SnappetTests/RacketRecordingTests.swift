import XCTest
@testable import Snappet

/// Unit tests for the **pure** racket recording core (prompt 244, issue #438 step 1): the per-match / per-drill
/// recording mode, Settings defaults, the storage estimate, and the record-everything state machine — countdown →
/// block → rest → review, match marks, interruptions with resume per mode, end routing (review5 H1) and
/// "Still playing?" (M4). No device, no camera.
final class RacketRecordingTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    private func drill(blocks: Int = 3, blockSec: Int = 300, restSec: Int = 60, autoStart: Bool = true,
                       countdown: Int = 5, still: Int? = 60) -> RacketRecordingMachine {
        let plan = RacketDrillPlan(blocks: blocks, blockSec: blockSec, restSec: restSec, autoStart: autoStart,
                                   countdownSec: countdown, recording: .everything)
        return RacketRecordingMachine(kind: .drill(plan), stillPlayingMinutes: still, now: t0)
    }

    private func match(still: Int? = 60) -> RacketRecordingMachine {
        RacketRecordingMachine(kind: .match, stillPlayingMinutes: still, now: t0)
    }

    // MARK: - Mode labels (review5 M1)

    func testDrillEverythingNeverPromisesASplit() {
        XCTAssertEqual(RacketRecordingMode.everything.label(for: .drill), "Everything, rests included")
        XCTAssertFalse(RacketRecordingMode.everything.helper(for: .drill).localizedCaseInsensitiveContains("split it"))
        XCTAssertTrue(RacketRecordingMode.everything.helper(for: .drill).contains("nothing to split"))
        XCTAssertEqual(RacketRecordingMode.everything.label(for: .match), "Everything, split later")
    }

    func testByUnitLabelFollowsTheSportsUnit() {
        XCTAssertEqual(RacketRecordingMode.byUnit.label(for: .match, unit: .game), "Game by game")
        XCTAssertEqual(RacketRecordingMode.byUnit.label(for: .match, unit: .set), "Set by set")
        XCTAssertEqual(RacketRecordingMode.byUnit.label(for: .drill), "Block by block")
        XCTAssertEqual(RacketRecordingMode.off.label(for: .drill), "Don’t film")
    }

    func testEntityWithoutAModeRecordsByUnit() {
        var ex = SessionExercise(exerciseId: "x", targetSets: 0, targetReps: "", targetRestSeconds: 0, sets: [])
        XCTAssertEqual(ex.racketRecording, .byUnit)
        ex.racketRecordingRaw = RacketRecordingMode.everything.rawValue
        XCTAssertEqual(ex.racketRecording, .everything)
    }

    // MARK: - Settings defaults

    func testDefaultsRoundTripIncludingOff() {
        var d = RacketRecordingDefaults()
        d.matchMode = .everything
        d.drillMode = .off
        d.quality = .uhd4k
        d.stillPlayingByUnitMin = nil
        d.stillPlayingEverythingMin = 90
        let back = RacketRecordingDefaults.load(from: d.encoded)
        XCTAssertEqual(back, d)
        XCTAssertNil(back.stillPlayingByUnitMin, "Off survives a round trip")
    }

    func testDefaultsToleratesMissingKeysAndGarbage() {
        let partial = Data(#"{"matchMode":"everything"}"#.utf8)
        let d = RacketRecordingDefaults.load(from: partial)
        XCTAssertEqual(d.matchMode, .everything)
        XCTAssertEqual(d.drillMode, .byUnit)
        XCTAssertEqual(d.stillPlayingEverythingMin, 60)
        XCTAssertEqual(RacketRecordingDefaults.load(from: Data("nope".utf8)), RacketRecordingDefaults())
        XCTAssertEqual(RacketRecordingDefaults.load(from: nil), RacketRecordingDefaults())
    }

    func testStillPlayingThresholdPerMode() {
        let d = RacketRecordingDefaults()
        XCTAssertEqual(d.stillPlayingMinutes(for: .byUnit), 30)
        XCTAssertEqual(d.stillPlayingMinutes(for: .everything), 60)
        XCTAssertNil(d.stillPlayingMinutes(for: .off))
    }

    func testDrillPlanAppliesAndReadsBack() {
        var ex = SessionExercise(exerciseId: "d", targetSets: 0, targetReps: "", targetRestSeconds: 0, sets: [])
        let plan = RacketDrillPlan(blocks: 4, blockSec: 180, restSec: 90, autoStart: false, countdownSec: 10,
                                   recording: .everything)
        plan.apply(to: &ex)
        XCTAssertEqual(ex.plannedSets, 4)
        XCTAssertEqual(ex.targetRestSeconds, 90)
        XCTAssertEqual(RacketDrillPlan(from: ex, defaults: .init()), plan)
        XCTAssertEqual(plan.summary, "4 blocks × 3:00")
        // By block keeps the legacy nil.
        RacketDrillPlan(recording: .byUnit).apply(to: &ex)
        XCTAssertNil(ex.racketRecordingRaw)
    }

    // MARK: - Storage

    private let hd = RacketCaptureConfig(quality: .hd1080)
    private let uhd = RacketCaptureConfig(quality: .uhd4k)

    func testBitrateFollowsTheCaptureConfig() {
        // Apple's per-minute sizes + ~1 MB/min audio.
        XCTAssertEqual(RacketBitrate.bytesPerSecond(hd) * 60, 61e6, accuracy: 1)
        XCTAssertEqual(RacketBitrate.bytesPerSecond(uhd) * 60, 171e6, accuracy: 1)
        let h264 = RacketCaptureConfig(quality: .hd1080, codec: .h264)
        XCTAssertGreaterThan(RacketBitrate.bytesPerSecond(h264), 2 * RacketBitrate.bytesPerSecond(hd), "H.264 is about twice HEVC")
        let hd60 = RacketCaptureConfig(quality: .hd1080, fps: 60)
        XCTAssertEqual(RacketBitrate.bytesPerSecond(hd60) * 60, 91e6, accuracy: 1)
        let hd45 = RacketCaptureConfig(quality: .hd1080, fps: 45)
        XCTAssertEqual(RacketBitrate.bytesPerSecond(hd45) * 60, 76e6, accuracy: 1, "Between 30 and 60 interpolates")
        let hd24 = RacketCaptureConfig(quality: .hd1080, fps: 24)
        XCTAssertEqual(RacketBitrate.bytesPerSecond(hd24) * 60, 49e6, accuracy: 1)
    }

    func testStorageRoomAndVerdict() {
        let gb: Int64 = 1_000_000_000
        // 41 GB − 2 % margin at 61 MB/min ≈ 10 h 58 min.
        XCTAssertEqual(RacketStorageCheck.roomLine(freeBytes: 41 * gb, config: hd), "Room for about 10 h 50 min at 1080p")
        XCTAssertEqual(RacketStorageCheck.verdict(freeBytes: 41 * gb, config: hd), .plenty)
        XCTAssertEqual(RacketStorageCheck.roughDuration(RacketStorageCheck.roomSec(freeBytes: 41 * gb, config: uhd)), "3 h 50 min")
        XCTAssertEqual(RacketStorageCheck.verdict(freeBytes: 10 * gb, config: uhd), .tight)
        XCTAssertEqual(RacketStorageCheck.verdict(freeBytes: 2 * gb, config: uhd), .notEnough)
        XCTAssertTrue(RacketStorageCheck.roomLine(freeBytes: 2 * gb, config: uhd).hasPrefix("Not enough room"))
        XCTAssertEqual(RacketStorageCheck.roomSec(freeBytes: 0, config: hd), 0)
    }

    func testMarginIsModest() {
        XCTAssertEqual(RacketStorageCheck.marginBytes(freeBytes: 10_000_000_000), 5e8, "500 MB floor")
        XCTAssertEqual(RacketStorageCheck.marginBytes(freeBytes: 100_000_000_000), 2e9, "2 % of a big free space")
    }

    func testWriteRateMeterSmoothsAndTakesOverAfterWarmUp() {
        var meter = RacketWriteRateMeter(smoothing: 0.5, warmUpSec: 20)
        let estimate = 1_000_000.0
        meter.sample(at: at(0), totalBytes: 0)
        meter.sample(at: at(10), totalBytes: 20_000_000)   // 2 MB/s
        XCTAssertEqual(meter.rate, 2_000_000)
        XCTAssertFalse(meter.isMeasured, "Not trusted before 20 s")
        XCTAssertEqual(meter.effectiveRate(estimate: estimate), estimate)
        meter.sample(at: at(20), totalBytes: 60_000_000)   // 4 MB/s → smoothed 3 MB/s
        XCTAssertEqual(meter.rate, 3_000_000)
        XCTAssertTrue(meter.isMeasured)
        XCTAssertEqual(meter.effectiveRate(estimate: estimate), 3_000_000)
        // A pause (interruption) doesn't count the gap.
        meter.pause()
        meter.sample(at: at(500), totalBytes: 60_000_000)
        meter.sample(at: at(510), totalBytes: 90_000_000)  // 3 MB/s
        XCTAssertEqual(meter.rate, 3_000_000)
        XCTAssertEqual(meter.measuredSec, 30)
        // A drop in total bytes is skipped.
        meter.sample(at: at(520), totalBytes: 10)
        XCTAssertEqual(meter.rate, 3_000_000)
        // Live space left uses the measured rate.
        XCTAssertEqual(RacketStorageCheck.roomSec(freeBytes: 10_500_000_000, bytesPerSec: meter.effectiveRate(estimate: estimate)),
                       (10_500_000_000 - 5e8) / 3_000_000, accuracy: 0.001)
    }

    func testRoughDuration() {
        XCTAssertEqual(RacketStorageCheck.roughDuration(5 * 3600), "5 h")
        XCTAssertEqual(RacketStorageCheck.roughDuration(110 * 60 + 59), "1 h 50 min")
        XCTAssertEqual(RacketStorageCheck.roughDuration(42 * 60), "40 min")
        XCTAssertEqual(RacketStorageCheck.gigabytes(41_300_000_000), "41 GB")
    }

    // MARK: - Match: record everything (RecordAll)

    func testMatchStartsRecordingAtOnceAndMarksMoments() {
        var m = match()
        XCTAssertEqual(m.start(now: t0), [.startCapture])
        XCTAssertEqual(m.phase, .recordingMatch)
        XCTAssertTrue(m.capturing)
        m.mark(.moment, now: at(60))
        m.mark(.newGame, now: at(600))
        XCTAssertEqual(m.log?.userMarkCount, 2)
        XCTAssertEqual(m.log?.marks.last?.startSec, 600)
        let effects = m.end(now: at(4450))
        XCTAssertEqual(effects, [.stopCapture, .ended(.splitPrompt)])
        XCTAssertEqual(m.log?.recordedSec(now: at(9999)), 4450)
        XCTAssertEqual(m.display(now: at(4450))?.tone, .done)
    }

    // MARK: - Drill: countdown → block → rest → review

    func testDrillRecordsFromBlockOneAndMarksBlocksAndRests() {
        var m = drill(blocks: 2, blockSec: 300, restSec: 60, countdown: 5)
        XCTAssertEqual(m.phase, .ready)
        XCTAssertEqual(m.start(now: t0), [], "Nothing records during the countdown")
        XCTAssertEqual(m.phase, .countdown(block: 0, endsAt: at(5)))
        XCTAssertEqual(m.tick(now: at(5)), [.startCapture], "Recording and the block timer start at zero")
        XCTAssertEqual(m.phase, .block(0, startedAt: at(5)))
        XCTAssertEqual(m.display(now: at(65))?.word, "Block")
        XCTAssertEqual(m.display(now: at(65))?.tone, .work)
        XCTAssertEqual(m.display(now: at(65))?.seconds, 240)

        // The block timer runs out → logged, rest begins (recording continues: everything includes rests).
        XCTAssertEqual(m.tick(now: at(305)), [.logBlock(index: 0, durationSec: 300)])
        XCTAssertEqual(m.phase, .rest(after: 0, endsAt: at(365)))
        XCTAssertTrue(m.capturing)
        XCTAssertEqual(m.display(now: at(335))?.tone, .rest)

        // Rest ends → auto-start countdown → block 2.
        m.tick(now: at(365))
        XCTAssertEqual(m.phase, .countdown(block: 1, endsAt: at(370)))
        XCTAssertEqual(m.tick(now: at(370)), [], "Already recording")
        XCTAssertEqual(m.phase, .block(1, startedAt: at(370)))

        // The last block ends → review, recording stops.
        XCTAssertEqual(m.endBlock(now: at(500)), [.logBlock(index: 1, durationSec: 130), .stopCapture, .ended(.drillReview)])
        let log = try! XCTUnwrap(m.log)
        XCTAssertEqual(log.blockMarks.map(\.startSec), [0, 365])
        XCTAssertEqual(log.blockMarks.map(\.endSec), [300, 495])
        let rest = log.marks.first { $0.kind == .rest }
        XCTAssertEqual(rest?.startSec, 300)
        XCTAssertEqual(rest?.endSec, 360)
        XCTAssertEqual(log.drillSummaryLine, "1 recording · 2 block parts")
        XCTAssertEqual(log.runs.count, 1, "One recording")
    }

    func testRestPauseAddAndManualStart() {
        var m = drill(blocks: 3, restSec: 60, autoStart: false)
        m.start(now: t0)
        m.tick(now: at(5))
        m.endBlock(now: at(65))
        XCTAssertEqual(m.phase, .rest(after: 0, endsAt: at(125)))
        m.addRest(30, now: at(70))
        XCTAssertEqual(m.phase, .rest(after: 0, endsAt: at(155)))
        m.pauseRest(now: at(100))
        XCTAssertEqual(m.phase, .restPaused(after: 0, remaining: 55))
        XCTAssertEqual(m.display(now: at(500))?.tone, .restPaused)
        m.tick(now: at(1000))
        XCTAssertEqual(m.phase, .restPaused(after: 0, remaining: 55), "A paused rest never runs out")
        m.resumeRest(now: at(1000))
        m.tick(now: at(1055))
        XCTAssertEqual(m.phase, .restDone(after: 0), "Auto-start off: the player starts block 2")
        m.startNextBlock(now: at(1100))
        XCTAssertEqual(m.phase, .countdown(block: 1, endsAt: at(1105)))
        let rest = m.log?.marks.first { $0.kind == .rest }
        XCTAssertEqual(rest?.endSec, 1095, "The rest lasts until the next block is started")
    }

    func testSkipRestStartsTheNextCountdown() {
        var m = drill()
        m.start(now: t0)
        m.tick(now: at(5))
        m.endBlock(now: at(50))
        m.startNextBlock(now: at(55))
        XCTAssertEqual(m.phase, .countdown(block: 1, endsAt: at(60)))
    }

    // MARK: - Countdown (review5 M3)

    func testWaitBeforeBlockOneGoesBackToReadyNotARestTimer() {
        var m = drill()
        m.start(now: t0)
        m.extendCountdown(by: 30, now: at(1))
        XCTAssertEqual(m.phase, .countdown(block: 0, endsAt: at(35)))
        m.wait(now: at(2))
        XCTAssertEqual(m.phase, .ready)
        XCTAssertNil(m.log, "Nothing recorded yet")
        m.startNextBlock(now: at(10))
        XCTAssertEqual(m.phase, .countdown(block: 0, endsAt: at(15)))
    }

    func testWaitBeforeALaterBlockHoldsTheRest() {
        var m = drill(restSec: 10)
        m.start(now: t0)
        m.tick(now: at(5))
        m.endBlock(now: at(20))
        m.tick(now: at(30))
        XCTAssertEqual(m.phase, .countdown(block: 1, endsAt: at(35)))
        m.wait(now: at(31))
        XCTAssertEqual(m.phase, .restPaused(after: 0, remaining: 0), "Wait returns to a paused rest timer")
        XCTAssertNil(m.log?.marks.first { $0.kind == .rest }?.endSec, "The rest reopens while held")
        m.addRest(30, now: at(32))
        m.resumeRest(now: at(33))
        XCTAssertEqual(m.phase, .rest(after: 0, endsAt: at(63)))
    }

    // MARK: - Finishing mid-way

    func testFinishMidBlockLogsThePlayedBlock() {
        var m = drill(blocks: 3)
        m.start(now: t0)
        m.tick(now: at(5))
        XCTAssertEqual(m.end(now: at(65)), [.logBlock(index: 0, durationSec: 60), .stopCapture, .ended(.drillReview)])
        XCTAssertEqual(m.log?.blockMarks.first?.endSec, 60)
    }

    func testFinishDuringRestClosesTheRest() {
        var m = drill(blocks: 3)
        m.start(now: t0)
        m.tick(now: at(5))
        m.endBlock(now: at(65))
        XCTAssertEqual(m.end(now: at(80)), [.stopCapture, .ended(.drillReview)])
        XCTAssertEqual(m.log?.marks.first { $0.kind == .rest }?.endSec, 75)
        XCTAssertEqual(m.end(now: at(90)), [], "Ending twice does nothing")
    }

    // MARK: - Interruptions (TtInterrupted / TtInterruptedStop)

    func testCallInterruptsAndResumeStartsANewPartOfTheSameRecording() {
        var m = match()
        m.start(now: t0)
        m.interrupt(.call, now: at(1864))
        XCTAssertFalse(m.capturing)
        XCTAssertEqual(m.interruption, .call)
        XCTAssertEqual(m.log?.savedUpToSec, 1864)
        XCTAssertEqual(m.log?.runs.last?.endReasonRaw, "call")
        XCTAssertEqual(m.resume(now: at(1900)), [.startCapture])
        XCTAssertNil(m.interruption)
        XCTAssertEqual(m.log?.runs.count, 2)
        XCTAssertEqual(m.log?.runs.last?.startSec, 1900)
        XCTAssertEqual(m.log?.recordedSec(now: at(2000)), 1864 + 100, "The gap isn't counted")
    }

    func testStorageFullCannotResume() {
        var m = drill()
        m.start(now: t0)
        m.tick(now: at(5))
        m.interrupt(.storageFull, now: at(100))
        XCTAssertEqual(m.resume(now: at(110)), [])
        XCTAssertEqual(m.interruption, .storageFull)
        // A later (resumable) report never downgrades a stop.
        m.interrupt(.call, now: at(120))
        XCTAssertEqual(m.interruption, .storageFull)
    }

    func testResumableInterruptionCanEscalateToAStop() {
        var m = match()
        m.start(now: t0)
        m.interrupt(.appLeft, now: at(10))
        m.interrupt(.tooHot, now: at(20))
        XCTAssertEqual(m.interruption, .tooHot)
        XCTAssertFalse(m.interruption!.canResume)
    }

    func testInterruptionBeforeAnythingRecordedIsIgnored() {
        var m = drill()
        m.start(now: t0)
        m.interrupt(.call, now: at(2))
        XCTAssertNil(m.interruption)
    }

    func testDrillResumesInsideARestToo() {
        var m = drill()
        m.start(now: t0)
        m.tick(now: at(5))
        m.endBlock(now: at(65))
        m.interrupt(.call, now: at(70))
        XCTAssertEqual(m.resume(now: at(80)), [.startCapture], "Everything includes rests")
    }

    func testKeepScoringWithoutVideoIsMatchOnly() {
        var m = match()
        m.start(now: t0)
        m.interrupt(.storageFull, now: at(50))
        XCTAssertEqual(m.continueWithoutVideo(now: at(60)), [.continueWithoutVideo])
        XCTAssertTrue(m.isEnded)

        var d = drill()
        d.start(now: t0)
        d.tick(now: at(5))
        d.interrupt(.storageFull, now: at(50))
        XCTAssertEqual(d.continueWithoutVideo(now: at(60)), [], "Hidden in drills (H1)")
    }

    func testCaptureInterruptionReasonsMap() {
        XCTAssertEqual(RacketInterruption.fromCaptureInterruption(reasonRaw: 1), .appLeft)
        XCTAssertEqual(RacketInterruption.fromCaptureInterruption(reasonRaw: 2), .call)
        XCTAssertEqual(RacketInterruption.fromCaptureInterruption(reasonRaw: 3), .cameraBusy)
        XCTAssertEqual(RacketInterruption.fromCaptureInterruption(reasonRaw: 5), .tooHot)
        XCTAssertNil(RacketInterruption.fromRecordingError(code: nil))
        XCTAssertNil(RacketInterruption.fromRecordingError(code: -11810), "The part limit rolls over, it's not a stop")
        XCTAssertEqual(RacketInterruption.fromRecordingError(code: -11807), .storageFull)
        XCTAssertEqual(RacketInterruption.fromRecordingError(code: -11818), .appLeft)
    }

    // MARK: - End routing + labels (review5 H1)

    func testEndRoutesByMode() {
        XCTAssertEqual(RacketRecordingRoutes.endRoute(mode: .drill, recording: .everything), .drillReview)
        XCTAssertEqual(RacketRecordingRoutes.endRoute(mode: .drill, recording: .byUnit), .drillReview)
        XCTAssertEqual(RacketRecordingRoutes.endRoute(mode: .match, recording: .everything), .splitPrompt)
        XCTAssertEqual(RacketRecordingRoutes.endRoute(mode: .match, recording: .byUnit), .score)
        XCTAssertEqual(RacketRecordingRoutes.endLabel(.drillReview), "End drill")
        XCTAssertEqual(RacketRecordingRoutes.endLabel(.splitPrompt), "End and split")
        XCTAssertEqual(RacketRecordingRoutes.endLabel(.score), "End and confirm the score")
        XCTAssertTrue(RacketRecordingRoutes.allowsScoringWithoutVideo(mode: .match))
        XCTAssertFalse(RacketRecordingRoutes.allowsScoringWithoutVideo(mode: .drill))
    }

    func testHeaderIsLabelledByModeNotAHardCodedGame() {
        XCTAssertEqual(RacketRecordingRoutes.header(mode: .match, recording: .byUnit, unit: .game, unitNumber: 3,
                                                    block: nil, blocks: 0), "Game 3")
        XCTAssertEqual(RacketRecordingRoutes.header(mode: .match, recording: .byUnit, unit: .set, unitNumber: 1,
                                                    block: nil, blocks: 0), "Set 1")
        XCTAssertEqual(RacketRecordingRoutes.header(mode: .match, recording: .everything, unit: .game, unitNumber: 2,
                                                    block: nil, blocks: 0), "Match, recording everything")
        XCTAssertEqual(RacketRecordingRoutes.header(mode: .drill, recording: .everything, unit: .game, unitNumber: 1,
                                                    block: 1, blocks: 3), "Block 2 of 3")
    }

    // MARK: - Still playing? (review5 M4)

    func testStillPlayingAsksAfterTheConfiguredThresholdThenStops() {
        var m = match(still: 90)
        m.start(now: t0)
        XCTAssertEqual(m.tick(now: at(89 * 60)), [])
        XCTAssertEqual(m.tick(now: at(90 * 60)), [.askStillPlaying])
        XCTAssertEqual(m.tick(now: at(90 * 60 + 60)), [], "Waiting for an answer")
        XCTAssertEqual(m.tick(now: at(90 * 60 + 120)), [.stopCapture, .ended(.splitPrompt)])
    }

    func testKeepRecordingAsksAgainAfterTheSameThreshold() {
        var m = match(still: 30)
        m.start(now: t0)
        m.tick(now: at(1800))
        XCTAssertNotNil(m.stillPlayingAskedAt)
        m.keepPlaying(now: at(1810))
        XCTAssertNil(m.stillPlayingAskedAt)
        XCTAssertEqual(m.tick(now: at(1810 + 1799)), [])
        XCTAssertEqual(m.tick(now: at(1810 + 1800)), [.askStillPlaying])
    }

    func testActivityResetsTheStillPlayingClockAndOffNeverAsks() {
        var m = match(still: 30)
        m.start(now: t0)
        m.mark(.moment, now: at(1000))
        XCTAssertEqual(m.tick(now: at(1800)), [])
        var off = match(still: nil)
        off.start(now: t0)
        XCTAssertEqual(off.tick(now: at(100_000)), [])
    }

    func testStillPlayingCopyQuotesTheThreshold() {
        XCTAssertEqual(RacketStillPlaying.reason(minutes: 45), "No score taps or marks for 45 minutes.")
        XCTAssertEqual(RacketStillPlaying.again(minutes: 45), "Keep recording asks again in 45 minutes.")
        XCTAssertTrue(RacketStillPlaying.recordAllFooter(minutes: 90).contains("90 min"))
        XCTAssertTrue(RacketStillPlaying.recordAllFooter(minutes: nil).contains("off"))
    }

    // MARK: - After a whole-match recording: scores (review5 M5)

    func testGamesToScoreFollowTheNewGameMarks() {
        var m = match()
        m.start(now: t0)
        XCTAssertEqual(m.log?.suggestedGameCount(maxRemaining: 5), 1, "One game with no marks")
        m.mark(.newGame, now: at(600))
        m.mark(.newGame, now: at(1200))
        m.mark(.moment, now: at(1300))
        XCTAssertEqual(m.log?.suggestedGameCount(maxRemaining: 5), 3)
        XCTAssertEqual(m.log?.suggestedGameCount(maxRemaining: 2), 2, "Never more than the format has left")
        XCTAssertEqual(m.log?.suggestedGameCount(maxRemaining: nil), 3, "Open play")
        let bo5 = RacketFormat.defaults(for: .tableTennis)
        XCTAssertEqual(RacketRecordedGames.maxRemaining(format: bo5, loggedUnits: 1), 4)
        XCTAssertEqual(RacketRecordedGames.maxRemaining(format: bo5, loggedUnits: 9), 1)
    }

    func testUnconfirmedScoreIsOneStateEverywhere() {
        var ex = SessionExercise(exerciseId: "m", targetSets: 0, targetReps: "", targetRestSeconds: 0, sets: [])
        ex.disciplineRaw = WorkoutDiscipline.racket.rawValue
        ex.racketSportRaw = RacketSport.tableTennis.rawValue
        var g1 = SetLog(); g1.scoreFor = 11; g1.scoreAgainst = 7
        var g2 = SetLog(); g2.scoreUnconfirmed = true
        var g3 = SetLog(); g3.scoreFor = 9; g3.scoreAgainst = 11
        ex.sets = [g1, g2, g3]
        XCTAssertEqual(g2.racketScoreState, .unconfirmed)
        XCTAssertEqual(g2.racketScoreState?.label, "Score unconfirmed")
        XCTAssertEqual(g1.racketScoreState?.label, "11–7")
        XCTAssertNil(SetLog().racketScoreState, "Not a match unit")
        XCTAssertEqual(ex.racketUnconfirmedCount, 1)
        XCTAssertEqual(ex.racketState.won, 1, "An unconfirmed game counts for neither side")
        XCTAssertEqual(ex.racketState.lost, 1)
        XCTAssertEqual(RacketStats.unitsLine(ex), "11–7  Score unconfirmed  9–11")
        XCTAssertEqual(SetMeasure.displaySummary(g2, discipline: .racket, kind: .duration, unit: .kg, distanceUnit: .km),
                       "Score unconfirmed")
    }

    // MARK: - Remembered drill plans

    func testDrillPlanStepOpensOnLastTimesPlan() {
        func drillEx(_ name: String, sport: RacketSport = .tableTennis, plan: RacketDrillPlan?) -> SessionExercise {
            var ex = SessionExercise(exerciseId: "d", targetSets: 0, targetReps: "", targetRestSeconds: 0, sets: [],
                                     displayName: name)
            ex.disciplineRaw = WorkoutDiscipline.racket.rawValue
            ex.racketSportRaw = sport.rawValue
            ex.racketModeRaw = RacketMode.drill.rawValue
            plan?.apply(to: &ex)
            return ex
        }
        let defaults = RacketRecordingDefaults()
        let newest = RacketDrillPlan(blocks: 5, blockSec: 120, restSec: 30, autoStart: false, countdownSec: 3, recording: .everything)
        let older = RacketDrillPlan(blocks: 2, blockSec: 600, restSec: 90, autoStart: true, countdownSec: 10, recording: .off)
        let candidates = [drillEx("Serve practice", plan: nil),                 // pre-244: no plan stored
                          drillEx("Forehand loop vs block", sport: .badminton, plan: older),
                          drillEx("forehand loop vs block ", plan: newest),
                          drillEx("Forehand loop vs block", plan: older)]
        XCTAssertEqual(RacketDrillPlanMemory.lastPlan(sport: .tableTennis, name: "Forehand loop vs block",
                                                      candidates: candidates, defaults: defaults), newest)
        XCTAssertNil(RacketDrillPlanMemory.lastPlan(sport: .tableTennis, name: "Serve practice",
                                                    candidates: candidates, defaults: defaults))
        XCTAssertEqual(RacketDrillPlanMemory.plan(sport: .tableTennis, name: "Serve practice",
                                                  candidates: candidates, defaults: defaults),
                       RacketDrillPlan(defaults: defaults), "Falls back to Settings")
    }

    // MARK: - Assets + clock

    func testSavedPartsLandOnTheRecordingTimeline() {
        var m = match()
        m.start(now: t0)
        m.assetSaved(localIdentifier: "a", startedAt: at(0), durationSec: 600)
        m.assetSaved(localIdentifier: "b", startedAt: at(601), durationSec: 120)
        XCTAssertEqual(m.log?.assets.map(\.startSec), [0, 601])
    }

    func testClockFormats() {
        XCTAssertEqual(RacketClock.mmss(65), "1:05")
        XCTAssertEqual(RacketClock.mmss(64.2), "1:05", "A countdown rounds up")
        XCTAssertEqual(RacketClock.elapsed(3724), "1:02:04")
    }
}
