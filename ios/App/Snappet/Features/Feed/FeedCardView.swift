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
    /// F3b (R6): the session's media (carousel) + the HR/name/export inputs the fullscreen viewer needs.
    /// Defaults empty so the milestone/detail/wall/story call sites render unchanged (no carousel).
    var media: FeedCardMedia? = nil

    /// The user's preferred weight unit (kg/lb). The run hero's distance follows the derived
    /// `DistanceUnit` so the LIST honors the user's km/mi choice (one source of truth via `card.display`).
    @AppStorage("workoutlog.preferredUnit") private var preferredUnitRaw = WeightUnit.kg.rawValue
    private var distanceUnit: DistanceUnit { SessionRecap.distanceUnit(WeightUnit(rawValue: preferredUnitRaw) ?? .kg) }

    var body: some View {
        // The 5 rich/bespoke kinds keep dedicated views (carousel · zone bar · sparkline); every other
        // kind renders through the ONE shared `FeedCardDisplay` descriptor (no per-kind switch arm here).
        switch card.payload {
        case .climbSession(let p):
            ClimbSessionCardView(payload: p, media: media, card: card)
        case .workoutSession(let p):
            WorkoutSessionCardView(payload: p, distanceUnit: distanceUnit)
        case .effort(let p):
            EffortCardView(payload: p, card: card)
        case .hardestEffort(let p):
            HardestEffortCardView(payload: p, card: card)
        case .hrTrend(let p):
            HRTrendCardView(payload: p, card: card)
        default:
            MilestoneCardView(display: card.display(unit: distanceUnit), identifier: card.identifier)
        }
    }
}

// MARK: - Accent token → SnappetColor bridge (view layer)
//
// The pure `FeedAccent` (in FeedCardDisplay.swift) can't import `Color`; this is the single place that
// maps the platform-free token to a `SnappetColor`. `.effort`/`.recovery`/`.aerobic` route through the
// performance ramp (max → hard, recovery → fresh, aerobic → moderate).
extension FeedAccent {
    var color: Color {
        switch self {
        case .kilter:   return SnappetColor.kilter
        case .workout:  return SnappetColor.workout
        case .brand:    return SnappetColor.brand
        case .effort:   return SnappetColor.performance(forZone: .max)
        case .recovery: return SnappetColor.performance(forZone: .recovery)
        case .aerobic:  return SnappetColor.performance(forZone: .aerobic)
        }
    }
}

// MARK: e1 — Session effort / zones

private struct EffortCardView: View {
    let payload: EffortPayload
    /// The source card — the kicker/hero/caption/sub/accent come from the shared `FeedCardDisplay`; the
    /// zone bar + legend stay bespoke (the descriptor doesn't own layout).
    let card: FeedCard
    private var display: FeedCardDisplay { card.display() }
    private var total: Double { max(1, payload.zones.reduce(0) { $0 + $1.seconds }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FeedCardHeader(title: display.kicker, trailing: durationText(payload.durationSec),
                           badge: .init(icon: display.iconName, text: "", tint: display.accent.color))
            DisciplineHero(value: display.hero, caption: display.heroCaption,
                           sublabel: display.primaryLine, accent: display.accent.color)
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
        .feedCard(accent: display.accent.color)
        .accessibilityIdentifier("feed.card.e1Effort")
    }
}

// MARK: e2 — Hardest-effort send

private struct HardestEffortCardView: View {
    let payload: HardestEffortPayload
    /// The source card — kicker/hero/caption/sub/accent from the shared `FeedCardDisplay`; the grade
    /// badge + climb-name line stay bespoke (layout the descriptor doesn't own).
    let card: FeedCard
    private var display: FeedCardDisplay { card.display() }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FeedCardHeader(title: display.kicker, trailing: nil,
                           badge: .init(icon: display.iconName, text: payload.grade, tint: display.accent.color))
            DisciplineHero(value: display.hero, caption: display.heroCaption,
                           sublabel: display.primaryLine, accent: display.accent.color)
            Text(payload.climbName).font(.footnote).foregroundStyle(SnappetColor.textSecondary).lineLimit(1)
        }
        .feedCard(accent: display.accent.color)
        .accessibilityIdentifier("feed.card.e2HardestEffort")
    }
}

// MARK: e3 — Avg/peak HR trend

