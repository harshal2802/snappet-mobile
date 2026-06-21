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
    /// The supporting stat lines (first = `primary`, rest = `secondary`).
    var lines: [String]
    /// The discipline accent (wayfinding) — `SnappetColor.kilter` / `.workout` / `.brand` etc.
    var accent: Color

    init(card: FeedCard) {
        switch card.payload {
        case .climbSession(let p):
            self = .init(kick: "Climb session", hero: p.hardestSendGrade ?? "—",
                         lines: ["\(p.totalClimbs) climbs", "\(p.sends) sends", "\(p.totalAttempts) tries"],
                         accent: SnappetColor.kilter)
        case .workoutSession(let p):
            self = .init(kick: "Workout", hero: p.distanceMeters != nil ? "Run" : "\(p.setCount) sets",
                         lines: ["\(p.exerciseCount) exercises", "\(p.setCount) sets"],
                         accent: SnappetColor.workout)
        case .gradePR(let p):
            self = .init(kick: "New hardest ever", hero: p.newGrade,
                         lines: [p.previousGrade.map { "up from \($0)" } ?? "your first peak", p.climbName],
                         accent: SnappetColor.brand)
        case .pyramid(let p):
            self = .init(kick: "Grade pyramid", hero: p.maxGrade ?? "—",
                         lines: ["\(p.totalSends) sends", "\(p.rows.count) grades"], accent: SnappetColor.kilter)
        case .streak(let p):
            // R7 parity: a record streak reflects the record in the kick + line (matches FeedCardView).
            self = .init(kick: p.isRecord ? "Longest streak ever" : "Streak", hero: "\(p.days)",
                         lines: p.isRecord && p.previousBest > 0
                             ? ["days in a row", "past best \(p.previousBest)"]
                             : ["days in a row"],
                         accent: SnappetColor.kilter)
        case .liftPR(let p):
            self = .init(kick: "Lift PR", hero: "\(Int(p.oneRepMaxKg.rounded())) \(p.unit)",
                         lines: [p.exerciseName, "est. 1RM"], accent: SnappetColor.brand)
        case .effort(let p):
            self = .init(kick: "Session effort", hero: "\(p.maxBpm)",
                         lines: ["peak BPM", "\(p.trimp) TRIMP"], accent: SnappetColor.performance(forZone: .max))
        case .hardestEffort(let p):
            self = .init(kick: "Hardest-effort send", hero: p.grade,
                         lines: ["\(p.peakBpm) bpm"], accent: SnappetColor.performance(forZone: .max))
        case .mostClimbs(let p):
            self = .init(kick: "Biggest session", hero: "\(p.count)",
                         lines: ["climbs in one go"], accent: SnappetColor.kilter)
        case .weeklyVolume(let p):
            self = .init(kick: "Weekly volume", hero: "\(p.buckets.last?.sends ?? 0)",
                         lines: ["sends this week"], accent: SnappetColor.kilter)
        case .hrTrend(let p):
            self = .init(kick: "HR trend", hero: "\(p.points.last?.avgBpm ?? 0)",
                         lines: ["recent avg BPM"], accent: SnappetColor.workout)
        case .onTheBoard(let p):
            self = .init(kick: "On the board", hero: "\(p.litCount)",
                         lines: ["climbs lit", p.hardestGrade.map { "hardest \($0)" } ?? p.gradeSpread],
                         accent: SnappetColor.kilter)
        case .pyramidHealth(let p):
            self = .init(kick: "Pyramid health", hero: p.consolidateGrade,
                         lines: ["consolidate this row", "\(p.rows.count) grades"], accent: SnappetColor.kilter)
        case .progression(let p):
            self = .init(kick: "Progression", hero: "\(p.fromGrade) → \(p.toGrade)",
                         lines: ["over \(p.points.count) months"], accent: SnappetColor.kilter)
        case .climbingLevel(let p):
            self = .init(kick: "Climbing level", hero: p.level,
                         lines: [p.maxGrade.map { "max \($0)" } ?? "working grade"], accent: SnappetColor.kilter)
        case .angleDist(let p):
            self = .init(kick: "Angles", hero: "\(p.topAngle)°",
                         lines: ["\(p.slices.count) angles"], accent: SnappetColor.kilter)
        case .periodVsLast(let p):
            self = .init(kick: "This period", hero: "\(p.current)",
                         lines: ["sends vs \(p.previous) last"], accent: SnappetColor.kilter)
        case .consistency(let p):
            self = .init(kick: "Consistency", hero: "\(p.activeDays)",
                         lines: ["active days"], accent: SnappetColor.kilter)
        case .onThisDay(let p):
            self = .init(kick: "On this day", hero: p.grade ?? "—",
                         lines: [p.summary], accent: SnappetColor.kilter)
        case .firstAtGrade(let p):
            self = .init(kick: "First at grade", hero: p.grade,
                         lines: [p.climbName], accent: SnappetColor.kilter)
        case .projectSent(let p):
            self = .init(kick: "Project sent", hero: p.grade,
                         lines: ["after \(p.sessions) sessions", p.climbName], accent: SnappetColor.brand)
        case .disciplineSplit(let p):
            self = .init(kick: "Discipline split", hero: p.topLabel,
                         lines: p.slices.prefix(3).map { "\($0.label): \($0.count)" }, accent: SnappetColor.workout)
        case .trendArrows(let p):
            self = .init(kick: "90-day trends",
                         hero: p.arrows.first.map { "\($0.improving ? "▲" : "▼")\(abs($0.deltaPct))%" } ?? "—",
                         lines: p.arrows.map(\.label), accent: SnappetColor.kilter)
        case .effortEfficiency(let p):
            self = .init(kick: "Fitness gain", hero: "\(p.newAvgBpm)",
                         lines: ["avg BPM at \(p.gradeBand)", "was \(p.oldAvgBpm)"], accent: SnappetColor.kilter)
        case .hrvRecovery(let p):
            self = .init(kick: "Recovery", hero: "\(p.rmssd)", lines: ["RMSSD", p.note], accent: SnappetColor.kilter)
        case .restNudge(let p):
            self = .init(kick: "Go gentler", hero: "\(p.hardDays)", lines: ["hard days", p.note], accent: SnappetColor.kilter)
        }
    }

    private init(kick: String, hero: String, lines: [String], accent: Color) {
        self.kick = kick; self.hero = hero; self.lines = lines; self.accent = accent
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

    private var spec: ShareCardSpec { ShareCardSpec(card: card) }
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

    private var spec: ShareCardSpec { ShareCardSpec(card: card) }

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
                            Text(spec.secondaryLines.joined(separator: " · "))
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

    private var spec: ShareCardSpec { ShareCardSpec(card: card) }

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
