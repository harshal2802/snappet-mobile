import XCTest
@testable import Snappet

/// Unit tests for the **pure** routine-share codec `SharedRoutine` (workout-redesign E6). This is the
/// off-device-testable half of QR routine sharing: a compact `snappet://routine/v1/<blob>` URL
/// (deflate + base64url, `exerciseId` references) round-trips a whole routine so a scanned/opened code
/// rebuilds it on another phone, offline. The camera scan stays device-pending.
final class SharedRoutineTests: XCTestCase {

    // MARK: - Fixtures

    /// A realistic mixed 11-block routine (strength + timed + climb + run) — the "10–12 exercise" case
    /// the design wants measured for the QR-vs-link threshold.
    private func mixedRoutine(blocks count: Int = 11) -> [RoutineExercise] {
        var out: [RoutineExercise] = []
        let strengthIds = ["barbell_bench_press", "barbell_squat", "deadlift", "overhead_press",
                           "barbell_row", "pull_up", "dumbbell_curl", "tricep_dip"]
        for i in 0..<count {
            switch i % 4 {
            case 0:
                out.append(RoutineExercise(exerciseId: strengthIds[i % strengthIds.count],
                                           sets: 4, reps: "8-12", restSeconds: 90,
                                           weight: 60 + Double(i), weightUnit: .kg))
            case 1:
                out.append(RoutineExercise(exerciseId: "plank", sets: 3, reps: "", restSeconds: 30,
                                           discipline: .timed, targetDurationSec: 45,
                                           timedSpecData: try? JSONEncoder().encode(TimedExerciseSpec.hold(45)),
                                           timedCategory: "core"))
            case 2:
                out.append(RoutineExercise(exerciseId: "boulder", sets: 5, reps: "", restSeconds: 120,
                                           discipline: .climb, climbTypeRaw: ClimbType.boulder.rawValue,
                                           climbGradeLabel: "V4", climbGradeScaleRaw: GradeScale.vScale.rawValue))
            default:
                out.append(RoutineExercise(exerciseId: "run", sets: 1, reps: "", restSeconds: 0,
                                           discipline: .run, targetDistanceMeters: 5000, targetRPE: 6))
            }
        }
        return out
    }

    // MARK: - Round-trip

    func testRoundTripPreservesEveryBlockField() throws {
        let exercises = mixedRoutine()
        let shared = SharedRoutine(name: "Mixed Day", detail: "A mixed modality session", exercises: exercises)
        let url = try XCTUnwrap(shared.url)
        XCTAssertTrue(url.absoluteString.hasPrefix("snappet://routine/v1/"), "versioned wire form")

        let decoded = try XCTUnwrap(SharedRoutine(decoding: url.absoluteString))
        XCTAssertEqual(decoded.name, "Mixed Day")
        XCTAssertEqual(decoded.detail, "A mixed modality session")
        XCTAssertEqual(decoded.exercises.count, exercises.count)

        // Rebuild RoutineExercises and compare the meaningful prescription fields (ids differ — fresh UUIDs).
        let rebuilt = decoded.routineExercises()
        XCTAssertEqual(rebuilt.count, exercises.count)
        for (a, b) in zip(exercises, rebuilt) {
            XCTAssertEqual(a.exerciseId, b.exerciseId)
            XCTAssertEqual(a.sets, b.sets)
            XCTAssertEqual(a.reps, b.reps)
            XCTAssertEqual(a.restSeconds, b.restSeconds)
            XCTAssertEqual(a.weight, b.weight)
            XCTAssertEqual(a.weightUnit, b.weightUnit)
            XCTAssertEqual(a.discipline, b.discipline)
            XCTAssertEqual(a.targetDurationSec, b.targetDurationSec)
            XCTAssertEqual(a.targetDistanceMeters, b.targetDistanceMeters)
            XCTAssertEqual(a.targetRPE, b.targetRPE)
            XCTAssertEqual(a.climbTypeRaw, b.climbTypeRaw)
            XCTAssertEqual(a.climbGradeLabel, b.climbGradeLabel)
            XCTAssertEqual(a.climbGradeScaleRaw, b.climbGradeScaleRaw)
            XCTAssertEqual(a.timedCategory, b.timedCategory)
            XCTAssertEqual(a.timedSpec, b.timedSpec)
        }
    }

    func testRebuiltBlocksGetFreshIdsNeverOverwrite() {
        let exercises = mixedRoutine(blocks: 4)
        let shared = SharedRoutine(name: "X", detail: nil, exercises: exercises)
        let rebuilt = shared.routineExercises()
        // New ids — an import never collides with the source routine's block ids.
        for (a, b) in zip(exercises, rebuilt) { XCTAssertNotEqual(a.id, b.id) }
    }