private struct HRTrendCardView: View {
    let payload: HRTrendPayload
    /// The source card — kicker/hero/caption/sub/accent from the shared `FeedCardDisplay`; the trailing
    /// session count + sparkline stay bespoke (layout the descriptor doesn't own).
    let card: FeedCard
    private var display: FeedCardDisplay { card.display() }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FeedCardHeader(title: display.kicker, trailing: "\(payload.points.count) sessions",
                           badge: .init(icon: display.iconName, text: "", tint: display.accent.color))
            DisciplineHero(value: display.hero, caption: display.heroCaption,
                           sublabel: display.primaryLine, accent: display.accent.color)
            sparkline
        }
        .feedCard(accent: display.accent.color)
        .accessibilityIdentifier("feed.card.e3HRTrend")
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
    /// F3b (R6): the session's media bundle (carousel + viewer inputs). `nil` → no carousel (the still
    /// `DisciplineHero` + the cheap "N clips · tap to view" affordance still render).
    var media: FeedCardMedia? = nil
    /// F3b (R6): the source card, threaded into the viewer's Share/Animate (`ShareComposerView`).
    let card: FeedCard

    private var display: FeedCardDisplay { card.display() }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FeedCardHeader(title: display.kicker,
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
                // overlay; "View all" opens the grouped browser. The carousel is the single media surface.
                FeedMediaCarousel(clips: media.clips, hrSeries: media.hrSeries, maxHR: media.maxHR,
                                  nameFor: media.nameFor, card: card, clipContext: media.clipContext)
            } else if payload.clipCount > 0 {
                // No threaded media (detail/wall/story call sites that don't thread media): the cheap
                // affordance — tap the card → CardDetail → Media browser.
                Label("\(payload.clipCount) clip\(payload.clipCount == 1 ? "" : "s") · tap to view",
                      systemImage: "play.rectangle.fill")
                    .font(.caption2.weight(.semibold)).foregroundStyle(SnappetColor.kilter)
                    .accessibilityIdentifier("feed.card.clips")
            }
        }
        .feedCard(accent: SnappetColor.kilter)
        .accessibilityIdentifier("feed.card.a1Session")
    }

    /// The still F1 hero: hardest-send grade + "Hardest send" (from the shared descriptor) + the
    /// a1-specific "Kilter · <angle>°" sublabel (board angle is layout the share/story/wall never show, so
    /// it stays inline, not in the descriptor). The carousel (when media is threaded) sits below it as the
    /// single in-card media surface.
    @ViewBuilder private var hero: some View {
        DisciplineHero(value: display.hero, caption: display.heroCaption,
                       sublabel: "Kilter · \(payload.angle)°", accent: display.accent.color)
    }
}

// MARK: a2 — Workout session (discipline-adaptive)

private struct WorkoutSessionCardView: View {
    let payload: WorkoutSessionPayload
    /// The user's derived `DistanceUnit` (km/mi) — threaded from `FeedCardView` so the run hero (and the
    /// derived pace sublabel) honor the user's choice. Defaults to km for direct previews/wall/detail.
    var distanceUnit: DistanceUnit = .km
    /// This view receives only the payload (not a FeedCard), so build the descriptor directly from the
    /// payload — the ONE shared mapping owns the hero/caption/accent.
    private var display: FeedCardDisplay {
        FeedCardDisplay(payload: .workoutSession(payload), kind: .a2Session, distanceUnit: distanceUnit)
    }

    private var isRunning: Bool { payload.disciplineRaw == "running" || (payload.distanceMeters ?? 0) > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FeedCardHeader(title: display.kicker, trailing: durationText(payload.durationSec), badge: nil)
            if isRunning, let meters = payload.distanceMeters {
                DisciplineHero(value: display.hero, caption: display.heroCaption,
                               sublabel: paceSublabel(meters: meters, durationSec: payload.durationSec),
                               accent: display.accent.color)
                StatRibbon(items: [
                    .init(text: durationText(payload.durationSec)),
                    .init(text: "\(payload.setCount) splits", tint: SnappetColor.workout, emphasized: true)
                ])
            } else {
                DisciplineHero(value: display.hero, caption: display.heroCaption,
                               sublabel: "\(payload.exerciseCount) exercises", accent: display.accent.color)
                StatRibbon(items: [
                    .init(text: "\(payload.exerciseCount) exercises"),
                    .init(text: "\(payload.setCount) sets", tint: SnappetColor.workout, emphasized: true),
                    .init(text: durationText(payload.durationSec))
                ])
            }
        }
        .feedCard(accent: display.accent.color)
        .accessibilityIdentifier("feed.card.a2Session")
    }

    /// The run hero's pace sublabel — unit-aware, routed through the one `SetMeasure.formatPace` funnel
    /// (replacing the bespoke km-only `paceText`). Empty when distance/duration are missing.
    private func paceSublabel(meters: Double, durationSec: Double) -> String {
        guard meters > 0, durationSec > 0 else { return "" }
        return SetMeasure.formatPace(secPerKm: durationSec / (meters / 1000), unit: distanceUnit)
    }
}

// MARK: Compact milestone / trend card (enriched in F5/F6)

private struct MilestoneCardView: View {
    /// The fully-resolved display from the ONE shared `FeedCardDisplay` descriptor — no per-kind switch.
    let display: FeedCardDisplay
    let identifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FeedCardHeader(title: display.kicker, trailing: nil,
                           badge: .init(icon: display.iconName, text: "", tint: display.accent.color))
            DisciplineHero(value: display.hero, caption: display.heroCaption,
                           sublabel: display.primaryLine, accent: display.accent.color)
        }
        .feedCard(accent: display.accent.color)
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

// `volumeText`/`distanceText`/`paceText` were retired: volume now lives in `FeedFmt.volume`, and
// distance/pace route through the unit-aware `SetMeasure.formatDistance`/`formatPace` (one source of truth).
