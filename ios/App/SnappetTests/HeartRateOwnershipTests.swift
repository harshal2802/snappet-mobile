import XCTest
import HealthKit
@testable import Snappet

/// Prompt 264: who owns the one live heart-rate source. One section per finding of the workout state-machine review:
/// F6 (the Watch ending its workout reaches the phone; the phone session keeps running), F7 (no gym start while a
/// Kilter board session is live), F8 (no source switch while a session is live).
@MainActor
final class HeartRateOwnershipTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// A coordinator on the Watch path with a throwaway band memory (a real remembered band can't leak in).
    private func coordinator() -> (LiveMetricsCoordinator, UserDefaults, String) {
        let suite = "snappet.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let c = LiveMetricsCoordinator(ble: BLEHeartRateMetricsSource(memory: BandMemory(defaults: defaults)))
        c.selectedSource = .appleWatch
        return (c, defaults, suite)
    }

    private func assertPlain(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(text.contains("—"), "no em dashes in UI strings", file: file, line: line)
        XCTAssertFalse(text.isEmpty, file: file, line: line)
    }

    // MARK: F6 — the wire

    func testEndedMessageRoundTrips() {
        let m = LiveWorkoutMessage.ended(startedAt: t0.timeIntervalSince1970)
        XCTAssertEqual(LiveWorkoutMessage(payload: m.payload), m)
        XCTAssertEqual(LiveWorkoutMessage(payload: LiveWorkoutMessage.ended(startedAt: nil).payload),
                       .ended(startedAt: nil))
        XCTAssertEqual(LiveWorkoutMessage(payload: ["kind": "ended"]), .ended(startedAt: nil),
                       "no start time still decodes (trusted as this session's)")
        XCTAssertNotEqual(LiveWorkoutMessage(payload: m.payload), .stop, "ended is not the phone's stop")
    }

    // MARK: F6 — the rule

    func testAcceptsOnlyWhileASessionIsRecording() {
        XCTAssertFalse(WatchEnded.accepts(sessionStart: nil, watchStartedAt: t0, alreadyEnded: false),
                       "nothing is recording: a stray ended changes nothing")
        XCTAssertTrue(WatchEnded.accepts(sessionStart: t0, watchStartedAt: t0.addingTimeInterval(2), alreadyEnded: false))
        XCTAssertTrue(WatchEnded.accepts(sessionStart: t0, watchStartedAt: nil, alreadyEnded: false),
                      "an older Watch app sends no start: trusted")
        XCTAssertFalse(WatchEnded.accepts(sessionStart: t0, watchStartedAt: t0, alreadyEnded: true),
                       "a re-sent copy changes nothing")
    }

    func testLateEndedFromAnEarlierSessionIsDropped() {
        // Queued with transferUserInfo, an earlier session's ended can land after a new session started.
        XCTAssertFalse(WatchEnded.accepts(sessionStart: t0, watchStartedAt: t0.addingTimeInterval(-600),
                                          alreadyEnded: false))
        // Clock skew between the devices is absorbed.
        XCTAssertTrue(WatchEnded.accepts(sessionStart: t0, watchStartedAt: t0.addingTimeInterval(-5),
                                         alreadyEnded: false))
        XCTAssertFalse(WatchEnded.accepts(sessionStart: t0,
                                          watchStartedAt: t0.addingTimeInterval(-WatchEnded.clockSkew - 1),
                                          alreadyEnded: false))
    }

    func testDisplayNoticeThenChip() {
        XCTAssertEqual(WatchEnded.display(watchIsSource: true, ended: false, dismissed: false), .none)
        XCTAssertEqual(WatchEnded.display(watchIsSource: true, ended: true, dismissed: false), .notice)
        XCTAssertEqual(WatchEnded.display(watchIsSource: true, ended: true, dismissed: true), .chip)
        XCTAssertEqual(WatchEnded.display(watchIsSource: false, ended: true, dismissed: false), .none,
                       "a band session never says Watch ended")
    }

    func testWatchEndedWording() {
        XCTAssertEqual(WatchEnded.notice.title, "Watch ended")
        XCTAssertTrue(WatchEnded.notice.message.contains("still running here"))
        XCTAssertEqual(WatchEnded.keepGoing, "Keep going")
        for s in [WatchEnded.notice.title, WatchEnded.notice.message, WatchEnded.keepGoing, WatchEnded.chip] {
            assertPlain(s)
        }
    }

    // MARK: F6 — the phone source

    func testWatchEndedClearsLiveHRAndKeepsTheBuffer() {
        let w = AppleWatchMetricsSource()
        w.start(activityType: .traditionalStrengthTraining, sessionStart: t0)
        w.ingest(hrBpm: 130, energyKcal: 10, watchOffset: 5, receivedAt: t0.addingTimeInterval(5))
        w.watchEnded(watchStartedAt: t0.addingTimeInterval(1))
        XCTAssertTrue(w.endedOnWatch)
        XCTAssertNil(w.latestHR, "no frozen bpm on the banner / Live Activity")
        XCTAssertEqual(w.samples.count, 1, "what arrived before stays for the finish flush")
        XCTAssertNotEqual(w.connectionState, .workoutRunning)
    }

    func testSampleLandingAfterEndedIsBufferedButNotLive() {
        let w = AppleWatchMetricsSource()
        w.start(activityType: .running, sessionStart: t0)
        w.watchEnded(watchStartedAt: nil)
        w.ingest(hrBpm: 140, energyKcal: 12, watchOffset: 8, receivedAt: t0.addingTimeInterval(9))
        XCTAssertNil(w.latestHR)
        XCTAssertEqual(w.samples.count, 1, "a sample queued before the end is still real heart rate")
    }

    func testStaleEndedIsIgnored() {
        let w = AppleWatchMetricsSource()
        w.start(activityType: .running, sessionStart: t0)
        w.ingest(hrBpm: 120, energyKcal: 1, watchOffset: 1, receivedAt: t0.addingTimeInterval(1))
        w.watchEnded(watchStartedAt: t0.addingTimeInterval(-3600))
        XCTAssertFalse(w.endedOnWatch)
        XCTAssertEqual(w.latestHR, 120)
    }

    func testEndedWithNoSessionIsIgnored() {
        let w = AppleWatchMetricsSource()
        w.watchEnded(watchStartedAt: nil)
        XCTAssertFalse(w.endedOnWatch)
    }

    func testStartAndStopClearTheEndedState() {
        let w = AppleWatchMetricsSource()
        w.start(activityType: .running, sessionStart: t0)
        w.watchEnded(watchStartedAt: nil)
        w.dismissEndedNotice()
        XCTAssertTrue(w.endedNoticeDismissed)
        w.stop()
        XCTAssertFalse(w.endedOnWatch)
        XCTAssertFalse(w.endedNoticeDismissed)
        w.start(activityType: .running, sessionStart: t0.addingTimeInterval(100))
        w.watchEnded(watchStartedAt: nil)
        XCTAssertTrue(w.endedOnWatch)
        w.start(activityType: .running, sessionStart: t0.addingTimeInterval(200))
        XCTAssertFalse(w.endedOnWatch, "a new session starts with the Watch recording again")
    }

    func testPhonePauseIsLeftAlone() {
        let w = AppleWatchMetricsSource()
        w.start(activityType: .running, sessionStart: t0)
        w.pause()
        w.watchEnded(watchStartedAt: nil)
        XCTAssertTrue(w.isPaused, "the phone's paused state is the phone's to change")
    }

    func testCoordinatorKeepsTheSessionRunningAndShowsNoticeThenChip() {
        let (c, defaults, suite) = coordinator()
        defer { defaults.removePersistentDomain(forName: suite) }
        c.start(LiveMetricsContext(startedAt: t0, activityType: .running))
        XCTAssertEqual(c.watchEndedDisplay, .none)
        c.watch.watchEnded(watchStartedAt: nil)
        XCTAssertTrue(c.isSessionActive, "the phone session keeps running: nothing finishes")
        XCTAssertNil(c.latestHR)
        XCTAssertEqual(c.watchEndedDisplay, .notice)
        c.dismissWatchEndedNotice()
        XCTAssertEqual(c.watchEndedDisplay, .chip)
        c.stop()
        XCTAssertEqual(c.watchEndedDisplay, .none)
    }

    // MARK: F7 — gym start while a board session is live

    func testGymStartRefusedOnlyWhileBoardLive() {
        XCTAssertNil(GymStartGate.refusal(boardSessionLive: false))
        let r = GymStartGate.refusal(boardSessionLive: true)
        XCTAssertEqual(r?.title, "A board session is running")
        XCTAssertTrue(r?.message.contains("Finish it in Kilter Board first") ?? false)
        assertPlain(r?.title ?? "")
        assertPlain(r?.message ?? "")
    }

    // MARK: F8 — switching the source mid-session

    func testSourceLockedWhileAnySessionIsLive() {
        XCTAssertNil(HRSourceLock.reason(metricsRunning: false, workoutLive: false, boardLive: false))
        XCTAssertNotNil(HRSourceLock.reason(metricsRunning: true, workoutLive: false, boardLive: false))
        XCTAssertNotNil(HRSourceLock.reason(metricsRunning: false, workoutLive: true, boardLive: false),
                        "a workout open after a relaunch, before its source restarts")
        XCTAssertNotNil(HRSourceLock.reason(metricsRunning: false, workoutLive: false, boardLive: true))
        let line = HRSourceLock.reason(metricsRunning: true, workoutLive: true, boardLive: false) ?? ""
        XCTAssertTrue(line.contains("while a session is live"))
        assertPlain(line)
    }
}
