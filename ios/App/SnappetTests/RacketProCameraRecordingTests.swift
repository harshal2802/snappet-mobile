import XCTest
@testable import Snappet

/// The pro camera while recording (prompt 256, issue #448 part 2): timers and headers, which banner shows for which
/// inputs, the trouble pill, the low-space guard, "HD · 30 from next game", stop / keep playing, resume after heat,
/// and the sideways mapping. No camera needed.
final class RacketProCameraRecordingTests: XCTestCase {

    // MARK: - Timer and headers

    func testTimerAndHeaders() {
        XCTAssertEqual(RacketCameraRecordingCopy.timer(581), "00:09:41")
        XCTAssertEqual(RacketCameraRecordingCopy.timer(3 * 3600 + 5), "03:00:05")
        XCTAssertEqual(RacketCameraRecordingCopy.left(107.2), "01:48 left")
        XCTAssertEqual(RacketCameraRecordingCopy.left(0), "00:00 left")
        XCTAssertEqual(RacketCameraRecordingCopy.gameTitle("Game 1", score: "4 – 3"), "Game 1 · 4 – 3")
        XCTAssertEqual(RacketCameraRecordingCopy.gameTitle("Set 2", score: nil), "Set 2")
        XCTAssertEqual(RacketCameraRecordingCopy.breakSaved("Game 1", score: "11–9"), "Game 1 saved · 11–9")
        XCTAssertEqual(RacketCameraRecordingCopy.breakSaved("Game 1", score: nil), "Game 1 saved")
        XCTAssertEqual(RacketCameraRecordingCopy.stoppedAt(24 * 60 + 18), "Stopped at 24:18")
    }

    func testEverythingStatusFollowsTheRealSaves() {
        let now = Date()
        XCTAssertEqual(RacketCameraRecordingCopy.everythingStatus(savingParts: 0, lastSavedAt: nil, now: now),
                       "Match · saves every 10 min")
        XCTAssertEqual(RacketCameraRecordingCopy.everythingStatus(savingParts: 0, lastSavedAt: now.addingTimeInterval(-20), now: now),
                       "Match · saved just now")
        XCTAssertEqual(RacketCameraRecordingCopy.everythingStatus(savingParts: 0, lastSavedAt: now.addingTimeInterval(-180), now: now),
                       "Match · saved 3 min ago")
        XCTAssertEqual(RacketCameraRecordingCopy.everythingStatus(savingParts: 1, lastSavedAt: nil, now: now),
                       "Match · saving a part")
    }

    func testBreakCentre() {
        let now = Date()
        XCTAssertEqual(RacketCameraRecordingCopy.breakCentre(next: "Game 2", phase: .breakTime(endsAt: now.addingTimeInterval(45)), now: now),
                       "Game 2 in 0:45")
        XCTAssertEqual(RacketCameraRecordingCopy.breakCentre(next: "Game 2", phase: .breakPaused(remaining: 30), now: now),
                       "Game 2 · paused 0:30")
        XCTAssertEqual(RacketCameraRecordingCopy.breakCentre(next: "Game 2", phase: .breakDone, now: now), "Game 2 ready")
    }

    // MARK: - Which banner

    private func conditions(_ edit: (inout RacketCameraConditions) -> Void) -> RacketCameraConditions {
        var c = RacketCameraConditions()
        c.roomSec = 10 * 3600
        edit(&c)
        return c
    }

    func testBannerPriorities() {
        XCTAssertEqual(RacketCameraBanner.decide(conditions { _ in }, savedUpToSec: 0), .none)
        XCTAssertEqual(RacketCameraBanner.decide(conditions { $0.thermal = .warm; $0.format = .uhd60 }, savedUpToSec: 0),
                       .warm(.uhd60))
        XCTAssertEqual(RacketCameraBanner.decide(conditions { $0.roomSec = 12 * 60 }, savedUpToSec: 0), .lowSpace(roomSec: 720))
        // Warm wins over low space; an interruption over warm; a heat stop over everything.
        XCTAssertEqual(RacketCameraBanner.decide(conditions { $0.thermal = .warm; $0.roomSec = 600 }, savedUpToSec: 0),
                       .warm(.hd30))
        XCTAssertEqual(RacketCameraBanner.decide(conditions { $0.thermal = .warm; $0.interruption = .call }, savedUpToSec: 581),
                       .interrupted(.call, savedUpToSec: 581))
        XCTAssertEqual(RacketCameraBanner.decide(conditions { $0.thermal = .tooHot; $0.interruption = .tooHot }, savedUpToSec: 1458),
                       .hot(savedUpToSec: 1458, canResume: false))
        XCTAssertEqual(RacketCameraBanner.decide(conditions { $0.thermal = .ok; $0.interruption = .tooHot }, savedUpToSec: 1458),
                       .hot(savedUpToSec: 1458, canResume: true), "cooled: Resume filming is enabled")
        XCTAssertEqual(RacketCameraBanner.decide(conditions { $0.interruption = .storageFull }, savedUpToSec: 60),
                       .full(savedUpToSec: 60))
        XCTAssertEqual(RacketCameraBanner.decide(conditions { $0.roomSec = nil }, savedUpToSec: 0), .none, "unknown space isn't low")
    }

