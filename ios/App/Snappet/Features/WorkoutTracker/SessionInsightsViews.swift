import SwiftUI
import SwiftData
import Charts

/// The redesigned top of a session's detail (prompt 146, wireframe frames 1–5): where this session sits
/// in its series, what changed since last time, what it earned, and the routine's trend. Reads only the
/// pure `SessionInsights`. (Later, the progression/XP system plugs into this header.)
struct SessionInsightsHeader: View {
    let session: WorkoutSession
    /// Every session (for records across all history); the series is derived from it.
    let history: [WorkoutSession]
    let schedule: RoutineSchedule?
    let resolver: ExerciseResolver
    let unit: WeightUnit

    private var prior: [WorkoutSession] { SessionInsights.comparable(for: session, in: history) }
    private var kind: SessionInsights.Kind { SessionInsights.Kind.of(session) }

    var body: some View {
        let prior = prior
        let count = prior.count + 1
        VStack(alignment: .leading, spacing: 12) {
            Text("\(session.startedAt.formatted(.dateTime.weekday().month().day())) · \(max(1, Int(session.duration / 60))) min · \(SessionInsights.ordinal(count)) \(session.routineName)")
                .font(.footnote).foregroundStyle(.secondary)
                .accessibilityIdentifier("insights.subtitle")
            chips(prior: prior)
            heroGrid(prior: prior)
            let badges = SessionInsights.badges(session, prior: prior, allHistory: history,
                                                resolve: { resolver.name(for: $0.exerciseId, override: $0.displayName) },
                                                unit: unit)
            if !badges.isEmpty { badgeStrip(badges) }
            if let progress = SessionInsights.progress(session, prior: prior, unit: unit) { ProgressCard(progress: progress) }
            if count > 1 { milestoneCard(count: count) }
        }
    }

    // MARK: Chips

    @ViewBuilder private func chips(prior: [WorkoutSession]) -> some View {
        let streak = SessionInsights.weekStreak(session, prior: prior)
        let onPlan = SessionInsights.onPlan(session, schedule: schedule)
        if streak >= 2 || onPlan != nil || SessionInsights.avgHR(session) != nil {
            HStack(spacing: 6) {
                if streak >= 2 { chip("🔥 \(streak)-week streak", tint: SnappetColor.workout) }
                if let onPlan { chip(onPlan ? "✓ On plan" : "Extra session", tint: onPlan ? .green : .secondary) }
                if let hr = SessionInsights.avgHR(session) { chip("♥ \(Int(hr.rounded())) avg", tint: .secondary) }
            }
            .accessibilityIdentifier("insights.chips")
        }
    }

    private func chip(_ text: String, tint: Color) -> some View {
        Text(text).font(.caption.weight(.bold))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(tint.opacity(0.16), in: Capsule())
            .foregroundStyle(tint)
    }

    // MARK: Headline with change since last time

