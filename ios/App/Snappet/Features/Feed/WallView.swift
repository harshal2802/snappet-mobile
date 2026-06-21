import SwiftUI

// MARK: - Recap Feed — the send wall (F7)
//
// A Pinterest-masonry layout over the SAME composed + lens-filtered corpus FeedView renders —
// identity-at-a-glance. The wall does NOT re-derive: it consumes the already-composed, lens-filtered,
// keyset-windowed `[FeedCard]` passed in by FeedView (one composition, two layouts — the keystone).
// Each tile is a compact Pulse-Pro card that taps through to the same CardDetailView the list uses.
//
// Rendered INLINE inside FeedView's NavigationStack (no NavigationStack / sheet of its own): FeedView's
// `.navigationDestination(for: FeedCard.self)` resolves each tile's NavigationLink to CardDetailView.
//
// CRITICAL: WallView is hosted INSIDE FeedView's outer `ScrollView`, so it must NOT introduce its own
// vertical `ScrollView` (a scroll-in-a-scroll collapses to ~zero height) NOR a layout-driving
// `GeometryReader` as a container. It reads the available width purely as a MEASUREMENT (width-only
// `.onGeometryChange`) and renders the masonry columns DIRECTLY into the outer scroll, which drives all
// scrolling. The wall fills width and grows vertically inside the feed's own scroll.

struct WallView: View {
    /// The already-composed + lens-filtered + keyset-windowed corpus from FeedView (no re-derivation).
    let cards: [FeedCard]
    /// Advance FeedView's `visibleCount` (keyset pagination) — fired from each rendered tile's
    /// `.onAppear`, exactly like the list's per-card `loadMoreIfNeeded`. The wall paginates the same keyset.
    let loadMore: (FeedCard) -> Void

    /// The visual-tile subset of the passed-in corpus (NOT a re-derive / NOT FeedQuery): only the kinds
    /// `WallTile` renders meaningfully (session / PR / board / first-at-grade / project-sent). Bland text
    /// insight cards are dropped so the wall is a real visual send-wall. Pagination still advances over the
    /// full window — `loadMore` fires from the rendered tiles, which is enough to walk the whole keyset.
    private static let tileKinds: Set<FeedCardKind> = [
        .a1Session, .a2Session, .b1GradePR, .b4LiftPR, .a3OnTheBoard, .b2FirstAtGrade, .g1ProjectSent]

    /// Available width, read as a pure measurement (not a layout-driving container).
    @State private var width: CGFloat = 0

    var body: some View {
        let tiles = cards.filter { Self.tileKinds.contains($0.kind) }
        if tiles.isEmpty {
            ContentUnavailableView("No sends yet", systemImage: "square.grid.3x3",
                                   description: Text("Log a climb or workout to fill your wall."))
                .accessibilityIdentifier("feed.wall.empty")
        } else {
            // Pure FeedWallLayout: balanced shortest-column masonry, 2–3 columns by width.
            let columns = FeedWallLayout.distribute(
                tiles, columns: FeedWallLayout.columnCount(forWidth: Double(width)))
            HStack(alignment: .top, spacing: 8) {
                ForEach(columns.indices, id: \.self) { ci in
                    LazyVStack(spacing: 8) {
                        ForEach(columns[ci]) { card in
                            NavigationLink(value: card) { WallTile(card: card) }
                                .buttonStyle(.plain)
                                .accessibilityElement(children: .combine)
                                // Keyset pagination: advance FeedView's window as tiles scroll in.
                                .onAppear { loadMore(card) }
                        }
                    }
                }
            }
            .padding(SnappetSpacing.lg)
            // Width-only measurement: feeds the masonry column count without driving layout/containing.
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .accessibilityIdentifier("feed.wall")
        }
    }
}

/// A compact Pulse-Pro tile: `DisciplineHero` + a trimmed `StatRibbon` on `.snappetCard()` with a
/// discipline edge-accent. Reads the card payload via the same display mapping the list cards use; a
/// card with no media simply shows the generated hero (degrade-by-absence — never an empty tile).
private struct WallTile: View {
    let card: FeedCard

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisciplineHero(value: spec.hero, caption: spec.badge,
                           sublabel: spec.label, systemImage: spec.icon, accent: spec.accent)
            if !spec.ribbon.isEmpty {
                StatRibbon(items: spec.ribbon)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .snappetCard()
        // Discipline edge-accent (wayfinding) — a tinted hairline on the discipline color.
        .overlay(
            RoundedRectangle(cornerRadius: SnappetRadius.md, style: .continuous)
                .strokeBorder(spec.accent.opacity(0.4), lineWidth: 1))
    }

    private typealias RibbonItem = StatRibbon.Item

    /// The compact display mapping for a tile — hero numeral + caption + sublabel + ≤2 ribbon chips,
    /// tinted on the discipline accent. Mirrors FeedCardView's accent/figure vocabulary in a denser form.
    private var spec: (hero: String, label: String, badge: String, icon: String,
                       accent: Color, ribbon: [RibbonItem]) {
        switch card.payload {
        case .climbSession(let p):
            let badge = p.isPRSession ? "PR session" : "Climb"
            var ribbon: [RibbonItem] = [.init(text: "\(p.sends) sends", tint: SnappetColor.kilter, emphasized: true)]
            if p.projects > 0 { ribbon.append(.init(text: "\(p.projects) proj")) }
            return (p.hardestSendGrade ?? "—", "hardest send", badge, "figure.climbing",
                    SnappetColor.kilter, ribbon)
        case .workoutSession(let p):
            if let m = p.distanceMeters {
                return (String(format: "%.1fk", m / 1000), "distance", "Run", "figure.run",
                        SnappetColor.workout, [.init(text: "\(p.exerciseCount) ex")])
            }
            return ("\(p.setCount)", "sets", "Lift", "dumbbell.fill", SnappetColor.workout,
                    [.init(text: "\(p.exerciseCount) ex")])
        case .gradePR(let p):
            return (p.newGrade, "hardest ever", "Grade PR", "trophy.fill", SnappetColor.brand,
                    [.init(text: p.climbName, tint: SnappetColor.brand, emphasized: true)])
        case .liftPR(let p):
            return ("\(Int(p.oneRepMaxKg.rounded()))", "\(p.unit) 1RM", "Lift PR", "trophy.fill",
                    SnappetColor.brand, [.init(text: p.exerciseName, tint: SnappetColor.brand, emphasized: true)])
        case .onTheBoard(let p):
            var ribbon: [RibbonItem] = []
            if let g = p.hardestGrade { ribbon.append(.init(text: g, tint: SnappetColor.kilter, emphasized: true)) }
            return ("\(p.litCount)", "lit", "On the board", "square.grid.3x3.fill",
                    SnappetColor.kilter, ribbon)
        case .firstAtGrade(let p):
            return (p.grade, "first at grade", "First", "star.fill", SnappetColor.kilter,
                    [.init(text: p.climbName)])
        case .projectSent(let p):
            return (p.grade, "project sent", "Sent", "checkmark.seal.fill", SnappetColor.brand,
                    [.init(text: p.climbName, tint: SnappetColor.brand, emphasized: true)])
        default:
            return ("—", "", "Recap", "sparkles", SnappetColor.kilter, [])
        }
    }
}
