import SwiftUI

// MARK: - Recap Feed — card views (F1)
//
// Renders a FeedCard on the Pulse Pro design system. a1/a2 session cards are rich (Pillar 1);
// the milestone/trend kinds (b1/b3/b5/c1/d1) render as compact cards now and are enriched by
// F5/F6 — never a blank/dead row. No HR/media/reactions/share here (F2/F3/F4).

/// F3b (R6): the session-media bundle a climb-session card needs to host its in-card carousel + feed
/// the fullscreen viewer. Threaded in from `FeedView` (the SwiftData edge) the same way R2 threads the
/// ranked clip — kept out of the keystone payload so the F0 ordering core stays untouched.
struct FeedCardMedia {
    var clips: [MediaInput]
    var hrSeries: [HRPoint]
    var maxHR: Double
    var nameFor: (String) -> String
    var clipContext: ClipExportCoordinator.Context?
}

struct FeedCardView: View {
    let card: FeedCard
    /// F3 (R2): true when this card is the scroll-center active player (single-active rule). The a1
    /// climb card uses it to animate its hero; every other card ignores it. Defaults false so all the
    /// existing call sites (CardDetailView, WallView, Story scenes) keep the still hero unchanged.
    var isCentral: Bool = false
    /// F3 (R2): the HighlightEngine-ranked top clip segment, computed lazily by `FeedView` ONLY for
    /// the active a1 card. `nil` → fall back to the cheap payload clip hint / still / generated hero.
    var rankedClip: FeedClipRef? = nil
    /// F3b (R6): the session's media (carousel) + the HR/name/export inputs the fullscreen viewer needs.
    /// Defaults empty so the milestone/detail/wall/story call sites render unchanged (no carousel).
    var media: FeedCardMedia? = nil

