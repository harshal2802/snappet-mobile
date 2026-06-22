import Foundation

// MARK: - Recap Feed — the single card → display mapping (pure)
//
// `FeedCardDisplay` is the ONE place that turns a `FeedCardPayload` (+ kind) into the kicker /
// hero / hero-caption / supporting lines / accent / icon every render surface shows. It is pure
// (Foundation only — it may reference `DistanceUnit` / `SetMeasure` / `HeartRateZone`, all pure
// same-target value types, but NO SwiftUI/UIKit/Color) so it unit-tests without a simulator and
// the Kotlin port mirrors it 1:1.
//
// Before this, FOUR surfaces each owned a parallel switch over `FeedCardPayload` and drifted apart
// (D1–D25 in the wording audit): `FeedCardView` (list), `ShareCardSpec` (share), `StoryComposition`
// (Wrapped stories), and `WallTile` (send wall). They now all read from this descriptor — they own
// LAYOUT, never wording/accent/icon. The view layer adds a `FeedAccent.color` bridge (it imports
// SwiftUI, so it lives in `FeedCardView.swift`, not here).
//
// Distance is unit-aware: the hosting views derive the user's `DistanceUnit` (from the
// `workoutlog.preferredUnit` @AppStorage via `SessionRecap.distanceUnit`) and pass it to
// `FeedCard.display(unit:)`, so the LIST and WALL always honor the user's km/mi choice.

/// A platform-free discipline-accent token. The view maps it to a `SnappetColor` (see
/// `FeedAccent.color` in `FeedCardView.swift`). Extends the former `StoryAccent`; the
/// `typealias StoryAccent = FeedAccent` below keeps `StoryComposition` + its tests compiling.
enum FeedAccent: String, Codable, Sendable, Equatable, CaseIterable {
    case kilter      // climbing (amber)
    case workout     // strength / running (ember)
    case brand       // PR / celebration (coral)
    case effort      // session effort peak (hot)
    case recovery    // fitness-gain / HRV recovery (fresh/green)
    case aerobic     // protective rest nudge (moderate/amber)
}

/// Keeps `StoryScene.accent` and the existing `.kilter`/`.workout`/`.brand`/`.effort` literals (and
/// `StoryCompositionTests`) compiling unchanged while folding the accent vocabulary into one type.
typealias StoryAccent = FeedAccent

/// The fully-resolved display of ONE card, computed once from its payload. Every field is a
/// presentation string already formatted (grades, deltas, units) — surfaces never re-derive.
struct FeedCardDisplay: Equatable, Sendable {
    /// Uppercased-on-render kicker / category line ("Climb session", "New hardest ever").
    var kicker: String
    /// The big hero numeral / grade.
    var hero: String
    /// The hero's caption (the small word(s) under the hero, e.g. "Hardest send", "days in a row").
    var heroCaption: String
    /// The single most-informative supporting line (delta, prev-best, climb name). `nil` ⇒ none.
    var primaryLine: String?
    /// Any further supporting lines (richest surfaces show these; story shows only the lead line).
    var secondaryLines: [String]
    /// SF Symbol for the badge / hero glyph.
    var iconName: String
    /// Platform-free accent token (the view maps it to a `SnappetColor`).
    var accent: FeedAccent

    /// Convenience: primary + secondaries flattened, used by the share `lines` field.
    var lines: [String] { ([primaryLine] + secondaryLines).compactMap { $0 } }
}

extension FeedCard {
    /// The single card → display mapping. A METHOD (with a `.km` default) — not a stored/parameterless
    /// property — so the hosting view can thread the user's `DistanceUnit` through for the run hero.
    func display(unit: DistanceUnit = .km) -> FeedCardDisplay {
        FeedCardDisplay(payload: payload, kind: kind, distanceUnit: unit)
    }

    /// The accessibility identifier for a card, derived from its kind so the 27 milestone arms no longer
    /// hardcode `"feed.card.b1GradePR"`-style literals. `FeedCardKind.rawValue` reproduces every current
    /// identifier byte-for-byte (e.g. `a1Session`, `consistencyMap`, `restNudge`).
    var identifier: String { "feed.card.\(kind.rawValue)" }
}

