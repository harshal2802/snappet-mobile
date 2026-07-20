import Foundation

// MARK: - Poster-scan draft domain + heuristic floor (festival prompt 06, pure)
//
// The ingestion path for a user with no hosted `.fpack`: a photo of the festival's printed schedule
// poster → Apple Vision OCR (the thin device edge, `ReceiptScanner`) → this PURE parser turns the
// noisy multi-line OCR text into an editable `FestivalDraft`. The user always reviews/edits the draft,
// which is then built into a `FestivalPack` (prompt 01) and put through `FestivalPackValidator`
// (prompt 01) before `FestivalLineupInstaller` (prompt 02) installs it — a draft that doesn't validate
// surfaces the exact error, never installs silently.
//
// This file is the **heuristic FLOOR** of the E7 contract (decisions.md 2026-07-17): it does what it
// can with NO Apple Intelligence — line-parsing `HH:MM Artist` schedule rows, stage headings, day
// dates, a festival-title guess — so a user without an entitlement still lands in a pre-filled editor,
// never a dead end. `FestivalPosterIntelligence` (the FM sharpener) refines the SAME text into a
// better-structured draft WHEN available; it can never break this floor. Pure Foundation → unit-tested
// against OCR-text fixtures with no simulator, no camera, no Vision pass.

/// An editable, best-effort lineup the poster-scan review form binds to. Deliberately looser than
/// `FestivalPack`: times are `"HH:mm"` strings the user edits, dates may be blank, and it need not
/// validate yet — validation happens on install, after edits (`toPack()` → `FestivalPackValidator`).
/// Identifiable/Hashable identity is per-editing-instance (a random `id`), NOT content — content
/// identity is the pack's UUIDv5 job, derived from `localPackID` at build time.
struct FestivalDraft: Identifiable, Hashable {
    /// How this draft was structured — surfaced so the review form can badge "structured on device".
    enum Source: String, Sendable, Equatable {
        /// The pure heuristic floor (`FestivalPosterParser.parse`) — always available.
        case heuristic
        /// Sharpened by the on-device Foundation Models pass (`FestivalPosterIntelligence`).
        case appleIntelligence
    }

    var id = UUID()
    var name: String
    var location: String
    /// `yyyy-MM-dd` festival window (inclusive), or `""` when the poster didn't say — the user fills it.
    var startDate: String
    var endDate: String
    var utcOffsetSeconds: Int
    var days: [DraftDay]
    var source: Source = .heuristic

    /// The raw OCR text this draft was parsed from, kept so the review form can show "from your photo"
    /// provenance and the FM refiner has the same source the floor saw. Not part of the built pack.
    var ocrText: String = ""

    struct DraftDay: Identifiable, Hashable {
        var id = UUID()
        var date: String              // yyyy-MM-dd or ""
        var stages: [DraftStage]
    }

    struct DraftStage: Identifiable, Hashable {
        var id = UUID()
        var name: String
        var sets: [DraftSet]
    }

    struct DraftSet: Identifiable, Hashable {
        var id = UUID()
        var artist: String
        var start: String             // "HH:mm"
        var end: String               // "HH:mm"
    }

    var allSetCount: Int { days.reduce(0) { $0 + $1.stages.reduce(0) { $0 + $1.sets.count } } }

    // MARK: Local pack identity

    /// Fixed namespace for locally-built (poster-scanned / hand-entered) festival packs — constant
    /// forever (a random v4 UUID, chosen once). Separate from the hosted `.fpack` slug space so a
    /// poster-scanned pack can never collide with a curated `glastonbury-2026`-style id.
    static let localPackNamespace = UUID(uuidString: "9E1D4C77-2A6B-4F53-8B0E-1C7A9D0F62A4")!

    /// The generated pack id for a locally-built lineup: `poster-<12 hex>` where the hash is UUIDv5 over
    /// the draft's normalized content, so re-scanning the SAME poster converges on the same id — and,
    /// because set content-ids derive from the pack id (prompt 01), the same set ids. Poster scans
    /// aren't hosted, so this is a deterministic local slug, not a curated author slug.
    var localPackID: String {
        let content = FestivalPosterParser.normalizedContent(of: self)
        let hex = KilterClimbIdentity.uuidV5(namespace: Self.localPackNamespace, name: content)
            .replacingOccurrences(of: "-", with: "")
        return "poster-" + hex.prefix(12)
    }

