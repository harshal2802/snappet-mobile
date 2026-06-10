import XCTest
@testable import Snappet

/// Unit tests for the pure (non-device) backup/export logic in `DataBackupService`.
/// Round-trip tests (serialize → decode the raw JSON → verify fields) avoid spinning up
/// a real `ModelContext` — the test goal is proving the DTO mapping and format correctness,
/// not the SwiftData mechanics (which are covered by integration tests on device/simulator).
final class DataBackupTests: XCTestCase {

    // MARK: - Schema version

    func testBundleDefaultSchemaVersionIsZero() throws {
        let bundle = SnappetBackupBundle(
            createdAt: .now, appVersion: "1.0",
            usageRecords: [], pomodoroSessions: [], habits: [], habitCompletions: [],
            journalEntries: [], expenseGroups: [], expenseRecords: [],
            budgetCategories: [], budgetTransactions: [], routines: [],
            workoutSessions: [], customExercises: [], sessionMedia: [],
            clipEdits: [], studioProjects: [], tipCalculations: [],
            kilterLogEntries: [], kilterSessions: [], kilterFavorites: [],
            kilterCreatedClimbs: []
        )
        XCTAssertEqual(bundle.schemaVersion, 0)
    }

    // MARK: - Journal Markdown export

    func testJournalMarkdownContainsTitleAndBody() {
        let entry = makeJournalEntry(title: "My Day", body: "Went climbing.", tags: ["fitness"])
        let data = DataBackupService.journalMarkdown([entry])
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("# My Day"), "should render title as H1")
        XCTAssertTrue(text.contains("Went climbing."), "should include body verbatim")
        XCTAssertTrue(text.contains("Tags: fitness"), "should list tags")
        XCTAssertTrue(text.contains("---"), "should add a separator between entries")
    }

    func testJournalMarkdownMultipleEntriesNewestFirst() {
        let older = makeJournalEntry(title: "Older", body: "B1",
                                     createdAt: Date(timeIntervalSince1970: 1_000_000))
        let newer = makeJournalEntry(title: "Newer", body: "B2",
                                     createdAt: Date(timeIntervalSince1970: 2_000_000))
        let data = DataBackupService.journalMarkdown([older, newer])
        let text = String(data: data, encoding: .utf8) ?? ""
        let newerRange = text.range(of: "Newer")
        let olderRange = text.range(of: "Older")
        XCTAssertNotNil(newerRange)
        XCTAssertNotNil(olderRange)
        XCTAssertLessThan(newerRange!.lowerBound, olderRange!.lowerBound,
                          "newer entry should appear first")
    }

    func testJournalMarkdownEmptyIsEmpty() {
        let data = DataBackupService.journalMarkdown([])
        XCTAssertTrue(data.isEmpty || String(data: data, encoding: .utf8)?.isEmpty == true)
    }

    func testJournalMarkdownEntryWithNoTitle() {
        let entry = makeJournalEntry(title: "", body: "Untitled body.", tags: [])
        let data = DataBackupService.journalMarkdown([entry])
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(text.hasPrefix("# "), "should skip H1 when title is empty")
        XCTAssertTrue(text.contains("Untitled body."))
    }

    // MARK: - Budget CSV export

    func testBudgetCSVContainsHeaders() {
        let cat = makeBudgetCategory(name: "Groceries", limit: 500)
        let tx = makeBudgetTransaction(categoryID: cat.id, amount: 45.50, note: "Weekly shop")
        let data = DataBackupService.budgetCSV(categories: [cat], transactions: [tx])
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("ID,Name,Monthly Limit,Created At"),
                      "should include category header row")
        XCTAssertTrue(text.contains("Category ID,Amount,Note,Date"),
                      "should include transaction header row")
    }

    func testBudgetCSVContainsValues() {
        let cat = makeBudgetCategory(name: "Dining", limit: 300)
        let tx = makeBudgetTransaction(categoryID: cat.id, amount: 22.75, note: "Lunch")
        let data = DataBackupService.budgetCSV(categories: [cat], transactions: [tx])
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("Dining"))
        XCTAssertTrue(text.contains("300.00"))
        XCTAssertTrue(text.contains("22.75"))
        XCTAssertTrue(text.contains("Lunch"))
    }

    func testBudgetCSVEscapesCommasInNames() {
        let cat = makeBudgetCategory(name: "Food, Drink", limit: 100)
        let data = DataBackupService.budgetCSV(categories: [cat], transactions: [])
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("\"Food, Drink\""),
                      "values with commas should be quoted")
    }

    // MARK: - Expense CSV export

    func testExpenseCSVContainsHeaders() {
        let group = makeExpenseGroup(name: "Dinner", participants: ["Alice", "Bob"])
        let record = makeExpenseRecord(groupID: group.id, title: "Pizza", amount: 60,
                                       payer: "Alice", participants: ["Alice", "Bob"])
        let data = DataBackupService.expenseCSV(groups: [group], records: [record])
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("ID,Name,Participants,Created At"),
                      "should include groups header")
        XCTAssertTrue(text.contains("Group ID,Title,Amount,Payer"),
                      "should include records header")
    }

    func testExpenseCSVContainsValues() {
        let group = makeExpenseGroup(name: "Trip", participants: ["Alice", "Bob"])
        let record = makeExpenseRecord(groupID: group.id, title: "Hotel", amount: 200,
                                       payer: "Bob", participants: ["Alice", "Bob"])
        let data = DataBackupService.expenseCSV(groups: [group], records: [record])
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("Trip"))
        XCTAssertTrue(text.contains("Hotel"))
        XCTAssertTrue(text.contains("200.00"))
        XCTAssertTrue(text.contains("Bob"))
    }

    // MARK: - Workout JSON export

    func testWorkoutJSONIsValidAndContainsFields() throws {
        let session = makeWorkoutSession(routineName: "Push Day", startedAt: Date(timeIntervalSince1970: 1_000_000))
        let data = try DataBackupService.workoutJSON([session])
        let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        XCTAssertNotNil(json, "should decode to an array of dicts")
        let first = json?.first
        XCTAssertNotNil(first?["id"])
        XCTAssertEqual(first?["routineName"] as? String, "Push Day")
    }

    func testWorkoutJSONEmptySessionsProducesEmptyArray() throws {
        let data = try DataBackupService.workoutJSON([])
        let json = try JSONSerialization.jsonObject(with: data) as? [Any]
        XCTAssertEqual(json?.count, 0)
    }

    // MARK: - SnappetBackupBundle round-trip (JSON encode/decode)

    func testBackupBundleRoundTripPreservesAllFields() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let bundle = SnappetBackupBundle(
            schemaVersion: 0,
            createdAt: date,
            appVersion: "2.1.0",
            usageRecords: [
                UsageRecordBackup(module: "journal", action: "entry", summary: "New entry",
                                  metric: 1, timestamp: date)
            ],
            pomodoroSessions: [PomodoroSessionBackup(minutes: 25, completedAt: date)],
            habits: [HabitBackup(id: UUID(), name: "Meditate", symbol: "brain.head.profile", createdAt: date)],
            habitCompletions: [HabitCompletionBackup(habitID: UUID(), day: date)],
            journalEntries: [
                JournalEntryBackup(title: "Roundtrip", body: "Test", createdAt: date,
                                   updatedAt: date, tags: ["test"])
            ],
            expenseGroups: [],
            expenseRecords: [],
            budgetCategories: [
                BudgetCategoryBackup(id: UUID(), name: "Rent", monthlyLimit: 1200, createdAt: date)
            ],
            budgetTransactions: [],
            routines: [],
            workoutSessions: [],
            customExercises: [],
            sessionMedia: [],
            clipEdits: [],
            studioProjects: [],
            tipCalculations: [
                TipCalculationBackup(bill: 45.0, tipPct: 18.0, people: 2,
                                     tipAmount: 8.1, total: 53.1, date: date)
            ],
            kilterLogEntries: [],
            kilterSessions: [],
            kilterFavorites: [],
            kilterCreatedClimbs: []
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoded: SnappetBackupBundle = try {
            let data = try encoder.encode(bundle)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(SnappetBackupBundle.self, from: data)
        }()

        XCTAssertEqual(decoded.schemaVersion, 0)
        XCTAssertEqual(decoded.appVersion, "2.1.0")
        XCTAssertEqual(decoded.usageRecords.count, 1)
        XCTAssertEqual(decoded.usageRecords.first?.module, "journal")
        XCTAssertEqual(decoded.pomodoroSessions.first?.minutes, 25)
        XCTAssertEqual(decoded.habits.first?.name, "Meditate")
        XCTAssertEqual(decoded.habitCompletions.count, 1)
        XCTAssertEqual(decoded.journalEntries.first?.title, "Roundtrip")
        XCTAssertEqual(decoded.journalEntries.first?.tags, ["test"])
        XCTAssertEqual(decoded.budgetCategories.first?.monthlyLimit, 1200)
        XCTAssertEqual(decoded.tipCalculations.first?.bill, 45.0)
        XCTAssertEqual(decoded.tipCalculations.first?.people, 2)
    }

    // MARK: - Kilter DTO round-trip

    func testKilterCreatedClimbBackupRoundTrip() throws {
        let b = KilterCreatedClimbBackup(
            uuid: "test-uuid", name: "My Climb", setterUsername: "tester",
            layoutId: 1, sizeId: 2, angle: 40, frames: "p100r12p200r13",
            edgeLeft: 0, edgeRight: 144, edgeBottom: 0, edgeTop: 156,
            isNoMatch: false, predictedGrade: 14.5, source: "manual", modelId: nil,
            createdAt: Date(timeIntervalSince1970: 1_000_000)
        )
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(b)
        let decoded = try decoder.decode(KilterCreatedClimbBackup.self, from: data)
        XCTAssertEqual(decoded.uuid, "test-uuid")
        XCTAssertEqual(decoded.frames, "p100r12p200r13")
        XCTAssertEqual(decoded.predictedGrade, 14.5)
        XCTAssertNil(decoded.modelId)
    }

    // MARK: - DataBackupPhase purity

    func testDataBackupPhaseEquality() {
        XCTAssertEqual(DataBackupPhase.idle, .idle)
        XCTAssertEqual(DataBackupPhase.busy, .busy)
        XCTAssertEqual(DataBackupPhase.done("ok"), .done("ok"))
        XCTAssertNotEqual(DataBackupPhase.done("ok"), .done("fail"))
        XCTAssertEqual(DataBackupPhase.failed("x"), .failed("x"))
        XCTAssertNotEqual(DataBackupPhase.idle, .busy)
    }

    // MARK: - Helpers (model construction without a SwiftData context)

    private func makeJournalEntry(title: String, body: String, tags: [String] = [],
                                   createdAt: Date = .now) -> JournalEntry {
        JournalEntry(title: title, body: body, createdAt: createdAt,
                     updatedAt: createdAt, tags: tags)
    }

    private func makeBudgetCategory(name: String, limit: Double) -> BudgetCategory {
        BudgetCategory(id: UUID(), name: name, monthlyLimit: limit)
    }

    private func makeBudgetTransaction(categoryID: UUID, amount: Double,
                                        note: String) -> BudgetTransaction {
        BudgetTransaction(categoryID: categoryID, amount: amount, note: note)
    }

    private func makeExpenseGroup(name: String, participants: [String]) -> ExpenseGroup {
        ExpenseGroup(id: UUID(), name: name, participants: participants)
    }

    private func makeExpenseRecord(groupID: UUID, title: String, amount: Double,
                                    payer: String, participants: [String]) -> ExpenseRecord {
        ExpenseRecord(groupID: groupID, title: title, amount: amount,
                      payer: payer, participants: participants)
    }

    private func makeWorkoutSession(routineName: String, startedAt: Date = .now) -> WorkoutSession {
        WorkoutSession(routineName: routineName, startedAt: startedAt,
                       completedAt: startedAt.addingTimeInterval(3600))
    }
}