    func testStrengthBlockKeepsDisciplineRawNilForByteStability() throws {
        let shared = SharedRoutine(name: "S", detail: nil,
                                   exercises: [RoutineExercise(exerciseId: "barbell_squat", sets: 5,
                                                               reps: "5", restSeconds: 120,
                                                               weight: 100, weightUnit: .kg)])
        let decoded = try XCTUnwrap(SharedRoutine(decoding: try XCTUnwrap(shared.url).absoluteString))
        // A strength block has no disciplineRaw on the wire (it derives .strength), like a local one.
        XCTAssertNil(decoded.exercises.first?.disciplineRaw)
        XCTAssertEqual(decoded.routineExercises().first?.discipline, .strength)
    }

    func testEmptyRoutineRoundTrips() throws {
        let shared = SharedRoutine(name: "Empty", detail: nil, exercises: [])
        let decoded = try XCTUnwrap(SharedRoutine(decoding: try XCTUnwrap(shared.url).absoluteString))
        XCTAssertEqual(decoded.name, "Empty")
        XCTAssertTrue(decoded.exercises.isEmpty)
    }

    // MARK: - Size (the QR-vs-link threshold, README §10 Q4)

    func testRealistic11BlockRoutineFitsInAScannableQR() {
        let shared = SharedRoutine(name: "Full Body Mixed", detail: "Push / pull / legs + a core circuit",
                                   exercises: mixedRoutine(blocks: 11))
        // Print the measured size so the threshold call is evidenced (shows up in test logs).
        print("SharedRoutine 11-block encoded byte size = \(shared.encodedByteCount) (cap \(SharedRoutine.scannableURLByteCap))")
        XCTAssertGreaterThan(shared.encodedByteCount, 0)
        XCTAssertTrue(shared.fitsInScannableQR,
                      "a realistic 11-block routine should fit a scannable QR (was \(shared.encodedByteCount) bytes)")
    }

    func testCompressionActuallyShrinksTheBlob() {
        // The deflate step should make a routine of repetitive blocks much smaller than its raw JSON.
        let exercises = mixedRoutine(blocks: 11)
        let shared = SharedRoutine(name: "Full Body Mixed", detail: nil, exercises: exercises)
        let rawJSON = try? JSONEncoder().encode(shared)
        XCTAssertNotNil(rawJSON)
        // The blob portion is the path after the version segment.
        let blob = shared.encoded.components(separatedBy: "/v1/").last ?? ""
        XCTAssertLessThan(blob.utf8.count, rawJSON!.count,
                          "deflate+base64url blob should be smaller than the raw JSON")
    }

    func testHugeRoutineFallsBackToLink() {
        // A routine with many blocks carrying DISTINCT (incompressible) custom names + notes — the realistic
        // way to exceed a scannable QR. (Deflate crushes repetitive content, so a routine only really blows
        // past the cap when its content is genuinely diverse — exactly the case worth falling back on.)
        var exercises: [RoutineExercise] = []
        for i in 0..<40 {
            let token = UUID().uuidString   // high-entropy: won't compress
            exercises.append(RoutineExercise(exerciseId: "custom-\(token)", sets: 5, reps: "8-12",
                                             restSeconds: 90, weight: 60 + Double(i), weightUnit: .kg,
                                             notes: "Cue \(token): focus on \(token.prefix(8)) tempo.",
                                             displayName: "Movement \(token.prefix(6))"))
        }
        let shared = SharedRoutine(name: "Mega Custom Program", detail: nil, exercises: exercises)
        print("SharedRoutine 40-block diverse encoded byte size = \(shared.encodedByteCount)")
        XCTAssertFalse(shared.fitsInScannableQR, "a 40-block diverse routine should exceed the QR cap")
        // But it still produces a valid, decodable URL (the link/file path stays usable).
        XCTAssertNotNil(shared.url)
        XCTAssertNotNil(SharedRoutine(decoding: shared.encoded))
    }

    // MARK: - explainMissing (the unresolvable-exercise landing)

    func testUnresolvableExerciseIdsAreFlagged() {
        let exercises = [
            RoutineExercise(exerciseId: "barbell_squat", sets: 5, reps: "5", restSeconds: 120),
            RoutineExercise(exerciseId: "custom-ABC123", sets: 3, reps: "10", restSeconds: 60,
                            displayName: "Sled Drag"),
            RoutineExercise(exerciseId: "custom-DEF456", sets: 3, reps: "10", restSeconds: 60),
        ]
        let shared = SharedRoutine(name: "Mixed", detail: nil, exercises: exercises)
        // Resolver knows only the catalog id.
        let known: Set<String> = ["barbell_squat"]
        let missing = shared.unresolvableExerciseIds { known.contains($0) }
        XCTAssertEqual(missing, ["custom-ABC123", "custom-DEF456"])
    }