    var body: some View {
        switch card.payload {
        case .climbSession(let p):
            ClimbSessionCardView(payload: p, isCentral: isCentral, rankedClip: rankedClip,
                                 media: media, card: card)
        case .workoutSession(let p):
            WorkoutSessionCardView(payload: p)
        case .gradePR(let p):
            MilestoneCardView(accent: SnappetColor.brand, icon: "trophy.fill", kind: "Grade PR",
                              hero: p.newGrade, caption: p.previousGrade.map { "was \($0) · new hardest" } ?? "new hardest ever",
                              sub: p.climbName, identifier: "feed.card.b1GradePR")
        case .mostClimbs(let p):
            MilestoneCardView(accent: SnappetColor.kilter, icon: "flame.fill", kind: "Most climbs",
                              hero: "\(p.count)", caption: p.previousRecord.map { "beat \($0)" } ?? "session record",
                              sub: "in one session", identifier: "feed.card.b3MostClimbs")
        case .streak(let p):
            MilestoneCardView(accent: SnappetColor.kilter, icon: p.isRecord ? "crown.fill" : "calendar",
                              kind: p.isRecord ? "Longest streak ever" : "Streak",
                              hero: "\(p.days)", caption: "days in a row",
                              sub: p.isRecord
                                  ? (p.previousBest > 0 ? "past best \(p.previousBest) — go gentler" : "go gentler")
                                  : (p.weeks >= 1 ? "\(p.weeks) week\(p.weeks == 1 ? "" : "s") unbroken" : nil),
                              identifier: "feed.card.b5Streak")
        case .pyramid(let p):
            MilestoneCardView(accent: SnappetColor.kilter, icon: "triangle.fill", kind: "Grade pyramid",
                              hero: p.maxGrade ?? "—", caption: "\(p.totalSends) sends",
                              sub: "across \(p.rows.filter { $0.sends > 0 }.count) grades", identifier: "feed.card.c1Pyramid")
        case .weeklyVolume(let p):
            MilestoneCardView(accent: SnappetColor.kilter, icon: "chart.bar.fill", kind: "Weekly volume",
                              hero: "\(p.buckets.last?.sends ?? 0)", caption: "sends this week",
                              sub: p.deltaVsPrev >= 0 ? "▲ \(p.deltaVsPrev) vs last week" : "▼ \(-p.deltaVsPrev) vs last week",
                              identifier: "feed.card.d1WeeklyVolume")
        case .effort(let p):
            EffortCardView(payload: p)
        case .hardestEffort(let p):
            HardestEffortCardView(payload: p)
        case .hrTrend(let p):
            HRTrendCardView(payload: p)
        case .onTheBoard(let p):
            MilestoneCardView(accent: SnappetColor.kilter, icon: "square.grid.3x3.fill", kind: "On the board",
                              hero: "\(p.litCount)", caption: "climbs lit",
                              sub: p.gradeSpread.isEmpty ? "pulled up, not logged" : p.gradeSpread,
                              identifier: "feed.card.a3OnTheBoard")
        case .liftPR(let p):
            MilestoneCardView(accent: SnappetColor.brand, icon: "dumbbell.fill", kind: "Lift PR",
                              hero: "\(Int(p.oneRepMaxKg.rounded())) \(p.unit)", caption: "est. 1RM · \(p.exerciseName)",
                              sub: p.previousOneRepMaxKg.map { "was \(Int($0.rounded())) \(p.unit)" },
                              identifier: "feed.card.b4LiftPR")
        case .pyramidHealth(let p):
            MilestoneCardView(accent: SnappetColor.kilter, icon: "triangle.fill", kind: "Pyramid health",
                              hero: p.consolidateGrade, caption: "consolidate", sub: p.note, identifier: "feed.card.c2PyramidHealth")
        case .progression(let p):
            MilestoneCardView(accent: SnappetColor.kilter, icon: "chart.line.uptrend.xyaxis", kind: "Progression",
                              hero: "\(p.fromGrade) → \(p.toGrade)", caption: "over \(p.points.count) months", sub: nil,
                              identifier: "feed.card.c3Progression")
        case .climbingLevel(let p):
            MilestoneCardView(accent: SnappetColor.kilter, icon: "figure.climbing", kind: "Climbing level",
                              hero: p.level, caption: "working grade", sub: p.maxGrade.map { "max \($0)" },
                              identifier: "feed.card.c4ClimbingLevel")
        case .angleDist(let p):
            MilestoneCardView(accent: SnappetColor.kilter, icon: "ruler", kind: "Angles",
                              hero: "\(p.topAngle)°", caption: "most sends", sub: "\(p.slices.count) angles climbed",
                              identifier: "feed.card.c5AngleDist")
        case .periodVsLast(let p):
            MilestoneCardView(accent: SnappetColor.kilter, icon: "calendar", kind: "This month vs last",
                              hero: "\(p.current)", caption: "sends · \(p.currentLabel)",
                              sub: p.current >= p.previous ? "▲ \(p.current - p.previous) vs last" : "▼ \(p.previous - p.current) vs last",
                              identifier: "feed.card.d2PeriodVsLast")
        case .consistency(let p):
            MilestoneCardView(accent: SnappetColor.kilter, icon: "square.grid.3x3.fill", kind: "Consistency",
                              hero: "\(p.activeDays)", caption: "active days", sub: "in the last \(p.windowDays)",
                              identifier: "feed.card.consistencyMap")
        case .onThisDay(let p):
            MilestoneCardView(accent: SnappetColor.kilter, icon: "clock.arrow.circlepath", kind: "On this day",
                              hero: p.grade ?? "—", caption: "\(p.yearsAgo) yr ago", sub: p.summary,
                              identifier: "feed.card.onThisDay")
        case .firstAtGrade(let p):
            MilestoneCardView(accent: SnappetColor.kilter, icon: "star.fill", kind: "First at grade",
                              hero: p.grade, caption: "your first \(p.grade)", sub: p.climbName, identifier: "feed.card.b2FirstAtGrade")
        case .projectSent(let p):
            MilestoneCardView(accent: SnappetColor.brand, icon: "checkmark.seal.fill", kind: "Project sent",
                              hero: p.grade, caption: "after \(p.sessions) session\(p.sessions == 1 ? "" : "s")", sub: p.climbName,
                              identifier: "feed.card.g1ProjectSent")
        case .disciplineSplit(let p):
            MilestoneCardView(accent: SnappetColor.workout, icon: "chart.pie.fill", kind: "Discipline split",
                              hero: p.topLabel, caption: "most sessions",
                              sub: p.slices.prefix(3).map { "\($0.label) \($0.count)" }.joined(separator: " · "),
                              identifier: "feed.card.d3DisciplineSplit")
        case .trendArrows(let p):
            MilestoneCardView(accent: SnappetColor.kilter, icon: "arrow.up.arrow.down", kind: "90-day trends",
                              hero: p.arrows.first.map { "\($0.improving ? "▲" : "▼") \(abs($0.deltaPct))%" } ?? "—",
                              caption: p.arrows.first?.label ?? "trend",
                              sub: p.arrows.dropFirst().first.map { "\($0.label) \($0.improving ? "▲" : "▼")\(abs($0.deltaPct))%" },
                              identifier: "feed.card.d4TrendArrows")
        case .effortEfficiency(let p):
            MilestoneCardView(accent: SnappetColor.performance(forZone: .recovery), icon: "bolt.heart", kind: "Fitness gain",
                              hero: "\(p.newAvgBpm)", caption: "avg BPM sending \(p.gradeBand)",
                              sub: "was \(p.oldAvgBpm) — same grade, less effort", identifier: "feed.card.e4EffortEfficiency")
        case .hrvRecovery(let p):
            MilestoneCardView(accent: SnappetColor.performance(forZone: .recovery), icon: "heart.text.square", kind: "Recovery",
                              hero: "\(p.rmssd)", caption: "RMSSD", sub: p.note, identifier: "feed.card.e5HRVRecovery")
        case .restNudge(let p):
            MilestoneCardView(accent: SnappetColor.performance(forZone: .aerobic), icon: "leaf.fill", kind: "Go gentler",
                              hero: "\(p.hardDays)", caption: "hard days in a row", sub: p.note, identifier: "feed.card.restNudge")
        }
    }
}

