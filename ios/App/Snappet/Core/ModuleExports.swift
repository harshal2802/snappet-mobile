import Foundation
import HighlightEngine

/// Per-module exports in the format that matters (issue #68): Journal → Markdown,
/// Budget / Split Expenses → CSV, workout history → JSON, highlight feedback → JSON.
/// Pure string/data builders over the models — unit-tested in `SnappetTests` with no
/// store; `BackupView` is the thin Files edge that writes the result.
///
/// Dates are ISO-8601 UTC (`Date.ISO8601FormatStyle`) — unambiguous, spreadsheet-
/// parseable, and deterministic in tests. These are human/tool-facing exports; only
/// the suite backup (`SnappetBackup`) needs exact `Date` round-tripping.
enum ModuleExports {

    // MARK: - Journal → Markdown

    /// One Markdown document, oldest entry first (reads like the journal itself).
    static func journalMarkdown(_ entries: [JournalEntry]) -> String {
        var out = "# Snappet Journal\n"
        for entry in entries.sorted(by: { $0.createdAt < $1.createdAt }) {
            let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            out += "\n## \(title.isEmpty ? "Untitled" : title)\n"
            var meta = entry.createdAt.formatted(.iso8601)
            if entry.updatedAt != entry.createdAt {
                meta += " · edited \(entry.updatedAt.formatted(.iso8601))"
            }
            if !entry.tags.isEmpty {
                meta += " · " + entry.tags.map { "#\($0)" }.joined(separator: " ")
            }
            out += "*\(meta)*\n\n\(entry.body)\n"
        }
        return out
    }

    // MARK: - Budget → CSV

