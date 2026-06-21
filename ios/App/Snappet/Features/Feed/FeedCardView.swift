import SwiftUI

// MARK: - Recap Feed — card views (F1)
//
// Renders a FeedCard on the Pulse Pro design system. a1/a2 session cards are rich (Pillar 1);
// the milestone/trend kinds (b1/b3/b5/c1/d1) render as compact cards now and are enriched by
// F5/F6 — never a blank/dead row. No HR/media/reactions/share here (F2/F3/F4).

struct FeedCardView: View {
    let card: FeedCard

    var body: some View {
        switch card.payload {
        case .climbSession(let p):
            ClimbSessionCardView(payload: p)
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
            MilestoneCardView(accent: SnappetColor.kilter, icon: "calendar", kind: "Streak",
                              hero: "\(p.days)", caption: "days in a row",
                              sub: p.weeks >= 1 ? "\(p.weeks) week\(p.weeks == 1 ? "" : "s") unbroken" : nil,
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
        }
    }
}

// MARK: a1 — Climb session

private struct ClimbSessionCardView: View {
    let payload: ClimbSessionPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FeedCardHeader(title: payload.title ?? "Climb session",
                           trailing: durationText(payload.durationSec),
                           badge: payload.isPRSession ? .init(icon: "trophy.fill", text: "PR", tint: SnappetColor.brand) : nil)
            DisciplineHero(value: payload.hardestSendGrade ?? "—", caption: "Hardest send",
                           sublabel: "Kilter · \(payload.angle)°", accent: SnappetColor.kilter)
            StatRibbon(items: [
                .init(text: "\(payload.totalClimbs) climbs"),
                .init(text: "\(payload.sends) sends", tint: SnappetColor.kilter, emphasized: true),
                .init(text: "\(payload.totalAttempts) tries")
            ])
        }
        .feedCard(accent: SnappetColor.kilter)
        .accessibilityIdentifier("feed.card.a1Session")
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