// MARK: e1 — Session effort / zones

private struct EffortCardView: View {
    let payload: EffortPayload
    private var total: Double { max(1, payload.zones.reduce(0) { $0 + $1.seconds }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FeedCardHeader(title: payload.title ?? "Session effort", trailing: durationText(payload.durationSec),
                           badge: .init(icon: "bolt.heart.fill", text: "", tint: SnappetColor.performance(forZone: .threshold)))
            DisciplineHero(value: "\(payload.maxBpm)", caption: "Peak BPM",
                           sublabel: "avg \(payload.avgBpm) · TRIMP \(payload.trimp)",
                           accent: SnappetColor.performance(forZone: .threshold))
            GeometryReader { geo in
                HStack(spacing: 1.5) {
                    ForEach(payload.zones, id: \.zone) { slice in
                        Rectangle().fill(SnappetColor.performance(forZone: HeartRateZone(rawValue: slice.zone) ?? .none))
                            .frame(width: max(0, geo.size.width * (slice.seconds / total)))
                    }
                }
            }
            .frame(height: 14)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            HStack(spacing: 10) {
                ForEach(payload.zones.filter { $0.seconds > 0 }, id: \.zone) { slice in
                    HStack(spacing: 4) {
                        Circle().fill(SnappetColor.performance(forZone: HeartRateZone(rawValue: slice.zone) ?? .none)).frame(width: 7, height: 7)
                        Text("Z\(slice.zone)").font(.caption2.weight(.bold)).foregroundStyle(SnappetColor.textSecondary)
                    }
                }
            }
        }
        .feedCard(accent: SnappetColor.performance(forZone: .threshold))
        .accessibilityIdentifier("feed.card.e1Effort")
    }
}

// MARK: e2 — Hardest-effort send

private struct HardestEffortCardView: View {
    let payload: HardestEffortPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FeedCardHeader(title: "Hardest-effort send", trailing: nil,
                           badge: .init(icon: "flame.fill", text: payload.grade, tint: SnappetColor.performance(forZone: .max)))
            DisciplineHero(value: "\(payload.peakBpm)", caption: "Peak BPM on a send",
                           sublabel: subline, accent: SnappetColor.performance(forZone: .max))
            Text(payload.climbName).font(.footnote).foregroundStyle(SnappetColor.textSecondary).lineLimit(1)
        }
        .feedCard(accent: SnappetColor.performance(forZone: .max))
        .accessibilityIdentifier("feed.card.e2HardestEffort")
    }

    private var subline: String {
        var parts = [payload.grade]
        if let hrr = payload.peakHRRPercent { parts.append("\(hrr)% HRR") }
        let z = HeartRateZone(rawValue: payload.zoneAtPeak) ?? .none
        if z != .none { parts.append(z.pillLabel) }
        return parts.joined(separator: " · ")
    }
}

// MARK: e3 — Avg/peak HR trend

