import XCTest
@testable import Snappet

/// Unit tests for the **pure** previous-climbs catalog (prompt 81): the dedup / ordering / cap of distinct
/// past climbs derived from session history, and the search + filter rail. No SwiftUI, SwiftData, or device
/// — `PreviousClimb` is Foundation-only so the "re-log a previous climb" logic is verified without Photos.
final class PreviousClimbTests: XCTestCase {

    // MARK: - Fixtures

    /// A climb `SessionExercise` (kind `.climbAttempt`) with the given identity fields and attempt outcomes.
    private func climb(_ name: String, type: ClimbType = .boulder, scale: GradeScale = .vScale,
                       grade: String = "V4", gym: String? = nil, wall: String? = nil,
                       color: ClimbColor? = nil, statuses: [KilterAscentStatus] = []) -> SessionExercise {
        var ex = SessionExercise(exerciseId: "adhoc-climbAttempt", targetSets: 0, targetReps: "",
                                 targetRestSeconds: 0, sets: statuses.map { SetLog(climbStatusRaw: $0.rawValue) },
                                 displayName: name, kindRaw: SetKind.climbAttempt.rawValue)
        ex.climbTypeRaw = type.rawValue
        ex.climbGradeLabel = grade
        ex.climbGradeScaleRaw = scale.rawValue
        ex.gym = gym; ex.wall = wall; ex.climbColorRaw = color?.rawValue
        return ex
    }

    private func at(_ secs: TimeInterval) -> Date { Date(timeIntervalSince1970: secs) }

    // MARK: - Catalog: dedup / order / cap

    func testCatalogDedupKeepsMostRecentInstance() {
        // Same climb logged twice (older first in the input) — one entry, stamped with the most recent time.
        let entries: [(exercise: SessionExercise, loggedAt: Date)] = [
            (climb("Crimp Master", grade: "V5", gym: "Movement"), at(100)),   // newest
            (climb("Crimp Master", grade: "V5", gym: "Movement"), at(50)),    // older dup
        ]
        let catalog = PreviousClimb.catalog(from: entries)
        XCTAssertEqual(catalog.count, 1)
        XCTAssertEqual(catalog[0].params.name, "Crimp Master")
        XCTAssertEqual(catalog[0].lastLoggedAt, at(100))
    }

    func testCatalogOrdersMostRecentFirst() {
        let entries: [(exercise: SessionExercise, loggedAt: Date)] = [
            (climb("Old", grade: "V1"), at(10)),
            (climb("New", grade: "V8"), at(90)),
            (climb("Mid", grade: "V4"), at(50)),
        ]
        let names = PreviousClimb.catalog(from: entries).map(\.params.name)
        XCTAssertEqual(names, ["New", "Mid", "Old"])
    }

    func testCatalogTieBreaksByInputOrder() {
        // Equal timestamps (e.g. two climbs logged in the same live session) keep input order — callers
        // pass the live session's most-recent climb first, so it floats to the top.
        let entries: [(exercise: SessionExercise, loggedAt: Date)] = [
            (climb("First", grade: "V2"), at(100)),
            (climb("Second", grade: "V3"), at(100)),
        ]
        XCTAssertEqual(PreviousClimb.catalog(from: entries).map(\.params.name), ["First", "Second"])
    }

    func testCatalogIgnoresNonClimbExercises() {
        var lifting = SessionExercise(exerciseId: "bench", targetSets: 3, targetReps: "5",
                                      targetRestSeconds: 90, sets: [])   // kindRaw nil ⇒ .repsWeight
        lifting.displayName = "Bench"
        let entries: [(exercise: SessionExercise, loggedAt: Date)] = [
            (lifting, at(100)),
            (climb("Boulder problem"), at(50)),
        ]
        let catalog = PreviousClimb.catalog(from: entries)
        XCTAssertEqual(catalog.count, 1)
        XCTAssertEqual(catalog[0].params.name, "Boulder problem")
    }

    func testCatalogRespectsCap() {
        let entries = (0..<20).map { i in
            (exercise: climb("Climb \(i)", grade: "V\(i % 10)"), loggedAt: at(Double(100 - i)))
        }
        XCTAssertEqual(PreviousClimb.catalog(from: entries, cap: 8).count, 8)
    }

    func testCatalogResolvesPhotoPreview() {
        let ex = climb("With photos")
        let entries: [(exercise: SessionExercise, loggedAt: Date)] = [(ex, at(100))]
        let catalog = PreviousClimb.catalog(from: entries, photoLookup: { id in
            id == ex.id ? ["asset-1", "asset-2"] : []
        })
        XCTAssertEqual(catalog[0].photoLocalIdentifier, "asset-1")
        XCTAssertEqual(catalog[0].photoCount, 2)
    }

    func testCatalogCarriesAttemptCountAndBestStatus() {
        let entries: [(exercise: SessionExercise, loggedAt: Date)] = [
            (climb("Project", statuses: [.attempt, .attempt, .sent]), at(100)),
        ]
        let pc = PreviousClimb.catalog(from: entries)[0]
        XCTAssertEqual(pc.attemptCount, 3)
        XCTAssertEqual(pc.bestStatus, .sent)   // best across attempts (sent > attempt)
    }

