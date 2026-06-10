import XCTest
@testable import Snappet

/// Unit tests for the pure backup/export/restore layer — no device, no SwiftData, no file I/O.
/// Covers serialisation round-trips, text-format spot-checks, state-machine transitions, and
/// schema-version enforcement. Mirrors the `ExportShareStateTests` discipline.
final class BackupExportTests: XCTestCase {

    // MARK: - Helpers

    private func makeBundle() -> SnappetBackupBundle {
        SnappetBackupBundle(
            schemaVersion: SnappetBackupBundle.currentSchemaVersion,
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
            usageRecords: [
                UsageRecordSnapshot(module: "journal", action: "entry",
                                    summary: "Wrote a note", metric: nil,
                                    timestamp: Date(timeIntervalSince1970: 1_700_000_100))
            ],
            pomodoroSessions: [
                PomodoroSessionSnapshot(minutes: 25,
                                        completedAt: Date(timeIntervalSince1970: 1_700_001_000))
            ],
            habits: [
                HabitSnapshot(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                              name: "Read", symbol: "book", createdAt: .now)
            ],
            habitCompletions: [
                HabitCompletionSnapshot(
                    habitID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                    day: Date(timeIntervalSince1970: 1_700_100_000))
            ],
            journalEntries: [
                JournalEntrySnapshot(title: "Day 1", body: "Hello world",
                                     createdAt: Date(timeIntervalSince1970: 1_700_200_000),
                                     updatedAt: Date(timeIntervalSince1970: 1_700_200_000),
                                     tags: ["test", "daily"])
            ],
            expenseGroups: [
                ExpenseGroupSnapshot(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                                     name: "Trip", participants: ["Alice", "Bob"],
                                     createdAt: .now)
            ],
            expenseRecords: [
                ExpenseRecordSnapshot(
                    groupID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                    title: "Lunch", amount: 40.0, payer: "Alice",
                    participants: ["Alice", "Bob"],
                    date: Date(timeIntervalSince1970: 1_700_300_000),
                    isSettlement: false, items: [], taxAmount: 0, discountAmount: 0)
            ],
            budgetCategories: [
                BudgetCategorySnapshot(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
                                       name: "Groceries", monthlyLimit: 400,
                                       createdAt: .now)
            ],
            budgetTransactions: [
                BudgetTransactionSnapshot(
                    categoryID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
                    amount: 55.50, note: "Weekly shop",
                    date: Date(timeIntervalSince1970: 1_700_400_000))
            ],
            routines: [],
            workoutSessions: [
                WorkoutSessionSnapshot(
                    id: UUID(), routineID: nil, routineName: "Freeform",
                    startedAt: Date(timeIntervalSince1970: 1_700_500_000),
                    completedAt: Date(timeIntervalSince1970: 1_700_503_600),
                    exercises: [], hrSeries: [
                        HRPointSnapshot(t: 0, bpm: 65, rrIntervalsMs: nil),
                        HRPointSnapshot(t: 60, bpm: 142, rrIntervalsMs: [420, 418])
                    ],
                    maxHR: 185, restHR: 60, metricsSourceRaw: "ble", kcalEstimate: 350)
            ],
            customExercises: [],
            tipCalculations: [
                TipCalculationSnapshot(bill: 80.0, tipPct: 20.0, people: 4,
                                       tipAmount: 16.0, total: 96.0, date: .now)
            ],
            kilterLogEntries: [
                KilterLogEntrySnapshot(climbUUID: "abc-123", climbName: "Test climb",
                                       angle: 40, difficulty: 5.0, gradeLabel: "V4/6c",
                                       statusRaw: "sent", attempts: 1, date: .now,
                                       sessionId: nil, startedAt: nil, endedAt: nil,
                                       attemptTimestamps: [], note: "Fun climb")
            ],
            kilterSessions: [],
            kilterFavorites: [
                KilterFavoriteSnapshot(climbUUID: "abc-123", addedAt: .now)
            ],
            kilterCreatedClimbs: []
        )
    }

    // MARK: - Bundle JSON round-trip

    func testBundleJSONRoundTrip() throws {
        let original = makeBundle()
        let data = try SnappetExporter.bundleJSON(original)
        XCTAssertFalse(data.isEmpty)
        let restored = try SnappetRestorer.restoreBundle(from: data)
        XCTAssertEqual(restored.schemaVersion, original.schemaVersion)
        XCTAssertEqual(restored.usageRecords.count, 1)
        XCTAssertEqual(restored.usageRecords[0].module, "journal")
        XCTAssertEqual(restored.usageRecords[0].action, "entry")
        XCTAssertEqual(restored.journalEntries.count, 1)
        XCTAssertEqual(restored.journalEntries[0].title, "Day 1")
        XCTAssertEqual(restored.journalEntries[0].tags, ["test", "daily"])
        XCTAssertEqual(restored.expenseRecords[0].amount, 40.0)
        XCTAssertEqual(restored.budgetTransactions[0].note, "Weekly shop")
        XCTAssertEqual(restored.workoutSessions[0].hrSeries.count, 2)
        XCTAssertEqual(restored.workoutSessions[0].hrSeries[1].bpm, 142)
        XCTAssertEqual(restored.workoutSessions[0].hrSeries[1].rrIntervalsMs, [420, 418])
        XCTAssertEqual(restored.kilterLogEntries[0].note, "Fun climb")
    }