private struct HRTrendCardView: View {
    let payload: HRTrendPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FeedCardHeader(title: "HR trend", trailing: "\(payload.points.count) sessions",
                           badge: .init(icon: "chart.xyaxis.line", text: "", tint: SnappetColor.workout))
            DisciplineHero(value: "\(payload.points.last?.avgBpm ?? 0)", caption: "Recent avg BPM",
                           sublabel: subline, accent: SnappetColor.workout)
            sparkline
        }
        .feedCard(accent: SnappetColor.workout)
        .accessibilityIdentifier("feed.card.e3HRTrend")
    }

    private var subline: String {
        guard let first = payload.points.first?.avgBpm, let last = payload.points.last?.avgBpm else { return "" }
        let d = last - first
        return d == 0 ? "flat over \(payload.points.count) sessions"
            : (d < 0 ? "▼ \(-d) bpm vs first" : "▲ \(d) bpm vs first")
    }

    private var sparkline: some View {
        let avgs = payload.points.map { Double($0.avgBpm) }
        let lo = avgs.min() ?? 0, hi = avgs.max() ?? 1
        let range = max(1, hi - lo)
        return GeometryReader { geo in
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(avgs.enumerated()), id: \.offset) { _, v in
                    RoundedRectangle(cornerRadius: 2).fill(SnappetColor.workout.opacity(0.85))
                        .frame(height: 8 + (geo.size.height - 8) * ((v - lo) / range))
                }
            }
        }
        .frame(height: 34)
    }
}

// MARK: a1 — Climb session

private struct ClimbSessionCardView: View {
    let payload: ClimbSessionPayload
    /// F3 (R2): whether this is the scroll-center active card (single-active rule). Set by `FeedView`.
    var isCentral: Bool = false
    /// F3 (R2): the ranked top clip segment (active card only) — preferred over the cheap payload hint.
    var rankedClip: FeedClipRef? = nil
    /// F3b (R6): the session's media bundle (carousel + viewer inputs). `nil` → no carousel (the F3
    /// inline-player hero + the cheap "N clips · tap to view" affordance still render).
    var media: FeedCardMedia? = nil
    /// F3b (R6): the source card, threaded into the viewer's Share/Animate (`ShareComposerView`).
    let card: FeedCard

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The clip ref to consider for the hero: the ranked segment (active card) if present, else the
    /// cheap payload hint (earliest video by offset) carried on every a1 card.
    private var clipRef: FeedClipRef? {
        if let rankedClip { return rankedClip }
        if let assetId = payload.clipAssetId {
            return FeedClipRef(assetId: assetId,
                               offsetSec: payload.clipOffsetSec ?? 0,
                               durationSec: payload.clipDurationSec ?? 0)
        }
        return nil
    }

    /// The resolved hero tier (F3 fallback chain: clip → photo → generated). A clip animates ONLY
    /// when this card is central AND motion is allowed (not reduceMotion, not Low Power Mode); the
    /// `clipReady` seam is `hasHR` + a non-empty clip ref. No still photo tier wired here (the a1 card
    /// always has a generated `DisciplineHero` underneath), so non-clip resolves to `.generated`.
    private var heroTier: HeroTier {
        let clip = (payload.hasHR && clipRef != nil) ? clipRef : nil
        return FeedHeroResolver.resolveHero(
            clip: clip, photoAssetId: nil, isCentral: isCentral,
            reduceMotion: reduceMotion, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FeedCardHeader(title: payload.title ?? "Climb session",
                           trailing: durationText(payload.durationSec),
                           badge: payload.isPRSession ? .init(icon: "trophy.fill", text: "PR", tint: SnappetColor.brand) : nil)
            hero
            StatRibbon(items: [
                .init(text: "\(payload.totalClimbs) climbs"),
                .init(text: "\(payload.sends) sends", tint: SnappetColor.kilter, emphasized: true),
                .init(text: "\(payload.totalAttempts) tries")
            ])
            if let media, !media.clips.isEmpty {
                // F3b (R6): the in-card carousel of ALL the session's clips (still posters; dots/count/
                // peek/View-all). Tapping a page opens the paged fullscreen viewer with the editor HR
                // overlay; "View all" opens the grouped browser. The R2 inline hero above is untouched.
                FeedMediaCarousel(clips: media.clips, hrSeries: media.hrSeries, maxHR: media.maxHR,
                                  nameFor: media.nameFor, card: card, clipContext: media.clipContext)
            } else if payload.clipCount > 0 {
                // No threaded media (detail/wall/story call sites): the cheap F3 affordance — tap the
                // card → CardDetail → Media browser. The hero above auto-plays the top clip when central.
                Label("\(payload.clipCount) clip\(payload.clipCount == 1 ? "" : "s") · tap to view",
                      systemImage: "play.rectangle.fill")
                    .font(.caption2.weight(.semibold)).foregroundStyle(SnappetColor.kilter)
                    .accessibilityIdentifier("feed.card.clips")
            }
        }
        .feedCard(accent: SnappetColor.kilter)
        .accessibilityIdentifier("feed.card.a1Session")
    }

