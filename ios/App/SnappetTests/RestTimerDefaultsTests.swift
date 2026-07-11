import XCTest
@testable import Snappet

/// Unit tests for the **pure** `RestTimerDefaults` (Quick Session redesign Phase 7) — the per-context
/// persistence key, the clamp, the seeded suggestions, and the remember/recall + JSON round-trip. No
/// UserDefaults, no view, no device.
final class RestTimerDefaultsTests: XCTestCase {

    // MARK: - Keys

    func testContextKeysAreStableAndDistinct() {
        XCTAssertEqual(RestTimerDefaults.Context.climb(.boulder).key, "climb.boulder")
        XCTAssertEqual(RestTimerDefaults.Context.climb(.lead).key, "climb.lead")
        XCTAssertEqual(RestTimerDefaults.Context.timed(.hangboard).key, "timed.hangboard")
        XCTAssertEqual(RestTimerDefaults.Context.lifting.key, "lifting")
        // A boulder rest and a lead rest must not share a bucket.
        XCTAssertNotEqual(RestTimerDefaults.Context.climb(.boulder).key,
                          RestTimerDefaults.Context.climb(.lead).key)
    }

    // MARK: - Suggested defaults

    func testSuggestedDefaultsPerDiscipline() {
        // Boulder rests are shorter than roped rests.
        XCTAssertEqual(RestTimerDefaults.Context.climb(.boulder).suggestedSeconds, 120)
        XCTAssertEqual(RestTimerDefaults.Context.climb(.lead).suggestedSeconds, 240)
        XCTAssertEqual(RestTimerDefaults.Context.climb(.topRope).suggestedSeconds, 240)
        XCTAssertEqual(RestTimerDefaults.Context.climb(.sport).suggestedSeconds, 240)
        // Hangboard protocols rest longer than a generic timed hold.
        XCTAssertEqual(RestTimerDefaults.Context.timed(.hangboard).suggestedSeconds, 180)
        XCTAssertEqual(RestTimerDefaults.Context.timed(.core).suggestedSeconds, 60)
        XCTAssertEqual(RestTimerDefaults.Context.lifting.suggestedSeconds, 120)
        // Every suggested default is already in band (no clamp surprise).
        for ctx: RestTimerDefaults.Context in [.climb(.boulder), .climb(.lead),
                                               .timed(.hangboard), .timed(.other), .lifting] {
            XCTAssertEqual(RestTimerDefaults.clamp(ctx.suggestedSeconds), ctx.suggestedSeconds)
        }
    }

    // MARK: - Clamp

    func testClampBounds() {
        XCTAssertEqual(RestTimerDefaults.clamp(0), RestTimerDefaults.minSeconds)
        XCTAssertEqual(RestTimerDefaults.clamp(-100), RestTimerDefaults.minSeconds)
        XCTAssertEqual(RestTimerDefaults.clamp(5), RestTimerDefaults.minSeconds)
        XCTAssertEqual(RestTimerDefaults.clamp(99_999), RestTimerDefaults.maxSeconds)
        XCTAssertEqual(RestTimerDefaults.clamp(90), 90)
        XCTAssertEqual(RestTimerDefaults.clamp(RestTimerDefaults.minSeconds), RestTimerDefaults.minSeconds)
        XCTAssertEqual(RestTimerDefaults.clamp(RestTimerDefaults.maxSeconds), RestTimerDefaults.maxSeconds)
    }

    // MARK: - Remember / recall

    func testRememberedFallsBackToSuggestionWhenAbsent() {
        let empty: [String: Int] = [:]
        XCTAssertEqual(RestTimerDefaults.remembered(for: .climb(.boulder), in: empty), 120)
        XCTAssertEqual(RestTimerDefaults.remembered(for: .timed(.hangboard), in: empty), 180)
    }

    func testRememberedReadsStoredValueClamped() {
        let map = ["climb.boulder": 75, "timed.hangboard": 99_999, "lifting": 0]
        XCTAssertEqual(RestTimerDefaults.remembered(for: .climb(.boulder), in: map), 75)
        // Out-of-band stored values are clamped on read.
        XCTAssertEqual(RestTimerDefaults.remembered(for: .timed(.hangboard), in: map),
                       RestTimerDefaults.maxSeconds)
        XCTAssertEqual(RestTimerDefaults.remembered(for: .lifting, in: map),
                       RestTimerDefaults.minSeconds)
    }

    func testRememberingWritesClampedAndIsImmutable() {
        let map = ["climb.lead": 240]
        let next = RestTimerDefaults.remembering(180, for: .climb(.boulder), in: map)
        // Original is untouched (value semantics).
        XCTAssertEqual(map, ["climb.lead": 240])
        XCTAssertEqual(next["climb.boulder"], 180)
        XCTAssertEqual(next["climb.lead"], 240)   // other contexts preserved
        // Remembering an out-of-band value stores the clamped one.
        let clamped = RestTimerDefaults.remembering(5, for: .lifting, in: next)
        XCTAssertEqual(clamped["lifting"], RestTimerDefaults.minSeconds)
        // Overwriting the same context replaces, not appends.
        let overwritten = RestTimerDefaults.remembering(90, for: .climb(.boulder), in: next)
        XCTAssertEqual(overwritten["climb.boulder"], 90)
        XCTAssertEqual(overwritten.count, next.count)
    }

    // MARK: - Prescribed rest (routine `targetRestSeconds`)

    func testPrescribedRestSeedsWhenNothingRemembered() {
        let empty: [String: Int] = [:]
        // A routine's prescribed rest wins over the seeded suggestion when nothing's remembered yet.
        XCTAssertEqual(RestTimerDefaults.remembered(for: .lifting, in: empty, prescribed: 90), 90)
        // …and is clamped like any other candidate.
        XCTAssertEqual(RestTimerDefaults.remembered(for: .lifting, in: empty, prescribed: 5),
                       RestTimerDefaults.minSeconds)
        // No prescription (nil or ≤ 0) → identical to the seeded suggestion.
        XCTAssertEqual(RestTimerDefaults.remembered(for: .lifting, in: empty, prescribed: nil), 120)
        XCTAssertEqual(RestTimerDefaults.remembered(for: .lifting, in: empty, prescribed: 0), 120)
    }

    func testStoredValueWinsOverPrescription() {
        // Once the user has remembered a rest for the context, their value beats the prescription.
        let map = ["lifting": 150]
        XCTAssertEqual(RestTimerDefaults.remembered(for: .lifting, in: map, prescribed: 90), 150)
    }

    // MARK: - JSON round-trip

    func testEncodeDecodeRoundTrips() {
        let map = ["climb.boulder": 90, "timed.hangboard": 180, "lifting": 120]
        let encoded = RestTimerDefaults.encode(map)
        XCTAssertEqual(RestTimerDefaults.decode(encoded), map)
    }

    func testDecodeMalformedDegradesToEmpty() {
        XCTAssertEqual(RestTimerDefaults.decode(""), [:])
        XCTAssertEqual(RestTimerDefaults.decode("not json"), [:])
        XCTAssertEqual(RestTimerDefaults.decode("{}"), [:])
        // Encode of an empty map decodes back to empty (and is a valid JSON object).
        XCTAssertEqual(RestTimerDefaults.decode(RestTimerDefaults.encode([:])), [:])
    }
}
