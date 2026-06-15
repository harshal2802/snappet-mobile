import XCTest
@testable import Snappet

/// Unit tests for the Spotlight indexing's PURE pieces (#81 Phase 4): the `SpotlightCatalog` spec
/// builders and the `snappet://exercise/<id>` route parse. The CoreSpotlight indexing itself
/// (`SpotlightIndexer`) and a real Spotlight-result tap are the device edge and aren't unit-tested;
/// the deep-link identifiers + routing — which decide where a tap lands — are.
@MainActor
final class SpotlightIndexTests: XCTestCase {

    // MARK: - Exercise spec + route

    func testExerciseSpecIdentifierRoutesBackToTheExercise() throws {
        let exercise = try XCTUnwrap(ExerciseCatalog.all.first)   // a real catalog id
        let spec = SpotlightCatalog.exerciseSpec(exercise)

        XCTAssertEqual(spec.identifier, "snappet://exercise/\(exercise.id)")
        XCTAssertEqual(spec.title, exercise.name)
        XCTAssertEqual(spec.domain, SpotlightCatalog.exerciseDomain)
        XCTAssertTrue(spec.keywords.contains(exercise.name))
        // The identifier IS the deep-link target — it must parse back to this exercise.
        let url = try XCTUnwrap(URL(string: spec.identifier))
        XCTAssertEqual(SnappetDeepLink.route(for: url), .exercise(id: exercise.id))
    }

    func testExerciseRouteParse() throws {
        let url = try XCTUnwrap(URL(string: "snappet://exercise/Barbell_Squat"))
        XCTAssertEqual(SnappetDeepLink.route(for: url), .exercise(id: "Barbell_Squat"))
    }

    func testExerciseRouteRejectsMalformed() throws {
        for bad in ["snappet://exercise", "snappet://exercise/", "snappet://exercise/a/b",
                    "snappet://workout/Barbell_Squat", "https://x/exercise/a"] {
            let url = try XCTUnwrap(URL(string: bad))
            XCTAssertNil(SnappetDeepLink.route(for: url), "should not route \(bad)")
        }
    }

    // MARK: - Created-climb spec (reuses the existing Kilter route)

    func testCreatedClimbSpecReusesTheKilterClimbDeepLink() throws {
        let spec = SpotlightCatalog.createdClimbSpec(
            uuid: "abc123", name: "My Crimp Ladder", setter: "Me", angle: 40)

        XCTAssertEqual(spec.identifier, "snappet://kilter/climb/abc123?angle=40")
        XCTAssertEqual(spec.title, "My Crimp Ladder")
        XCTAssertEqual(spec.domain, SpotlightCatalog.createdClimbDomain)
        XCTAssertTrue(spec.keywords.contains("My Crimp Ladder"))
        // The identifier routes via the EXISTING kilter-climb path (no new routing needed).
        let url = try XCTUnwrap(URL(string: spec.identifier))
        XCTAssertEqual(SnappetDeepLink.route(for: url),
                       .kilterClimb(KilterClimbLink(uuid: "abc123", angle: 40)))
    }

    /// The de-index-on-delete identifier MUST equal the indexed one, or a deleted climb would leak in
    /// Spotlight (the review finding). One source of truth: createdClimbIdentifier.
    func testCreatedClimbDeindexIdentifierMatchesTheIndexedOne() {
        let spec = SpotlightCatalog.createdClimbSpec(uuid: "u9", name: "n", setter: "s", angle: 25)
        XCTAssertEqual(spec.identifier, SpotlightCatalog.createdClimbIdentifier(uuid: "u9", angle: 25))
    }

    /// Exercise + created-climb specs use distinct Spotlight domains (so each type can be bulk-managed)
    /// and distinct URL hosts (so the router can't confuse them).
    func testDomainsAndHostsAreDistinct() {
        XCTAssertNotEqual(SpotlightCatalog.exerciseDomain, SpotlightCatalog.createdClimbDomain)
        let ex = SpotlightCatalog.createdClimbSpec(uuid: "u", name: "n", setter: "s", angle: 30)
        XCTAssertTrue(ex.identifier.hasPrefix("snappet://kilter/climb/"))
    }
}