    private func heroGrid(prior: [WorkoutSession]) -> some View {
        let now = SessionInsights.headline(session, unit: unit)
        let last = prior.first.map { SessionInsights.headline($0, unit: unit) }
        return HStack(spacing: 8) {
            ForEach(Array(now.enumerated()), id: \.offset) { i, stat in
                let change = SessionInsights.change(stat, last: last.flatMap { i < $0.count ? $0[i] : nil }, kind: kind)
                VStack(spacing: 2) {
                    Text(stat.display).font(.title3.weight(.bold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.6)
                    Text(stat.label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    if let change {
                        Text(change.text).font(.caption2.weight(.heavy))
                            .foregroundStyle(change.direction == .better ? Color.green
                                             : change.direction == .worse ? Color.orange : Color.secondary)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    } else if prior.isEmpty {
                        Text("first one").font(.caption2.weight(.heavy)).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10).padding(.horizontal, 4)
                .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("insights.stat.\(i)")
            }
        }
    }

    // MARK: Badges

    private func badgeStrip(_ badges: [SessionInsights.Badge]) -> some View {
        BadgeStrip(badges: badges, unit: unit)
    }

    private func milestoneCard(count: Int) -> some View {
        let m = SessionInsights.nextMilestone(count: count)
        let span = Double(max(1, m.target - m.previous))
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Next milestone").font(.subheadline.weight(.bold))
                Spacer()
                Text("\(count) / \(m.target)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text("\(m.target) × \(session.routineName)").font(.caption).foregroundStyle(.secondary)
            ProgressView(value: Double(count - m.previous), total: span).tint(SnappetColor.workout)
        }
        .padding(12)
        .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("insights.milestone")
    }
}

/// One earned badge — a real record, first, streak or count.
struct BadgeCard: View {
    let badge: SessionInsights.Badge
    let unit: WeightUnit

    private var content: (icon: String, title: String, detail: String, tint: Color) {
        func w(_ kg: Double) -> String { "\(SetMeasure.formatWeight((WorkoutMath.kgToUnit(kg, unit) * 100).rounded() / 100)) \(unit.display)" }
        switch badge {
        case .firstOfSeries(let name): return ("sparkles", "First \(name)", "the start of the series", .blue)
        case .weightPR(let ex, let kg, let reps, let prev):
            return ("trophy.fill", "\(ex) PR", "\(w(kg)) × \(reps)" + (prev.map { " (was \(w($0)))" } ?? ""), SnappetColor.workout)
        case .repPR(let ex, let reps): return ("trophy.fill", "\(ex) rep PR", "\(reps) reps", SnappetColor.workout)
        case .bestVolume(let name): return ("chart.line.uptrend.xyaxis", "Best volume", "for \(name)", .green)
        case .heaviestLoad(let kg): return ("scalemass.fill", "Heaviest yet", "\(SessionInsights.signedLoad(kg)) kg added", SnappetColor.workout)
        case .peakForcePR(let kg): return ("bolt.fill", "Peak force PR", "\(SetMeasure.formatWeight((kg * 10).rounded() / 10)) kg", .green)
        case .firstSend(let grade): return ("party.popper.fill", "First \(grade) send", "a new grade", SnappetColor.workout)
        case .mostSends(let n): return ("chart.line.uptrend.xyaxis", "Most sends", "\(n) in a session", .green)
        case .fastestPace(let pace): return ("bolt.fill", "Fastest pace", pace, .green)
        case .longestDistance(let d): return ("figure.run", "Longest run", d, .green)
        case .sessionCount(let n, let name): return ("flag.checkered", "\(n) × \(name)", "milestone reached", .blue)
        case .weekStreak(let weeks): return ("flame.fill", "\(weeks)-week streak", "keep it going", .orange)
        }
    }

    var body: some View {
        let c = content
        VStack(alignment: .leading, spacing: 3) {
            Image(systemName: c.icon).font(.headline).foregroundStyle(c.tint)
            Text(c.title).font(.caption.weight(.heavy)).lineLimit(2, reservesSpace: true)
            Text(c.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 150, alignment: .leading)
        .padding(10)
        .background(c.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(c.tint.opacity(0.35)))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("badge")
    }
}

/// The routine's trend with today highlighted and best ever dashed (wireframe frame 1).
struct ProgressCard: View {
    let progress: SessionInsights.Progress

    var body: some View {
        let pts = progress.points
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Progress · \(progress.title)").font(.subheadline.weight(.bold))
                Spacer()
                Text("last \(pts.count)").font(.caption).foregroundStyle(.secondary)
            }
            Chart {
                ForEach(Array(pts.enumerated()), id: \.offset) { i, v in
                    LineMark(x: .value("Session", i), y: .value(progress.title, v))
                        .foregroundStyle(SnappetColor.workout)
                }
                RuleMark(y: .value("Best", progress.best))
                    .foregroundStyle(Color.green.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                if let last = pts.last {
                    PointMark(x: .value("Session", pts.count - 1), y: .value(progress.title, last))
                        .foregroundStyle(SnappetColor.workout).symbolSize(70)
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine()
                    AxisValueLabel { if let v = value.as(Double.self) { Text(progress.display(v)) } }
                }
            }
            .chartYScale(domain: .automatic(includesZero: false, reversed: progress.lowerIsBetter))
            .frame(height: 90)
            Text(summary).font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("insights.progress")
    }

    private var summary: String {
        guard let first = progress.points.first, let last = progress.points.last else { return "" }
        let isBest = last == progress.best
        let from = progress.display(first), to = progress.display(last)
        return "\(from) → \(to)" + (isBest ? " · today is your best" : " · best \(progress.display(progress.best))")
    }
}

/// Strength: each exercise compares itself with last time (wireframe frame 2).
struct ExerciseCompareCard: View {
    let row: SessionInsights.ExerciseCompare

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.name).font(.subheadline.weight(.bold)).lineLimit(1)
                Spacer()
                if let c = row.change {
                    Text(c.text).font(.caption.weight(.heavy))
                        .foregroundStyle(c.direction == .better ? Color.green : c.direction == .worse ? .orange : .secondary)
                }
            }
            Text(row.summary).font(.caption).foregroundStyle(.secondary)
            if row.trend.count >= 2 {
                Chart(Array(row.trend.enumerated()), id: \.offset) { i, v in
                    LineMark(x: .value("Session", i), y: .value("Top", v))
                        .foregroundStyle(SnappetColor.workout).interpolationMethod(.monotone)
                }
                .chartXAxis(.hidden).chartYAxis(.hidden)
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 30)
            }
            if row.setChanges.contains(where: { $0 != "=" && $0 != "new" }) {
                HStack(spacing: 6) {
                    ForEach(Array(row.setChanges.enumerated()), id: \.offset) { i, c in
                        Text("S\(i + 1) \(c)").font(.caption2.weight(.semibold).monospacedDigit())
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background((c.hasPrefix("+") ? Color.green : c.hasPrefix("−") ? Color.orange : Color.secondary).opacity(0.15),
                                        in: Capsule())
                    }
                }
            }
            if let nudge = row.nudge {
                Label(nudge, systemImage: "arrow.up.forward.circle").font(.caption).foregroundStyle(SnappetColor.workout)
            }
        }
        .padding(12)
        .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("insights.exercise")
    }
}

