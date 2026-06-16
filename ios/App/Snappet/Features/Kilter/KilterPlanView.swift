import SwiftUI
import SwiftData

/// Route for the "Plan a session" screen, pushed onto the suite's shared nav stack from the Kilter
/// root's More menu (and the live chip / Home resume card once a session is running).
struct KilterPlanRoute: Hashable {}

/// "Plan a session" — two modes off one screen:
///
/// • **Generate** (no plan pinned to the live session): turns the user's Kilter history into a
///   *preview* session (warm-ups, sends, a project) via the pure `KilterRecommender`, recomputed as
///   history/angle change. "Start session" **snapshots** that preview into a persisted `KilterPlan`,
///   pins it to the session, and freezes it.
/// • **Session home** (a `KilterPlan` is pinned to the live session): reads the **stored, frozen**
///   plan back — order never reshuffles, and each pick's tick comes from `KilterPlanItem.status`, not
///   from re-deriving `logs ∩ recommend()`. This is the re-enterable home a running session returns
///   to, with live progress + a "next up" highlight.
///
/// The math stays in the pure `KilterRecommender` / `KilterPlanProgress`; this screen does the I/O.
struct KilterPlanView: View {
    /// Shared session manager (passed from the root, like `KilterSessionDetailView`) so "Start session"
    /// drives the same live-HR / Live-Activity / media pipeline as a manual or BLE session.
    let sessions: KilterSessionManager

