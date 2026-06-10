import XCTest
@testable import Snappet

/// Unit tests for `SnappetBackupEngine` and the pure text-format converters.
/// **No device, no SwiftData** — all inputs are plain DTO value types constructed inline.
/// Tests the roundtrip guarantee, version gating, and the Markdown/CSV/JSON formatters.
final class SnappetBackupEngineTests: XCTestCase {

    // MARK: - Roundtrip: serialize → deserialize

    func testEmptyBundleRoundtrips() throws {
        let original = SnappetBackup(exportedAt: Date(timeIntervalSince1970: 0))
        let data = try SnappetBackupEngine.serialize(original)
        let decoded = try SnappetBackupEngine.deserialize(data)
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.exportedAt.timeIntervalSince1970, 0, accuracy: 1)
        XCTAssertTrue(decoded.journalEntries.isEmpty)
        XCTAssertTrue(decoded.workoutSessions.isEmpty)
    }

    func testJournalEntriesRoundtrip() throws {
        let entry = JournalEntryDTO(title: "Day 1", body: "Went for a run.",
                                    createdAt: Date(timeIntervalSince1970: 1_000_000),
                                    updatedAt: Date(timeIntervalSince1970: 1_000_000),
                                    tags: ["fitness", "outdoors"])
        var bundle = SnappetBackup(exportedAt: .now)
        bundle.journalEntries = [entry]
        let decoded = try SnappetBackupEngine.deserialize(try SnappetBackupEngine.serialize(bundle))
        XCTAssertEqual(decoded.journalEntries.count, 1)
        XCTAssertEqual(decoded.journalEntries[0].title, "Day 1")
        XCTAssertEqual(decoded.journalEntries[0].tags, ["fitness", "outdoors"])
    }

    func testKilterLogEntryRoundtrip() throws {
        let entry = KilterLogEntryDTO(
            climbUUID: "abc-123", climbName: "Crimpy Reachy", angle: 40,
            difficulty: 22.0, gradeLabel: "7a / V6", statusRaw: "sent",
            attempts: 3, date: Date(timeIntervalSince1970: 2_000_000),
            sessionId: UUID(), startedAt: nil, endedAt: nil, attemptTimestamps: [], note: "Great send!"
        )
        var bundle = SnappetBackup(exportedAt: .now)
        bundle.kilterLogEntries = [entry]
        let decoded = try SnappetBackupEngine.deserialize(try SnappetBackupEngine.serialize(bundle))
        XCTAssertEqual(decoded.kilterLogEntries[0].climbName, "Crimpy Reachy")
        XCTAssertEqual(decoded.kilterLogEntries[0].note, "Great send!")
        XCTAssertEqual(decoded.kilterLogEntries[0].attempts, 3)
    }

    func testWorkoutSessionWithHRSeriesRoundtrips() throws {
        let session = WorkoutSessionDTO(
            id: UUID(), routineID: nil, routineName: "Push day",
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            completedAt: Date(timeIntervalSince1970: 1_003_600),
            exercises: [],
            hrSeries: [
                HRPointDTO(t: 0, bpm: 60, rrIntervalsMs: nil),
                HRPointDTO(t: 30, bpm: 130, rrIntervalsMs: [780, 790]),
                HRPointDTO(t: 60, bpm: 155, rrIntervalsMs: nil),
            ],
            maxHR: 185, restHR: 55, metricsSourceRaw: "ble", kcalEstimate: 420
        )
        var bundle = SnappetBackup(exportedAt: .now)
        bundle.workoutSessions = [session]
        let decoded = try SnappetBackupEngine.deserialize(try SnappetBackupEngine.serialize(bundle))
        let s = decoded.workoutSessions[0]
        XCTAssertEqual(s.routineName, "Push day")
        XCTAssertEqual(s.hrSeries.count, 3)
        XCTAssertEqual(s.hrSeries[1].bpm, 130)
        XCTAssertEqual(s.hrSeries[1].rrIntervalsMs, [780, 790])
        XCTAssertEqual(s.maxHR, 185)
        XCTAssertEqual(s.kcalEstimate, 420)
    }

    // MARK: - Version gating

    func testFutureSchemaVersionThrows() throws {
        var bundle = SnappetBackup(exportedAt: .now)
        bundle.schemaVersion = 99
        let data = try SnappetBackupEngine.serialize(bundle)
        XCTAssertThrowsError(try SnappetBackupEngine.deserialize(data)) { error in
            if case SnappetBackupError.unsupportedVersion(let v) = error {
                XCTAssertEqual(v, 99)
            } else {
                XCTFail("Expected unsupportedVersion, got \(error)")
            }
        }
    }

    func testCurrentVersionAccepted() throws {
        let bundle = SnappetBackup(exportedAt: .now)
        XCTAssertEqual(bundle.schemaVersion, 1)
        XCTAssertNoThrow(try SnappetBackupEngine.deserialize(try SnappetBackupEngine.serialize(bundle)))
    }

    // MARK: - Journal → Markdown

    func testEmptyJournalMarkdownPlaceholder() {
        let md = SnappetBackupEngine.journalMarkdown([])
        XCTAssertTrue(md.contains("no entries"))
    }

    func testJournalMarkdownContainsTitleAndBody() {
        let entry = JournalEntryDTO(title: "Morning pages", body: "I am grateful.",
                                    createdAt: Date(timeIntervalSince1970: 1_000_000),
                                    updatedAt: Date(timeIntervalSince1970: 1_000_000),
                                    tags: ["reflection"])
        let md = SnappetBackupEngine.journalMarkdown([entry])
        XCTAssertTrue(md.contains("## Morning pages"))
        XCTAssertTrue(md.contains("I am grateful."))
        XCTAssertTrue(md.contains("#reflection"))
    }

    func testJournalMarkdownUntitledPlaceholder() {
        let entry = JournalEntryDTO(title: "", body: "No title.",
                                    createdAt: .now, updatedAt: .now, tags: [])
        let md = SnappetBackupEngine.journalMarkdown([entry])
        XCTAssertTrue(md.contains("_(untitled)_"))
    }

    func testJournalMarkdownSortedNewestFirst() {
        let older = JournalEntryDTO(title: "Old", body: ".",
                                    createdAt: Date(timeIntervalSince1970: 100),
                                    updatedAt: Date(timeIntervalSince1970: 100), tags: [])
        let newer = JournalEntryDTO(title: "New", body: ".",
                                    createdAt: Date(timeIntervalSince1970: 200),
                                    updatedAt: Date(timeIntervalSince1970: 200), tags: [])
        let md = SnappetBackupEngine.journalMarkdown([older, newer])
        let newIdx = md.range(of: "## New")!.lowerBound
        let oldIdx = md.range(of: "## Old")!.lowerBound
        XCTAssertLessThan(newIdx, oldIdx, "Newer entry should appear first")
    }

    // MARK: - Budget → CSV

    func testBudgetCSVContainsHeadersAndData() {
        let cat = BudgetCategoryDTO(id: UUID(), name: "Groceries", monthlyLimit: 400, createdAt: .now)
        let txn = BudgetTransactionDTO(categoryID: cat.id, amount: 52.30, note: "Supermarket", date: .now)
        let csv = SnappetBackupEngine.budgetCSV(categories: [cat], transactions: [txn])
        XCTAssertTrue(csv.contains("id,name,monthlyLimit,createdAt"))
        XCTAssertTrue(csv.contains("Groceries"))
        XCTAssertTrue(csv.contains("52.3"))
        XCTAssertTrue(csv.contains("Supermarket"))
        XCTAssertTrue(csv.contains("categoryID,amount,note,date"))
    }

    func testBudgetCSVEmptySectionsStillHaveHeaders() {
        let csv = SnappetBackupEngine.budgetCSV(categories: [], transactions: [])
        XCTAssertTrue(csv.contains("id,name,monthlyLimit,createdAt"))
        XCTAssertTrue(csv.contains("categoryID,amount,note,date"))
    }

    // MARK: - Expense → CSV

    func testExpenseCSVContainsGroupsAndRecords() {
        let group = ExpenseGroupDTO(id: UUID(), name: "Road trip", participants: ["Alice", "Bob"],
                                    createdAt: .now)
        let record = ExpenseRecordDTO(groupID: group.id, title: "Hotel", amount: 200, payer: "Alice",
                                      participants: ["Alice", "Bob"], date: .now,
                                      isSettlement: false, items: [], taxAmount: 0, discountAmount: 0)
        let csv = SnappetBackupEngine.expenseCSV(groups: [group], records: [record])
        XCTAssertTrue(csv.contains("Road trip"))
        XCTAssertTrue(csv.contains("Hotel"))
        XCTAssertTrue(csv.contains("Alice"))
        XCTAssertTrue(csv.contains("200.0"))
    }

    // MARK: - Workout history → JSON

    func testWorkoutHistoryJSONOnlyIncludesCompletedSessions() throws {
        let complete = WorkoutSessionDTO(id: UUID(), routineID: nil, routineName: "Legs",
                                         startedAt: Date(timeIntervalSince1970: 1_000_000),
                                         completedAt: Date(timeIntervalSince1970: 1_003_600),
                                         exercises: [], hrSeries: [], maxHR: nil, restHR: nil,
                                         metricsSourceRaw: nil, kcalEstimate: nil)
        let active = WorkoutSessionDTO(id: UUID(), routineID: nil, routineName: "Active",
                                        startedAt: Date(timeIntervalSince1970: 2_000_000),
                                        completedAt: nil,  // still live
                                        exercises: [], hrSeries: [], maxHR: nil, restHR: nil,
                                        metricsSourceRaw: nil, kcalEstimate: nil)
        let data = try SnappetBackupEngine.workoutHistoryJSON([complete, active])
        let decoded = try JSONDecoder().decode([WorkoutSessionDTO].self, from: data)
        XCTAssertEqual(decoded.count, 1, "Only the completed session should be exported")
        XCTAssertEqual(decoded[0].routineName, "Legs")
    }

    func testWorkoutHistoryJSONSortedNewestFirst() throws {
        let older = WorkoutSessionDTO(id: UUID(), routineID: nil, routineName: "Older",
                                       startedAt: Date(timeIntervalSince1970: 1_000_000),
                                       completedAt: Date(timeIntervalSince1970: 1_003_600),
                                       exercises: [], hrSeries: [], maxHR: nil, restHR: nil,
                                       metricsSourceRaw: nil, kcalEstimate: nil)
        let newer = WorkoutSessionDTO(id: UUID(), routineID: nil, routineName: "Newer",
                                       startedAt: Date(timeIntervalSince1970: 2_000_000),
                                       completedAt: Date(timeIntervalSince1970: 2_003_600),
                                       exercises: [], hrSeries: [], maxHR: nil, restHR: nil,
                                       metricsSourceRaw: nil, kcalEstimate: nil)
        let data = try SnappetBackupEngine.workoutHistoryJSON([older, newer])
        let decoded = try JSONDecoder().decode([WorkoutSessionDTO].self, from: data)
        XCTAssertEqual(decoded[0].routineName, "Newer", "Newest session should be first")
    }

    // MARK: - CSV escaping

    func testCSVEscapeNoEscapeNeeded() {
        XCTAssertEqual(SnappetBackupEngine.csvEscape("Simple"), "Simple")
    }

    func testCSVEscapeComma() {
        XCTAssertEqual(SnappetBackupEngine.csvEscape("Apples, Oranges"), "\"Apples, Oranges\"")
    }

    func testCSVEscapeQuote() {
        XCTAssertEqual(SnappetBackupEngine.csvEscape("He said \"hi\""), "\"He said \"\"hi\"\"\"")
    }

    func testCSVEscapeNewline() {
        XCTAssertEqual(SnappetBackupEngine.csvEscape("Line1\nLine2"), "\"Line1\nLine2\"")
    }

    // MARK: - Large bundle performance (does not hang)

    func testSerializeLargeBundleIsUnder5Seconds() throws {
        var bundle = SnappetBackup(exportedAt: .now)
        bundle.workoutSessions = (0..<500).map { i in
            WorkoutSessionDTO(id: UUID(), routineID: nil, routineName: "Session \(i)",
                              startedAt: Date(timeIntervalSince1970: Double(i) * 3600),
                              completedAt: Date(timeIntervalSince1970: Double(i) * 3600 + 3600),
                              exercises: [],
                              hrSeries: (0..<60).map { t in HRPointDTO(t: Double(t) * 10, bpm: 130, rrIntervalsMs: nil) },
                              maxHR: 180, restHR: 55, metricsSourceRaw: nil, kcalEstimate: nil)
        }
        measure {
            _ = try? SnappetBackupEngine.serialize(bundle)
        }
    }
}
