import XCTest
import SwiftData
@testable import Snappet

/// Pins the contract of `SessionMedia.allIdentifiers(in:)` — the ONE global auto-discovery dedup
/// set shared by the live-session discovery loop, `SessionDetailView`, and the Kilter session
/// controller (prompt 114): identifiers come from EVERY session (global, not session-scoped),
/// duplicate rows for one physical asset collapse into the set, and an empty store yields an
/// empty set. The perf half of the fix (identifier-only fetch via `propertiesToFetch`) rides the
/// same call, so a future signature/predicate change trips these first.
@MainActor
final class SessionMediaIdentifierSetTests: XCTestCase {

    /// Kept as a property: a `ModelContext` does NOT retain its `ModelContainer` — hold the
    /// container for the test's lifetime (same trap note as `SessionSetEditingTests`).
    private var container: ModelContainer!

    override func setUpWithError() throws {
        container = try ModelContainer(
            for: Schema(SnappetSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    override func tearDown() {
        container = nil
        super.tearDown()
    }

    func testCollectsIdentifiersAcrossAllSessionsAndDedups() throws {
        let context = ModelContext(container)
        let sessionA = UUID(), sessionB = UUID()
        context.insert(SessionMedia(sessionID: sessionA, localIdentifier: "asset-1",
                                    kind: .video, offsetSec: 10))
        context.insert(SessionMedia(sessionID: sessionA, localIdentifier: "asset-2",
                                    kind: .photo, offsetSec: 20))
        // The same physical asset filed in a SECOND session (a legitimate manual add) still
        // collapses to one entry — the set is global, a superset of any one session's own.
        context.insert(SessionMedia(sessionID: sessionB, localIdentifier: "asset-1",
                                    kind: .video, offsetSec: 5))
        try context.save()

        XCTAssertEqual(SessionMedia.allIdentifiers(in: context), ["asset-1", "asset-2"])
    }

    func testEmptyStoreYieldsEmptySet() {
        XCTAssertEqual(SessionMedia.allIdentifiers(in: ModelContext(container)), [])
    }
}