    func testTotalRecordCount() {
        let b = makeBundle()
        // 1 usageRecord + 1 pomodoro + 1 habit + 1 completion + 1 journal + 1 group + 1 expense
        // + 1 category + 1 transaction + 0 routines + 1 workout + 0 custom + 1 tip
        // + 1 kilterLog + 0 kilterSession + 1 favorite + 0 createdClimb = 12
        XCTAssertEqual(b.totalRecordCount, 12)
    }

    // MARK: - Schema version enforcement

    func testRestoreFailsForNewerSchemaVersion() {
        let newer = SnappetBackupBundle(
            schemaVersion: SnappetBackupBundle.currentSchemaVersion + 1,
            exportedAt: .now,
            usageRecords: [], pomodoroSessions: [], habits: [], habitCompletions: [],
            journalEntries: [], expenseGroups: [], expenseRecords: [],
            budgetCategories: [], budgetTransactions: [], routines: [],
            workoutSessions: [], customExercises: [], tipCalculations: [],
            kilterLogEntries: [], kilterSessions: [], kilterFavorites: [],
            kilterCreatedClimbs: [])
        let data = try! SnappetExporter.bundleJSON(newer)
        XCTAssertThrowsError(try SnappetRestorer.restoreBundle(from: data)) { error in
            XCTAssertTrue(error is SnappetRestorer.RestoreError)
        }
    }

    func testRestoreFailsForGarbage() {
        let garbage = Data("not json".utf8)
        XCTAssertThrowsError(try SnappetRestorer.restoreBundle(from: garbage)) { error in
            XCTAssertTrue(error is SnappetRestorer.RestoreError)
        }
    }

    func testRestoreAcceptsCurrentSchemaVersion() throws {
        let bundle = makeBundle()
        let data = try SnappetExporter.bundleJSON(bundle)
        let restored = try SnappetRestorer.restoreBundle(from: data)
        XCTAssertEqual(restored.schemaVersion, SnappetBackupBundle.currentSchemaVersion)
    }

    // MARK: - Journal Markdown

    func testJournalMarkdownEmpty() {
        let md = SnappetExporter.journalMarkdown([])
        XCTAssertTrue(md.contains("# Journal"))
        XCTAssertTrue(md.contains("No entries"))
    }

    func testJournalMarkdownContainsTitle() {
        let entry = JournalEntrySnapshot(title: "My Title", body: "Body text",
                                         createdAt: Date(timeIntervalSince1970: 0),
                                         updatedAt: Date(timeIntervalSince1970: 0), tags: [])
        let md = SnappetExporter.journalMarkdown([entry])
        XCTAssertTrue(md.contains("## My Title"))
        XCTAssertTrue(md.contains("Body text"))
    }

    func testJournalMarkdownContainsTags() {
        let entry = JournalEntrySnapshot(title: "", body: "Some text",
                                         createdAt: Date(timeIntervalSince1970: 0),
                                         updatedAt: Date(timeIntervalSince1970: 0),
                                         tags: ["morning", "reflection"])
        let md = SnappetExporter.journalMarkdown([entry])
        XCTAssertTrue(md.contains("#morning"))
        XCTAssertTrue(md.contains("#reflection"))
    }

    func testJournalMarkdownSortedNewestFirst() {
        let older = JournalEntrySnapshot(title: "Older", body: "",
                                          createdAt: Date(timeIntervalSince1970: 1_000),
                                          updatedAt: Date(timeIntervalSince1970: 1_000), tags: [])
        let newer = JournalEntrySnapshot(title: "Newer", body: "",
                                          createdAt: Date(timeIntervalSince1970: 2_000),
                                          updatedAt: Date(timeIntervalSince1970: 2_000), tags: [])
        let md = SnappetExporter.journalMarkdown([older, newer])
        let newerIdx = md.range(of: "Newer")!.lowerBound
        let olderIdx = md.range(of: "Older")!.lowerBound
        XCTAssertLessThan(newerIdx, olderIdx, "newest entry appears first in the Markdown")
    }

    // MARK: - Expense CSV

    func testExpenseCSVHeader() {
        let csv = SnappetExporter.expenseCSV(groups: [], records: [])
        XCTAssertTrue(csv.hasPrefix("group_id,group_name,date,title,amount,payer,participants,is_settlement"))
    }

