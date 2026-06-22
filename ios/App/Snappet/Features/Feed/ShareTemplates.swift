import SwiftUI

// MARK: - Recap Feed — bespoke share templates (F4 / R5)
//
// The three named templates beyond Send Card + Receipt (which live inline in `FeedShareComposer`):
//   • GradePRTicketTemplate — a "ticket" treatment of a grade PR (new grade hero + "up from X").
//   • BoardPolaroidTemplate — a polaroid-framed climb/board moment (grade + sends / angle).
//   • PyramidCardTemplate   — the grade pyramid drawn from the payload's per-grade counts.
//
// All three render over `PulsePro` (`DisciplineHero` / `StatRibbon` / `pulseGlassChrome`) + `.snappetCard()`
// + `SnappetColor` discipline accents — NO new brand tokens. Each is parameterized by the `FeedCard` (read
// through the shared `ShareCardSpec` so there is ONE card→display mapping) and a `visibleMetrics` set so
// the live preview and the exported image stay WYSIWYG (preview view == exported view).

// MARK: - Shared card → display mapping (single source of truth)

/// The display fields the share templates render, derived from a `FeedCard`'s already-computed payload
/// (derive-on-read discipline — the composer NEVER re-derives stats, it only formats card numbers).
///
/// This is the single card→display mapping reused by `ShareCardView` (Send Card / Receipt) AND the three
/// bespoke templates below, so there is exactly one place that turns a payload into kicker / hero / lines.
struct ShareCardSpec {
    /// The small uppercased kicker line ("Climb session", "New hardest ever", …).
    var kick: String
    /// The big hero number / grade.
    var hero: String
    /// The hero's caption ("climbs lit", "working grade", "over N months"). The share path falls back to
    /// this when a card's `primaryLine`/`secondaryLines` are thin, so the descriptor moving the lead fact
    /// into `heroCaption` doesn't drop it from the export (the list/story already render the caption).
    var heroCaption: String
    /// The supporting stat lines (first = `primary`, rest = `secondary`).
    var lines: [String]
    /// The discipline accent (wayfinding) — `SnappetColor.kilter` / `.workout` / `.brand` etc.
    var accent: Color

    /// A thin SwiftUI adapter over the ONE pure `FeedCardDisplay` descriptor — `ShareCardSpec` no longer
    /// owns the card→display mapping (it used to carry a parallel switch that drifted from the list/story/
    /// wall, D1–D25). `kick`/`hero`/`lines` come straight from the descriptor; `accent` is the bridged
    /// token. `unit` (default `.km`) follows the user's km/mi choice for the run hero, threaded from
    /// `ShareComposerView`.
    init(card: FeedCard, unit: DistanceUnit = .km) {
        let d = card.display(unit: unit)
        self.kick = d.kicker
        self.hero = d.hero
        self.heroCaption = d.heroCaption
        self.lines = d.lines          // [primaryLine] + secondaryLines, compacted
        self.accent = d.accent.color
    }

    /// The `primary` supporting line (first), gated by visibility.
    var primaryLine: String? { lines.first }
    /// The `secondary` supporting lines (the rest), gated by visibility.
    var secondaryLines: [String] { Array(lines.dropFirst()) }
}

// MARK: - Grade PR Ticket

/// A "ticket" treatment of a grade PR: a torn-ticket card with the new grade as the hero numeral and an
/// "up from X" stub. Falls back to the shared spec for non-PR payloads (gating keeps it to `.gradePR`).
struct GradePRTicketTemplate: View {
    let card: FeedCard
    var visibleMetrics: Set<ShareMetric>
    /// The user's km/mi choice, threaded from `ShareComposerView` (defaults `.km` for previews/tests).
    var unit: DistanceUnit = .km

    private var spec: ShareCardSpec { ShareCardSpec(card: card, unit: unit) }
    private var upFrom: String? {
        if case .gradePR(let p) = card.payload { return p.previousGrade.map { "up from \($0)" } ?? "your first peak" }
        return spec.primaryLine
    }
    private var climbName: String? {
        if case .gradePR(let p) = card.payload { return p.climbName.isEmpty ? nil : p.climbName }
        return nil
    }