    func testCustomExerciseKeepsItsInlineDisplayName() throws {
        let exercises = [RoutineExercise(exerciseId: "custom-ABC123", sets: 3, reps: "10", restSeconds: 60,
                                         displayName: "Sled Drag", discipline: .strength)]
        let shared = SharedRoutine(name: "Custom Day", detail: nil, exercises: exercises)
        let decoded = try XCTUnwrap(SharedRoutine(decoding: try XCTUnwrap(shared.url).absoluteString))
        // The custom block survives with its inline name so it's still legible after import.
        XCTAssertEqual(decoded.exercises.first?.displayName, "Sled Drag")
        XCTAssertEqual(decoded.routineExercises().first?.displayName, "Sled Drag")
    }

    func testAllResolvableYieldsNoMissing() {
        let shared = SharedRoutine(name: "Strength", detail: nil,
                                   exercises: [RoutineExercise(exerciseId: "barbell_squat", sets: 5,
                                                               reps: "5", restSeconds: 120)])
        XCTAssertTrue(shared.unresolvableExerciseIds { _ in true }.isEmpty)
    }

    // MARK: - Rejection / version

    func testRejectsForeignAndMalformedCodes() {
        for bad in [
            "snappet://kilter/climb/abc",        // our scheme, a climb (not a routine)
            "snappet://routine/v1/",             // missing blob
            "snappet://routine/notaversion/xyz", // bad version segment
            "snappet://routine",                 // no path
            "https://example.com/routine/v1/abc",// wrong scheme
            "snappet://routine/v1/!!!notbase64", // undecodable blob
            "abc123", "",
        ] {
            XCTAssertNil(SharedRoutine(decoding: bad), "should reject \(bad)")
        }
    }

    func testRejectsWrongVersionSegment() {
        // A v2 code (a future format) must not decode as v1 — the version is enforced.
        let shared = SharedRoutine(name: "X", detail: nil, exercises: [])
        let v1 = try? XCTUnwrap(shared.url).absoluteString
        let v2 = v1?.replacingOccurrences(of: "/v1/", with: "/v2/")
        XCTAssertNotNil(v2)
        XCTAssertNil(SharedRoutine(decoding: v2!))
    }

    func testSchemeAndHostAreCaseInsensitive() throws {
        let shared = SharedRoutine(name: "X", detail: nil,
                                   exercises: [RoutineExercise(exerciseId: "barbell_squat", sets: 5,
                                                               reps: "5", restSeconds: 120)])
        let upper = try XCTUnwrap(shared.url).absoluteString
            .replacingOccurrences(of: "snappet://routine", with: "SNAPPET://ROUTINE")
        XCTAssertNotNil(SharedRoutine(decoding: "  \(upper)  "), "trim + case-insensitive scheme/host")
    }
}

/// The base64url + raw-deflate primitives the codec is built on.
final class SharedRoutineCodecPrimitiveTests: XCTestCase {

    func testBase64URLRoundTrip() {
        let data = Data((0..<256).map { UInt8($0) })   // includes bytes that produce +, /, = in std base64
        let s = Base64URL.encode(data)
        XCTAssertFalse(s.contains("+"))
        XCTAssertFalse(s.contains("/"))
        XCTAssertFalse(s.contains("="))
        XCTAssertEqual(Base64URL.decode(s), data)
    }

    func testBase64URLDecodeRejectsGarbage() {
        XCTAssertNil(Base64URL.decode("@@@@"))
    }

    func testDeflateInflateRoundTrip() throws {
        let original = Data(String(repeating: "the quick brown fox ", count: 200).utf8)
        let deflated = try XCTUnwrap(ZlibCodec.deflate(original))
        XCTAssertLessThan(deflated.count, original.count, "repetitive text should compress")
        let inflated = try XCTUnwrap(ZlibCodec.inflate(deflated))
        XCTAssertEqual(inflated, original)
    }

    func testDeflateInflateEmpty() {
        XCTAssertEqual(ZlibCodec.deflate(Data()), Data())
        XCTAssertEqual(ZlibCodec.inflate(Data()), Data())
    }

    func testInflateRejectsTruncatedStream() {
        let original = Data(String(repeating: "abcdefghij", count: 100).utf8)
        let deflated = ZlibCodec.deflate(original)!
        let truncated = deflated.prefix(deflated.count / 2)
        // A half stream should not inflate to the original (returns nil or different bytes).
        XCTAssertNotEqual(ZlibCodec.inflate(Data(truncated)), original)
    }
}
