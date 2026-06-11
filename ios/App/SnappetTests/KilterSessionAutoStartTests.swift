import XCTest
import SwiftData
@testable import Snappet

/// Unit tests for the auto-start-on-log path (#75): a climber logging with no session live gets a
/// session started for them (recovery folds in, so an open session is adopted rather than forked),
/// `start` reports whether it **created** a fresh session — the only case the climb screen offers
/// Undo for — and `undoStart` keeps the logs while removing the session. Same harness as
/// `KilterSessionStartRecoveryTests`: in-memory store, deliberately **unbound** manager (store
/// effects only; the live-HR / Live-Activity halves stay device-pending per the repo pattern).
@MainActor
final class KilterSessionAutoStartTests: XCTestCase {
    /// Kept as a property: a `ModelContext` does NOT retain its `ModelContainer`, so letting the
    /// container deallocate makes every later SwiftData call trap (the documented gotcha).
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }

    override func setUpWithError() throws {
        container = try ModelContainer(
            for: Schema(SnappetSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    override func tearDown() {
        container = nil
        super.tearDown()
    }

    private func allSessions() throws -> [KilterSession] {
        try context.fetch(FetchDescriptor<KilterSession>())
    }

    // MARK: - `start`'s created-fresh report (what gates the Undo offer)

    func testStartReportsCreatedFreshOnAnEmptyStore() throws {
        let manager = KilterSessionManager()
        XCTAssertTrue(manager.start(angle: 40, source: "auto", in: context),
                      "a fresh auto-start must be undoable")
        XCTAssertEqual(try allSessions().count, 1)
        XCTAssertEqual(try allSessions().first?.source, "auto")
    }

    func testStartReportsNotFreshWhenRecoveryAdoptsAnOpenSession() throws {
        let open = KilterSession(startedAt: .now.addingTimeInterval(-600), angle: 40, source: "manual")
        context.insert(open)
        try context.save()

        let manager = KilterSessionManager()
        XCTAssertFalse(manager.start(angle: 45, source: "auto", in: context),
                       "adopting an open session must NOT offer Undo — undo would delete real history")
        XCTAssertEqual(manager.currentId, open.id)
    }

    func testStartReportsNotFreshWhileASessionIsAlreadyCurrent() throws {
        let manager = KilterSessionManager()
        manager.start(angle: 40, source: "manual", in: context)
        XCTAssertFalse(manager.start(angle: 45, source: "auto", in: context))
    }

    // MARK: - `undoStart`: keep the logs, drop the session

    func testUndoStartDetachesLogsAndDeletesTheSession() throws {
        let manager = KilterSessionManager()
        XCTAssertTrue(manager.start(angle: 40, source: "auto", in: context))
        let sid = try XCTUnwrap(manager.currentId)

        // The log that triggered the auto-start, attached exactly as the climb screen attaches it.
        let entry = KilterLogEntry(climbUUID: "c-1", climbName: "Test climb", angle: 40,
                                   difficulty: 16, gradeLabel: "6a / V3", status: .sent,
                                   sessionId: sid)
        context.insert(entry)
        try context.save()

        manager.undoStart(in: context)

        XCTAssertNil(manager.currentId)
        XCTAssertTrue(try allSessions().isEmpty, "the undone session row must be gone")
        XCTAssertNil(entry.sessionId, "the log survives, detached — exactly the pre-#75 idle-log shape")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<KilterLogEntry>()), 1)
    }

    func testUndoStartWithNoCurrentSessionIsANoOp() throws {
        let bystander = KilterSession(startedAt: .now.addingTimeInterval(-90_000),
                                      endedAt: .now.addingTimeInterval(-86_000),
                                      angle: 40, source: "manual")
        context.insert(bystander)
        try context.save()

        let manager = KilterSessionManager()
        manager.undoStart(in: context)   // nothing current — must not touch the store

        XCTAssertEqual(try allSessions().count, 1)
    }
}
