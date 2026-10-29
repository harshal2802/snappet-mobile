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
    /// The board size the browse screen uses — so the plan only suggests climbs your board can fully light.
    @AppStorage("kilter.productSizeId") private var productSizeId = 0
    @AppStorage("kilter.gradeFormat") private var gradeFormatRaw = KilterGradeFormat.both.rawValue
    private var gradeFormat: KilterGradeFormat { KilterGradeFormat(rawValue: gradeFormatRaw) ?? .both }

    // Plan customization (bug #4) — last-used selection strategy + the knobs it seeds; persisted so the
    // plan stays the way the climber likes it. Defaults reproduce the original behaviour (balanced/6).
    @AppStorage("kilter.plan.strategy") private var strategyRaw = KilterRecommender.Strategy.balanced.rawValue
    @AppStorage("kilter.plan.targetCount") private var planTargetCount = 6
    @AppStorage("kilter.plan.gradeOffset") private var planGradeOffset = 0
    @AppStorage("kilter.plan.preferUnsent") private var planPreferUnsent = true
    /// Prompt 208 (superseded within the PR by the two switches below; read once to carry the choice over).
    @AppStorage("kilter.plan.climbChoice") private var planClimbChoiceRaw = ""
    /// "Climbs to pick" switches: 1 on, 0 off, -1 not set yet → carried over from the earlier settings.
    @AppStorage("kilter.plan.includeSent") private var planIncludeSentRaw = -1
    @AppStorage("kilter.plan.includeProjects") private var planIncludeProjectsRaw = -1
    @AppStorage("kilter.plan.classicsOnly") private var planClassicsOnly = false
    private var planClimbs: KilterPlanClimbs {
        let carried: KilterPlanClimbs = switch planClimbChoiceRaw {
        case "includeSent": .init(includeSent: true, includeProjects: true)
        case "projectsFirst": .init(includeSent: false, includeProjects: true)
        case "newOnly": .newOnly
        default: planPreferUnsent ? .newOnly : .init(includeSent: true, includeProjects: true)
        }
        return .init(includeSent: planIncludeSentRaw < 0 ? carried.includeSent : planIncludeSentRaw == 1,
                     includeProjects: planIncludeProjectsRaw < 0 ? carried.includeProjects : planIncludeProjectsRaw == 1,
                     classicsOnly: planClassicsOnly)
    }
    private var strategy: KilterRecommender.Strategy { .init(rawValue: strategyRaw) ?? .balanced }

    /// The recommender preview shown in generate-mode (ephemeral; never the source of truth once Started).
    @State private var preview: KilterRecommender.Plan = .empty
    @State private var built = false
    @State private var showingConfig = false
    /// Ephemeral "Shuffle" re-roll counter (not persisted — variety is per-visit). Feeds the
    /// recommender's `rerollSeed` and `planKey` so each tap regenerates a different preview.
    @State private var rerollSeed = 0

    // MARK: Editing (prompt 209)
    /// Your edited plan. `nil` = following the suggestion; once you edit, the plan stops rebuilding itself.
    @State private var draft: [KilterPlanItem]?
    /// The settings the draft was made from — when they change, ask before rebuilding (Q3).
    @State private var draftKey: String?
    @State private var editing = false
    /// Where "+ Add" was tapped (a section in the preview; `nil` goal = during a session, filed by grade).
    @State private var addTarget: AddTarget?
    /// The preview's grade anchor (working grade + offset) — the "+ Add" sheet's grade bands.
    @State private var anchor: Double?

    struct AddTarget: Identifiable {
        let goal: KilterRecommender.Goal?
        var id: String { goal?.rawValue ?? "session" }
    }

    private var boardSizeBox: KilterSizeBox? {
        catalog.sizes(forLayout: layoutId).first { $0.id == productSizeId }?.box
    }

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
                Section {
                    Button { addTarget = AddTarget(goal: nil) } label: { Label("Add a climb", systemImage: "plus") }
                        .accessibilityIdentifier("kilter.plan.addClimb")
                } footer: {
                    Text("Done or tried climbs stay — you can remove only what’s still pending.")
                }
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
                                  gradeOffset: $planGradeOffset,
                                  climbs: Binding(get: { planClimbs }, set: {
                                      planIncludeSentRaw = $0.includeSent ? 1 : 0
                                      planIncludeProjectsRaw = $0.includeProjects ? 1 : 0
                                      planClassicsOnly = $0.classicsOnly
                                  }))
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $addTarget) { target in addSheet(target) }
        .environment(\.editMode, .constant(editing && !isSessionHome ? .active : .inactive))
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
        isSessionHome ? (activePlan?.items.isEmpty ?? true) : (draft.map { $0.isEmpty } ?? preview.isEmpty)
    }

    /// Snapshot the recommender preview into a persisted, frozen `KilterPlan`, pin it to the session
    /// (starting one if needed), and deep-link into the first pick.
    private func startPlan() {
        let picks = draft.map(KilterPlanProgress.normalized) ?? KilterPlanProgress.items(from: preview)
        guard !picks.isEmpty else { return }
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
            optionsPreferUnsent: !planClimbs.includeSent, optionsGradeOffset: planGradeOffset,
            strategyRaw: strategyRaw,
            items: picks)
        modelContext.insert(plan)
        if !sessions.isActive {
            // Stamp the plan's board layout so History can facet this session by board/layout (FC).
            sessions.start(angle: angle, source: "manual", layoutId: layoutId, in: modelContext)
        }
        sessions.attachPlan(plan, in: modelContext)   // pins sessionId, freezes, enforces one-open-plan
        try? modelContext.save()
        draft = nil; draftKey = nil; editing = false
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
                // Push the summary FIRST so it covers the plan screen before `end` flips this view back
                // to generate-mode (no one-frame flash of the empty generator).
                router.push(KilterSessionRoute(id: id))
                sessions.end(in: modelContext)
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
        // Skip a pick you're not doing today — flips it to .skipped (leaves the "next up" rotation,
        // not counted as done). Only meaningful while still pending.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if KilterPlanProgress.canRemove(item, inSession: true) {
                Button(role: .destructive) {
                    sessions.editPlanItems(in: modelContext) { KilterPlanProgress.removing(id: item.id, from: $0, inSession: true) }
                } label: { Label("Remove", systemImage: "trash") }
                .accessibilityIdentifier("kilter.plan.remove")
            }
            if item.status == .pending {
                Button { sessions.skipPlanItem(id: item.id, in: modelContext) } label: {
                    Label("Skip", systemImage: "minus.circle")
                }
                .tint(.gray)
                .accessibilityIdentifier("kilter.plan.skip")
            }
        }
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
                    // The whole log feeds the plan — not a window of recent climbs ("your last 20" read like a cut-off).
                    Text(Self.historyLine(ascentIndex, climbs: planClimbs))
                        .font(.subheadline)
                    Spacer()
                    if draft != nil {
                        // Edited: no more shuffling — go back to the suggestion explicitly.
                        Button { draft = nil; draftKey = nil; editing = false } label: {
                            Label("Reset", systemImage: "arrow.uturn.backward").font(.caption.weight(.semibold))
                        }
                            .buttonStyle(.bordered).controlSize(.small)
                            .accessibilityIdentifier("kilter.plan.resetEdits")
                            .accessibilityLabel("Reset to suggestion")
                    } else if !preview.isEmpty {
                        Button { rerollSeed += 1 } label: { Image(systemName: "shuffle") }
                            .buttonStyle(.bordered).controlSize(.small)
                            .accessibilityIdentifier("kilter.plan.shuffle")
                            .accessibilityLabel("Shuffle the suggested climbs")
                    }
                    if !preview.isEmpty || draft != nil {
                        Button {
                            if draft == nil { draft = KilterPlanProgress.items(from: preview); draftKey = planKey }
                            editing.toggle()
                        } label: { Text(editing ? "Done" : "Edit").font(.caption.weight(.semibold)) }
                        .buttonStyle(.bordered).controlSize(.small)
                        .accessibilityIdentifier("kilter.plan.edit")
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
        if let draft {
            if let key = draftKey, key != planKey {
                // Q3: settings changed after editing — ask, never silently replace the edits.
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your settings changed. Rebuild the plan and lose your edits?").font(.subheadline)
                        HStack {
                            Button("Rebuild") { self.draft = nil; draftKey = nil; editing = false }
                                .buttonStyle(.borderedProminent).controlSize(.small)
                                .accessibilityIdentifier("kilter.plan.rebuild")
                            Button("Keep my edits") { draftKey = planKey }
                                .buttonStyle(.bordered).controlSize(.small)
                                .accessibilityIdentifier("kilter.plan.keepEdits")
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            draftSections(draft)
        } else if preview.isEmpty {
            Section {
                ContentUnavailableView(
                    built ? "Nothing to suggest" : "Building your plan…",
                    systemImage: built ? "figure.climbing" : "wand.and.stars",
                    description: Text(built
                        ? "No catalog climbs match your grade at \(angle)°. Try a different angle, or log a few climbs first."
                        : "Reading your history and the catalog."))
            }
        } else {
            let index = ascentIndex
            ForEach(KilterRecommender.Goal.allCases, id: \.self) { goal in
                let picks = preview.picks(for: goal)
                if !picks.isEmpty {
                    Section(goal.label) { ForEach(picks) { previewRow($0, badge: index.badge($0.item.uuid, angle: angle)) } }
                }
            }
        }
    }

    /// The plan's catalog pool: layout + angle + the grade window, narrowed to climbs your board can fully light
    /// (`sizeBox`) and, with "Classics only", to benchmarks.
    static func candidateFilter(layoutId: Int, angle: Int, window: (min: Double, max: Double),
                                climbs: KilterPlanClimbs, sizeBox: KilterSizeBox?) -> KilterFilter {
        KilterFilter(layoutId: layoutId, angle: angle, minDifficulty: window.min, maxDifficulty: window.max,
                     benchmarksOnly: climbs.classicsOnly, sizeBox: sizeBox)
    }

    /// "16 climbs logged — 9 sent (excluded), 7 projects (excluded)": the whole log in distinct climbs, and what the
    /// two switches do with each group. Same counts as the browse chips.
    static func historyLine(_ index: KilterAscentIndex, climbs: KilterPlanClimbs) -> String {
        let total = index.loggedUUIDs.count, sent = index.sentUUIDs.count, projects = index.projectUUIDs.count
        guard total > 0 else { return "No climbs logged yet — starting from the catalog." }
        let sentPart = "\(sent) sent (\(climbs.includeSent ? "included" : "excluded"))"
        let projectPart = "\(projects) project\(projects == 1 ? "" : "s") (\(climbs.includeProjects ? "included" : "excluded"))"
        return "\(total) climb\(total == 1 ? "" : "s") logged — \(sentPart), \(projectPart)"
            + (climbs.classicsOnly ? " · classics only" : "")
    }

    /// The climber's log per climb (prompt 208) — so a sent warm-up or a project reads as such in the preview.
    private var ascentIndex: KilterAscentIndex {
        KilterAscentIndex(entries.map {
            .init(climbUUID: $0.climbUUID, status: $0.status, attempts: $0.attempts, date: $0.date, angle: $0.angle)
        })
    }

    /// The edited plan, by section. While editing: delete, drag within a section, "Move to" another section,
    /// and "+ Add a …" per section (shown even when a section is empty, so you can add a project).
    @ViewBuilder private func draftSections(_ items: [KilterPlanItem]) -> some View {
        let index = ascentIndex
        ForEach(KilterRecommender.Goal.allCases, id: \.self) { goal in
            let section = items.filter { $0.goal == goal }.sorted { $0.order < $1.order }
            if !section.isEmpty || editing {
                Section(goal.label) {
                    ForEach(section) { item in
                        draftRow(item, badge: index.badge(item.climbUUID, angle: angle))
                            .contextMenu {
                                ForEach(KilterRecommender.Goal.allCases.filter { $0 != goal }, id: \.self) { g in
                                    Button("Move to \(g.label)") {
                                        draft = KilterPlanProgress.moving(id: item.id, to: g, in: draft ?? [])
                                    }
                                }
                                Button("Remove", role: .destructive) {
                                    draft = KilterPlanProgress.removing(id: item.id, from: draft ?? [], inSession: false)
                                }
                            }
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { section[$0].id }
                        draft = ids.reduce(draft ?? []) { KilterPlanProgress.removing(id: $1, from: $0, inSession: false) }
                    }
                    .onMove { from, to in
                        draft = KilterPlanProgress.reordering(goal, from: from, to: to, in: draft ?? [])
                    }
                    if editing {
                        Button { addTarget = AddTarget(goal: goal) } label: {
                            Label("Add a \(goal.label.lowercased())", systemImage: "plus")
                        }
                        .accessibilityIdentifier("kilter.plan.add.\(goal.rawValue)")
                    }
                }
            }
        }
    }

    private func draftRow(_ item: KilterPlanItem, badge: String?) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.climbName).font(.headline).lineLimit(1)
                    if let badge { ascentBadge(badge) }
                }
                Text("by \(item.setter)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(kilterDisplayGrade(item.gradeLabel, gradeFormat))
                .font(.subheadline.weight(.semibold)).monospacedDigit()
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(Color(.tertiarySystemBackground), in: Capsule())
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("kilter.plan.draftPick")
    }

    private func ascentBadge(_ badge: String) -> some View {
        let sent = badge.hasPrefix("✓")
        return Text(badge).font(.caption2.weight(.bold))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background((sent ? Color.green : Color.orange).opacity(0.18), in: Capsule())
            .foregroundStyle(sent ? Color.green : Color.orange)
    }

    /// "+ Add a send" (preview) / "+ Add a climb" (session): the picker sheet, scoped to that section's grade band.
    private func addSheet(_ target: AddTarget) -> some View {
        let plan = activePlan
        let centre = plan.map { ($0.workingDifficulty ?? anchor ?? 18) + Double($0.optionsGradeOffset) } ?? anchor
        let window: (min: Double, max: Double)? = centre.map { a in
            switch target.goal {
            case .warmup?: (a - 4, a - 1)
            case .send?: (a - 1, a + 1)
            case .project?: (a + 1, a + 3)
            case nil: (a - 4, a + 3)
            }
        }
        let inPlan = Set((plan?.items ?? draft ?? []).map(\.climbUUID))
        return KilterPlanAddClimbSheet(
            title: target.goal.map { "Add a \($0.label.lowercased())" } ?? "Add a climb",
            layoutId: plan?.layoutId ?? layoutId, angle: plan?.angle ?? angle, sizeBox: boardSizeBox,
            gradeWindow: window, ascents: ascentIndex, inPlan: inPlan, gradeFormat: gradeFormat
        ) { climb in
            if let plan {
                let goal = KilterPlanProgress.goalForAdded(difficulty: climb.difficulty,
                                                           working: plan.workingDifficulty.map { $0 + Double(plan.optionsGradeOffset) })
                sessions.editPlanItems(in: modelContext) { KilterPlanProgress.adding(climb, as: goal, to: $0) }
            } else if let goal = target.goal {
                draft = KilterPlanProgress.adding(climb, as: goal, to: draft ?? [])
            }
        }
    }

    private func previewRow(_ pick: KilterRecommender.Pick, badge: String? = nil) -> some View {
        Button { router.push(KilterClimbRoute(uuid: pick.item.uuid)) } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(pick.item.name).font(.headline).lineLimit(1)
                        if let badge {
                            let sent = badge.hasPrefix("✓")
                            Text(badge).font(.caption2.weight(.bold))
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background((sent ? Color.green : Color.orange).opacity(0.18), in: Capsule())
                                .foregroundStyle(sent ? Color.green : Color.orange)
                                .accessibilityIdentifier("kilter.plan.pick.ascent")
                        }
                    }
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
        "\(entries.count)|\(angle)|\(layoutId)|\(productSizeId)|\(strategyRaw)|\(planTargetCount)|\(planGradeOffset)|\(planClimbs.includeSent)|\(planClimbs.includeProjects)|\(planClimbs.classicsOnly)|\(rerollSeed)"
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
        self.anchor = anchor
        let window = KilterRecommender.candidateWindow(anchor: anchor)
        // "Classics only" narrows the pool to benchmark climbs, exactly like the browse filter.
        // Only climbs your board can fully light — the browse screen's strict size fit (prompt 154). The plan
        // used to skip it and could suggest a climb set on a bigger board (2026-10-29).
        let sizeBox = catalog.sizes(forLayout: layoutId).first { $0.id == productSizeId }?.box
        let candidates = catalog.list(Self.candidateFilter(layoutId: layoutId, angle: angle, window: window,
                                                           climbs: planClimbs, sizeBox: sizeBox),
                                      limit: max(200, planTargetCount * 25))   // a 30-climb plan needs a deeper pool

        let options = KilterRecommender.Options(
            targetCount: planTargetCount, sendThreshold: 2, climbs: planClimbs,
            mix: KilterRecommender.config(for: strategy).mix, rerollSeed: rerollSeed)
        preview = KilterRecommender.recommend(history: history, candidates: candidates,
                                              anchor: anchor, options: options)
        built = true
    }
}
