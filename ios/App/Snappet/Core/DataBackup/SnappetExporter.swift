import Foundation

/// Pure serialization helpers — no SwiftUI, no SwiftData, no platform I/O.
/// Every function takes plain value types and returns `Data` or `String`.
/// Device-side I/O (writing to Files, presenting share sheets) lives in `DataManagementView`.
enum SnappetExporter {

    // MARK: - Full backup

    static func bundleJSON(_ bundle: SnappetBackupBundle) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(bundle)
    }

    // MARK: - Journal → Markdown

    static func journalMarkdown(_ entries: [JournalEntrySnapshot]) -> String {
        guard !entries.isEmpty else { return "# Journal\n\n*No entries.*\n" }
        let sorted = entries.sorted { $0.createdAt > $1.createdAt }
        var lines: [String] = ["# Journal\n"]
        let df = ISO8601DateFormatter()
        for entry in sorted {
            let date = df.string(from: entry.createdAt)
            if entry.title.isEmpty {
                lines.append("## \(date)")
            } else {
                lines.append("## \(entry.title)")
                lines.append("*\(date)*")
            }
            if !entry.tags.isEmpty {
                lines.append("**Tags:** " + entry.tags.map { "#\($0)" }.joined(separator: " "))
            }
            lines.append("")
            lines.append(entry.body)
            lines.append("\n---\n")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Expense → CSV

    static func expenseCSV(
        groups: [ExpenseGroupSnapshot],
        records: [ExpenseRecordSnapshot]
    ) -> String {
        var rows: [String] = [
            "group_id,group_name,date,title,amount,payer,participants,is_settlement"
        ]
        let nameByID = Dictionary(groups.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let df = ISO8601DateFormatter()
        for r in records.sorted(by: { $0.date > $1.date }) {
            let group = nameByID[r.groupID] ?? r.groupID.uuidString
            let participants = r.participants.joined(separator: "|")
            let row = [
                r.groupID.uuidString,
                csvQuote(group),
                df.string(from: r.date),
                csvQuote(r.title),
                String(format: "%.2f", r.amount),
                csvQuote(r.payer),
                csvQuote(participants),
                r.isSettlement ? "true" : "false"
            ].joined(separator: ",")
            rows.append(row)
        }
        return rows.joined(separator: "\n") + "\n"
    }

    // MARK: - Budget → CSV

    static func budgetCSV(
        categories: [BudgetCategorySnapshot],
        transactions: [BudgetTransactionSnapshot]
    ) -> String {
        var rows: [String] = [
            "category_id,category_name,monthly_limit,date,amount,note"
        ]
        let nameByID = Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let df = ISO8601DateFormatter()
        for t in transactions.sorted(by: { $0.date > $1.date }) {
            let cat = nameByID[t.categoryID]
            let row = [
                t.categoryID.uuidString,
                csvQuote(cat?.name ?? ""),
                cat.map { String(format: "%.2f", $0.monthlyLimit) } ?? "",
                df.string(from: t.date),
                String(format: "%.2f", t.amount),
                csvQuote(t.note)
            ].joined(separator: ",")
            rows.append(row)
        }
        return rows.joined(separator: "\n") + "\n"
    }

    // MARK: - Workout history → JSON

    static func workoutSessionsJSON(_ sessions: [WorkoutSessionSnapshot]) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(sessions)
    }

    // MARK: - Helpers

    private static func csvQuote(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}