    // MARK: Build a real pack (pure — the validator gate runs on the result)

    /// Assemble the editable draft into a wire `FestivalPack` (which stamps UUIDv5 content ids). Times
    /// combine each day's `date` with the set's `"HH:mm"` at the draft's UTC offset; an end that isn't
    /// strictly after its start is treated as crossing midnight (a 23:00–00:30 set), matching the poster.
    /// Lenient by design: an unparseable date/time yields a set the validator will reject with a typed
    /// error, rather than silently dropping the user's row. Empty days/stages/sets carry through so the
    /// validator can name exactly what's missing.
    func toPack() -> FestivalPack {
        let offset = utcOffsetSeconds
        let packDays: [FestivalDay] = days.map { day in
            FestivalDay(date: day.date, stages: day.stages.map { stage in
                FestivalStage(name: stage.name, sets: stage.sets.map { set in
                    let (start, end) = FestivalPosterParser.dates(date: day.date,
                                                                  start: set.start, end: set.end,
                                                                  offsetSeconds: offset)
                    return FestivalSet(artist: set.artist, start: start, end: end)
                })
            })
        }
        return FestivalPack(id: localPackID, name: name, location: location,
                            startDate: startDate, endDate: endDate,
                            utcOffsetSeconds: offset, days: packDays)
    }
}

/// The pure heuristic that turns Vision OCR text into a `FestivalDraft`. No SwiftUI/SwiftData/Vision —
/// so the whole floor unit-tests against multi-line OCR-text fixtures with no device.
enum FestivalPosterParser {

    /// Minutes fabricated for a set that shows only a start time (`"22:00 Aurora Skies"`) — a friendly
    /// default the user reviews, so the draft is immediately editable rather than half-blank.
    static let defaultSetMinutes = 60

    /// Stage-heading vocabulary: a line with NO time that contains one of these (or is short all-caps)
    /// starts a new stage.
    private static let stageKeywords = ["STAGE", "TENT", "ARENA", "FIELD", "TERRACE", "DOME",
                                        "CLUB", "PAVILION", "GARDEN", "BARN"]
    private static let weekdays = ["monday", "tuesday", "wednesday", "thursday", "friday",
                                   "saturday", "sunday", "mon", "tue", "wed", "thu", "fri",
                                   "sat", "sun"]

    /// OCR text → editable draft. `defaultOffsetSeconds` seeds the draft's offset (the poster rarely
    /// prints a UTC offset; the user confirms it in the editor). Garbage in → a draft with a name guess
    /// and no days — an "empty-but-valid" starting point the user fills, never a crash or a dead end.
    static func parse(ocrText: String, defaultOffsetSeconds: Int = 0) -> FestivalDraft {
        let rawLines = ocrText.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var draft = FestivalDraft(name: "", location: "", startDate: "", endDate: "",
                                  utcOffsetSeconds: defaultOffsetSeconds, days: [])
        draft.ocrText = ocrText
        guard !rawLines.isEmpty else { return draft }

        // The first non-empty line is the festival-title guess.
        draft.name = rawLines[0]

        for line in rawLines.dropFirst() {
            // 1) A day date line (`2026-08-15`, possibly with a trailing weekday label).
            if let date = posterDate(in: line) {
                appendDay(date, to: &draft)
                if draft.startDate.isEmpty { draft.startDate = date }
                draft.endDate = date
                continue
            }

            // 2) A schedule row: at least one time AND artist text left after the times are removed.
            let times = timeTokens(in: line)
            if !times.isEmpty {
                let artist = artistResidue(of: line)
                if !artist.isEmpty {
                    appendSet(artist: artist, times: times, to: &draft)
                    continue
                }
                // A bare time with no artist — ignore it (nothing to tag).
                continue
            }

            // 3) A stage heading: no time, and either a stage keyword or short all-caps.
            if isStageHeading(line) {
                appendStage(named: titleCased(line), to: &draft)
                continue
            }

            // 4) A plain line before any set — the location guess (only the first one).
            if draft.location.isEmpty && draft.allSetCount == 0 && !hasStarted(draft) {
                draft.location = line
            }
        }
        return draft
    }

