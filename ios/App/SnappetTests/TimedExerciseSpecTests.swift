import XCTest
@testable import Snappet

/// Unit tests for the **pure** `TimedExerciseSpec` value type (Quick Session redesign Phase 5) — no
/// device, no SwiftData, no SwiftUI. Exercises the structure math (`totalSeconds`), the one-line
/// `summary`, the protocol-preset factories, the clamping init, and the Codable round-trip the
/// catalog/session blobs rely on.
final class TimedExerciseSpecTests: XCTestCase {

    // MARK: - Total seconds

    func testOpenCountUpHasNoPrescribedTotal() {
        XCTAssertNil(TimedExerciseSpec(mode: .openCountUp).totalSeconds)
    }

    func testSingleHoldTotalIsLeadInPlusHold() {
        // A 10 s count-down with a 3 s lead-in → 13 s prescribed.
        XCTAssertEqual(TimedExerciseSpec.hold(10).totalSeconds, 13)
        // A 10 s max hang, default lead-in 3 → 13 s.
        XCTAssertEqual(TimedExerciseSpec.maxHang10.totalSeconds, 13)
    }

    func testRepeatersTotalAccountsForInterRepAndBetweenSetRest() {
        // 7:3 × 6, six sets, 180 s between sets, 3 s lead-in.
        // Per set: 6 work (42 s) + 5 inter-rep rests (15 s) = 57 s.
        // Six sets = 342 s; 5 between-set rests = 900 s; + 3 lead-in = 1245 s.
        XCTAssertEqual(TimedExerciseSpec.repeaters7x3x6.totalSeconds, 1245)
    }

    func testTabataTotal() {
        // 20:10 × 8, one set, default 3 s lead-in.
        // 8 work (160 s) + 7 inter-rep rests (70 s) = 230 s; + 3 lead-in = 233 s.
        XCTAssertEqual(TimedExerciseSpec.tabata.totalSeconds, 233)
    }

    func testNoBetweenSetRestAfterLastSet() {
        // Two sets of a single 10 s rep, 60 s between sets, lead-in 0.
        // Per set 10 s; two sets 20 s; one between-set rest 60 s → 80 s (NOT 140 — no trailing rest).
        let spec = TimedExerciseSpec(mode: .repeaters, workSec: 10, restSec: 0, reps: 1, sets: 2,
                                     restBetweenSetsSec: 60, leadInSec: 0)
        XCTAssertEqual(spec.totalSeconds, 80)
    }

    // MARK: - Summary

    func testSummaries() {
        XCTAssertEqual(TimedExerciseSpec(mode: .openCountUp).summary, "Count up")
        XCTAssertEqual(TimedExerciseSpec.maxHang10.summary, "10s hold")
        XCTAssertEqual(TimedExerciseSpec.hold(60).summary, "60s hold")
        XCTAssertEqual(TimedExerciseSpec.repeaters7x3x6.summary, "7:3 × 6 · 6 sets")
        XCTAssertEqual(TimedExerciseSpec.tabata.summary, "20:10 × 8")
        XCTAssertEqual(TimedExerciseSpec.emom.summary, "EMOM × 10")
    }

    func testRepeatersSummaryDropsSetCountWhenOne() {
        let one = TimedExerciseSpec(mode: .repeaters, workSec: 7, restSec: 3, reps: 6, sets: 1)
        XCTAssertEqual(one.summary, "7:3 × 6")
    }

    // MARK: - Preset values

    func testPresetValues() {
        let rep = TimedExerciseSpec.repeaters7x3x6
        XCTAssertEqual(rep.mode, .repeaters)
        XCTAssertEqual(rep.workSec, 7)
        XCTAssertEqual(rep.restSec, 3)
        XCTAssertEqual(rep.reps, 6)
        XCTAssertEqual(rep.sets, 6)

        XCTAssertEqual(TimedExerciseSpec.maxHang10.workSec, 10)
        XCTAssertEqual(TimedExerciseSpec.maxHang7.workSec, 7)

        let tab = TimedExerciseSpec.tabata
        XCTAssertEqual(tab.mode, .tabata)
        XCTAssertEqual(tab.workSec, 20)
        XCTAssertEqual(tab.restSec, 10)
        XCTAssertEqual(tab.reps, 8)

        XCTAssertEqual(TimedExerciseSpec.emom.mode, .emom)
        XCTAssertEqual(TimedExerciseSpec.emom.reps, 10)
    }

    // MARK: - Clamping init (a value the UI hands in is never out of range)

    func testInitClampsToSaneBounds() {
        let spec = TimedExerciseSpec(mode: .repeaters, workSec: -5, restSec: -1, reps: 0, sets: 0,
                                     restBetweenSetsSec: -10, leadInSec: -3)
        XCTAssertEqual(spec.workSec, 0)
        XCTAssertEqual(spec.restSec, 0)
        XCTAssertEqual(spec.reps, 1, "reps clamps to at least 1 — a structure has ≥ 1 rep")
        XCTAssertEqual(spec.sets, 1, "sets clamps to at least 1")
        XCTAssertEqual(spec.restBetweenSetsSec, 0)
        XCTAssertEqual(spec.leadInSec, 0)
    }

    // MARK: - Mode classification

    func testStructuredClassification() {
        for m in [TimedExerciseSpec.Mode.openCountUp, .maxHang, .countDown] {
            XCTAssertFalse(m.isStructured, "\(m) is a simple single-clock effort (Phase 5)")
        }
        for m in [TimedExerciseSpec.Mode.repeaters, .tabata, .emom] {
            XCTAssertTrue(m.isStructured, "\(m) is a structured protocol (Phase 6 runner)")
        }
    }

    // MARK: - Codable round-trip (the catalog/session blob contract)

    func testCodableRoundTrip() throws {
        let original = TimedExerciseSpec.repeaters7x3x6
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TimedExerciseSpec.self, from: data)
        XCTAssertEqual(original, decoded)
    }
}
