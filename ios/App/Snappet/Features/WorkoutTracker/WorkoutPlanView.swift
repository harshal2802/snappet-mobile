import SwiftUI
import SwiftData

/// Route for the smart-planning screen, pushed from the dashboard's "Plan" entry and the Home "Today" card.
struct WorkoutPlanRoute: Hashable {}

/// **Smart workout planning** (workout-redesign E7) — the I/O edge of the planner. The math stays in the
/// pure `WorkoutRecommender` / `WorkoutHistoryStats` / `WorkoutPlanLogic`; this screen does the join + the
/// editing:
///
/// • reads the user's `WorkoutSession` history (`@Query`) + resolves `Exercise.primaryMuscles` via the
///   `@MainActor ExerciseResolver`, flattening both into the device-free value types the pure core consumes;
/// • shows a **"Today"** verb card (REST/EASY/TRAIN/PUSH on the performance ramp + a plain-language *why* +
///   the freshest-muscle focus);
/// • renders the recommender's suggestion as an **editable draft** — strategy + constraint chips re-generate
///   it, a natural-language tweak field runs the optional on-device Apple-Intelligence sharpener (degrading
///   to the heuristic), and each row can be swapped / ±set / removed;
/// • then **Start this session** (a freeform routine started via `RoutineSessionBuilder`) or **Save as
///   routine** (the pre-filled editor).
///
/// The suggestion is never forced — it's a draft you accept, swap, or tweak (the locked decision).
struct WorkoutPlanView: View {
    let history: [WorkoutSession]
    let resolver: ExerciseResolver
    let unit: WeightUnit
    /// Start a freeform session seeded from the plan's `[RoutineExercise]`.
    let start: ([RoutineExercise], String) -> Void
    /// Open the routine editor pre-filled with the plan (Save as routine).
    let saveAsRoutine: ([RoutineExercise], String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Plan customization — last-used strategy + constraints (persisted; defaults reproduce the verb's pick).
    @AppStorage("workoutlog.plan.strategy") private var strategyRaw = ""
    @State private var excludedEquipment: Set<Equipment> = []
    @State private var bodyweightOnly = false
    @State private var rerollSeed = 0

    /// The current draft picks (mutable: swap/±/remove edit this directly so manual edits survive a chip
    /// change unless the user explicitly regenerates).
    @State private var draft: [WorkoutRecommender.Pick] = []
    @State private var focusMuscles: [Muscle] = []
    @State private var built = false

    // Natural-language tweak (the AI sharpener seam).
    @State private var tweakText = ""
    @State private var tweakSource: WorkoutPlanIntelligence.Source?
    @State private var sharpening = false
    @State private var swapping: WorkoutRecommender.Pick?

    /// The strategy the verb suggests, unless the user overrode it.
    private var strategy: WorkoutRecommender.Strategy {
        WorkoutRecommender.Strategy(rawValue: strategyRaw) ?? today.readiness.suggestedStrategy
    }

    // MARK: - Derived signal (the pure join, computed at this edge)

    private var signal: WorkoutHistoryStats {
        WorkoutHistoryStats.make(history: history, resolved: resolvedSessions)
    }

    /// Each completed-session's completed sets, with `Exercise.primaryMuscles` joined in — the value snapshot
    /// the pure per-muscle stats consume. The `@MainActor` resolver join happens HERE, never in the pure core.
    private var resolvedSessions: [WorkoutHistoryStats.ResolvedSession] {
        history.map { session in
            let sets: [WorkoutHistoryStats.ResolvedSet] = session.exercises.flatMap { ex -> [WorkoutHistoryStats.ResolvedSet] in
                let muscles = resolver.exercise(id: ex.exerciseId)?.primaryMuscles ?? []
                return ex.sets.filter { $0.completedAt != nil }.map { _ in WorkoutHistoryStats.ResolvedSet(muscles: muscles) }
            }
            return WorkoutHistoryStats.ResolvedSession(startedAt: session.startedAt, completedSets: sets)
        }
    }

    /// The candidate pool — value snapshots of the merged catalog (the join that keeps the recommender pure).
    private var candidates: [WorkoutRecommender.Candidate] {
        resolver.allMerged
            .filter { $0.category == .strength || $0.category == .powerlifting }
            .map { ex in
                WorkoutRecommender.Candidate(
                    id: ex.id, name: ex.name, primaryMuscles: ex.primaryMuscles,
                    equipment: ex.equipment, isCompound: ex.mechanic == .compound,
                    isBodyweight: ex.equipment == .bodyOnly)
            }
    }

    private var daysSinceLastSession: Int? {
        guard let last = history.map(\.startedAt).max() else { return nil }
        return Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: last),
                                               to: Calendar.current.startOfDay(for: .now)).day
    }

