import XCTest
import HighlightEngine
@testable import Snappet

/// The #68 per-module exports stay readable and correctly escaped: Journal → Markdown,
/// Budget / Split Expenses → CSV (RFC-4180 escaping, FK resolution, settlement/receipt
/// typing), workout history → JSON (ISO dates, full HR series), feedback → JSON.
final class ModuleExportsTests: XCTestCase {

    private let day = Date(timeIntervalSince1970: 1_750_000_000)   // 2025-06-15T15:06:40Z

    // MARK: - Journal → Markdown

    func testJournalMarkdownHasHeadingsTagsAndBodiesOldestFirst() throws {
        let older = JournalEntry(title: "Morning", body: "Coffee & plans.",
                                 createdAt: day, updatedAt: day, tags: ["calm"])
        let newer = JournalEntry(title: "", body: "Late thoughts.",
                                 createdAt: day.addingTimeInterval(3600),
                                 updatedAt: day.addingTimeInterval(7200))
        let md = ModuleExports.journalMarkdown([newer, older])

        XCTAssertTrue(md.hasPrefix("# Snappet Journal\n"))
        XCTAssertTrue(md.contains("## Morning"))
        XCTAssertTrue(md.contains("#calm"))
        XCTAssertTrue(md.contains("Coffee & plans."))
        XCTAssertTrue(md.contains("## Untitled"), "blank titles get a readable placeholder")
        XCTAssertTrue(md.contains("· edited "), "an edited entry shows both timestamps")
        let morning = try XCTUnwrap(md.range(of: "## Morning"))
        let untitled = try XCTUnwrap(md.range(of: "## Untitled"))
        XCTAssertLessThan(morning.lowerBound, untitled.lowerBound, "oldest entry first")
    }

    // MARK: - Budget → CSV