    func testBannerCopy() {
        XCTAssertEqual(RacketCameraBanner.warmLine(.uhd60), "▲ Warm at 4K · 60. Recording continues.")
        XCTAssertEqual(RacketCameraBanner.spaceLine(12 * 60 + 30), "About 12 min of space left")
        XCTAssertEqual(RacketInterruptionCopy.title(.call), "Recording paused by a phone call")
        XCTAssertEqual(RacketInterruptionCopy.line(.call, savedUpToSec: 581),
                       "Saved up to 09:41. It starts again by itself when the call ends.")
        XCTAssertEqual(RacketInterruptionCopy.title(.tooHot), "The phone got too hot to film")
        XCTAssertEqual(RacketInterruptionCopy.hotLine(savedUpToSec: 1458),
                       "Everything up to 24:18 is saved. Scoring carries on from your Watch or the buttons below.")
        XCTAssertTrue(RacketInterruptionCopy.autoResumes(.call))
        XCTAssertTrue(RacketInterruptionCopy.autoResumes(.cameraBusy))
        XCTAssertFalse(RacketInterruptionCopy.autoResumes(.cameraError))
        XCTAssertFalse(RacketInterruptionCopy.autoResumes(.tooHot))
    }

    // MARK: - Trouble pill, space guard

    func testTroublePillListsOnlyTheTroubles() {
        XCTAssertNil(RacketCameraTrouble.pill(conditions { $0.batteryPercent = 82 }))
        XCTAssertEqual(RacketCameraTrouble.pill(conditions { $0.roomSec = 12 * 60; $0.batteryPercent = 9; $0.watchOff = true }),
                       "12 min left · 9% · Watch off")
        XCTAssertEqual(RacketCameraTrouble.pill(conditions { $0.batteryPercent = 9; $0.charging = true; $0.watchOff = true }),
                       "Watch off", "charging isn't trouble")
        XCTAssertEqual(RacketCameraTrouble.pill(conditions { $0.batteryPercent = 20 }), "20%")
        XCTAssertNil(RacketCameraTrouble.pill(conditions { $0.batteryPercent = 21 }))
    }

    func testSpaceGuardStopsBeforeTheDiskIsFull() {
        XCTAssertFalse(RacketSpaceGuard.mustStop(roomSec: nil))
        XCTAssertFalse(RacketSpaceGuard.mustStop(roomSec: 61))
        XCTAssertTrue(RacketSpaceGuard.mustStop(roomSec: 59))
        // At HD · 30 with 560 MB free, under a minute fits above the 500 MB margin: stop, with 500 MB still free.
        let room = RacketStorageCheck.roomSec(freeBytes: 560_000_000, config: RacketCameraFormat.hd30.config())
        XCTAssertTrue(RacketSpaceGuard.mustStop(roomSec: room))
    }

    // MARK: - "HD · 30 from next game"

    func testPendingFormatAppliesOnceAtTheBoundary() {
        XCTAssertTrue(RacketPendingFormat.offers(current: .uhd60, pending: nil))
        XCTAssertFalse(RacketPendingFormat.offers(current: .hd30, pending: nil), "already HD · 30: nothing to offer")
        XCTAssertFalse(RacketPendingFormat.offers(current: .uhd60, pending: .hd30))
        var p = RacketPendingFormat()
        XCTAssertNil(p.takeAtBoundary())
        p.choose(.hd30)
        XCTAssertEqual(p.takeAtBoundary(), .hd30)
        XCTAssertNil(p.takeAtBoundary(), "once")
        XCTAssertEqual(RacketPendingFormat.label(boundary: .game, chosen: false), "HD · 30 from next game")
        XCTAssertEqual(RacketPendingFormat.label(boundary: .block, chosen: true), "HD · 30 next block ✓")
    }

    // MARK: - Stop, keep playing, resume after heat