    // MARK: - Building the draft up

    /// Whether any day/stage/set structure has been opened yet (so a plain line after the header block
    /// isn't mistaken for the location).
    private static func hasStarted(_ draft: FestivalDraft) -> Bool {
        !draft.days.isEmpty
    }

    private static func appendDay(_ date: String, to draft: inout FestivalDraft) {
        // Don't duplicate a day the poster repeats; just make it current by leaving it last if it is.
        if draft.days.last?.date == date { return }
        if let idx = draft.days.firstIndex(where: { $0.date == date }) {
            let existing = draft.days.remove(at: idx)
            draft.days.append(existing)
            return
        }
        draft.days.append(.init(date: date, stages: []))
    }

    private static func appendStage(named name: String, to draft: inout FestivalDraft) {
        ensureDay(&draft)
        draft.days[draft.days.count - 1].stages.append(.init(name: name, sets: []))
    }

    private static func appendSet(artist: String, times: [String], to draft: inout FestivalDraft) {
        ensureStage(&draft)
        let start = times[0]
        let end = times.count >= 2 ? times[1] : addMinutes(start, defaultSetMinutes)
        let lastDay = draft.days.count - 1
        let lastStage = draft.days[lastDay].stages.count - 1
        draft.days[lastDay].stages[lastStage].sets.append(.init(artist: artist, start: start, end: end))
    }

    /// Ensure there's a current day (create a blank-dated one — the user dates it in the editor).
    private static func ensureDay(_ draft: inout FestivalDraft) {
        if draft.days.isEmpty {
            draft.days.append(.init(date: draft.startDate, stages: []))
        }
    }

    /// Ensure there's a current stage under the current day (create a default-named one).
    private static func ensureStage(_ draft: inout FestivalDraft) {
        ensureDay(&draft)
        let lastDay = draft.days.count - 1
        if draft.days[lastDay].stages.isEmpty {
            draft.days[lastDay].stages.append(.init(name: "Stage", sets: []))
        }
    }

    // MARK: - Line classification (pure token work)

    /// `yyyy-MM-dd` at the start of a line (allowing a trailing weekday / label), or nil.
    static func posterDate(in line: String) -> String? {
        let token = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? line
        let parts = token.split(separator: "-").map(String.init)
        guard parts.count == 3, parts[0].count == 4,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d), y >= 1970 else { return nil }
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    /// Every `HH:MM` / `H.MM` time token on a line, normalized to zero-padded `"HH:mm"`, in order.
    static func timeTokens(in line: String) -> [String] {
        var out: [String] = []
        // Split on whitespace and common separators so `21:00-22:30` yields two tokens.
        let pieces = line.split(whereSeparator: { " \t–—-".contains($0) })
        for piece in pieces {
            if let t = normalizedTime(String(piece)) { out.append(t) }
        }
        return out
    }

    /// The artist text left once times and range words are stripped: `"21:00 - 22:30 Neon Parade"` →
    /// `"Neon Parade"`, `"The Midnights 19:30"` → `"The Midnights"`. Whitespace-collapsed.
    static func artistResidue(of line: String) -> String {
        var kept: [String] = []
        for piece in line.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            let token = String(piece)
            // Drop time tokens, a bare range dash, and the word "to" / "til" between times.
            if normalizedTime(token.trimmingCharacters(in: CharacterSet(charactersIn: "–—-"))) != nil {
                continue
            }
            let lower = token.lowercased()
            if token == "-" || token == "–" || token == "—" || lower == "to" || lower == "til"
                || lower == "till" { continue }
            kept.append(token)
        }
        return kept.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    /// A stage heading: no time, and either it carries a stage keyword or it's short all-caps prose.
    static func isStageHeading(_ line: String) -> Bool {
        guard timeTokens(in: line).isEmpty else { return false }
        let upper = line.uppercased()
        if stageKeywords.contains(where: { upper.contains($0) }) { return true }
        // Short, letter-only, all-caps line (`"MAIN"`) → a stage. Avoid dates/weekday-only lines.
        let letters = line.filter { $0.isLetter }
        let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        let looksLikeWeekday = words.count == 1 && weekdays.contains(line.lowercased())
        return line == upper && !letters.isEmpty && words.count <= 4 && !looksLikeWeekday
            && !line.contains(where: \.isNumber)
    }

