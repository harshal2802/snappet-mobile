import XCTest
@testable import Snappet

/// Unit tests for the racket model hooks (prompt 248, issue #438 step 5), all pure, no device: the capability registry,
/// the placeholder's rally rule on synthetic motion signals (bursts, noise, drift, gaps, score-tap anchors), the scan
/// loop's progress / cancel / no-video with fake sources, how guesses merge with your tags, model-vs-model compare,
/// scan state per row, the time left, "After a session", guesses in AICompare, and the Watch's point marks.
final class RacketModelHooksTests: XCTestCase {

    // MARK: Helpers

    private let fps = 10.0

    /// A quiet floor (0.02 ± a little) with bursts of `level` over each `(start, end)` in seconds.
    private func signal(_ seconds: Double, bursts: [(Double, Double)], level: Float = 0.2, floor: Float = 0.02,
                        drift: Float = 0, start: Double = 0) -> RacketMotionSignal {
        let n = Int(seconds * fps)
        let values: [Float] = (0..<n).map { k in
            let t = Double(k) / fps
            let jitter = Float((k * 7919) % 13) / 1300           // deterministic 0…0.009
            let base = floor + drift * Float(t / seconds) + jitter
            return bursts.contains { t >= $0.0 && t < $0.1 } ? base + level : base
        }
        return RacketMotionSignal(startSec: start, fps: fps, values: values)
    }