    /// The hero slot: the inline clip player overlaid on the generated `DisciplineHero` when central +
    /// clip-ready + motion allowed, else the still generated hero (F1's no-media hero). The generated
    /// hero stays underneath so a dropped/failed asset degrades to it with no dead surface.
    @ViewBuilder private var hero: some View {
        let generated = DisciplineHero(value: payload.hardestSendGrade ?? "—", caption: "Hardest send",
                                       sublabel: "Kilter · \(payload.angle)°", accent: SnappetColor.kilter)
        switch heroTier {
        case .clip(let ref):
            generated.overlay {
                FeedClipPlayer(clip: ref)
                    .clipShape(RoundedRectangle(cornerRadius: SnappetRadius.md, style: .continuous))
            }
        case .photo, .generated:
            generated
        }
    }
}

// MARK: a2 — Workout session (discipline-adaptive)

private struct WorkoutSessionCardView: View {
    let payload: WorkoutSessionPayload

    private var isRunning: Bool { payload.disciplineRaw == "running" || (payload.distanceMeters ?? 0) > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FeedCardHeader(title: payload.title, trailing: durationText(payload.durationSec), badge: nil)
            if isRunning, let meters = payload.distanceMeters {
                DisciplineHero(value: distanceText(meters), caption: "Distance",
                               sublabel: paceText(meters: meters, durationSec: payload.durationSec), accent: SnappetColor.workout)
                StatRibbon(items: [
                    .init(text: durationText(payload.durationSec)),
                    .init(text: "\(payload.setCount) splits", tint: SnappetColor.workout, emphasized: true)
                ])
            } else {
                DisciplineHero(value: volumeText(payload.totalVolume), caption: "Volume",
                               sublabel: "\(payload.exerciseCount) exercises", accent: SnappetColor.workout)
                StatRibbon(items: [
                    .init(text: "\(payload.exerciseCount) exercises"),
                    .init(text: "\(payload.setCount) sets", tint: SnappetColor.workout, emphasized: true),
                    .init(text: durationText(payload.durationSec))
                ])
            }
        }
        .feedCard(accent: SnappetColor.workout)
        .accessibilityIdentifier("feed.card.a2Session")
    }
}

// MARK: Compact milestone / trend card (enriched in F5/F6)

private struct MilestoneCardView: View {
    let accent: Color
    let icon: String
    let kind: String
    let hero: String
    let caption: String
    var sub: String? = nil
    let identifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FeedCardHeader(title: kind, trailing: nil, badge: .init(icon: icon, text: "", tint: accent))
            DisciplineHero(value: hero, caption: caption, sublabel: sub, accent: accent)
        }
        .feedCard(accent: accent)
        .accessibilityIdentifier(identifier)
    }
}

// MARK: Shared chrome

private struct FeedCardHeader: View {
    struct Badge { var icon: String; var text: String; var tint: Color }
    let title: String
    var trailing: String?
    var badge: Badge?

    var body: some View {
        HStack(spacing: 8) {
            if let badge {
                HStack(spacing: 4) {
                    Image(systemName: badge.icon).font(.caption2.weight(.bold))
                    if !badge.text.isEmpty { Text(badge.text).font(.caption2.weight(.heavy)) }
                }
                .foregroundStyle(badge.tint)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(badge.tint.opacity(0.16), in: Capsule())
            }
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(SnappetColor.ink).lineLimit(1)
            Spacer(minLength: 4)
            if let trailing {
                Text(trailing).font(.caption.weight(.semibold)).foregroundStyle(SnappetColor.textSecondary)
            }
        }
    }
}

private extension View {
    /// A Pulse-Pro card with a discipline edge accent on the leading edge.
    func feedCard(accent: Color) -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .snappetCard()
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(accent)
                    .frame(width: 4)
                    .padding(.vertical, 14)
            }
    }
}

// MARK: Formatting

private func durationText(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    let h = total / 3600, m = (total % 3600) / 60
    if h > 0 { return "\(h)h \(m)m" }
    if m > 0 { return "\(m)m" }
    return "\(total)s"
}

private func volumeText(_ kg: Double) -> String {
    let v = Int(kg.rounded())
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.maximumFractionDigits = 0
    return "\(f.string(from: NSNumber(value: v)) ?? "\(v)") kg"
}

private func distanceText(_ meters: Double) -> String {
    let km = meters / 1000
    return km >= 10 ? String(format: "%.0f km", km) : String(format: "%.2f km", km)
}

private func paceText(meters: Double, durationSec: Double) -> String {
    guard meters > 0, durationSec > 0 else { return "" }
    let secPerKm = durationSec / (meters / 1000)
    let m = Int(secPerKm) / 60, s = Int(secPerKm) % 60
    return String(format: "%d:%02d /km", m, s)
}