    // MARK: - Time helpers

    /// `"9:30"`, `"21.00"`, `"07:05"` → `"HH:mm"`; anything else → nil. Rejects out-of-range clocks.
    static func normalizedTime(_ token: String) -> String? {
        let t = token.trimmingCharacters(in: CharacterSet(charactersIn: ".,;"))
        let sep: Character
        if t.contains(":") { sep = ":" } else if t.contains(".") { sep = "." } else { return nil }
        let parts = t.split(separator: sep)
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              parts[1].count == 2, (0...23).contains(h), (0...59).contains(m) else { return nil }
        return String(format: "%02d:%02d", h, m)
    }

    /// Add minutes to an `"HH:mm"`, wrapping past midnight (`"23:30" + 60` → `"00:30"`).
    static func addMinutes(_ hhmm: String, _ minutes: Int) -> String {
        guard let base = minutesOfDay(hhmm) else { return hhmm }
        let total = (base + minutes) % (24 * 60)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private static func minutesOfDay(_ hhmm: String) -> Int? {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return h * 60 + m
    }

    /// Combine a `yyyy-MM-dd` day + two `"HH:mm"` clocks at a fixed UTC offset into absolute
    /// `(start, end)` dates. An end not strictly after the start crosses midnight onto the next day (a
    /// late-night set). An unparseable date/time yields `start == end` so the validator flags it —
    /// nothing is silently dropped.
    static func dates(date: String, start: String, end: String,
                      offsetSeconds: Int) -> (start: Date, end: Date) {
        guard let startDate = isoDate(date: date, hhmm: start, offsetSeconds: offsetSeconds),
              let sMin = minutesOfDay(normalizedTime(start) ?? start) else {
            let epoch = Date(timeIntervalSince1970: 0)
            return (epoch, epoch)
        }
        let eMin = minutesOfDay(normalizedTime(end) ?? end) ?? sMin
        let span = (eMin <= sMin ? eMin + 24 * 60 : eMin) - sMin
        return (startDate, startDate.addingTimeInterval(Double(span) * 60))
    }

    private static func isoDate(date: String, hhmm: String, offsetSeconds: Int) -> Date? {
        guard let time = normalizedTime(hhmm) else { return nil }
        let sign = offsetSeconds < 0 ? "-" : "+"
        let a = abs(offsetSeconds)
        let iso = "\(date)T\(time):00\(sign)" + String(format: "%02d:%02d", a / 3600, (a % 3600) / 60)
        return FestivalPack.parseISO(iso)
    }

    // MARK: - Content identity + display

    /// The normalized string a locally-built pack's id hashes over (see `FestivalDraft.localPackID`):
    /// name + every `day|stage|artist|start|end`, lowercased + whitespace-collapsed, so cosmetic
    /// whitespace differences between two scans of the same poster don't re-key the pack.
    static func normalizedContent(of draft: FestivalDraft) -> String {
        var rows = ["poster:v1", normalize(draft.name)]
        for day in draft.days {
            for stage in day.stages {
                for set in stage.sets {
                    rows.append([normalize(day.date), normalize(stage.name), normalize(set.artist),
                                 set.start, set.end].joined(separator: "|"))
                }
            }
        }
        return rows.joined(separator: "\n")
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Title-case a stage heading OCR'd in all caps (`"MAIN STAGE"` → `"Main Stage"`), leaving
    /// already-mixed-case text alone.
    private static func titleCased(_ line: String) -> String {
        guard line == line.uppercased() else { return line }
        return line.split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }
}
