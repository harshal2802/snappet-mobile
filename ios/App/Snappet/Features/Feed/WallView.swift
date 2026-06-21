import SwiftUI
import SwiftData

// MARK: - Recap Feed — the send wall (F7)
//
// A masonry-ish grid over the same composed corpus — identity-at-a-glance. Each tile taps through to
// the same CardDetailView the feed uses. Reuses the F0 composer (no new math, no card persistence).

struct WallView: View {
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \KilterSession.startedAt, order: .reverse) private var kilterSessions: [KilterSession]
    @Query private var kilterLogs: [KilterLogEntry]
    @Query(sort: \WorkoutSession.startedAt, order: .reverse) private var workoutSessions: [WorkoutSession]
    @Query private var litEvents: [KilterLitEvent]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)
    private let tileKinds: Set<FeedCardKind> = [.a1Session, .a2Session, .b1GradePR, .b4LiftPR, .a3OnTheBoard]

    private var tiles: [FeedCard] {
        FeedQuery.cards(kilterSessions: kilterSessions, kilterLogs: kilterLogs,
                        workoutSessions: workoutSessions, litEvents: litEvents, now: .now)
            .filter { tileKinds.contains($0.kind) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if tiles.isEmpty {
                    ContentUnavailableView("No sends yet", systemImage: "square.grid.3x3",
                                           description: Text("Log a climb or workout to fill your wall."))
                        .padding(.top, 60)
                } else {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(tiles) { card in
                            NavigationLink(value: card) { WallTile(card: card) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(SnappetSpacing.lg)
                }
            }
            .background(SnappetColor.paper)
            .navigationTitle("Send wall")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: FeedCard.self) { CardDetailView(card: $0) }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .accessibilityIdentifier("feed.wall")
    }
}

private struct WallTile: View {
    let card: FeedCard

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(spec.badge).font(.caption2.weight(.heavy)).foregroundStyle(spec.accent).lineLimit(1)
            Spacer(minLength: 8)
            Text(spec.hero).font(.title3.weight(.bold)).foregroundStyle(SnappetColor.ink)
                .lineLimit(1).minimumScaleFactor(0.5)
            Text(spec.label).font(.caption2).foregroundStyle(SnappetColor.textSecondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
        .padding(10)
        .background(SnappetColor.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(spec.accent.opacity(0.4), lineWidth: 1))
    }

    private var spec: (hero: String, label: String, badge: String, accent: Color) {
        switch card.payload {
        case .climbSession(let p):
            return (p.hardestSendGrade ?? "—", "\(p.sends) sends", p.isPRSession ? "PR" : "Climb", SnappetColor.kilter)
        case .workoutSession(let p):
            if let m = p.distanceMeters { return (String(format: "%.1fk", m / 1000), "run", "Run", SnappetColor.workout) }
            return ("\(p.setCount)", "sets", "Lift", SnappetColor.workout)
        case .gradePR(let p):
            return (p.newGrade, "hardest ever", "PR", SnappetColor.brand)
        case .liftPR(let p):
            return ("\(Int(p.oneRepMaxKg.rounded()))", "kg 1RM", "PR", SnappetColor.brand)
        case .onTheBoard(let p):
            return ("\(p.litCount)", "lit", "Board", SnappetColor.kilter)
        default:
            return ("—", "", "Recap", SnappetColor.kilter)
        }
    }
}