    private func close(_ a: Double, _ b: Double, _ tol: Double = 1.1, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a, b, accuracy: tol, file: file, line: line)
    }

    // MARK: Registry (TtCapabilities)

    func testEverySportHasThePlaceholderWithEveryFeatureAvailable() {
        for s in RacketSport.allCases {
            let caps = RacketCapabilityRegistry.capabilities(for: s)
            XCTAssertEqual(caps.model?.id, "snappet.placeholder.motion")
            XCTAssertTrue(caps.model?.isPlaceholder == true)
            for f in RacketFeature.allCases {
                XCTAssertTrue(caps.has(f), "\(s) \(f)")
                XCTAssertEqual(RacketCapabilityRegistry.statusLabel(caps, f), "✓ Available")
            }
            XCTAssertEqual(RacketRallyFinding.availability(for: s), .available(modelName: "Snappet placeholder v1"))
        }
        XCTAssertEqual(RacketFeature.allCases.map(\.title), ["Find rallies", "Live tracking", "Court check", "Shot count",
                                                             "Shot types", "Endings", "Ball path on video",
                                                             "Longest rally in drills"])
        XCTAssertEqual(RacketFeature.findRallies.withoutIt, "Without it: mark rallies on the timeline")
        XCTAssertEqual(RacketFeature.longestRallyInDrills.withoutIt, "Without it: enter it during rest")
    }

    func testPreviewWithNoModelDegradesToByHand() {
        let caps = RacketCapabilityRegistry.capabilities(for: .squash, noModel: true)
        XCTAssertNil(caps.model)
        XCTAssertFalse(caps.has(.findRallies))
        XCTAssertEqual(RacketCapabilityRegistry.statusLabel(caps, .endings), "Not yet")
        XCTAssertEqual(RacketRallyFinding.availability(for: .squash, noModel: true), .notYet)
        XCTAssertEqual(RacketRallyFinding.notYetLine(.squash), "Rally finding isn’t available for squash yet.")
    }

    func testModelSourceRoundTripsAndIsNotAnAIApp() {
        let raw = RacketCapabilityRegistry.placeholder.source
        XCTAssertEqual(raw, "model:snappet.placeholder.motion@1")
        XCTAssertEqual(RacketModelSource.parse(raw)?.id, "snappet.placeholder.motion")
        XCTAssertEqual(RacketModelSource.parse(raw)?.version, 1)
        XCTAssertFalse(RacketAISource.isAI(raw))
        XCTAssertNil(RacketModelSource.parse("ai:ChatGPT"))
        XCTAssertNotNil(RacketRallyModels.model(for: RacketCapabilityRegistry.placeholder))
    }

    // MARK: The rule

    func testBurstsBecomeRalliesWithPadding() {
        let s = signal(120, bursts: [(10, 18), (40, 46), (80, 92)])
        let g = RacketMotionRallyRule.rallies(s)
        XCTAssertEqual(g.count, 3)
        close(g[0].startSec, 9.5); close(g[0].endSec, 18.5)
        close(g[1].startSec, 39.5); close(g[1].endSec, 46.5)
        close(g[2].startSec, 79.5); close(g[2].endSec, 92.5)
        XCTAssertTrue(g.allSatisfy { $0.confidence >= RacketRallyGuessMerge.unsureBelow }, "\(g.map(\.confidence))")
        XCTAssertTrue(g.allSatisfy { $0.winnerRaw == nil && $0.anchored == nil }, "no taps, no winners")
    }

    func testQuietNoiseFindsNothing() {
        XCTAssertEqual(RacketMotionRallyRule.rallies(signal(300, bursts: [])), [])
        XCTAssertEqual(RacketMotionRallyRule.rallies(RacketMotionSignal(startSec: 0, fps: fps, values: [])), [])
    }

    func testSlowDriftInLightIsNotARally() {
        // The room gets brighter / busier over 10 minutes: the rolling baseline follows it.
        let s = signal(600, bursts: [(100, 108), (500, 508)], drift: 0.08)
        let g = RacketMotionRallyRule.rallies(s)
        XCTAssertEqual(g.count, 2, "\(g)")
        close(g[1].startSec, 499.5)
    }

    func testShortGapsMergeAndShortBlipsDrop() {
        // 1 s gap inside a rally (a high lob) merges; a 0.8 s blip is a bump of the camera.
        let s = signal(90, bursts: [(10, 15), (16, 20), (50, 50.8)])
        let g = RacketMotionRallyRule.rallies(s)
        XCTAssertEqual(g.count, 1)
        close(g[0].startSec, 9.5); close(g[0].endSec, 20.5)
    }

    func testMissingVideoSplitsARally() {
        var s = signal(60, bursts: [(10, 30)])
        for k in 190..<210 { s.values[k] = .nan }   // an interruption 19–21 s
        let g = RacketMotionRallyRule.rallies(s)
        XCTAssertEqual(g.count, 2, "never across missing video: \(g)")
        XCTAssertLessThan(g[0].endSec, 19.6)
        XCTAssertGreaterThan(g[1].startSec, 20.4)
    }

    func testWeakBurstIsUnsureAndVeryLongIsUnsure() {
        let s = signal(200, bursts: [(10, 18), (60, 68), (100, 170)], level: 0.2)
        var weak = s
        for k in 600..<680 { weak.values[k] -= 0.15 }  // 60–68 s: much less movement
        let g = RacketMotionRallyRule.rallies(weak, params: .init(maxRallySec: 60))
        XCTAssertEqual(g.count, 3, "\(g)")
        XCTAssertGreaterThanOrEqual(g[0].confidence, RacketRallyGuessMerge.unsureBelow)
        XCTAssertLessThan(g[1].confidence, RacketRallyGuessMerge.unsureBelow, "weak movement: unsure")
        XCTAssertLessThanOrEqual(g[2].confidence, 0.3, "70 s of motion is not one rally")
    }

    func testScoreTapsConfirmNameTheWinnerAndFillMissedRallies() {
        let s = signal(120, bursts: [(10, 18), (30, 34), (40, 46)])
        let anchors = [RallyAnchor(atSec: 21, winner: .us),     // after the first rally
                       RallyAnchor(atSec: 49, winner: .them),   // after the third
                       RallyAnchor(atSec: 100, winner: .us)]    // nothing found before it
        let g = RacketMotionRallyRule.rallies(s, anchors: anchors)
        XCTAssertEqual(g.count, 4, "\(g)")
        XCTAssertEqual(g[0].winner, .us)
        XCTAssertEqual(g[0].anchored, true)
        XCTAssertGreaterThanOrEqual(g[0].confidence, 0.85)
        // 30–34 s sits between taps and no tap confirms it: probably the ball being picked up.
        XCTAssertNil(g[1].winner)
        XCTAssertLessThan(g[1].confidence, RacketRallyGuessMerge.unsureBelow)
        XCTAssertEqual(g[2].winner, .them)
        // A tap with nothing before it adds an unsure guess ending 1 s before the tap.
        XCTAssertEqual(g[3].winner, .us)
        close(g[3].endSec, 99, 0.01)
        close(g[3].startSec, 93, 0.01)
        XCTAssertEqual(g[3].confidence, 0.3)
    }

    func testAnchorsFromTheRecordingMarks() {
        var log = RacketRecordingLog(startedAt: Date(timeIntervalSince1970: 0))
        log.marks = [.init(kindRaw: "firstPoint", index: nil, startSec: 20, endSec: nil),
                     .init(kindRaw: "point", index: 0, startSec: 20, endSec: nil),
                     .init(kindRaw: "point", index: 1, startSec: 45, endSec: nil),
                     .init(kindRaw: "point", index: 0, startSec: 900, endSec: nil)]
        let a = RacketScanAnchors.anchors(log, from: 0, to: 600)
        XCTAssertEqual(a, [RallyAnchor(atSec: 20, winner: .us), RallyAnchor(atSec: 45, winner: .them)])
        // Older recordings: first points only, no winner.
        log.marks = [.init(kindRaw: "firstPoint", index: nil, startSec: 385, endSec: nil)]
        XCTAssertEqual(RacketScanAnchors.anchors(log, from: 0, to: 600), [RallyAnchor(atSec: 385, winner: nil)])
    }

    // MARK: The scan loop

    /// Serves a synthetic signal; counts chunk reads.
    private final class FakeSource: RallyFrameSource, @unchecked Sendable {
        let s: RacketMotionSignal
        var reads = 0
        var noVideo = false
        init(_ s: RacketMotionSignal) { self.s = s }
        func motion(from a: Double, to b: Double, fps: Double, gridWidth: Int) async throws -> [Float] {
            reads += 1
            let n = RacketMotionRallyRule.sampleCount(b - a, fps: fps)
            if noVideo { return Array(repeating: .nan, count: n) }
            let i0 = Int(((a - s.startSec) * fps).rounded())
            return (0..<n).map { i0 + $0 < s.values.count ? s.values[i0 + $0] : .nan }
        }
    }

    private actor Log { var fractions: [Double] = []; func add(_ f: Double) { fractions.append(f) } }

    func testPlaceholderScanReportsProgressAndFindsTheRallies() async throws {
        let src = FakeSource(signal(95, bursts: [(10, 18), (60, 70)]))
        let log = Log()
        let model = PlaceholderMotionRallyModel()
        let g = try await model.scan(RallyScanRequest(sport: .tableTennis, startSec: 0, endSec: 95, anchors: []),
                                     source: src) { await log.add($0.fraction) }
        XCTAssertEqual(g.count, 2)
        let f = await log.fractions
        XCTAssertEqual(src.reads, 4, "30 s chunks over 95 s")
        XCTAssertEqual(f, f.sorted())
        XCTAssertEqual(f.last ?? 0, 1, accuracy: 1e-9)
    }

    func testScanOnARangeKeepsRecordingTime() async throws {
        let src = FakeSource(signal(200, bursts: [(130, 140)]))
        let g = try await PlaceholderMotionRallyModel().scan(
            RallyScanRequest(sport: .badminton, startSec: 100, endSec: 200, anchors: []), source: src) { _ in }
        XCTAssertEqual(g.count, 1)
        close(g[0].startSec, 129.5)
    }

    func testScanWithNoVideoThrows() async {
        let src = FakeSource(signal(60, bursts: []))
        src.noVideo = true
        do {
            _ = try await PlaceholderMotionRallyModel().scan(
                RallyScanRequest(sport: .tennis, startSec: 0, endSec: 60, anchors: []), source: src) { _ in }
            XCTFail("expected noVideo")
        } catch {
            XCTAssertEqual(error as? RallyScanError, .noVideo)
        }
    }

    func testScanStopsWhenCancelled() async {
        let src = FakeSource(signal(3600, bursts: [(10, 18)]))
        let task = Task {
            try await PlaceholderMotionRallyModel().scan(
                RallyScanRequest(sport: .tableTennis, startSec: 0, endSec: 3600, anchors: []), source: src) { p in
                if p.doneSec >= 300 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertLessThan(src.reads, 20, "stops between chunks, long before the end")
    }

    // MARK: Guesses on the timeline

    private func guess(_ a: Double, _ b: Double, _ c: Double = 0.8, winner: String? = nil) -> RallyGuess {
        RallyGuess(startSec: a, endSec: b, confidence: c, winnerRaw: winner)
    }

    func testGuessesReplaceEarlierGuessesButNeverYourRallies() {
        let src = RacketCapabilityRegistry.placeholder.source
        let mine = RacketRally(startSec: 10, endSec: 18, winner: .us)
        var old = RacketRally(startSec: 30, endSec: 36); old.sourceRaw = src; old.confidence = 0.7
        var checked = RacketRally(startSec: 50, endSec: 56); checked.sourceRaw = src; checked.confirmed = true
        let outside = RacketRally(startSec: 500, endSec: 505)
        let out = RacketRallyGuessMerge.apply([guess(11, 17), guess(31, 37, 0.4, winner: "them"), guess(52, 55), guess(70, 78)],
                                              source: src, to: [mine, old, checked, outside], partStart: 0, partEnd: 100)
        XCTAssertEqual(out.map(\.startSec), [10, 31, 50, 70, 500])
        XCTAssertEqual(out[0].id, mine.id, "yours is kept; the guess over it is dropped")
        XCTAssertNotEqual(out[1].id, old.id, "the old guess is replaced")
        XCTAssertTrue(out[1].isUnsure)
        XCTAssertEqual(out[1].guessWinner, .them)
        XCTAssertNil(out[1].winner, "a suggested winner is never a tag")
        XCTAssertEqual(out[2].id, checked.id, "a guess you checked is yours now")
        XCTAssertTrue(out[3].isGuess && !out[3].isUnsure)
        XCTAssertEqual(out[4].id, outside.id)
    }

    func testTaggingOrFixingAGuessConfirmsItAndOnlyThenItCounts() {
        let src = RacketCapabilityRegistry.placeholder.source
        let rallies = RacketRallyGuessMerge.apply([guess(10, 18, 0.4), guess(30, 36, 0.4), guess(50, 56)],
                                                  source: src, to: [], partStart: 0, partEnd: 100)
        XCTAssertEqual(RacketRallyMarking.nextUnsure(rallies, after: nil)?.startSec, 10)
        XCTAssertEqual(RacketRallyMarking.nextUnsure(rallies, after: rallies[0].id)?.startSec, 30)
        var g = RacketGuessSummary.make(rallies)
        XCTAssertEqual(g.found, 3); XCTAssertEqual(g.guesses, 3); XCTAssertEqual(g.unsureTotal, 2); XCTAssertEqual(g.unsureLeft, 2)

        var after = RacketRallyMarking.tag(rallies, id: rallies[0].id, winner: .us, ending: nil, lastShotBy: nil, notRally: false)
        after = RacketRallyMarking.tag(after, id: rallies[1].id, winner: nil, ending: nil, lastShotBy: nil, notRally: true)
        g = RacketGuessSummary.make(after)
        XCTAssertEqual(g.unsureLeft, 0)
        XCTAssertEqual(g.checkedLine, "2 of 2 checked")
        XCTAssertEqual(g.found, 2, "not a rally is gone")
        XCTAssertEqual(g.guesses, 1)
        XCTAssertNil(RacketRallyMarking.nextUnsure(after, after: nil))

        let fixed = RacketRallyMarking.fix(after, id: rallies[2].id, start: 49, end: 56, within: 0, 100)
        XCTAssertEqual(fixed?.first { $0.id == rallies[2].id }?.isGuess, false, "fixing it means you looked at it")

        // History counts guesses only once confirmed.
        var ex = SessionExercise(exerciseId: "x", targetSets: 0, targetReps: "", targetRestSeconds: 0, sets: [])
        ex.disciplineRaw = WorkoutDiscipline.racket.rawValue
        var log = RacketRecordingLog(startedAt: .now)
        log.rallies = after
        ex.racketRecordingLog = log
        let totals = RacketTagTotals.of([ex])
        XCTAssertEqual(totals.marked, 1, "the tagged one; the untouched guess doesn't count")
        XCTAssertEqual(totals.tagged, 1)
    }

    // MARK: Scan state, compare, ETA, settings

    private func record(_ a: Double, _ b: Double, status: RacketScanRecord.Status, applied: Bool? = nil,
                        version: Int = 1, guesses: [RallyGuess]? = nil, at: Double = 0) -> RacketScanRecord {
        var r = RacketScanRecord(modelID: "snappet.placeholder.motion", modelVersion: version, modelName: "Snappet placeholder",
                                 partStart: a, partEnd: b, startedAt: Date(timeIntervalSince1970: at),
                                 statusRaw: status.rawValue)
        r.applied = applied
        r.guesses = guesses
        return r
    }

    func testScanStatePerRow() {
        var log = RacketRecordingLog(startedAt: .now)
        let current = RacketCapabilityRegistry.placeholder
        XCTAssertEqual(RacketScanState.of(log, partStart: 0, partEnd: 100, current: current), .notScanned)
        var running = record(0, 100, status: .running)
        running.doneSec = 62
        log.scans = [running]
        XCTAssertEqual(RacketScanState.of(log, partStart: 0, partEnd: 100, current: current), .scanning(0.62))
        XCTAssertEqual(RacketScanState.scanning(0.62).chip, "Scanning · 62%")
        log.scans = [record(0, 100, status: .paused)]
        XCTAssertEqual(RacketScanState.of(log, partStart: 0, partEnd: 100, current: current).chip, "Paused at 0%")
        log.scans = [record(0, 100, status: .done, applied: true)]
        XCTAssertEqual(RacketScanState.of(log, partStart: 0, partEnd: 100, current: current),
                       .scanned(modelLabel: "Snappet placeholder v1", newerAvailable: false))
        var v2 = current
        v2.version = 2
        XCTAssertEqual(RacketScanState.of(log, partStart: 0, partEnd: 100, current: v2),
                       .scanned(modelLabel: "Snappet placeholder v1", newerAvailable: true))
        // A whole recording scanned before the split: each game is scanned too.
        log.scans = [record(0, 4450, status: .done, applied: true)]
        XCTAssertTrue(RacketScanState.of(log, partStart: 385, partEnd: 1480, current: current).isScanned)
        var pending = record(0, 100, status: .done, at: 10)
        pending.compare = true
        log.scans = [record(0, 100, status: .done, applied: true), pending]
        XCTAssertEqual(RacketScanState.of(log, partStart: 0, partEnd: 100, current: current), .readyToCompare)
    }

    @MainActor
    func testApplyAndKeepEarlierResults() {
        var log = RacketRecordingLog(startedAt: .now)
        let first = record(0, 100, status: .done, applied: true, guesses: [guess(10, 18)])
        var second = record(0, 100, status: .done, guesses: [guess(10, 13), guess(14, 18), guess(60, 66)], at: 5)
        second.compare = true
        log.scans = [first]
        RacketScanCenter.applyResults(&log, recordID: first.id)
        XCTAssertEqual(log.allRallies.count, 1)
        log.scans = [log.allScans[0], second]
        RacketScanCenter.keepEarlier(&log, recordID: second.id)
        XCTAssertEqual(log.appliedScan(partStart: 0, partEnd: 100)?.id, first.id)
        XCTAssertEqual(log.allRallies.count, 1, "Keep: the timeline doesn't change")
        RacketScanCenter.applyResults(&log, recordID: second.id)
        XCTAssertEqual(log.appliedScan(partStart: 0, partEnd: 100)?.id, second.id)
        XCTAssertEqual(log.allRallies.map(\.startSec), [10, 14, 60])
        XCTAssertEqual(log.allScans.first { $0.id == first.id }?.applied, false)
    }

    func testModelCompareFindsSplitsMergesAndOneSidedRallies() {
        let newer = [guess(10, 13), guess(14, 18), guess(30, 36, winner: "us"), guess(60, 66), guess(80, 90)]
        let older = [guess(10, 18), guess(30, 36, winner: "them"), guess(45, 50), guess(78, 82), guess(84, 90)]
        let r = RacketModelCompare.build(newer: newer, older: older, newerName: "v3", olderName: "v2",
                                         sides: (us: "You", them: "Alex"))
        XCTAssertEqual(r.items.map(\.kind), [.split, .winner, .onlyOld, .onlyNew, .merged])
        XCTAssertEqual(r.items[0].title, "Rally 1 · one rally or two?")
        XCTAssertEqual(r.items[0].newer, "v3: two")
        XCTAssertEqual(r.items[0].older, "v2: one")
        XCTAssertEqual(r.items[1].newer, "v3: You won")
        XCTAssertEqual(r.items[3].title, "Rally 4 · found only by v3")
        XCTAssertEqual(r.items[4].older, "v2: two")
        XCTAssertEqual(r.differencesLine, "5 differences")
        XCTAssertEqual(r.countsLine, "v3 found 5 rallies, v2 found 5")
        let same = RacketModelCompare.build(newer: older, older: older, newerName: "New scan", olderName: "Earlier scan",
                                            sides: (us: "You", them: "Alex"))
        XCTAssertEqual(same.differencesLine, "No differences")
        // Limited to a part.
        let part = RacketModelCompare.build(newer: newer, older: older, newerName: "v3", olderName: "v2",
                                            sides: (us: "You", them: "Alex"), within: 0...40)
        XCTAssertEqual(part.items.map(\.kind), [.split, .winner])
    }

    func testCompareNames() {
        let a = record(0, 1, status: .done), b = record(0, 1, status: .done, version: 2)
        XCTAssertEqual(RacketModelCompare.names(newer: b, older: a).0, "v2")
        XCTAssertEqual(RacketModelCompare.names(newer: a, older: a).1, "Earlier scan")
    }

    func testTimeLeft() {
        XCTAssertNil(RacketScanETA.remaining(doneSec: 10, totalSec: 1200, elapsedWallSec: 5), "too early to tell")
        XCTAssertEqual(RacketScanETA.remaining(doneSec: 600, totalSec: 1200, elapsedWallSec: 120) ?? 0, 120, accuracy: 0.001)
        XCTAssertEqual(RacketScanETA.line(240), "about 4 min left")
        XCTAssertEqual(RacketScanETA.line(30), "under a minute left")
        XCTAssertEqual(RacketScanETA.headline(title: "Game 2", fraction: 0.62, eta: 240), "Game 2 · 62% · about 4 min left")
    }

    func testAfterASessionSetting() {
        XCTAssertEqual(RacketAutoScan.default, .ask)
        XCTAssertEqual(RacketAutoScan.decision(.automatically, unscanned: 3, alreadyHandled: false), .start)
        XCTAssertEqual(RacketAutoScan.decision(.onCharger, unscanned: 3, alreadyHandled: false), .startOnCharger)
        XCTAssertEqual(RacketAutoScan.decision(.ask, unscanned: 3, alreadyHandled: false), .ask)
        XCTAssertEqual(RacketAutoScan.decision(.never, unscanned: 3, alreadyHandled: false), .nothing)
        XCTAssertEqual(RacketAutoScan.decision(.automatically, unscanned: 0, alreadyHandled: false), .nothing)
        XCTAssertEqual(RacketAutoScan.decision(.ask, unscanned: 2, alreadyHandled: true), .nothing)
        XCTAssertEqual(RacketAutoScan.allCases.map(\.title), ["Automatically", "Only on charger", "Ask me", "Never"])
    }

    // MARK: AICompare with Snappet's guesses (prompt 247 → 248)

    func testAICompareUsesSnappetsGuessesAsTheOtherSide() {
        let src = RacketCapabilityRegistry.placeholder.source
        var g = RacketRally(startSec: 10, endSec: 18); g.sourceRaw = src; g.confidence = 0.8; g.guessWinnerRaw = "us"
        let mine = RacketRally(startSec: 30, endSec: 36, winner: .us)
        let ai = [RacketRally(startSec: 10, endSec: 18, winner: .them), RacketRally(startSec: 30, endSec: 36, winner: .them),
                  RacketRally(startSec: 60, endSec: 66)]
        let r = RacketAICompare.build(ai: ai, yours: [g, mine], appName: "ChatGPT", sides: (us: "You", them: "Alex"))
        XCTAssertEqual(r.items.count, 3)
        XCTAssertEqual(r.items[0].yours, "Snappet: You won")
        XCTAssertFalse(r.items[0].protected, "a guess is never protected")
        XCTAssertEqual(r.items[1].yours, "Yours: You won")
        XCTAssertTrue(r.items[1].protected, "your tag stays yours unless you pick that item")
        XCTAssertEqual(r.items[2].yours, "Snappet: Not found")
        let picks = RacketAICompare.useAppForAll(r, current: RacketAICompare.defaultPicks(r))
        let out = RacketAIMerge.apply(r, picks: picks, yours: [g, mine], ai: ai, source: "ai:ChatGPT")
        XCTAssertEqual(out.rallies.first { $0.id == g.id }?.winner, .them)
        XCTAssertEqual(out.rallies.first { $0.id == g.id }?.isGuess, false, "accepted: no longer a guess")
        XCTAssertEqual(out.rallies.first { $0.id == mine.id }?.winner, .us)
    }

    // MARK: Watch point marks (the scan's anchors)

    func testWatchPointTapsAreMarkedWithTheWinnerAndUndoDropsThem() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var m = RacketRecordingMachine(kind: .match, stillPlayingMinutes: nil, now: t0)
        m.start(now: t0)
        var sc = RacketLiveScore(rules: RacketLiveRules(kind: .rally, pointsTo: 11))
        _ = RacketWatchBridge.apply(.pointUs, to: &m, score: &sc, now: t0.addingTimeInterval(20))
        _ = RacketWatchBridge.apply(.pointThem, to: &m, score: &sc, now: t0.addingTimeInterval(45))
        _ = RacketWatchBridge.apply(.undo, to: &m, score: &sc, now: t0.addingTimeInterval(46))
        _ = RacketWatchBridge.apply(.pointThem, to: &m, score: &sc, now: t0.addingTimeInterval(50))
        let points = m.log?.marks.filter { $0.kind == .point } ?? []
        XCTAssertEqual(points.map(\.startSec), [20, 50])
        XCTAssertEqual(points.map(\.index), [0, 1])
        XCTAssertEqual(m.log?.userMarkCount, 0, "point marks aren't user marks")
        let anchors = RacketScanAnchors.anchors(m.log!, from: 0, to: 100)
        XCTAssertEqual(anchors.map(\.winner), [.us, .them])
    }
}
