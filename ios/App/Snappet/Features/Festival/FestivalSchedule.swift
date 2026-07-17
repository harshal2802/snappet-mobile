import Foundation

/// Pure derivation for the day-schedule screen (wireframe frame 4): day tabs, stage-grouped rows
/// with past/NOW/upcoming state, ★/clash marks, the "I'm here" candidate, and the up-next set.
/// Everything takes `now` as a parameter — no `Date()` inside — so the whole surface unit-tests
/// without a simulator and the view is a thin render of these values.
enum FestivalSchedule {

    // MARK: Day tabs

    /// One tab per poster day: "SAT" / "27" (festival-local weekday + day-of-month).
    struct DayTab: Equatable, Identifiable {
        let date: String       // the poster date, "yyyy-MM-dd" — the selection key
        let weekday: String    // "SAT"
        let dayNumber: String  // "27"
        var id: String { date }
    }

    static func dayTabs(for pack: FestivalPack) -> [DayTab] {
        let cal = calendar(offsetSeconds: pack.utcOffsetSeconds)
        return pack.days.map { day in
            guard let window = day.window(utcOffsetSeconds: pack.utcOffsetSeconds) else {
                return DayTab(date: day.date, weekday: "—", dayNumber: "—")
            }
            // The window starts at rolloverHour ON the poster date — its start IS the poster day.
            let weekdayIndex = cal.component(.weekday, from: window.start) - 1
            let weekday = cal.shortWeekdaySymbols[weekdayIndex].uppercased()
            let dayNumber = String(cal.component(.day, from: window.start))
            return DayTab(date: day.date, weekday: weekday, dayNumber: dayNumber)
        }
    }

    /// The tab to land on: the day whose (rollover-to-rollover) window contains `now`; else the
    /// next upcoming day (pre-festival opens on day 1); else the last day (post-festival recap).
    static func defaultDayDate(in pack: FestivalPack, now: Date) -> String? {
        if let current = pack.day(containing: now) { return current.date }
        let upcoming = pack.days.first {
            ($0.window(utcOffsetSeconds: pack.utcOffsetSeconds)?.start ?? .distantPast) > now
        }
        return (upcoming ?? pack.days.last)?.date
    }

    // MARK: Rows

    enum RowState: Equatable {
        case past
        case now(remaining: TimeInterval)
        case upcoming(startsIn: TimeInterval)
    }

    struct Row: Equatable, Identifiable {
        let set: FestivalSet
        let state: RowState
        let starred: Bool
        /// This starred set overlaps another starred set (frame 4's "⚠︎ clash"). Only ever true
        /// on a starred row — an unstarred overlap is normal festival programming, not a clash.
        let clashing: Bool
        // `self.` is load-bearing: a getter body starting with the bare identifier `set` parses
        // as a setter accessor ("expected '{' to start setter definition") — the prompt-01 pitfall.
        var id: UUID { self.set.id }

        var isNow: Bool { if case .now = state { return true } else { return false } }
    }

    struct StageGroup: Equatable, Identifiable {
        let stage: String
        let rows: [Row]
        var id: String { stage }
    }

    /// The selected day's schedule, grouped by stage in pack order, sets sorted by start.
    /// `starred` is the set-id bag the ★ rows toggle; clash marks derive from it via
    /// `FestivalPlan.clashes` (prompt 01's interval math — one source of truth).
    static func stageGroups(for dayDate: String, in pack: FestivalPack,
                            starred: Set<UUID>, now: Date) -> [StageGroup] {
        guard let day = pack.days.first(where: { $0.date == dayDate }) else { return [] }
        let clashIDs = clashingSetIDs(in: pack, starred: starred)
        return day.stages.map { stage in
            let rows = stage.sets
                .sorted { $0.start != $1.start ? $0.start < $1.start : $0.artist < $1.artist }
                .map { set in
                    Row(set: set,
                        state: state(of: set, now: now),
                        starred: starred.contains(set.id),
                        clashing: clashIDs.contains(set.id))
                }
            return StageGroup(stage: stage.name, rows: rows)
        }
    }