extension FeedCardDisplay {
    init(payload: FeedCardPayload, kind: FeedCardKind, distanceUnit: DistanceUnit = .km) {
        switch payload {
        case .climbSession(let p):
            self.init(kicker: p.title ?? "Climb session", hero: p.hardestSendGrade ?? "—",
                      heroCaption: "Hardest send",
                      primaryLine: "\(p.sends) sends",
                      secondaryLines: ["\(p.totalClimbs) climbs", "\(p.totalAttempts) tries"],
                      iconName: "figure.climbing", accent: .kilter)

        case .workoutSession(let p):
            let running = p.disciplineRaw == "running" || (p.distanceMeters ?? 0) > 0
            if running, let m = p.distanceMeters {
                self.init(kicker: p.title, hero: SetMeasure.formatDistance(m, unit: distanceUnit),
                          heroCaption: "Distance",
                          primaryLine: "\(p.setCount) splits",
                          secondaryLines: ["\(p.exerciseCount) exercises"],
                          iconName: "figure.run", accent: .workout)
            } else {
                self.init(kicker: p.title, hero: FeedFmt.volume(p.totalVolume), heroCaption: "Volume",
                          primaryLine: "\(p.setCount) sets",
                          secondaryLines: ["\(p.exerciseCount) exercises"],
                          iconName: "dumbbell.fill", accent: .workout)
            }

        case .gradePR(let p):
            self.init(kicker: "New hardest ever", hero: p.newGrade, heroCaption: "New grade",
                      primaryLine: p.previousGrade.map { "up from \($0)" } ?? "your first peak",
                      secondaryLines: p.climbName.isEmpty ? [] : [p.climbName],
                      iconName: "trophy.fill", accent: .brand)

        case .mostClimbs(let p):
            self.init(kicker: "Biggest session", hero: "\(p.count)", heroCaption: "climbs in one go",
                      primaryLine: p.previousRecord.map { "beat \($0)" } ?? "session record",
                      secondaryLines: [], iconName: "flame.fill", accent: .kilter)

        case .streak(let p):
            self.init(kicker: p.isRecord ? "Longest streak ever" : "Streak",
                      hero: "\(p.days)", heroCaption: "days in a row",
                      primaryLine: p.isRecord
                          ? (p.previousBest > 0 ? "past best \(p.previousBest)" : "your longest yet")
                          : (p.weeks >= 1 ? "\(p.weeks) week\(p.weeks == 1 ? "" : "s") unbroken" : nil),
                      secondaryLines: [],
                      iconName: p.isRecord ? "crown.fill" : "calendar", accent: .kilter)

        case .pyramid(let p):
            let graded = p.rows.filter { $0.sends > 0 }.count
            self.init(kicker: "Grade pyramid", hero: p.maxGrade ?? "—",
                      heroCaption: "\(p.totalSends) sends",
                      primaryLine: "across \(graded) grade\(graded == 1 ? "" : "s")",
                      secondaryLines: [], iconName: "triangle.fill", accent: .kilter)

        case .weeklyVolume(let p):
            self.init(kicker: "Weekly volume", hero: "\(p.buckets.last?.sends ?? 0)",
                      heroCaption: "sends this week",
                      primaryLine: FeedFmt.delta(p.deltaVsPrev, suffix: "vs last week"),
                      secondaryLines: [], iconName: "chart.bar.fill", accent: .kilter)

        case .effort(let p):
            self.init(kicker: p.title ?? "Session effort", hero: "\(p.maxBpm)", heroCaption: "Peak BPM",
                      primaryLine: "avg \(p.avgBpm) · TRIMP \(p.trimp)",
                      secondaryLines: [], iconName: "bolt.heart.fill", accent: .effort)

        case .hardestEffort(let p):
            self.init(kicker: "Hardest-effort send", hero: "\(p.peakBpm)", heroCaption: "Peak BPM on a send",
                      primaryLine: FeedFmt.hardestEffortSub(p),
                      secondaryLines: p.climbName.isEmpty ? [] : [p.climbName],
                      iconName: "flame.fill", accent: .effort)

        case .hrTrend(let p):
            self.init(kicker: "HR trend", hero: "\(p.points.last?.avgBpm ?? 0)", heroCaption: "Recent avg BPM",
                      primaryLine: FeedFmt.hrTrendSub(p),
                      secondaryLines: [], iconName: "chart.xyaxis.line", accent: .workout)

        case .onTheBoard(let p):
            self.init(kicker: "On the board", hero: "\(p.litCount)", heroCaption: "climbs lit",
                      primaryLine: p.hardestGrade.map { "hardest \($0)" }
                          ?? (p.gradeSpread.isEmpty ? "pulled up, not logged" : p.gradeSpread),
                      secondaryLines: [], iconName: "square.grid.3x3.fill", accent: .kilter)

        case .liftPR(let p):
            self.init(kicker: "Lift PR", hero: "\(Int(p.oneRepMaxKg.rounded())) \(p.unit)",
                      heroCaption: "est. 1RM · \(p.exerciseName)",
                      primaryLine: p.previousOneRepMaxKg.map { "was \(Int($0.rounded())) \(p.unit)" } ?? "first 1RM",
                      secondaryLines: [], iconName: "dumbbell.fill", accent: .brand)

        case .pyramidHealth(let p):
            self.init(kicker: "Pyramid health", hero: p.consolidateGrade, heroCaption: "consolidate",
                      primaryLine: p.note, secondaryLines: [], iconName: "triangle.fill", accent: .kilter)

        case .progression(let p):
            self.init(kicker: "Progression", hero: "\(p.fromGrade) → \(p.toGrade)",
                      heroCaption: "over \(p.points.count) month\(p.points.count == 1 ? "" : "s")",
                      primaryLine: nil, secondaryLines: [],
                      iconName: "chart.line.uptrend.xyaxis", accent: .kilter)

        case .climbingLevel(let p):
            self.init(kicker: "Climbing level", hero: p.level, heroCaption: "working grade",
                      primaryLine: p.maxGrade.map { "max \($0)" }, secondaryLines: [],
                      iconName: "figure.climbing", accent: .kilter)

        case .angleDist(let p):
            self.init(kicker: "Angles", hero: "\(p.topAngle)°", heroCaption: "most sends",
                      primaryLine: "\(p.slices.count) angle\(p.slices.count == 1 ? "" : "s") climbed",
                      secondaryLines: [], iconName: "ruler", accent: .kilter)

        case .periodVsLast(let p):
            self.init(kicker: "This period", hero: "\(p.current)", heroCaption: "sends · \(p.currentLabel)",
                      primaryLine: FeedFmt.delta(p.current - p.previous, suffix: "vs last"),
                      secondaryLines: [], iconName: "calendar", accent: .kilter)

        case .consistency(let p):
            self.init(kicker: "Consistency", hero: "\(p.activeDays)", heroCaption: "active days",
                      primaryLine: "in the last \(p.windowDays)", secondaryLines: [],
                      iconName: "square.grid.3x3.fill", accent: .kilter)

        case .onThisDay(let p):
            self.init(kicker: "On this day", hero: p.grade ?? "—", heroCaption: "\(p.yearsAgo) yr ago",
                      primaryLine: p.summary, secondaryLines: [],
                      iconName: "clock.arrow.circlepath", accent: .kilter)

        case .firstAtGrade(let p):
            self.init(kicker: "First at grade", hero: p.grade, heroCaption: "your first \(p.grade)",
                      primaryLine: p.climbName.isEmpty ? nil : p.climbName, secondaryLines: [],
                      iconName: "star.fill", accent: .kilter)

        case .projectSent(let p):
            self.init(kicker: "Project sent", hero: p.grade,
                      heroCaption: "after \(p.sessions) session\(p.sessions == 1 ? "" : "s")",
                      primaryLine: p.climbName.isEmpty ? nil : p.climbName, secondaryLines: [],
                      iconName: "checkmark.seal.fill", accent: .brand)

        case .disciplineSplit(let p):
            self.init(kicker: "Discipline split", hero: p.topLabel, heroCaption: "most sessions",
                      primaryLine: p.slices.prefix(3).map { "\($0.label) \($0.count)" }.joined(separator: " · "),
                      secondaryLines: [], iconName: "chart.pie.fill", accent: .workout)

        case .trendArrows(let p):
            self.init(kicker: "90-day trends",
                      hero: p.arrows.first.map { "\($0.improving ? "▲" : "▼") \(abs($0.deltaPct))%" } ?? "—",
                      heroCaption: p.arrows.first?.label ?? "trend",
                      primaryLine: p.arrows.dropFirst().first.map {
                          "\($0.label) \($0.improving ? "▲" : "▼")\(abs($0.deltaPct))%" },
                      secondaryLines: [], iconName: "arrow.up.arrow.down", accent: .kilter)

        case .effortEfficiency(let p):
            self.init(kicker: "Fitness gain", hero: "\(p.newAvgBpm)",
                      heroCaption: "avg BPM sending \(p.gradeBand)",
                      primaryLine: "was \(p.oldAvgBpm) — same grade, less effort",
                      secondaryLines: [], iconName: "bolt.heart", accent: .recovery)

        case .hrvRecovery(let p):
            self.init(kicker: "Recovery", hero: "\(p.rmssd)", heroCaption: "RMSSD",
                      primaryLine: p.note, secondaryLines: [],
                      iconName: "heart.text.square", accent: .recovery)

        case .restNudge(let p):
            self.init(kicker: "Go gentler", hero: "\(p.hardDays)", heroCaption: "hard days in a row",
                      primaryLine: p.note, secondaryLines: [],
                      iconName: "leaf.fill", accent: .aerobic)
        }
    }
}

