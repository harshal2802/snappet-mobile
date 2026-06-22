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

    /// The user's preferred weight unit → derived `DistanceUnit` (km/mi) so the run hero honors the user's
    /// choice (same `workoutlog.preferredUnit` the list/share/story read — one source of truth).
    @AppStorage("workoutlog.preferredUnit") private var preferredUnitRaw = WeightUnit.kg.rawValue
    private var distanceUnit: DistanceUnit { SessionRecap.distanceUnit(WeightUnit(rawValue: preferredUnitRaw) ?? .kg) }

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

    /// The compact display mapping for a tile — hero numeral + caption + sublabel + ≤2 ribbon chips. The
    /// kicker/hero/caption/icon/accent come from the ONE shared `FeedCardDisplay` descriptor (so the wall
    /// can't drift from the list/share/story); the wall keeps its DENSITY overrides — the lift hero splits
    /// the unit out of the numeral and shows a set-count, the badge maps from the kicker, and the ribbon
    /// chips stay payload-specific (sends+proj, ex count, climb name).
    private var spec: (hero: String, label: String, badge: String, icon: String,
                       accent: Color, ribbon: [RibbonItem]) {
        let d = card.display(unit: distanceUnit)
        let base = (hero: d.hero, label: d.heroCaption, badge: d.kicker, icon: d.iconName, accent: d.accent.color)
        switch card.payload {
        case .climbSession(let p):
            var ribbon: [RibbonItem] = [.init(text: "\(p.sends) sends", tint: SnappetColor.kilter, emphasized: true)]
            if p.projects > 0 { ribbon.append(.init(text: "\(p.projects) proj")) }
            return (base.hero, "hardest send", p.isPRSession ? "PR session" : "Climb", base.icon, base.accent, ribbon)
        case .workoutSession(let p):
            // Run hero = the descriptor's unit-aware distance (one SetMeasure funnel, no inline conversion).
            // Lift keeps the wall's denser set-count hero (a layout choice; list/share/story show volume).
            if p.distanceMeters != nil {
                return (base.hero, "distance", "Run", "figure.run", base.accent,
                        [.init(text: "\(p.exerciseCount) ex")])
            }
            return ("\(p.setCount)", "sets", "Lift", "dumbbell.fill", base.accent,
                    [.init(text: "\(p.exerciseCount) ex")])
        case .gradePR(let p):
            return (base.hero, "hardest ever", base.badge, base.icon, base.accent,
                    [.init(text: p.climbName, tint: SnappetColor.brand, emphasized: true)])
        case .liftPR(let p):
            // Wall density override: split the unit out of the hero numeral into the caption.
            return ("\(Int(p.oneRepMaxKg.rounded()))", "\(p.unit) 1RM", base.badge, base.icon, base.accent,
                    [.init(text: p.exerciseName, tint: SnappetColor.brand, emphasized: true)])
        case .onTheBoard(let p):
            var ribbon: [RibbonItem] = []
            if let g = p.hardestGrade { ribbon.append(.init(text: g, tint: SnappetColor.kilter, emphasized: true)) }
            return (base.hero, "lit", base.badge, base.icon, base.accent, ribbon)
        case .firstAtGrade(let p):
            return (base.hero, "first at grade", base.badge, base.icon, base.accent,
                    [.init(text: p.climbName)])
        case .projectSent(let p):
            return (base.hero, "project sent", base.badge, base.icon, base.accent,
                    [.init(text: p.climbName, tint: SnappetColor.brand, emphasized: true)])
        default:
            return (base.hero, base.label, "Recap", base.icon, base.accent, [])
        }
    }
}
