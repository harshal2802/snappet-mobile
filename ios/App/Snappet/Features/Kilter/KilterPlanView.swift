import SwiftUI
import SwiftData

/// Route for the "Plan a session" screen, pushed onto the suite's shared nav stack from the Kilter
/// root's More menu.
struct KilterPlanRoute: Hashable {}

/// "Plan a session" — turns the user's Kilter history into a suggested session (a few warm-ups, a
/// block of sends at the working grade, and a project), then lets them start a session and tap through
/// the picks. The math lives in the pure `KilterRecommender`; this screen just does the I/O: reads the
/// logged ascents, queries the catalog for a difficulty window, and renders the plan.
struct KilterPlanView: View {
    /// Shared session manager (passed from the root, like `KilterSessionDetailView`) so "Start session"
    /// drives the same live-HR / Live-Activity / media pipeline as a manual or BLE session.
    let sessions: KilterSessionManager

    @Environment(SuiteRouter.self) private var router
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \KilterLogEntry.date, order: .reverse) private var entries: [KilterLogEntry]

    private let catalog = KilterCatalog.shared
    @AppStorage("kilter.angle") private var angle: Int = 40
    @AppStorage("kilter.layout") private var layoutId: Int = 1
    @AppStorage("kilter.gradeFormat") private var gradeFormatRaw = KilterGradeFormat.both.rawValue
    private var gradeFormat: KilterGradeFormat { KilterGradeFormat(rawValue: gradeFormatRaw) ?? .both }

    @State private var plan: KilterRecommender.Plan = .empty
    @State private var built = false

    var body: some View {
        List {
            headerSection
            if plan.isEmpty {
                Section {
                    ContentUnavailableView(
                        built ? "Nothing to suggest" : "Building your plan…",
                        systemImage: built ? "figure.climbing" : "wand.and.stars",
                        description: Text(built
                            ? "No catalog climbs match your grade at \(angle)°. Try a different angle, or log a few climbs first."
                            : "Reading your history and the catalog."))
                }
            } else {
                ForEach(KilterRecommender.Goal.allCases, id: \.self) { goal in
                    let picks = plan.picks(for: goal)
                    if !picks.isEmpty {
                        Section(goal.label) {
                            ForEach(picks) { pickRow($0) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Plan a session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if !sessions.isActive {
                        sessions.start(angle: angle, source: "manual", in: modelContext)
                    }
                    if let first = plan.picks.first {
                        router.push(KilterClimbRoute(uuid: first.item.uuid))
                    }
                } label: {
                    Label(sessions.isActive ? "Go" : "Start session", systemImage: "play.circle.fill")
                }
                .disabled(plan.isEmpty)
                .accessibilityIdentifier("kilter.plan.start")
            }
        }
        .task(id: planKey) { rebuild() }
    }

    // MARK: - Sections

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("Suggested from your last \(entries.count) logged climb\(entries.count == 1 ? "" : "s").")
                    .font(.subheadline)
                if let grade = plan.workingGradeLabel {
                    Label("Working grade ~ \(kilterDisplayGrade(grade, gradeFormat)) · \(angle)°",
                          systemImage: "target")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Label("No send history yet — starting easy at \(angle)°.", systemImage: "sparkles")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func pickRow(_ pick: KilterRecommender.Pick) -> some View {
        Button { router.push(KilterClimbRoute(uuid: pick.item.uuid)) } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(pick.item.name).font(.headline).lineLimit(1)
                    Text("by \(pick.item.setter)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if loggedThisSession(pick.item.uuid) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Text(kilterDisplayGrade(pick.item.gradeLabel, gradeFormat))
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Color(.tertiarySystemBackground), in: Capsule())
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("kilter.plan.pick")
    }

    // MARK: - Data

    /// Whether this climb was already logged in the currently-active session (a live progress check).
    private func loggedThisSession(_ uuid: String) -> Bool {
        guard let id = sessions.currentId else { return false }
        return entries.contains { $0.climbUUID == uuid && $0.sessionId == id }
    }

    /// Recompute when the history, angle, or layout changes.
    private var planKey: String { "\(entries.count)|\(angle)|\(layoutId)" }

    private func rebuild() {
        guard catalog.isAvailable else { plan = .empty; built = true; return }
        let history = entries.map(KilterClimbLog.from)
        let working = KilterRecommender.workingDifficulty(history: history)

        // Anchor the candidate query: the working grade, or the catalog's median grade on a cold start.
        let scale = catalog.gradeScale()
        let median = scale.isEmpty ? 18.0 : Double(scale[scale.count / 2].difficulty)
        let anchor = working ?? median
        let candidates = catalog.list(layoutId: layoutId, angle: angle,
                                      minDifficulty: anchor - 3, maxDifficulty: anchor + 2, limit: 200)

        plan = KilterRecommender.recommend(history: history, candidates: candidates)
        built = true
    }
}
