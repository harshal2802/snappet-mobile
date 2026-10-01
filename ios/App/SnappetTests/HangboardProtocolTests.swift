import XCTest
@testable import Snappet

/// Prompt 140 — hangboard presets, the plain-English summary, adaptive duration steps, the editor draft,
/// and finding routine copies of a preset.
final class HangboardProtocolTests: XCTestCase {

    // MARK: - Presets match the protocols users asked for

    func testMaxHangsPreset() {
        let s = TimedExerciseSpec.maxHangs
        XCTAssertEqual([s.workSec, s.restSec, s.reps, s.sets, s.restBetweenSetsSec], [7, 120, 3, 3, 240])
        // 5 lead-in + 3 × (3×7 + 2×120) + 2×240
        XCTAssertEqual(s.totalSeconds, 5 + 3 * (21 + 240) + 480)
    }

    func testEnduranceAndAbrahangsPresets() {
        let e = TimedExerciseSpec.enduranceRepeaters
        XCTAssertEqual([e.workSec, e.restSec, e.reps, e.sets, e.restBetweenSetsSec], [10, 6, 24, 2, 360])
        let a = TimedExerciseSpec.abrahangs
        XCTAssertEqual([a.workSec, a.restSec, a.reps, a.sets], [10, 20, 20, 1])
        XCTAssertTrue(a.mode.isStructured)
    }

    func testPresetsAreOfferedAsSuggestionsAfterFreeHold() {
        let keys = TimedExerciseCatalog.suggestions.map(\.key)
        XCTAssertEqual(keys.first, "seed.freehold", "UI tests tap Free hold in a half-height sheet")
        XCTAssertTrue(keys.contains("seed.maxhangs"))
        XCTAssertTrue(keys.contains("seed.abrahangs"))
    }

    // MARK: - Sentence

    func testSentenceReadsLikeTheWireframe() {
        XCTAssertEqual(TimedExerciseSpec.maxHangs.sentence,
                       "3 sets × 3 hangs of 7 s · 2 min between hangs · 4 min between sets · 90 % of max · about 21 min")
        XCTAssertEqual(TimedExerciseSpec.abrahangs.sentence,
                       "20 hangs of 10 s · 20 s between hangs · 40 % of max · about 10 min")
        XCTAssertEqual(TimedExerciseSpec.hold(45).sentence, "One hold of 45 s")
        XCTAssertEqual(TimedExerciseSpec(mode: .openCountUp).sentence, "Open hold, counted up")
    }

    func testSpokenDurations() {
        XCTAssertEqual(TimedExerciseSpec.spoken(7), "7 s")
        XCTAssertEqual(TimedExerciseSpec.spoken(120), "2 min")
        XCTAssertEqual(TimedExerciseSpec.spoken(150), "2:30")
    }

    // MARK: - Duration steps

    func testDurationStepsAreFineWhereItMatters() {
        XCTAssertEqual(DurationStep.next(7, up: true, range: 0...3600), 8)
        XCTAssertEqual(DurationStep.next(30, up: true, range: 0...3600), 35)
        XCTAssertEqual(DurationStep.next(30, up: false, range: 0...3600), 29)
        XCTAssertEqual(DurationStep.next(120, up: true, range: 0...3600), 135)
        XCTAssertEqual(DurationStep.next(120, up: false, range: 0...3600), 115)
        XCTAssertEqual(DurationStep.next(600, up: true, range: 0...3600), 660)
        XCTAssertEqual(DurationStep.next(0, up: false, range: 0...3600), 0)
    }

    func testReachingTwoMinutesTakesFewTaps() {
        var v = 0, taps = 0
        while v < 120 { v = DurationStep.next(v, up: true, range: 0...3600); taps += 1 }
        XCTAssertEqual(v, 120)
        XCTAssertLessThan(taps, 50, "used to be 120 taps of ±1 s")
    }

    // MARK: - Draft

    func testDraftRoundTripsEveryField() {
        let draft = ProtocolDraft(name: "Max", category: .hangboard, spec: .maxHangs)
        XCTAssertEqual(draft.spec, .maxHangs)
    }

    func testApplyingAPresetKeepsATypedNameButFillsAnEmptyOne() {
        var named = ProtocolDraft(name: "My hangs", spec: .hold(30))
        named.apply(.maxHangs, name: "Max hangs")
        XCTAssertEqual(named.name, "My hangs")
        XCTAssertEqual(named.spec, .maxHangs)
        var empty = ProtocolDraft(spec: .hold(30))
        empty.apply(.abrahangs, name: "Abrahangs")
        XCTAssertEqual(empty.name, "Abrahangs")
    }

    func testSingleSetDropsBetweenSetRest() {
        var d = ProtocolDraft(spec: .maxHangs)
        d.sets = 1
        XCTAssertEqual(d.spec.restBetweenSetsSec, 0)
    }

    // MARK: - Copies

    func testOnlyUnchangedCopiesOfThePresetMatch() {
        let preset = UUID()
        let key = ProtocolCopies.exerciseID(forPreset: preset)
        func block(_ id: String, _ spec: TimedExerciseSpec) -> RoutineExercise {
            RoutineExercise(exerciseId: id, sets: 1, reps: "", restSeconds: 0, discipline: .timed,
                            timedSpecData: try? JSONEncoder().encode(spec))
        }
        var tweaked = TimedExerciseSpec.maxHangs
        tweaked.reps = 4
        let blocks = [block(key, .maxHangs), block(key, tweaked), block("timed:\(UUID())", .maxHangs),
                      RoutineExercise(exerciseId: "bench", sets: 3, reps: "8", restSeconds: 90)]
        XCTAssertEqual(ProtocolCopies.matchingBlockIndices(in: blocks, presetID: preset, oldSpec: .maxHangs), [0])
    }
}