    func testCatalogFoldsBestStatusAcrossSessions() {
        // Flashed in an OLDER session, then only attempted on the same climb in the most-recent one. The
        // representative is the latest (attempt) instance, but bestStatus must fold the older send so the
        // "Sent" filter stays truthful ("climbs you have sent").
        let entries: [(exercise: SessionExercise, loggedAt: Date)] = [
            (climb("Crimp", grade: "V5", statuses: [.attempt]), at(200)),   // most recent: not a send
            (climb("Crimp", grade: "V5", statuses: [.flash]), at(100)),     // older: a flash
        ]
        let catalog = PreviousClimb.catalog(from: entries)
        XCTAssertEqual(catalog.count, 1, "the two logs dedup to one climb")
        XCTAssertEqual(catalog[0].lastLoggedAt, at(200), "representative is the most-recent instance")
        XCTAssertEqual(catalog[0].bestStatus, .flash, "bestStatus folds the best outcome ever achieved")
        XCTAssertEqual(PreviousClimb.filtered(catalog, sentOnly: true).map(\.params.name), ["Crimp"],
                       "a climb sent in an earlier session passes the Sent filter")
    }

    // MARK: - Identity normalization

    func testIdentityCollapsesCaseAndWhitespace() {
        let entries: [(exercise: SessionExercise, loggedAt: Date)] = [
            (climb("The Prow", gym: "Movement", wall: "Cave"), at(100)),
            (climb("the prow ", gym: " movement", wall: "CAVE"), at(50)),
        ]
        XCTAssertEqual(PreviousClimb.catalog(from: entries).count, 1, "name/gym/wall match case-insensitively")
    }

    func testIdentityDistinctOnGradeTypeColour() {
        let entries: [(exercise: SessionExercise, loggedAt: Date)] = [
            (climb("X", grade: "V5"), at(100)),
            (climb("X", grade: "V6"), at(99)),                     // different grade ⇒ distinct
            (climb("X", type: .lead, scale: .yds, grade: "5.10a"), at(98)),  // different type ⇒ distinct
            (climb("X", grade: "V5", color: .blue), at(97)),       // different colour ⇒ distinct
        ]
        XCTAssertEqual(PreviousClimb.catalog(from: entries).count, 4)
    }

    // MARK: - Filtering

    private func sampleCatalog() -> [PreviousClimb] {
        let entries: [(exercise: SessionExercise, loggedAt: Date)] = [
            (climb("Crimp Master", type: .boulder, grade: "V5", gym: "Movement", statuses: [.sent]), at(100)),
            (climb("Sunset Arête", type: .lead, scale: .yds, grade: "5.11a", gym: "Earth Treks",
                   statuses: [.attempt]), at(90)),
            (climb("The Prow", type: .boulder, grade: "V7", gym: "Movement", statuses: [.flash]), at(80)),
            (climb("Roof Traverse", type: .topRope, scale: .yds, grade: "5.10c", gym: "Earth Treks"), at(70)),
        ]
        return PreviousClimb.catalog(from: entries)
    }

    func testFilterScopeBoulderVsRoutes() {
        let all = sampleCatalog()
        XCTAssertEqual(PreviousClimb.filtered(all, scope: .all).count, 4)
        XCTAssertEqual(Set(PreviousClimb.filtered(all, scope: .boulder).map(\.params.name)),
                       ["Crimp Master", "The Prow"])
        XCTAssertEqual(Set(PreviousClimb.filtered(all, scope: .routes).map(\.params.name)),
                       ["Sunset Arête", "Roof Traverse"])
    }

    func testFilterThisGymIsCaseInsensitive() {
        let names = PreviousClimb.filtered(sampleCatalog(), gym: "movement").map(\.params.name)
        XCTAssertEqual(Set(names), ["Crimp Master", "The Prow"])
    }

    func testFilterSentOnlyUsesBestStatus() {
        let names = PreviousClimb.filtered(sampleCatalog(), sentOnly: true).map(\.params.name)
        // Crimp Master (sent) + The Prow (flash) are sends; the route attempt + the un-logged climb are not.
        XCTAssertEqual(Set(names), ["Crimp Master", "The Prow"])
    }

    func testFilterQueryMatchesNameGradeGym() {
        let all = sampleCatalog()
        XCTAssertEqual(PreviousClimb.filtered(all, query: "prow").map(\.params.name), ["The Prow"])
        XCTAssertEqual(PreviousClimb.filtered(all, query: "5.11").map(\.params.name), ["Sunset Arête"])
        XCTAssertEqual(Set(PreviousClimb.filtered(all, query: "earth treks").map(\.params.name)),
                       ["Sunset Arête", "Roof Traverse"])
    }

    func testFiltersCompose() {
        // Routes at Earth Treks matching "roof" → just Roof Traverse.
        let names = PreviousClimb.filtered(sampleCatalog(), query: "roof", scope: .routes,
                                           gym: "Earth Treks").map(\.params.name)
        XCTAssertEqual(names, ["Roof Traverse"])
    }

    // MARK: - Re-log prefill carries the setter

    func testReLogParamsCarrySetter() {
        var ex = climb("Setter climb", gym: "Movement")
        ex.setter = "Alex H."
        let pc = PreviousClimb.catalog(from: [(ex, at(100))])[0]
        XCTAssertEqual(pc.params.setter, "Alex H.")
    }
}