    func testStopThenAMistakeKeepsTheSameGame() {
        var f = RacketGameFlow(filming: true, unitIndex: 0, options: .init(sport: .tableTennis, pointsTo: 11), startInWarmup: true)
        XCTAssertEqual(f.startGame(now: Date()), [.resumeCapture])
        let started = f.gameStartedAt
        XCTAssertEqual(f.endGame(matchOver: false, now: Date()), [.openScore], "one tap on stop opens the score sheet")
        XCTAssertTrue(f.wantsCapture, "the clip runs on under the sheet")
        XCTAssertEqual(f.cancelScore(), [.resumeCapture], "keep playing: a new part if the file had stopped")
        XCTAssertEqual(f.phase, .playing)
        XCTAssertEqual(f.unitIndex, 0, "the same game")
        XCTAssertEqual(f.gameStartedAt, started)
        XCTAssertEqual(f.cancelScore(), [], "only from the sheet")
        var noVideo = RacketGameFlow(filming: false, unitIndex: 0, options: .init(sport: .tableTennis, pointsTo: 11), startInWarmup: false)
        noVideo.startGame(now: Date())
        noVideo.endGame(matchOver: false, now: Date())
        XCTAssertEqual(noVideo.cancelScore(), [])
    }

    func testKeepPlayingAfterTheFileStoppedContinuesAsANewPart() {
        var m = RacketRecordingMachine(kind: .match, recording: .byUnit, stillPlayingMinutes: nil, now: Date())
        m.start(now: Date())
        XCTAssertEqual(m.log?.runs.count, 1)
        m.pauseCapture(now: Date())
        XCTAssertEqual(m.resumeCapture(now: Date()), [.startCapture])
        XCTAssertEqual(m.log?.runs.count, 2, "a new part of the same recording")
        XCTAssertEqual(m.resumeCapture(now: Date()), [], "no-op while still writing")
    }

    func testResumeAfterHeatOnlyWhenCooled() {
        var m = RacketRecordingMachine(kind: .match, recording: .byUnit, stillPlayingMinutes: nil, now: Date())
        m.start(now: Date())
        m.interrupt(.tooHot, now: Date())
        XCTAssertEqual(m.resume(now: Date()), [], "too hot can't resume by itself")
        XCTAssertEqual(m.interruption, .tooHot)
        XCTAssertEqual(m.resume(now: Date(), cooled: true), [.startCapture])
        XCTAssertNil(m.interruption)
        var full = RacketRecordingMachine(kind: .match, recording: .byUnit, stillPlayingMinutes: nil, now: Date())
        full.start(now: Date())
        full.interrupt(.storageFull, now: Date())
        XCTAssertEqual(full.resume(now: Date(), cooled: true), [], "cooling doesn't free space")
    }

    // MARK: - Sideways

    func testSidewaysMapping() {
        XCTAssertEqual(RacketCameraOrientation.portrait.previewRotation, 90)
        XCTAssertEqual(RacketCameraOrientation.landscapeRight.previewRotation, 0)
        XCTAssertEqual(RacketCameraOrientation.landscapeLeft.previewRotation, 180)
        XCTAssertEqual(RacketCameraOrientation.landscapeRight.shownAspect(portraitAspect: 9.0 / 16.0)!, 16.0 / 9.0, accuracy: 1e-9)
        XCTAssertEqual(RacketCameraOrientation.portrait.shownAspect(portraitAspect: 9.0 / 16.0)!, 9.0 / 16.0, accuracy: 1e-9)
        for o in [RacketCameraOrientation.portrait, .landscapeLeft, .landscapeRight] {
            let d = o.devicePoint(u: 0.2, v: 0.7)
            let back = o.viewPoint(x: d.x, y: d.y)
            XCTAssertEqual(back.u, 0.2, accuracy: 1e-9)
            XCTAssertEqual(back.v, 0.7, accuracy: 1e-9)
        }
        let r = RacketCameraOrientation.landscapeRight.devicePoint(u: 0.25, v: 0.5)
        XCTAssertEqual(r.x, 0.25)
        XCTAssertEqual(r.y, 0.5)
        // A tap on a sideways screen goes through the same conversion.
        let p = RacketFocusPoint.devicePoint(tap: CGPoint(x: 0, y: 0), in: CGSize(width: 1600, height: 900), videoAspect: 16.0 / 9.0,
                                             orientation: .landscapeLeft)
        XCTAssertEqual(p.x, 1, accuracy: 1e-9)
        XCTAssertEqual(p.y, 1, accuracy: 1e-9)
    }
}