    @Environment(SuiteRouter.self) private var router
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \KilterLogEntry.date, order: .reverse) private var entries: [KilterLogEntry]
    /// All persisted plans — the active one (pinned to `sessions.currentId`) flips the screen to
    /// session-home. Few rows; filtered in `activePlan`.
    @Query private var plans: [KilterPlan]
    /// Session clips — a plan row shows a clip count by the same `climbUUID` key the media pipeline
    /// already tags on (`SessionMedia.assignedClimbUUID`), so the plan inherits its media for free.
    @Query private var allMedia: [SessionMedia]

    private let catalog = KilterCatalog.shared
    @AppStorage("kilter.angle") private var angle: Int = 40
    @AppStorage("kilter.layout") private var layoutId: Int = 1
    @AppStorage("kilter.gradeFormat") private var gradeFormatRaw = KilterGradeFormat.both.rawValue
    private var gradeFormat: KilterGradeFormat { KilterGradeFormat(rawValue: gradeFormatRaw) ?? .both }

    // Plan customization (bug #4) — last-used selection strategy + the knobs it seeds; persisted so the
    // plan stays the way the climber likes it. Defaults reproduce the original behaviour (balanced/6).
    @AppStorage("kilter.plan.strategy") private var strategyRaw = KilterRecommender.Strategy.balanced.rawValue
    @AppStorage("kilter.plan.targetCount") private var planTargetCount = 6
    @AppStorage("kilter.plan.gradeOffset") private var planGradeOffset = 0
    @AppStorage("kilter.plan.preferUnsent") private var planPreferUnsent = true
    private var strategy: KilterRecommender.Strategy { .init(rawValue: strategyRaw) ?? .balanced }

    /// The recommender preview shown in generate-mode (ephemeral; never the source of truth once Started).
    @State private var preview: KilterRecommender.Plan = .empty
    @State private var built = false
    @State private var showingConfig = false
    /// Ephemeral "Shuffle" re-roll counter (not persisted — variety is per-visit). Feeds the
    /// recommender's `rerollSeed` and `planKey` so each tap regenerates a different preview.
    @State private var rerollSeed = 0

    /// The frozen plan pinned to the live session, when this run was started from a plan. Its presence
    /// switches the screen to session-home (read stored items; never regenerate).
    private var activePlan: KilterPlan? {
        guard let id = sessions.currentId else { return nil }
        return plans.first { $0.sessionId == id && $0.completedAt == nil }
    }
    private var isSessionHome: Bool { activePlan != nil }

    var body: some View {
        List {
            if let plan = activePlan {
                sessionHomeHeader(plan)
                planSections(plan)
                finishSection
            } else {
                previewHeader
                previewSections
            }
        }
        .navigationTitle(isSessionHome ? "Session plan" : "Plan a session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .primaryAction) { startButton } }
        .sheet(isPresented: $showingConfig) {
            KilterPlanConfigSheet(strategyRaw: $strategyRaw, targetCount: $planTargetCount,
                                  gradeOffset: $planGradeOffset, preferUnsent: $planPreferUnsent)
                .presentationDetents([.medium, .large])
        }
        // Resolve the live session from the store on appear, so a deep-link entry (Home → plan, which
        // can skip the root's recover) renders session-home immediately when a plan is already running.
        .onAppear { sessions.recover(in: modelContext) }
        // Only regenerate in generate-mode — a started plan is frozen and must never be rebuilt.
        .task(id: planKey) { if !isSessionHome { rebuild() } }
    }

    // MARK: - Toolbar

    private var startButton: some View {
        Button {
            if let plan = activePlan {
                // Session home: jump to the next thing to climb (the first still-pending pick).
                let target = KilterPlanProgress.nextPending(plan.items) ?? plan.items.first
                if let target { router.push(KilterClimbRoute(uuid: target.climbUUID)) }
            } else {
                startPlan()
            }
        } label: {
            Label(isSessionHome ? "Go" : "Start session", systemImage: "play.circle.fill")
        }
        .disabled(startDisabled)
        .accessibilityIdentifier("kilter.plan.start")
    }

    private var startDisabled: Bool {
        isSessionHome ? (activePlan?.items.isEmpty ?? true) : preview.isEmpty
    }

    /// Snapshot the recommender preview into a persisted, frozen `KilterPlan`, pin it to the session
    /// (starting one if needed), and deep-link into the first pick.
    private func startPlan() {
        guard !preview.isEmpty else { return }
        // Match our view of the live session to the store before deciding to create a plan — a deep
        // link (Home → plan) can render this screen before the root's recover ran.
        sessions.recover(in: modelContext)
        // If the live session already owns an open plan, re-enter it instead of forking a second
        // (the single-open-plan invariant; attachPlan is the backstop for the start-adopts-stale race).
        if let id = sessions.currentId,
           let existing = sessions.openPlan(forSession: id, in: modelContext) {
            let target = KilterPlanProgress.nextPending(existing.items) ?? existing.items.first
            if let target { router.push(KilterClimbRoute(uuid: target.climbUUID)) }
            return
        }
        let plan = KilterPlan(
            angle: angle, layoutId: layoutId,
            workingDifficulty: preview.workingDifficulty,
            workingGradeLabel: preview.workingGradeLabel,
            title: strategy == .balanced ? nil : strategy.label,
            optionsTargetCount: planTargetCount, optionsSendThreshold: 2,
            optionsPreferUnsent: planPreferUnsent, optionsGradeOffset: planGradeOffset,
            strategyRaw: strategyRaw,
            items: KilterPlanProgress.items(from: preview))
        modelContext.insert(plan)
        if !sessions.isActive {
            sessions.start(angle: angle, source: "manual", in: modelContext)
        }
        sessions.attachPlan(plan, in: modelContext)   // pins sessionId, freezes, enforces one-open-plan
        try? modelContext.save()
        if let first = plan.items.first {
            router.push(KilterClimbRoute(uuid: first.climbUUID))
        }
    }

    // MARK: - Session-home (frozen plan)

    private func sessionHomeHeader(_ plan: KilterPlan) -> some View {
        let p = KilterPlanProgress.progress(plan.items)
        return Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Plan in progress").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(p.done) of \(p.total) done")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        .accessibilityIdentifier("kilter.plan.progress")
                }
                ProgressView(value: Double(p.done), total: Double(max(1, p.total)))
                    .tint(SnappetColor.moduleAccent("kilter"))
                if let grade = plan.workingGradeLabel {
                    Label("Working grade ~ \(kilterDisplayGrade(grade, gradeFormat)) · \(plan.angle)°",
                          systemImage: "target")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// Ends the session (which closes the plan) and routes to its summary — the explicit "I'm done"
    /// that turns a running plan into a completed one with a plan-vs-actual recap.
    private var finishSection: some View {
        Section {
            Button {
                guard let id = sessions.currentId else { return }
                sessions.end(in: modelContext)
                router.push(KilterSessionRoute(id: id))
            } label: {
                Label("Finish plan", systemImage: "flag.checkered")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("kilter.plan.finish")
        }
    }

    @ViewBuilder private func planSections(_ plan: KilterPlan) -> some View {
        let next = KilterPlanProgress.nextPending(plan.items)
        ForEach(KilterRecommender.Goal.allCases, id: \.self) { goal in
            let items = plan.items.filter { $0.goal == goal }.sorted { $0.order < $1.order }
            if !items.isEmpty {
                Section(goal.label) {
                    ForEach(items) { planItemRow($0, isNext: $0.id == next?.id) }
                }
            }
        }
    }

    private func planItemRow(_ item: KilterPlanItem, isNext: Bool) -> some View {
        Button { router.push(KilterClimbRoute(uuid: item.climbUUID)) } label: {
            HStack(spacing: 12) {
                statusGlyph(item.status)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.climbName).font(.headline).lineLimit(1)
                        .strikethrough(item.status == .skipped)
                    HStack(spacing: 6) {
                        Text("by \(item.setter)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        if isNext {
                            Text("NEXT UP").font(.caption2.weight(.bold))
                                .foregroundStyle(SnappetColor.moduleAccent("kilter"))
                        }
                        let clips = clipCount(item.climbUUID)
                        if clips > 0 {
                            Label("\(clips)", systemImage: "video.fill")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                Text(kilterDisplayGrade(item.gradeLabel, gradeFormat))
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Color(.tertiarySystemBackground), in: Capsule())
            }
            .padding(.vertical, 2)
            .opacity(item.status.isDone ? 0.6 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("kilter.plan.pick")
    }

    @ViewBuilder private func statusGlyph(_ status: KilterPlanItemStatus) -> some View {
        switch status {
        case .sent:      Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .attempted: Image(systemName: "circle.lefthalf.filled").foregroundStyle(.orange)
        case .skipped:   Image(systemName: "minus.circle").foregroundStyle(.secondary)
        case .pending:   Image(systemName: "circle").foregroundStyle(.secondary)
        }
    }

    // MARK: - Generate-mode (recommender preview)

    private var previewHeader: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    Text("Suggested from your last \(entries.count) logged climb\(entries.count == 1 ? "" : "s").")
                        .font(.subheadline)
                    Spacer()
                    if !preview.isEmpty {
                        Button { rerollSeed += 1 } label: { Image(systemName: "shuffle") }
                            .buttonStyle(.bordered).controlSize(.small)
                            .accessibilityIdentifier("kilter.plan.shuffle")
                            .accessibilityLabel("Shuffle the suggested climbs")
                    }
                    Button { showingConfig = true } label: {
                        Label(strategy.label, systemImage: "slider.horizontal.3")
                            .font(.caption).lineLimit(1)
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .accessibilityIdentifier("kilter.plan.adjust")
                }
                if let grade = preview.workingGradeLabel {
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

    @ViewBuilder private var previewSections: some View {
        if preview.isEmpty {
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
                let picks = preview.picks(for: goal)
                if !picks.isEmpty {
                    Section(goal.label) { ForEach(picks) { previewRow($0) } }
                }
            }
        }
    }

    private func previewRow(_ pick: KilterRecommender.Pick) -> some View {
        Button { router.push(KilterClimbRoute(uuid: pick.item.uuid)) } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(pick.item.name).font(.headline).lineLimit(1)
                    Text("by \(pick.item.setter)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
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

    /// Clips tagged to this climb within the current session — the plan inherits media by `climbUUID`.
    private func clipCount(_ uuid: String) -> Int {
        guard let sid = sessions.currentId else { return 0 }
        return allMedia.lazy.filter { $0.assignedClimbUUID == uuid && $0.sessionID == sid }.count
    }

    /// Recompute the preview when the history, angle, layout, or any plan-config knob changes
    /// (generate-mode only).
    private var planKey: String {
        "\(entries.count)|\(angle)|\(layoutId)|\(strategyRaw)|\(planTargetCount)|\(planGradeOffset)|\(planPreferUnsent)|\(rerollSeed)"
    }

    private func rebuild() {
        guard catalog.isAvailable else { preview = .empty; built = true; return }
        let history = entries.map(KilterClimbLog.from)
        let working = KilterRecommender.workingDifficulty(history: history)

        // Anchor the candidate query: the working grade (or the catalog's median grade on a cold
        // start), shifted by the chosen grade offset. Applying the offset HERE — not inside the
        // recommender — keeps the candidate-query window and the recommender's bands sharing one
        // centre (the recommender's contract; otherwise the deep bands point at unfetched climbs).
        let scale = catalog.gradeScale()
        let median = scale.isEmpty ? 18.0 : Double(scale[scale.count / 2].difficulty)
        let anchor = (working ?? median) + Double(planGradeOffset)
        let window = KilterRecommender.candidateWindow(anchor: anchor)
        let candidates = catalog.list(layoutId: layoutId, angle: angle,
                                      minDifficulty: window.min, maxDifficulty: window.max, limit: 200)

        let options = KilterRecommender.Options(
            targetCount: planTargetCount, sendThreshold: 2, preferUnsent: planPreferUnsent,
            mix: KilterRecommender.config(for: strategy).mix, rerollSeed: rerollSeed)
        preview = KilterRecommender.recommend(history: history, candidates: candidates,
                                              anchor: anchor, options: options)
        built = true
    }
}