    private var today: WorkoutPlanLogic.Today {
        WorkoutPlanLogic.today(signal: signal, daysSinceLastSession: daysSinceLastSession)
    }

    private var options: WorkoutRecommender.Options {
        let cfg = WorkoutRecommender.config(for: strategy)
        return WorkoutRecommender.Options(
            targetCount: cfg.targetCount, mix: cfg.mix, scheme: cfg.scheme,
            excludedEquipment: excludedEquipment, bodyweightOnly: bodyweightOnly, rerollSeed: rerollSeed)
    }

    /// Build the `[RoutineExercise]` form of the current draft (Start / Save consume this).
    private var draftRoutine: [RoutineExercise] {
        let plan = WorkoutRecommender.Plan(picks: draft, focusMuscles: focusMuscles)
        return WorkoutPlanLogic.routineExercises(from: plan, nameFor: { resolver.name(for: $0) })
    }

    private var draftName: String {
        WorkoutPlanLogic.defaultRoutineName(readiness: today.readiness, date: .now)
    }

    // MARK: - Body

    var body: some View {
        List {
            todaySection
            if candidates.isEmpty {
                emptySection
            } else {
                strategySection
                constraintsSection
                tweakSection
                draftSection
                actionSection
            }
        }
        .navigationTitle("Plan a session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { rerollSeed += 1; regenerate() } label: { Image(systemName: "shuffle") }
                    .disabled(draft.isEmpty)
                    .accessibilityIdentifier("workout.plan.shuffle")
                    .accessibilityLabel("Shuffle the suggested exercises")
            }
        }
        .task { if !built { regenerate() } }
        .sheet(item: $swapping) { pick in swapSheet(for: pick) }
    }

    // MARK: - Today verb card

    private var todaySection: some View {
        let t = today
        let ramp = SnappetColor.performance(for: t.readiness.rampPosition)
        return Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: t.readiness.systemImage)
                        .font(.title2).foregroundStyle(ramp)
                    DisciplineHero(value: t.readiness.headline, caption: "Today", accent: ramp)
                }
                Text(t.why).font(.subheadline).foregroundStyle(SnappetColor.textSecondary)
                if !t.focusMuscles.isEmpty {
                    StatRibbon(items: t.focusMuscles.prefix(3).enumerated().map { i, m in
                        StatRibbon.Item(text: m.display, tint: SnappetColor.workout, emphasized: i == 0,
                                        systemImage: "target")
                    })
                    .accessibilityIdentifier("workout.plan.focus")
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var emptySection: some View {
        Section {
            ContentUnavailableView(
                "Nothing to suggest yet",
                systemImage: "dumbbell",
                description: Text("Log a few strength sessions and the planner will tailor a session to the muscles you've rested."))
        }
    }

    // MARK: - Strategy chips

    private var strategySection: some View {
        Section("Strategy") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(WorkoutRecommender.Strategy.allCases, id: \.self) { s in
                        chip(label: s.label, systemImage: s.systemImage, selected: s == strategy) {
                            strategyRaw = s.rawValue
                            regenerate()
                        }
                        .accessibilityIdentifier("workout.plan.strategy.\(s.rawValue)")
                    }
                }
                .padding(.vertical, 2)
            }
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 0))
        }
    }

    // MARK: - Constraint chips (regenerate)

    private var constraintsSection: some View {
        Section("Constraints") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip(label: "No equipment", systemImage: "figure.strengthtraining.functional",
                         selected: bodyweightOnly) {
                        bodyweightOnly.toggle(); regenerate()
                    }
                    .accessibilityIdentifier("workout.plan.constraint.bodyweight")
                    ForEach([Equipment.barbell, .dumbbell, .machine, .cable], id: \.self) { eq in
                        chip(label: "No \(eq.display.lowercased())", systemImage: eq.symbol,
                             selected: excludedEquipment.contains(eq)) {
                            if excludedEquipment.contains(eq) { excludedEquipment.remove(eq) }
                            else { excludedEquipment.insert(eq) }
                            regenerate()
                        }
                        .accessibilityIdentifier("workout.plan.constraint.\(eq.rawValue)")
                    }
                }
                .padding(.vertical, 2)
            }
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 0))
        }
    }

    // MARK: - Natural-language tweak (the AI sharpener seam)

    private var tweakSection: some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars").foregroundStyle(SnappetColor.workout)
                TextField("e.g. 15 min, no barbell", text: $tweakText)
                    .submitLabel(.go)
                    .onSubmit { applyTweak() }
                    .accessibilityIdentifier("workout.plan.tweakField")
                if sharpening {
                    ProgressView().controlSize(.small)
                } else if !tweakText.isEmpty {
                    Button("Apply") { applyTweak() }
                        .font(.caption.weight(.semibold))
                        .accessibilityIdentifier("workout.plan.tweakApply")
                }
            }
        } header: {
            Text("Tweak in words")
        } footer: {
            switch tweakSource {
            case .appleIntelligence:
                Label("Sharpened on device with Apple Intelligence", systemImage: "apple.intelligence")
                    .font(.caption2).foregroundStyle(SnappetColor.textSecondary)
            case .heuristic:
                Text("Applied your request to the plan.").font(.caption2)
            case nil:
                Text("Describe a change in plain words — it adjusts the constraints, then re-plans.")
                    .font(.caption2)
            }
        }
    }

    // MARK: - Editable draft

    private var draftSection: some View {
        ForEach(WorkoutRecommender.Goal.allCases, id: \.self) { goal in
            let picks = draft.filter { $0.goal == goal }
            if !picks.isEmpty {
                Section(goal.label) {
                    ForEach(picks) { pick in draftRow(pick) }
                }
            }
        }
    }

    private func draftRow(_ pick: WorkoutRecommender.Pick) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(resolver.name(for: pick.candidate.id)).font(.headline).lineLimit(1)
                Text(prescriptionLabel(pick)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            // ± sets
            HStack(spacing: 4) {
                stepperButton(systemImage: "minus") { adjustSets(pick, by: -1) }
                    .accessibilityIdentifier("workout.plan.minusSet")
                Text("\(setCount(pick))").font(.subheadline.weight(.semibold)).monospacedDigit()
                    .frame(minWidth: 16)
                stepperButton(systemImage: "plus") { adjustSets(pick, by: 1) }
                    .accessibilityIdentifier("workout.plan.plusSet")
            }
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("workout.plan.row")
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) { remove(pick) } label: { Label("Remove", systemImage: "trash") }
                .accessibilityIdentifier("workout.plan.remove")
            Button { swapping = pick } label: { Label("Swap", systemImage: "arrow.triangle.2.circlepath") }
                .tint(SnappetColor.workout)
                .accessibilityIdentifier("workout.plan.swap")
        }
    }

    // MARK: - Actions (Start / Save)

    private var actionSection: some View {
        Section {
            Button {
                start(draftRoutine, draftName)
            } label: {
                Label("Start this session", systemImage: "play.circle.fill")
                    .fontWeight(.semibold).frame(maxWidth: .infinity)
            }
            .disabled(draft.isEmpty)
            .accessibilityIdentifier("workout.plan.start")

            Button {
                saveAsRoutine(draftRoutine, draftName)
            } label: {
                Label("Save as routine", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .disabled(draft.isEmpty)
            .accessibilityIdentifier("workout.plan.save")
        }
    }

    // MARK: - Swap sheet

    private func swapSheet(for pick: WorkoutRecommender.Pick) -> some View {
        // Alternatives: same-discipline candidates hitting any of this pick's muscles, not already in the
        // draft, best-ranked by the recommender's own muscle-focus ordering (reuse via a tiny single-pick run).
        let inDraft = Set(draft.map(\.candidate.id))
        let muscles = Set(pick.candidate.primaryMuscles)
        let alts = candidates
            .filter { !inDraft.contains($0.id) && !$0.primaryMuscles.filter(muscles.contains).isEmpty }
            .prefix(20)
        return NavigationStack {
            List {
                ForEach(Array(alts)) { alt in
                    Button {
                        replace(pick, with: alt)
                        swapping = nil
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(resolver.name(for: alt.id)).font(.headline)
                            Text(alt.primaryMuscles.map(\.display).joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("workout.plan.swapOption")
                }
            }
            .navigationTitle("Swap exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { swapping = nil } } }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Mutations

    /// Regenerate the whole draft from the current strategy + constraints (replaces manual edits — explicit).
    private func regenerate() {
        let plan = WorkoutRecommender.recommend(candidates: candidates, signal: signal, options: options)
        draft = plan.picks
        focusMuscles = plan.focusMuscles
        built = true
    }

    /// Apply the natural-language tweak through the AI/heuristic seam, fold it onto the constraints, regen.
    private func applyTweak() {
        let phrase = tweakText
        guard !phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        sharpening = true
        Task {
            let result = await WorkoutPlanIntelligence.resolve(phrase: phrase)
            await MainActor.run {
                let tweak = result.tweak
                if let s = tweak.strategy { strategyRaw = s.rawValue }
                excludedEquipment.formUnion(tweak.excludedEquipment)
                if tweak.bodyweightOnly { bodyweightOnly = true }
                // A count tweak overrides the strategy's default count via the rerollSeed-free path: fold it
                // into a one-off options regen.
                var opts = options
                opts = tweak.apply(to: opts)
                let plan = WorkoutRecommender.recommend(candidates: candidates, signal: signal, options: opts)
                draft = plan.picks
                focusMuscles = plan.focusMuscles
                tweakSource = result.source
                sharpening = false
            }
        }
    }

    private func setCount(_ pick: WorkoutRecommender.Pick) -> Int {
        draft.first { $0.id == pick.id }?.sets ?? pick.sets
    }

    private func adjustSets(_ pick: WorkoutRecommender.Pick, by delta: Int) {
        guard let idx = draft.firstIndex(where: { $0.id == pick.id }) else { return }
        draft[idx].sets = max(1, min(10, draft[idx].sets + delta))
    }

    private func remove(_ pick: WorkoutRecommender.Pick) {
        draft.removeAll { $0.id == pick.id }
    }

    private func replace(_ pick: WorkoutRecommender.Pick, with alt: WorkoutRecommender.Candidate) {
        guard let idx = draft.firstIndex(where: { $0.id == pick.id }) else { return }
        draft[idx] = WorkoutRecommender.Pick(candidate: alt, goal: pick.goal, sets: pick.sets,
                                             reps: pick.reps, restSeconds: pick.restSeconds)
    }

    // MARK: - Small view helpers

    private func prescriptionLabel(_ pick: WorkoutRecommender.Pick) -> String {
        let sets = setCount(pick)
        return "\(sets) × \(pick.reps) · rest \(pick.restSeconds)s"
    }

    private func chip(label: String, systemImage: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(.caption2)
                Text(label).font(.caption.weight(.semibold)).lineLimit(1)
            }
            .padding(.horizontal, 11).padding(.vertical, 6)
            .foregroundStyle(selected ? .white : SnappetColor.textSecondary)
            .background(selected ? SnappetColor.workout : SnappetColor.surfaceMuted, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func stepperButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage).font(.caption.weight(.bold))
                .frame(width: 26, height: 26)
                .background(SnappetColor.surfaceMuted, in: Circle())
                .foregroundStyle(SnappetColor.workout)
        }
        .buttonStyle(.plain)
    }
}