/// Pure presentation formatters lifted out of `FeedCardView` (which had them `private`). Foundation only.
/// Distance/pace formatting is delegated to the unit-aware `SetMeasure` (one source of truth) — see
/// `FeedCardDisplay.init`'s run hero and `WorkoutSessionCardView`/`WallTile` for the run sublabels.
enum FeedFmt {
    /// Strength volume → a grouped "1,250 kg" string (the bespoke volumeText that lived in FeedCardView).
    static func volume(_ kg: Double) -> String {
        let v = Int(kg.rounded())
        let f = NumberFormatter(); f.numberStyle = .decimal; f.maximumFractionDigits = 0
        return "\(f.string(from: NSNumber(value: v)) ?? "\(v)") kg"
    }

    /// A signed delta line, e.g. "▲ 4 vs last week" / "▼ 2 vs last".
    static func delta(_ d: Int, suffix: String) -> String {
        d >= 0 ? "▲ \(d) \(suffix)" : "▼ \(-d) \(suffix)"
    }

    /// The e2 sub: "grade · 88% HRR · Z5 · Max" — grade + optional %HRR + the peak zone's pill label.
    static func hardestEffortSub(_ p: HardestEffortPayload) -> String {
        var parts = [p.grade]
        if let hrr = p.peakHRRPercent { parts.append("\(hrr)% HRR") }
        let z = HeartRateZone(rawValue: p.zoneAtPeak) ?? .none
        if z != .none { parts.append(z.pillLabel) }
        return parts.joined(separator: " · ")
    }

    /// The e3 sub: "▼ 6 bpm vs first" / "flat over N sessions" — recent-avg-HR trend vs the first point.
    static func hrTrendSub(_ p: HRTrendPayload) -> String {
        guard let first = p.points.first?.avgBpm, let last = p.points.last?.avgBpm else { return "" }
        let d = last - first
        return d == 0 ? "flat over \(p.points.count) sessions"
            : (d < 0 ? "▼ \(-d) bpm vs first" : "▲ \(d) bpm vs first")
    }
}