    /// One row per transaction, oldest first, with the category resolved by FK (a
    /// transaction whose category was deleted still exports, labeled as such).
    static func budgetCSV(categories: [BudgetCategory], transactions: [BudgetTransaction]) -> String {
        // First-wins uniquing, NOT `uniqueKeysWithValues` (which traps): duplicate ids are
        // legal data a tampered/duplicated backup can restore — an export must never crash
        // on them (#68 review fix 4; restore also dedupes, this is the belt-and-braces).
        let names = Dictionary(categories.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let limits = Dictionary(categories.map { ($0.id, $0.monthlyLimit) }, uniquingKeysWith: { a, _ in a })
        var out = "date,category,note,amount,category_monthly_limit\n"
        for tx in transactions.sorted(by: { $0.date < $1.date }) {
            let fields = [
                tx.date.formatted(.iso8601),
                names[tx.categoryID] ?? "(deleted category)",
                tx.note,
                money(tx.amount),
                limits[tx.categoryID].map(money) ?? "",
            ]
            out += fields.map(csvField).joined(separator: ",") + "\n"
        }
        return out
    }

    // MARK: - Split Expenses → CSV

    /// One row per record, oldest first. Settlements and itemized receipts share the
    /// `ExpenseRecord` model, so a `type` column keeps the three shapes distinguishable;
    /// receipt line items flatten into one readable cell.
    static func expenseCSV(groups: [ExpenseGroup], records: [ExpenseRecord]) -> String {
        // First-wins uniquing — same duplicate-id tolerance as `budgetCSV` above.
        let names = Dictionary(groups.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        var out = "date,group,title,type,payer,participants,amount,tax,discount,items\n"
        for record in records.sorted(by: { $0.date < $1.date }) {
            let type = record.isSettlement ? "settlement" : (record.isReceipt ? "receipt" : "expense")
            let items = record.items
                .map { "\($0.name) (\(money($0.price))) → \($0.assignees.joined(separator: " + "))" }
                .joined(separator: "; ")
            let fields = [
                record.date.formatted(.iso8601),
                names[record.groupID] ?? "(deleted group)",
                record.title,
                type,
                record.payer,
                record.participants.joined(separator: "; "),
                money(record.amount),
                record.isReceipt ? money(record.taxAmount) : "",
                record.isReceipt ? money(record.discountAmount) : "",
                items,
            ]
            out += fields.map(csvField).joined(separator: ",") + "\n"
        }
        return out
    }

    // MARK: - Festival → CSV

    /// One row per set across every installed lineup, annotated with YOUR weekend: whether you
    /// starred it, minutes you spent "on the floor" (summed `FestivalAttendance` stretches), and how
    /// many clips are tagged to it. The schedule is decoded from each lineup's stored `.fpack` bytes,
    /// so the file is self-contained — the same UUIDv5 set content-ids the stars / attendance / tags
    /// key on. A lineup whose bytes won't decode is skipped rather than crashing the export (the same
    /// tampered-data tolerance as `budgetCSV`). Sets are emitted in schedule order; set times are the
    /// festival's own local time (ISO-8601 with the pack's offset), the day is its poster date.
    static func festivalCSV(lineups: [FestivalLineup], stars: [FestivalStar],
                            attendance: [FestivalAttendance], tags: [FestivalClipTag]) -> String {
        func key(_ packID: String, _ setID: UUID) -> String { "\(packID)\u{1}\(setID.uuidString)" }
        let starred = Set(stars.map { key($0.packID, $0.setID) })
        var dancedSec: [String: TimeInterval] = [:]
        for a in attendance {
            let seconds = max(0, (a.endedAt ?? a.startedAt).timeIntervalSince(a.startedAt))
            dancedSec[key(a.packID, a.setID), default: 0] += seconds
        }
        var clipCount: [String: Int] = [:]
        for t in tags { clipCount[key(t.packID, t.setID), default: 0] += 1 }

        var out = "festival,day,stage,artist,start,end,starred,danced_minutes,clips\n"
        for lineup in lineups.sorted(by: { $0.packID < $1.packID }) {
            guard let pack = try? FestivalPack.decode(fpack: lineup.fpackData) else { continue }
            for day in pack.days {
                var rows: [(stage: String, set: FestivalSet)] = []
                for stage in day.stages {
                    for set in stage.sets { rows.append((stage.name, set)) }
                }
                rows.sort { a, b in
                    a.set.start != b.set.start ? a.set.start < b.set.start : a.set.artist < b.set.artist
                }
                for row in rows {
                    let stageName = row.stage
                    let set = row.set
                    let k = key(lineup.packID, set.id)
                    let mins = Int((dancedSec[k] ?? 0) / 60.0 + 0.5)
                    let fields = [
                        pack.name,
                        day.date,
                        stageName,
                        set.artist,
                        FestivalPack.isoString(set.start, utcOffsetSeconds: pack.utcOffsetSeconds),
                        FestivalPack.isoString(set.end, utcOffsetSeconds: pack.utcOffsetSeconds),
                        starred.contains(k) ? "yes" : "no",
                        String(mins),
                        String(clipCount[k] ?? 0),
                    ]
                    out += fields.map(csvField).joined(separator: ",") + "\n"
                }
            }
        }
        return out
    }

    // MARK: - Workout history → JSON

    /// Readable JSON (pretty, sorted keys, ISO-8601 dates) of the full history — every
    /// set log AND the complete HR series. HR is deliberately NOT downsampled (the
    /// export is the user's data, whole); see the `SnappetBackup` size note.
    static func workoutHistoryJSON(_ sessions: [WorkoutSession]) throws -> Data {
        let rows = sessions
            .map(SnappetBackup.WorkoutSessionRow.init)
            .sorted { $0.startedAt < $1.startedAt }
        return try prettyEncoder().encode(rows)
    }

    // MARK: - Highlight feedback → JSON

    /// The consented export of `FeedbackStore.exportAll()` — the on-device reel-edit
    /// training data (#60 §E). Stays on device unless the user writes it out here.
    static func feedbackJSON(_ events: [HighlightFeedbackEvent]) throws -> Data {
        try prettyEncoder().encode(events)
    }

    // MARK: - Helpers

    /// RFC-4180-style escaping: quote when the field holds a comma, quote, or newline;
    /// double any embedded quotes.
    static func csvField(_ raw: String) -> String {
        guard raw.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else {
            return raw
        }
        return "\"" + raw.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func money(_ value: Double) -> String { String(format: "%.2f", value) }

    private static func prettyEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