    func testExpenseCSVRow() {
        let gid = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
        let group = ExpenseGroupSnapshot(id: gid, name: "Flatmates",
                                          participants: ["A", "B"], createdAt: .now)
        let record = ExpenseRecordSnapshot(
            groupID: gid, title: "Electric", amount: 120.0, payer: "A",
            participants: ["A", "B"], date: Date(timeIntervalSince1970: 0),
            isSettlement: false, items: [], taxAmount: 0, discountAmount: 0)
        let csv = SnappetExporter.expenseCSV(groups: [group], records: [record])
        XCTAssertTrue(csv.contains("Flatmates"))
        XCTAssertTrue(csv.contains("Electric"))
        XCTAssertTrue(csv.contains("120.00"))
        XCTAssertTrue(csv.contains("false"))
    }

    func testExpenseCSVQuotesCommasInNames() {
        let gid = UUID()
        let group = ExpenseGroupSnapshot(id: gid, name: "Foo, Bar",
                                          participants: [], createdAt: .now)
        let record = ExpenseRecordSnapshot(
            groupID: gid, title: "A \"quoted\" title", amount: 1.0, payer: "A",
            participants: [], date: .now, isSettlement: false, items: [],
            taxAmount: 0, discountAmount: 0)
        let csv = SnappetExporter.expenseCSV(groups: [group], records: [record])
        XCTAssertTrue(csv.contains("\"Foo, Bar\""))
        XCTAssertTrue(csv.contains("\"A \"\"quoted\"\" title\""))
    }

    // MARK: - Budget CSV

    func testBudgetCSVHeader() {
        let csv = SnappetExporter.budgetCSV(categories: [], transactions: [])
        XCTAssertTrue(csv.hasPrefix("category_id,category_name,monthly_limit,date,amount,note"))
    }

    func testBudgetCSVRow() {
        let cid = UUID(uuidString: "00000000-0000-0000-0000-000000000088")!
        let cat = BudgetCategorySnapshot(id: cid, name: "Groceries", monthlyLimit: 400, createdAt: .now)
        let txn = BudgetTransactionSnapshot(categoryID: cid, amount: 55.5,
                                             note: "Weekly shop", date: Date(timeIntervalSince1970: 0))
        let csv = SnappetExporter.budgetCSV(categories: [cat], transactions: [txn])
        XCTAssertTrue(csv.contains("Groceries"))
        XCTAssertTrue(csv.contains("400.00"))
        XCTAssertTrue(csv.contains("55.50"))
        XCTAssertTrue(csv.contains("Weekly shop"))
    }

    // MARK: - Workout JSON

    func testWorkoutSessionsJSONRoundTrips() throws {
        let sessions = makeBundle().workoutSessions
        let data = try SnappetExporter.workoutSessionsJSON(sessions)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let decoded = try dec.decode([WorkoutSessionSnapshot].self, from: data)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].routineName, "Freeform")
        XCTAssertEqual(decoded[0].maxHR, 185)
        XCTAssertEqual(decoded[0].hrSeries.count, 2)
    }

    // MARK: - BackupState machine

    func testBackupStateIdleNotBusy() {
        XCTAssertFalse(BackupState.idle.isBusy)
    }

    func testBackupStatePreparingIsBusy() {
        XCTAssertTrue(BackupState.preparingBundle.isBusy)
    }

    func testBackupStateRestoringIsBusy() {
        XCTAssertTrue(BackupState.restoring.isBusy)
    }

    func testBackupStateBundleReadyNotBusy() {
        let s = BackupState.idle.bundleReady(data: Data(), filename: "test.json")
        XCTAssertFalse(s.isBusy)
    }

    func testBackupStateRestoredNotBusy() {
        XCTAssertFalse(BackupState.restored(42).isBusy)
    }

    func testBackupStateFailedNotBusy() {
        XCTAssertFalse(BackupState.failed("oops").isBusy)
    }

    func testBackupStateFullHappyPath() {
        var s = BackupState.idle
        s = s.beginningPreparation()
        XCTAssertEqual(s, .preparingBundle)
        let data = Data("{}".utf8)
        s = s.bundleReady(data: data, filename: "snap.json")
        if case .bundleReady(let d, let n) = s {
            XCTAssertEqual(d, data)
            XCTAssertEqual(n, "snap.json")
        } else { XCTFail("expected bundleReady") }
        s = s.beginningRestore()
        XCTAssertEqual(s, .restoring)
        s = s.restoreSucceeded(recordCount: 77)
        XCTAssertEqual(s, .restored(77))
        s = s.reset()
        XCTAssertEqual(s, .idle)
    }

    func testBackupStateFailure() {
        let s = BackupState.preparingBundle.failed("disk full")
        XCTAssertEqual(s, .failed("disk full"))
    }

    func testBackupStateBundleDataAccessor() {
        XCTAssertNil(BackupState.idle.bundleData)
        XCTAssertNil(BackupState.preparingBundle.bundleData)
        let data = Data("test".utf8)
        let s = BackupState.bundleReady(data, "f.json")
        XCTAssertEqual(s.bundleData, data)
    }

    func testBackupStateBundleFilenameAccessor() {
        XCTAssertNil(BackupState.idle.bundleFilename)
        XCTAssertEqual(BackupState.bundleReady(Data(), "backup.json").bundleFilename, "backup.json")
    }
}
