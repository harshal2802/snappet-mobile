import XCTest
@testable import Snappet

/// Prompt 142 — load (added / pulley) and one-hand protocols: the math, the per-hand timeline, the set
/// record, and that nothing existing changes bytes.
final class HangLoadHandsTests: XCTestCase {

    // MARK: - Load

    func testAddedAndAssistedLoad() {
        XCTAssertEqual(HangLoad(kind: .added, amount: 10).signedKg, 10)
        XCTAssertEqual(HangLoad(kind: .assisted, amount: 25).signedKg, -25)
        XCTAssertEqual(HangLoad(kind: .added, amount: 10).totalKg(bodyweightKg: 70), 80)
        XCTAssertEqual(HangLoad(kind: .assisted, amount: 25).totalKg(bodyweightKg: 70), 45)
        XCTAssertEqual(HangLoad(kind: .assisted, amount: 90).totalKg(bodyweightKg: 70), 0, "never negative")
    }

    func testPoundsConvert() {
        XCTAssertEqual(HangLoad(kind: .added, amount: 22.5, unitRaw: "lb").signedKg, 22.5 * 0.45359237, accuracy: 1e-9)
    }

    func testZeroLoadIsBodyweight() {
        let spec = TimedExerciseSpec(mode: .repeaters, workSec: 7, reps: 3, load: HangLoad(kind: .added, amount: 0))
        XCTAssertNil(spec.load)
    }

    // MARK: - Hands

    func testAlternateIsPerHandLeftRight() {
        let seq = HandMode.alternate.sequence(reps: 3).map { "\($0.hand == .left ? "L" : "R")\($0.rep)" }
        XCTAssertEqual(seq, ["L1", "R1", "L2", "R2", "L3", "R3"])
        let lr = HandMode.leftThenRight.sequence(reps: 2).map { "\($0.hand == .left ? "L" : "R")\($0.rep)" }
        XCTAssertEqual(lr, ["L1", "L2", "R1", "R2"])
        XCTAssertEqual(HandMode.rightOnly.sequence(reps: 2).map(\.hand), [.right, .right])
    }

    func testOneHandScheduleDoublesHangsAndLabelsHands() {
        var spec = TimedExerciseSpec.maxHangs          // 3 × 3 × 7 s, 120 s rest, 240 s between sets
        spec.handMode = .alternate
        let s = IntervalSchedule(spec: spec)
        let work = s.phases.filter(\.isWork)
        XCTAssertEqual(work.count, 3 * 6)
        XCTAssertEqual(work.prefix(4).map { $0.hand }, [.left, .right, .left, .right])
        XCTAssertEqual(s.totalSeconds, spec.totalSeconds, "spec total accounts for per-hand reps")
        XCTAssertEqual(spec.totalSeconds, 5 + 3 * (6 * 7 + 5 * 120) + 2 * 240)
        XCTAssertEqual(s.nextWorkHand(after: work[0]), .right)
    }

    func testBothHandsScheduleIsUnchanged() {
        let s = IntervalSchedule(spec: .maxHangs)
        XCTAssertTrue(s.phases.allSatisfy { $0.hand == nil })
        XCTAssertEqual(s.phases.filter(\.isWork).count, 9)
    }

    // MARK: - Sentence + set record

    func testSentenceMentionsHandsAndLoad() {
        var spec = TimedExerciseSpec.maxHangs
        spec.handMode = .alternate
        spec.load = HangLoad(kind: .assisted, amount: 25)
        XCTAssertTrue(spec.sentence.hasPrefix("3 sets × 3 hangs of 7 s each hand, alternating"), spec.sentence)
        XCTAssertTrue(spec.sentence.contains("pulley −25 kg"), spec.sentence)
    }

    func testSetRowShowsLoadAndHands() {
        var log = SetLog(durationSec: 63)
        log.loadKg = 12.5
        XCTAssertEqual(SetMeasure.summary(log, kind: .duration, unit: .kg), "1:03 · +12.5 kg")
        log.loadKg = -25
        log.handModeRaw = HandMode.alternate.rawValue
        XCTAssertEqual(SetMeasure.summary(log, kind: .duration, unit: .kg), "1:03 · −25 kg assist · one hand, each side")
        XCTAssertEqual(SetMeasure.summary(SetLog(durationSec: 63), kind: .duration, unit: .kg), "1:03", "plain holds unchanged")
    }

    // MARK: - Back-compat

    func testExistingProtocolsKeepTheirBytes() throws {
        let json = String(decoding: try JSONEncoder().encode(TimedExerciseSpec.repeaters7x3x6), as: UTF8.self)
        XCTAssertFalse(json.contains("load"))
        XCTAssertFalse(json.contains("handMode"))
        let log = String(decoding: try JSONEncoder().encode(SetLog(durationSec: 10)), as: UTF8.self)
        XCTAssertFalse(log.contains("loadKg"))
    }

    func testLoadAndHandsRoundTrip() throws {
        var spec = TimedExerciseSpec.abrahangs
        spec.load = HangLoad(kind: .added, amount: 71.3, unitRaw: "lb")
        spec.handMode = .leftOnly
        let back = try JSONDecoder().decode(TimedExerciseSpec.self, from: JSONEncoder().encode(spec))
        XCTAssertEqual(back, spec)
        XCTAssertEqual(back.load?.amount, 71.3)
    }

    func testDraftCarriesLoadAndHands() {
        var spec = TimedExerciseSpec.maxHangs
        spec.load = HangLoad(kind: .added, amount: 10)
        spec.handMode = .alternate
        XCTAssertEqual(ProtocolDraft(spec: spec).spec, spec)
    }
}