    func testBudgetCSVResolvesCategoriesEscapesFieldsAndKeepsOrphans() {
        let food = BudgetCategory(name: "Food, drink", monthlyLimit: 400)
        let tx = BudgetTransaction(categoryID: food.id, amount: 12.5,
                                   note: "Lunch \"special\", downtown", date: day)
        let orphan = BudgetTransaction(categoryID: UUID(), amount: 9, note: "", date: day.addingTimeInterval(60))
        let csv = ModuleExports.budgetCSV(categories: [food], transactions: [orphan, tx])

        let lines = csv.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[0], "date,category,note,amount,category_monthly_limit")
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[1].contains("\"Food, drink\""), "comma-bearing category is quoted")
        XCTAssertTrue(lines[1].contains("\"Lunch \"\"special\"\", downtown\""), "quotes doubled")
        XCTAssertTrue(lines[1].contains("12.50"))
        XCTAssertTrue(lines[1].contains("400.00"))
        XCTAssertTrue(lines[1].contains("2025-06-15T15:06:40Z"), "ISO-8601 UTC dates")
        XCTAssertTrue(lines[2].contains("(deleted category)"), "orphaned FK still exports")
        XCTAssertTrue(lines[2].hasSuffix(","), "no limit for a deleted category")
    }

    // MARK: - Split Expenses → CSV

    func testExpenseCSVTypesRowsAndFlattensReceiptItems() {
        let group = ExpenseGroup(name: "Trip", participants: ["Ana", "Bo"])
        let even = ExpenseRecord(groupID: group.id, title: "Dinner", amount: 40,
                                 payer: "Ana", participants: ["Ana", "Bo"], date: day)
        let receipt = ExpenseRecord(groupID: group.id, title: "Groceries", amount: 35,
                                    payer: "Bo", participants: ["Ana", "Bo"],
                                    date: day.addingTimeInterval(60),
                                    items: [ReceiptItem(name: "Milk", price: 3.5, assignees: ["Ana", "Bo"])],
                                    taxAmount: 2, discountAmount: 0.5)
        let settle = ExpenseRecord(groupID: group.id, title: "Settle up", amount: 10,
                                   payer: "Bo", participants: ["Ana"],
                                   date: day.addingTimeInterval(120), isSettlement: true)
        let csv = ModuleExports.expenseCSV(groups: [group], records: [settle, receipt, even])

        let lines = csv.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[0], "date,group,title,type,payer,participants,amount,tax,discount,items")
        XCTAssertEqual(lines.count, 4)
        XCTAssertTrue(lines[1].contains(",expense,"))
        XCTAssertTrue(lines[2].contains(",receipt,"))
        XCTAssertTrue(lines[2].contains("Milk (3.50) → Ana + Bo"))
        XCTAssertTrue(lines[2].contains("2.00"))
        XCTAssertTrue(lines[3].contains(",settlement,"))
        XCTAssertTrue(lines[1].contains("Ana; Bo"), "participants stay one readable cell")
    }

    // MARK: - Duplicate FK ids (a tampered/duplicated backup can restore them)

    /// Duplicate category/group ids must not crash the CSV builders — the old
    /// `Dictionary(uniqueKeysWithValues:)` trapped on them; now first-wins (#68 review
    /// fix 4; `SnappetBackup.restore` also dedupes, this is the belt-and-braces).
    func testCSVBuildersSurviveDuplicateIDsFirstWins() {
        let categoryID = UUID()
        let first = BudgetCategory(id: categoryID, name: "First", monthlyLimit: 100)
        let dupe = BudgetCategory(id: categoryID, name: "Shadow", monthlyLimit: 999)
        let tx = BudgetTransaction(categoryID: categoryID, amount: 5, note: "ok", date: day)
        let budget = ModuleExports.budgetCSV(categories: [first, dupe], transactions: [tx])
        XCTAssertTrue(budget.contains(",First,"), "the first occurrence's name wins")
        XCTAssertTrue(budget.contains("100.00"), "…and its limit")
        XCTAssertFalse(budget.contains("Shadow"))
        XCTAssertFalse(budget.contains("999.00"))

        let groupID = UUID()
        let tripA = ExpenseGroup(id: groupID, name: "Trip A", participants: ["Ana"])
        let tripB = ExpenseGroup(id: groupID, name: "Trip B", participants: ["Bo"])
        let record = ExpenseRecord(groupID: groupID, title: "Dinner", amount: 10,
                                   payer: "Ana", participants: ["Ana"], date: day)
        let expenses = ModuleExports.expenseCSV(groups: [tripA, tripB], records: [record])
        XCTAssertTrue(expenses.contains(",Trip A,"))
        XCTAssertFalse(expenses.contains("Trip B"))
    }

    // MARK: - Workout history → JSON

    func testWorkoutHistoryJSONIsReadableAndCarriesTheFullHRSeries() throws {
        let session = WorkoutSession(
            routineName: "Push day", startedAt: day, completedAt: day.addingTimeInterval(1800),
            exercises: [SessionExercise(exerciseId: "bench-press", targetSets: 1, targetReps: "8",
                                        targetRestSeconds: 60,
                                        sets: [SetLog(actualReps: 8, actualWeight: 60,
                                                      weightUnit: .kg, completedAt: day)])],
            hrSeries: (0..<600).map { HRPoint(t: Double($0), bpm: 120) })
        let data = try ModuleExports.workoutHistoryJSON([session])
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(text.contains("\"routineName\" : \"Push day\""), "pretty-printed")
        XCTAssertTrue(text.contains("2025-06-15T15:06:40Z"), "ISO-8601 dates, not raw doubles")
        XCTAssertTrue(text.contains("\"bench-press\""))

        // And it parses back: full HR series, nothing downsampled.
        let parsed = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual((parsed[0]["hrSeries"] as? [[String: Any]])?.count, 600)
    }

    // MARK: - Feedback → JSON

    func testFeedbackJSONEncodesEvents() throws {
        let event = HighlightFeedbackEvent(workoutId: "w1", activity: .climbing, action: .kept,
                                           atOffset: 12.5, score: 0.9, highlightKind: .high,
                                           selectorName: "hr", configFingerprint: "v1",
                                           timestamp: 1_750_000_000)
        let data = try ModuleExports.feedbackJSON([event])
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"workoutId\" : \"w1\""))
        XCTAssertTrue(text.contains("\"kept\""))
    }

    // MARK: - Festival → CSV

    func testFestivalCSVAnnotatesSetsWithPlanAndCaptures() throws {
        let pack = FestivalFixtures.glastonbury()
        let lineup = FestivalLineup(
            packID: pack.id, name: pack.name, location: pack.location,
            startDate: pack.startDate, endDate: pack.endDate, utcOffsetSeconds: pack.utcOffsetSeconds,
            stageCount: 6, setCount: 8, sourceLabel: "Test", fpackData: try pack.fpackData())
        let fred = FestivalFixtures.set(named: "Fred again..", in: pack)
        let simz = FestivalFixtures.set(named: "Little Simz", in: pack)

        // You starred Fred, danced ~30 min at his set, and filmed two clips there. Simz: untouched.
        let stars = [FestivalStar(packID: pack.id, setID: fred.id)]
        let attendance = [FestivalAttendance(
            packID: pack.id, setID: fred.id, artist: fred.artist, stage: fred.stage,
            sessionID: UUID(), startedAt: fred.start, endedAt: fred.start.addingTimeInterval(30 * 60))]
        let tags = [
            FestivalClipTag(packID: pack.id, setID: fred.id, artist: fred.artist, stage: fred.stage,
                            mediaID: UUID(), sessionID: UUID(), confidence: 0.97, reason: "withinSet",
                            source: .auto),
            FestivalClipTag(packID: pack.id, setID: fred.id, artist: fred.artist, stage: fred.stage,
                            mediaID: UUID(), sessionID: UUID(), confidence: 0.9, reason: "user",
                            source: .user),
        ]

        let csv = ModuleExports.festivalCSV(lineups: [lineup], stars: stars,
                                            attendance: attendance, tags: tags)
        let lines = csv.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "festival,day,stage,artist,start,end,starred,danced_minutes,clips")
        XCTAssertEqual(lines.count, 1 + pack.allSets.count, "one row per set in the installed lineup")

        let fredRow = try XCTUnwrap(lines.first { $0.contains("Fred again..") })
        XCTAssertTrue(fredRow.contains("Glastonbury 2026"))
        XCTAssertTrue(fredRow.hasSuffix(",yes,30,2"), "starred=yes, 30 danced minutes, 2 clips (\(fredRow))")

        let simzRow = try XCTUnwrap(lines.first { $0.contains("Little Simz") })
        XCTAssertTrue(simzRow.hasSuffix(",no,0,0"), "an untouched set reads no/0/0 (\(simzRow))")
    }

    func testFestivalCSVSkipsUndecodableLineupWithoutCrashing() {
        let junk = FestivalLineup(
            packID: "corrupt", name: "Corrupt", location: "", startDate: "2026-01-01",
            endDate: "2026-01-01", utcOffsetSeconds: 0, stageCount: 0, setCount: 0,
            sourceLabel: "Test", fpackData: Data([0x00, 0x01, 0x02]))
        let csv = ModuleExports.festivalCSV(lineups: [junk], stars: [], attendance: [], tags: [])
        // Header only — the bad lineup is skipped, not a crash, matching the CSV tolerance elsewhere.
        XCTAssertEqual(csv, "festival,day,stage,artist,start,end,starred,danced_minutes,clips\n")
    }

    // MARK: - CSV escaping

    func testCSVFieldEscaping() {
        XCTAssertEqual(ModuleExports.csvField("plain"), "plain")
        XCTAssertEqual(ModuleExports.csvField("a,b"), "\"a,b\"")
        XCTAssertEqual(ModuleExports.csvField("say \"hi\""), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(ModuleExports.csvField("two\nlines"), "\"two\nlines\"")
    }
}
