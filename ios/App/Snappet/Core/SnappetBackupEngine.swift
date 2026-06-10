import Foundation

/// Pure, platform-free engine for Snappet suite-level data backup and per-module text exports.
///
/// **No SwiftData / UIKit / AppKit imports** — the engine works only on DTO value types so every
/// function is testable in `SnappetTests` without a device or simulator.
///
/// The service layer (`SnappetDataService`) is responsible for fetching model objects from the
/// `ModelContext` and constructing the DTOs; this engine only serializes and formats them.
enum SnappetBackupEngine {

    // MARK: - Full-suite backup (JSON)

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Encode a complete suite backup to JSON.
    static func serialize(_ backup: SnappetBackup) throws -> Data {
        try encoder.encode(backup)
    }

    /// Decode a JSON blob previously produced by `serialize`.
    ///
    /// - Throws: `SnappetBackupError.unsupportedVersion` when `schemaVersion > 1`.
    static func deserialize(_ data: Data) throws -> SnappetBackup {
        let backup = try decoder.decode(SnappetBackup.self, from: data)
        guard backup.schemaVersion <= 1 else {
            throw SnappetBackupError.unsupportedVersion(backup.schemaVersion)
        }
        return backup
    }

    // MARK: - Journal → Markdown

    /// Render journal entries as a single Markdown document, newest first.
    /// Front-matter block per entry: `## title\n_date_\n**tags**\n\nbody`.
    static func journalMarkdown(_ entries: [JournalEntryDTO]) -> String {
        guard !entries.isEmpty else { return "# Journal\n\n_(no entries)_\n" }

        var lines = ["# Journal\n"]
        let dateFormatter = ISO8601DateFormatter()

        for entry in entries.sorted(by: { $0.createdAt > $1.createdAt }) {
            let title = entry.title.isEmpty ? "_(untitled)_" : entry.title
            lines.append("## \(title)\n")
            lines.append("_\(dateFormatter.string(from: entry.createdAt))_\n")
            if !entry.tags.isEmpty {
                lines.append("**Tags:** \(entry.tags.map { "#\($0)" }.joined(separator: " "))\n")
            }
            lines.append("")
            lines.append(entry.body)
            lines.append("\n---\n")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Budget → CSV

    /// Render budget categories + transactions as CSV.
    /// Two sections: `## Categories` header + rows, `## Transactions` header + rows.
    static func budgetCSV(
        categories: [BudgetCategoryDTO],
        transactions: [BudgetTransactionDTO]
    ) -> String {
        var rows: [String] = []
        rows.append("## Categories")
        rows.append("id,name,monthlyLimit,createdAt")
        for c in categories.sorted(by: { $0.name < $1.name }) {
            rows.append("\(csvEscape(c.id.uuidString)),\(csvEscape(c.name)),\(c.monthlyLimit),\(iso(c.createdAt))")
        }
        rows.append("")
        rows.append("## Transactions")
        rows.append("categoryID,amount,note,date")
        for t in transactions.sorted(by: { $0.date > $1.date }) {
            rows.append("\(csvEscape(t.categoryID.uuidString)),\(t.amount),\(csvEscape(t.note)),\(iso(t.date))")
        }
        return rows.joined(separator: "\n") + "\n"
    }

    // MARK: - Expense → CSV

    /// Render expense groups + records as CSV (two sections).
    static func expenseCSV(
        groups: [ExpenseGroupDTO],
        records: [ExpenseRecordDTO]
    ) -> String {
        var rows: [String] = []
        rows.append("## Groups")
        rows.append("id,name,participants,createdAt")
        for g in groups.sorted(by: { $0.name < $1.name }) {
            rows.append("\(csvEscape(g.id.uuidString)),\(csvEscape(g.name)),\(csvEscape(g.participants.joined(separator: ";"))),\(iso(g.createdAt))")
        }
        rows.append("")
        rows.append("## Expense Records")
        rows.append("groupID,title,amount,payer,participants,date,isSettlement")
        for r in records.sorted(by: { $0.date > $1.date }) {
            rows.append(
                "\(csvEscape(r.groupID.uuidString))," +
                "\(csvEscape(r.title))," +
                "\(r.amount)," +
                "\(csvEscape(r.payer))," +
                "\(csvEscape(r.participants.joined(separator: ";")))," +
                "\(iso(r.date))," +
                "\(r.isSettlement ? "true" : "false")"
            )
        }
        return rows.joined(separator: "\n") + "\n"
    }

    // MARK: - Workout history → JSON

    /// Encode completed workout sessions as a standalone JSON array (without the full bundle).
    static func workoutHistoryJSON(_ sessions: [WorkoutSessionDTO]) throws -> Data {
        try encoder.encode(sessions.filter { $0.completedAt != nil }
                                   .sorted { ($0.startedAt) > ($1.startedAt) })
    }

    // MARK: - Helpers

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    /// RFC 4180: wrap field in `"…"` if it contains comma, newline, or `"`. Double internal `"`.
    static func csvEscape(_ value: String) -> String {
        guard value.contains(",") || value.contains("\n") || value.contains("\"") else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

// MARK: - Errors

enum SnappetBackupError: LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case corruptData(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let v):
            return "This backup was made by a newer version of Snappet (schema v\(v)) and can't be read by this version. Update the app and try again."
        case .corruptData(let detail):
            return "The backup file appears to be corrupted and couldn't be read. (\(detail))"
        }
    }
}