    var body: some View {
        ShareTemplateCanvas(accent: spec.accent) {
            VStack(alignment: .leading, spacing: 14) {
                if visibleMetrics.contains(.subtitle) {
                    HStack(spacing: 6) {
                        Image(systemName: "ticket.fill").font(.caption.weight(.bold))
                        Text(spec.kick.uppercased()).font(.caption.weight(.heavy)).tracking(1.4)
                    }
                    .foregroundStyle(spec.accent)
                }

                if visibleMetrics.contains(.headline) {
                    DisciplineHero(value: spec.hero, caption: "New grade",
                                   sublabel: visibleMetrics.contains(.primary) ? upFrom : nil,
                                   systemImage: "trophy.fill", accent: spec.accent)
                }

                // The torn-ticket perforation: a dashed rule separating hero from the stub.
                Rectangle().fill(SnappetColor.hairline)
                    .frame(height: 1)
                    .overlay(
                        Rectangle().stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .foregroundStyle(SnappetColor.hairline)
                    )
                    .padding(.vertical, 2)

                if visibleMetrics.contains(.secondary), let climbName {
                    StatRibbon(items: [
                        .init(text: climbName, tint: spec.accent, emphasized: true, systemImage: "figure.climbing")
                    ])
                }

                Spacer(minLength: 0)
                ShareBrandingFooter(show: visibleMetrics.contains(.branding))
            }
        }
    }
}

// MARK: - Board Polaroid

/// A polaroid-framed climb/board moment: a white polaroid mat with the grade hero on a discipline-tinted
/// "photo" and a hand-written-feeling caption strip (sends / angle / lit count) along the bottom.
struct BoardPolaroidTemplate: View {
    let card: FeedCard
    var visibleMetrics: Set<ShareMetric>
    /// The user's km/mi choice, threaded from `ShareComposerView` (defaults `.km` for previews/tests).
    var unit: DistanceUnit = .km

    private var spec: ShareCardSpec { ShareCardSpec(card: card, unit: unit) }

    var body: some View {
        ShareTemplateCanvas(accent: spec.accent) {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                // The polaroid: a white mat (thick bottom border) around the tinted "photo".
                VStack(spacing: 0) {
                    // The "photo": discipline gradient + the grade hero.
                    ZStack {
                        LinearGradient(colors: [spec.accent.opacity(0.95), spec.accent.opacity(0.55)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                        VStack(spacing: 6) {
                            if visibleMetrics.contains(.subtitle) {
                                Text(spec.kick.uppercased()).font(.caption.weight(.heavy)).tracking(1.4)
                                    .foregroundStyle(.white.opacity(0.9))
                            }
                            if visibleMetrics.contains(.headline) {
                                Text(spec.hero).font(.system(size: 60, weight: .heavy, design: .rounded))
                                    .foregroundStyle(.white).minimumScaleFactor(0.4).lineLimit(1)
                            }
                            if visibleMetrics.contains(.primary), let primary = spec.primaryLine {
                                Text(primary).font(.headline).foregroundStyle(.white.opacity(0.92))
                            }
                        }
                        .padding(18)
                    }
                    .aspectRatio(1, contentMode: .fit)

                    // The polaroid caption strip (the thick white mat bottom).
                    HStack {
                        if visibleMetrics.contains(.secondary) {
                            // Fall back to the hero caption when a card has no secondary lines (the descriptor
                            // moved the lead fact, e.g. "climbs lit", into heroCaption) so the mat is never blank.
                            Text(spec.secondaryLines.isEmpty ? spec.heroCaption : spec.secondaryLines.joined(separator: " · "))
                                .font(.subheadline.weight(.semibold)).foregroundStyle(SnappetColor.ink)
                                .lineLimit(1).minimumScaleFactor(0.6)
                        } else {
                            Text(spec.kick).font(.subheadline.weight(.semibold)).foregroundStyle(SnappetColor.ink)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "camera.fill").font(.caption).foregroundStyle(spec.accent)
                    }
                    .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 22)
                    .frame(maxWidth: .infinity)
                    .background(Color.white)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 18, y: 10)
                .rotationEffect(.degrees(-2))

                Spacer(minLength: 0)
                ShareBrandingFooter(show: visibleMetrics.contains(.branding))
            }
        }
    }
}

// MARK: - Pyramid Card