/// Hangboard: force per hang, set × rep, with fatigue (wireframe frame 3).
struct ForceGridCard: View {
    let grid: SessionInsights.ForceGrid
    let lastFatigue: Double?

    var body: some View {
        let all = grid.cells.flatMap { $0 }.compactMap { $0 }
        let lo = all.min() ?? 0, hi = all.max() ?? 1
        VStack(alignment: .leading, spacing: 8) {
            Text("Force per hang · peak kg").font(.subheadline.weight(.bold))
            Grid(horizontalSpacing: 5, verticalSpacing: 5) {
                GridRow {
                    Text("")
                    ForEach(0..<(grid.cells.first?.count ?? 0), id: \.self) { r in
                        Text("Rep \(r + 1)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                ForEach(Array(grid.cells.enumerated()), id: \.offset) { s, row in
                    GridRow {
                        Text("Set \(s + 1)").font(.caption2).foregroundStyle(.secondary)
                        ForEach(Array(row.enumerated()), id: \.offset) { _, v in
                            Text(v.map { SetMeasure.formatWeight(($0 * 10).rounded() / 10) } ?? "–")
                                .font(.caption.weight(.bold).monospacedDigit())
                                .frame(maxWidth: .infinity).padding(.vertical, 5)
                                .background(SnappetColor.workout.opacity(v.map { 0.2 + 0.6 * (hi > lo ? ($0 - lo) / (hi - lo) : 1) } ?? 0.05),
                                            in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }
            if let f = grid.fatigue {
                Text("Fatigue: \(Int((f * 100).rounded()))% from first to last set"
                     + (lastFatigue.map { " (last time \(Int(($0 * 100).rounded()))%)" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
        .accessibilityIdentifier("insights.forceGrid")
    }
}

/// Climbing: today's sends by grade against the last 30 days (wireframe frame 4).
struct PyramidCompareCard: View {
    let rows: [SessionInsights.PyramidRow]

    var body: some View {
        let top = Double(max(1, rows.map { max($0.today, $0.last30) }.max() ?? 1))
        VStack(alignment: .leading, spacing: 6) {
            Text("Grade pyramid · today vs last 30 days").font(.subheadline.weight(.bold))
            ForEach(rows, id: \.grade) { r in
                HStack(spacing: 8) {
                    Text(r.grade).font(.caption.weight(.bold).monospacedDigit()).frame(width: 34, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                                .frame(width: geo.size.width * Double(r.last30) / top)
                            RoundedRectangle(cornerRadius: 4).fill(SnappetColor.workout)
                                .frame(width: geo.size.width * Double(r.today) / top)
                        }
                    }
                    .frame(height: 12)
                    Text("\(r.today)" + (r.last30 > 0 ? " · 30d \(r.last30)" : "")).font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
                }
            }
        }
        .padding(12)
        .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
        .accessibilityIdentifier("insights.pyramid")
    }
}

/// "This session earned" — a horizontal strip of badges (session detail + the finish screen).
struct BadgeStrip: View {
    let badges: [SessionInsights.Badge]
    let unit: WeightUnit

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("THIS SESSION EARNED").font(.caption.weight(.heavy)).tracking(0.8).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(badges) { b in BadgeCard(badge: b, unit: unit) }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("insights.badges")
    }
}

/// The finish screen's badge strip (prompt 146): what this just-finished session earned against
/// history. Queries completed sessions itself so the player needn't thread history through.
struct SessionEarnedStrip: View {
    let session: WorkoutSession
    let resolver: ExerciseResolver
    let unit: WeightUnit
    @Query(filter: #Predicate<WorkoutSession> { $0.completedAt != nil }) private var completed: [WorkoutSession]

    var body: some View {
        let history = completed.filter { $0.id != session.id && !$0.isImportedFromHealth }
        let badges = SessionInsights.badges(session, prior: SessionInsights.comparable(for: session, in: history),
                                            allHistory: history,
                                            resolve: { resolver.name(for: $0.exerciseId, override: $0.displayName) },
                                            unit: unit)
        if !badges.isEmpty { BadgeStrip(badges: badges, unit: unit) }
    }
}