    static func state(of set: FestivalSet, now: Date) -> RowState {
        if now < set.start { return .upcoming(startsIn: set.start.timeIntervalSince(now)) }
        if now < set.end { return .now(remaining: set.end.timeIntervalSince(now)) }
        return .past
    }

    /// Every starred set involved in at least one clash (both sides of each overlapping pair).
    static func clashingSetIDs(in pack: FestivalPack, starred: Set<UUID>) -> Set<UUID> {
        let plan = FestivalPlan(starredSetIDs: starred)
        return Set(plan.clashes(in: pack).flatMap { [$0.first.id, $0.second.id] })
    }

    // MARK: "I'm here" / up next

    /// The set the "I'm here" CTA names: among the sets live at `now` (any stage, any day),
    /// prefer a starred one, then the most recently started (where the action is), then artist
    /// for stability. `nil` between sets — the CTA hides; nothing to claim.
    static func liveSet(in pack: FestivalPack, starred: Set<UUID>, now: Date) -> FestivalSet? {
        let live = pack.allSets.filter { $0.start <= now && now < $0.end }
        return live.min { a, b in
            let aStar = starred.contains(a.id), bStar = starred.contains(b.id)
            if aStar != bStar { return aStar }
            if a.start != b.start { return a.start > b.start }
            return a.artist < b.artist
        }
    }

    /// All sets live at `now`, for the live sheet's "Switch set" picker (two stages live is exactly
    /// when the user needs to correct the claim). Sorted by start, then artist.
    static func liveSets(in pack: FestivalPack, now: Date) -> [FestivalSet] {
        pack.allSets.filter { $0.start <= now && now < $0.end }
            .sorted { $0.start != $1.start ? $0.start < $1.start : $0.artist < $1.artist }
    }

    /// The next set to start anywhere after `now` (the live sheet's "Up next" row).
    static func upNext(in pack: FestivalPack, now: Date) -> FestivalSet? {
        pack.allSets.filter { $0.start > now }
            .min { $0.start != $1.start ? $0.start < $1.start : $0.artist < $1.artist }
    }

    // MARK: Labels (festival-local — the pack's offset, never the phone's zone)

    /// "22:15" in festival-local time.
    static func timeLabel(_ date: Date, offsetSeconds: Int) -> String {
        let cal = calendar(offsetSeconds: offsetSeconds)
        let c = cal.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// "in 53 min" / "in 2 h 05" — the upcoming badge. `nil` beyond the 2-hour horizon (a badge on
    /// every future row is noise; the schedule times already say when).
    static func startsInLabel(_ interval: TimeInterval) -> String? {
        guard interval > 0, interval <= 2 * 3600 else { return nil }
        let minutes = Int((interval / 60).rounded(.up))
        if minutes < 60 { return "in \(minutes) min" }
        return String(format: "in %d h %02d", minutes / 60, minutes % 60)
    }

    /// "46 min left" / "1 h 12 left" — the live sheet's countdown.
    static func remainingLabel(_ interval: TimeInterval) -> String {
        let minutes = max(0, Int((interval / 60).rounded(.down)))
        if minutes < 60 { return "\(minutes) min left" }
        return String(format: "%d h %02d left", minutes / 60, minutes % 60)
    }

    /// "Dancing 44:12" / "1:02:07" — elapsed time on the floor.
    static func elapsedLabel(since start: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        if s < 3600 { return String(format: "%d:%02d", s / 60, s % 60) }
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    private static func calendar(offsetSeconds: Int) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: offsetSeconds) ?? TimeZone(secondsFromGMT: 0)!
        // Fixed English weekday labels ("SAT") — the process locale is unset under XCTest and
        // every other label in the app is English (the FestivalBrowse.dateRange rationale).
        cal.locale = Locale(identifier: "en_US")
        return cal
    }
}