/// The grade pyramid drawn from the payload's per-grade `sends` counts: a stack of horizontal bars, one
/// per grade row (widest = most sends), tinted by the discipline accent. Reads `.pyramid` / `.pyramidHealth`.
struct PyramidCardTemplate: View {
    let card: FeedCard
    var visibleMetrics: Set<ShareMetric>
    /// The user's km/mi choice, threaded from `ShareComposerView` (defaults `.km` for previews/tests).
    var unit: DistanceUnit = .km

    private var spec: ShareCardSpec { ShareCardSpec(card: card, unit: unit) }

    /// The per-grade rows (descending difficulty → narrow top, wide base), from whichever payload carries them.
    private var rows: [PyramidRow] {
        let raw: [PyramidRow]
        switch card.payload {
        case .pyramid(let p):       raw = p.rows
        case .pyramidHealth(let p): raw = p.rows
        default:                    raw = []
        }
        return raw.sorted { $0.difficulty > $1.difficulty }
    }
    private var maxSends: Int { max(rows.map(\.sends).max() ?? 1, 1) }

    var body: some View {
        ShareTemplateCanvas(accent: spec.accent) {
            VStack(alignment: .leading, spacing: 14) {
                if visibleMetrics.contains(.subtitle) {
                    HStack(spacing: 6) {
                        Image(systemName: "triangle.fill").font(.caption.weight(.bold))
                        Text(spec.kick.uppercased()).font(.caption.weight(.heavy)).tracking(1.4)
                    }
                    .foregroundStyle(spec.accent)
                }
                if visibleMetrics.contains(.headline) {
                    DisciplineHero(value: spec.hero, caption: "Top grade",
                                   sublabel: visibleMetrics.contains(.primary) ? spec.primaryLine : nil,
                                   systemImage: "triangle", accent: spec.accent)
                }

                if visibleMetrics.contains(.secondary) {
                    VStack(alignment: .leading, spacing: 6) {
                        if rows.isEmpty {
                            Text("No graded sends yet").font(.footnote).foregroundStyle(SnappetColor.textSecondary)
                        } else {
                            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                                PyramidBar(grade: row.grade, sends: row.sends, maxSends: maxSends, accent: spec.accent)
                            }
                        }
                    }
                }

                Spacer(minLength: 0)
                ShareBrandingFooter(show: visibleMetrics.contains(.branding))
            }
        }
    }
}

/// One horizontal pyramid bar: grade label + a discipline-tinted bar whose width ∝ sends, with the count.
private struct PyramidBar: View {
    let grade: String
    let sends: Int
    let maxSends: Int
    let accent: Color

    var body: some View {
        HStack(spacing: 8) {
            Text(grade).font(.caption.weight(.bold)).monospacedDigit()
                .foregroundStyle(SnappetColor.ink).frame(width: 38, alignment: .leading)
            GeometryReader { geo in
                let frac = max(0.06, CGFloat(sends) / CGFloat(maxSends))
                ZStack(alignment: .leading) {
                    Capsule().fill(SnappetColor.surfaceMuted)
                    Capsule().fill(accent.opacity(0.85)).frame(width: geo.size.width * frac)
                }
            }
            .frame(height: 16)
            Text("\(sends)").font(.caption2.weight(.bold)).monospacedDigit()
                .foregroundStyle(SnappetColor.textSecondary).frame(width: 26, alignment: .trailing)
        }
    }
}

// MARK: - Shared chrome for the bespoke templates

/// The common export canvas: a discipline-tinted backdrop with a `.snappetCard()` content surface inside,
/// filling the frame the renderer lays out (WYSIWYG — the same view previews and exports). No new tokens.
private struct ShareTemplateCanvas<Content: View>: View {
    let accent: Color
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            // A soft discipline backdrop so the card reads as "Snappet" even when matted (polaroid) etc.
            RadialGradient(colors: [accent.opacity(0.30), SnappetColor.paper], center: .top,
                           startRadius: 0, endRadius: 520)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(18)
                .snappetCard(cornerRadius: SnappetRadius.lg)
                .overlay(alignment: .leading) {
                    // Discipline edge accent (wayfinding) along the leading edge.
                    Rectangle().fill(accent).frame(width: 5)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The "snappet · recap" footer, gated by the `branding` metric.
private struct ShareBrandingFooter: View {
    let show: Bool
    var body: some View {
        if show {
            Text("snappet · recap").font(.caption.weight(.bold)).foregroundStyle(SnappetColor.textSecondary)
        }
    }
}
