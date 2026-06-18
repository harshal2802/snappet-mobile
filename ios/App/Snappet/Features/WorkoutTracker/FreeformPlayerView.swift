import SwiftUI
import SwiftData
import HighlightEngine

/// A **freeform / dynamic** session player: unlike the guided `WorkoutPlayerView` (which walks a fixed
/// routine set-by-set), this is a grow-as-you-go logbook — add exercises and sets/attempts on the fly,
/// of any `SetKind` (reps & weight, timed, or climb attempts). Used for routineless sessions
/// (`routineID == nil`), e.g. an ad-hoc gym lifting session or a bouldering session where you don't
/// know the next climb. (dynamic-sessions D3/D5; reworked as a discoverable canvas in issue #158)
///
/// Kept separate from `WorkoutPlayerView` on purpose: the guided flow is device-verified and tightly
/// coupled to reps×weight + a fixed index walk; a list-based logbook is the right shape for "add as you
/// go" and avoids destabilizing it.
///
/// **Canvas + command bar (issue #158 §A):** the empty state offers three discoverable type cards
/// (Lifting / Climbing / Timed); an always-present `Menu` (`freeform.addExercise`) adds more once
/// underway; the title is inline-editable; and a persistent bottom command bar
/// (`safeAreaInset(edge: .bottom)`) carries the wall-clock timer, a compact live-HR chip, and the
/// always-available Finish — replacing the redundant toolbar "End" so there's one consistent exit.
struct FreeformPlayerView: View {
    @Bindable var session: WorkoutSession
    let resolver: ExerciseResolver
    /// Prior completed sessions — feeds the "Last time…" prefill/hint (§B) and the milestone check (§D).
    let history: [WorkoutSession]
    let defaultUnit: WeightUnit
    /// Close + report whether to keep (finish / save & exit) or discard the session.
    let onClose: (_ saved: Bool) -> Void
    /// Dismiss without ending — the session stays active (background/minimize ask).
    let onMinimize: () -> Void
    /// Finish + save, then open the completed session's detail (the completion screen's "View detail").
    let onViewDetail: (WorkoutSession) -> Void

    @Environment(\.modelContext) private var context
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var pickingLift = false
    @State private var logging: LogTarget?
    @State private var showingAddMenu = false
    /// Cross-session prefill per exerciseId, cached so the ~1 Hz body re-render never re-scans history
    /// (history is fixed for the live session). Recomputed on appear + when an exercise is added. (§B)
    @State private var prefills: [String: LastSetLookup.LastTime] = [:]
    /// Post-workout completion moment (§D): Finish switches the cover to a summary screen (in-cover, not a
    /// push — avoids the push-vs-cover wedge `SessionRoute` exists for). The milestones drive the burst.
    @State private var showingSummary = false
    @State private var doneMilestones: [FreeformSummary.Milestone] = []
    @State private var doneBounce = 0
    @State private var celebrationTrigger = 0
    @State private var showingDiscard = false
    /// The expandable live-metrics & recovery panel (§E), opened from the command-bar HR chip.
    @State private var showingMetrics = false
    @ScaledMetric(relativeTo: .largeTitle) private var doneSealSize: CGFloat = 72

    private var unit: WeightUnit { defaultUnit }

    var body: some View {
        if showingSummary {
            doneScreen
        } else {
            loggingContent
        }
    }

    private var loggingContent: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            List {
                titleSection
                if session.exercises.isEmpty { emptyStateHero }
                ForEach(session.exercises) { ex in exerciseSection(ex) }
            }
            // Keep the scroll content clear of the floating command bar: without enough bottom margin a
            // tap on the last exercise's controls can fall through to the Finish button beneath it.
            .contentMargins(.bottom, 96, for: .scrollContent)
            // Auto-scroll to a newly added exercise so it (and its controls) are on-screen as the logbook
            // grows — otherwise a new exercise can land off the bottom of a long list (and a List renders
            // off-screen rows lazily, so the freshly-added section isn't even there until scrolled to).
            .onChange(of: session.exercises.count) { old, new in
                if new > old, let lastID = session.exercises.last?.id {
                    withAnimation { proxy.scrollTo(lastID, anchor: .center) }
                }
            }
            .navigationTitle(session.routineName)
            .navigationBarTitleDisplayMode(.inline)
            // The persistent command bar (§A): wall-clock timer · compact HR chip · always-on Finish.
            // Reuses the module's `safeAreaInset(edge: .bottom)` banner idiom.
            .safeAreaInset(edge: .bottom) { commandBar }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { onMinimize() } label: { Label("Minimize", systemImage: "chevron.down") }
                        .accessibilityIdentifier("minimizeWorkout")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { togglePause() } label: {
                        Label(isPaused ? "Resume" : "Pause", systemImage: isPaused ? "play.fill" : "pause.fill")
                    }
                    .accessibilityIdentifier("pauseWorkout")
                }
                // Add-exercise lives in the toolbar (§A): always one tap away regardless of how long the
                // logbook grows — a bottom-of-list Menu becomes unreachable once the list scrolls. A
                // confirmationDialog (not a Menu) because SwiftUI toolbar-Menu item actions fire
                // unreliably under XCUITest (the action sometimes no-ops); the dialog's buttons are
                // dependable. Label is "New exercise" (not "Add …") so it doesn't collide with the
                // picker's nav-bar "Add (N)" commit the UITests match by `BEGINSWITH 'Add'`.
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingAddMenu = true } label: {
                        Label("New exercise", systemImage: "plus")
                    }
                    .accessibilityIdentifier("freeform.addExercise")
                }
            }
            }
        }
        .interactiveDismissDisabled()
        .sheet(isPresented: $pickingLift) {
            ExercisePickerView(resolver: resolver) { picked in addLifting(picked) }
        }
        .sheet(item: $logging) { target in
            LogSetSheet(kind: target.kind, unit: unit, prefill: prefills[target.exerciseId]) { log in
                appendLog(log, toExerciseID: target.exerciseID)
            }
        }
        .sheet(isPresented: $showingMetrics) {
            LiveMetricsPanel(session: session)
        }
        // Add-exercise options (§A). The button titles are the labels the freeform UITests drive.
        .confirmationDialog("Add exercise", isPresented: $showingAddMenu, titleVisibility: .visible) {
            Button("Lifting exercise") { pickingLift = true }
            Button("Climbing") { addExercise(kind: .climbAttempt, name: SetMeasure.climbName("")) }
            Button("Timed exercise") { addExercise(kind: .duration, name: "Timed exercise") }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear {
            app.workoutNotifications.requestAuthorization()
            recomputePrefills()
            pushLiveActivity()
        }
        .onChange(of: session.exercises.count) { _, _ in recomputePrefills() }
        // Keep the Live Activity (Lock Screen / Dynamic Island) in sync with the freeform session:
        // live HR and the paused state push as they change. The overall timer self-ticks off
        // `startedAt`; these refresh HR + the exercise line + the paused flag. Mirrors `WorkoutPlayerView`.
        .onChange(of: app.liveWorkout.latestHR) { _, _ in pushLiveActivity() }
        .onChange(of: app.liveWorkout.isPaused) { _, _ in pushLiveActivity() }
        // Live clip discovery (§F): periodically scan the Photos library for clips filmed during the
        // session and auto-tag them to the set they fall in. Device-only — a no-op without full Photo
        // access / on the simulator. ~20 s cadence (clips don't land faster, and a full-library time
        // scan is not free).
        .task {
            while !Task.isCancelled {
                await discoverClips()
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    // MARK: - Sections

    /// Inline-editable session title (§A). Commits to `WorkoutSession.routineName` (default "Quick
    /// session") and pushes the Live Activity so the Lock-Screen label updates. A leaf TextField.
    private var titleSection: some View {
        Section {
            TextField("Session name", text: $session.routineName)
                .font(.title3.weight(.semibold))
                .submitLabel(.done)
                .onSubmit { persist(); pushLiveActivity() }
                .accessibilityIdentifier("freeform.sessionTitle")
        }
    }

    /// Discoverable empty-state canvas (§A): three labelled type cards instead of a buried menu. They
    /// call the same mutators as the `freeform.addExercise` menu items; their accessibility labels are
    /// distinct from the menu-item labels so XCUITest queries stay unambiguous.
    private var emptyStateHero: some View {
        Section {
            VStack(spacing: 12) {
                Text("Start your session").font(.headline)
                Text("Pick what you're tracking — add more as you go.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    typeCard("Lifting", symbol: "dumbbell.fill",
                             id: "freeform.cardLifting", accLabel: "Start lifting") { pickingLift = true }
                    typeCard("Climbing", symbol: "figure.climbing",
                             id: "freeform.cardClimbing", accLabel: "Start climbing") {
                        addExercise(kind: .climbAttempt, name: SetMeasure.climbName(""))
                    }
                    typeCard("Timed", symbol: "timer",
                             id: "freeform.cardTimed", accLabel: "Start a timed exercise") {
                        addExercise(kind: .duration, name: "Timed exercise")
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
        }
    }

    private func typeCard(_ title: String, symbol: String, id: String,
                          accLabel: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.title2).foregroundStyle(SnappetColor.workout)
                Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .snappetTile()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityLabel(accLabel)
    }

    private func exerciseSection(_ ex: SessionExercise) -> some View {
        Section {
            ForEach(Array(ex.sets.enumerated()), id: \.offset) { i, set in
                HStack {
                    Text("\(i + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 20, alignment: .leading)
                    Text(SetMeasure.summary(set, kind: ex.kind, unit: unit))
                        .font(.body.weight(.medium))
                    Spacer()
                }
                .accessibilityIdentifier("freeform.setRow")
            }
            .onDelete { offsets in deleteSets(ex, at: offsets) }

            // Faster entry (§B): keyboard-free inline steppers for reps & weight, seeded from this
            // session's last set or the cached cross-session prefill, logging through the one `appendLog`
            // funnel. `.id(ex.sets.count)` re-seeds them to the latest after each log/delete. The sheet
            // ("Log something different") stays for precise / non-default entry.
            if ex.kind == .repsWeight {
                let last = ex.sets.last
                let pf = prefills[ex.exerciseId]
                QuickAddRow(reps: last?.actualReps ?? pf?.reps ?? 8,
                            weight: last?.actualWeight ?? pf?.weight ?? 0,
                            unitSel: last?.weightUnit ?? pf?.unit ?? unit,
                            hint: last == nil ? pf?.hint : nil) { log in
                    appendLog(log, toExerciseID: ex.id)
                }
                .id(ex.sets.count)
            }

            Button {
                logging = LogTarget(exerciseID: ex.id, kind: ex.kind, exerciseId: ex.exerciseId)
            } label: {
                Label(ex.kind == .repsWeight ? "Log something different" : ex.kind.addLabel,
                      systemImage: "plus.circle.fill")
            }
            .accessibilityIdentifier("freeform.addSet")

            // One-tap repeat of the most recent set — duplicates it (all kind-specific fields, fresh
            // completedAt) without opening the sheet. Only shown once there's a set to repeat. A sibling
            // leaf Button (NOT wrapped in a composite); value-labelled via the pure FreeformSummary (§B)
            // so it reads like the set it duplicates ("Repeat 8 × 60 kg"). Matched by id in tests.
            if let last = ex.sets.last {
                Button {
                    repeatLastSet(ex)
                } label: {
                    Label(FreeformSummary.repeatLabel(for: last, kind: ex.kind, unit: unit),
                          systemImage: "arrow.clockwise")
                }
                .accessibilityIdentifier("freeform.repeatSet")
            }

            // Live clips (§F): a per-set media strip for the latest set — auto-discovered clips appear
            // here seconds after you film them, and you can attach more by hand. Keyed by exercise+set so
            // its @Query re-scopes as sets are logged. Device-only (Photos/PHPicker); the affordance
            // renders everywhere, the pick/discovery is on-device.
            if let lastIndex = ex.sets.indices.last {
                SetMediaStrip(session: session, exerciseID: ex.id, setIndex: lastIndex)
                    .id("set-media-\(ex.id)-\(lastIndex)")
            }
        } header: {
            HStack {
                Image(systemName: ex.kind.symbol).foregroundStyle(.secondary)
                // Climbs name inline (§C): rename anytime, no blocking prompt. Commits via the one tested
                // SetMeasure.climbName trim/"Climbing" fallback. The TextField is a directly-queryable leaf
                // (freeform.climbName) — simpler than the iOS-26 alert-TextField workaround it replaces.
                if ex.kind == .climbAttempt {
                    ClimbNameHeader(initialName: ex.displayName ?? SetMeasure.climbName("")) { name in
                        guard let idx = indexOf(ex) else { return }
                        session.exercises[idx].displayName = name
                        persist()
                        pushLiveActivity()
                    }
                    .id(ex.id)
                } else {
                    Text(resolver.name(for: ex.exerciseId, override: ex.displayName))
                }
                Spacer()
                Menu {
                    Button(role: .destructive) { removeExercise(ex) } label: {
                        Label("Remove exercise", systemImage: "trash")
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
            .textCase(nil)
        }
    }

    /// The persistent bottom command bar (§A): wall-clock total timer · compact live-HR chip · the
    /// always-available Finish. The timer/HR are non-interactive labels (a labelled composite is fine —
    /// the leaf-only rule is about interactive controls); Finish keeps its `freeform.finish` id.
    private var commandBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: isPaused ? "pause.fill" : "stopwatch")
                    .foregroundStyle(isPaused ? .yellow : SnappetColor.workout)
                Text(timerInterval: session.startedAt...Date.distantFuture, countsDown: false)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
            }
            .accessibilityIdentifier("overallWorkoutTimer")

            Spacer(minLength: 8)

            if let bpm = app.liveWorkout.latestHR {
                let profile = app.userProfile.profile
                let zone = HeartRateZone.forBpm(bpm, maxHR: profile.resolvedMaxHR ?? HeartRateZone.defaultMaxHR)
                let recovery = RecoveryReadiness.evaluate(currentBpm: bpm, restBpm: profile.restingBound,
                                                          maxBpm: profile.resolvedMaxHR)
                Button { showingMetrics = true } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "heart.fill").foregroundStyle(zone.color)
                        Text("\(Int(bpm.rounded()))")
                            .font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(.primary)
                        if zone != .none {
                            Text("Z\(zone.rawValue)").font(.caption2.weight(.bold))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(zone.color.opacity(0.18), in: Capsule())
                                .foregroundStyle(zone.color)
                        }
                        if recovery.state != .unknown {
                            Circle().fill(recovery.state == .ready ? Color.green : Color.orange)
                                .frame(width: 8, height: 8)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("freeform.hrChip")
            }

            Button { finishTapped() } label: {
                Text("Finish").font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .tint(SnappetColor.workout)
            .accessibilityIdentifier("freeform.finish")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Completion moment (§D)

    /// The post-workout summary, mirroring the guided player's done-screen: a seal, the three completion
    /// stats (Duration · Sets · a dominant-kind headline — Volume / Sends / Hold-time), an optional
    /// milestone headline, and the Done / View detail CTAs (plus Keep going / Discard). A milestone fires
    /// a `CelebrationBurst` (haptic always; confetti suppressed under Reduce Motion). All figures come from
    /// the pure `FreeformSummary` — derived, not persisted, so there's no model change.
    private var doneScreen: some View {
        let stats = FreeformSummary.stats(for: session, unit: unit)
        return VStack(spacing: 0) {
            HStack {
                Button("Keep going") { showingSummary = false }
                    .accessibilityIdentifier("freeform.keepGoing")
                Spacer()
            }
            .padding(.horizontal)

            Spacer()

            VStack(spacing: 16) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: doneSealSize))
                    .foregroundStyle(SnappetColor.workout)
                    .symbolEffect(.bounce, value: reduceMotion ? 0 : doneBounce)
                Text("Workout Complete").font(.title.bold())
                Text(session.routineName).foregroundStyle(.secondary)
                if let milestone = doneMilestones.first {
                    Text(FreeformSummary.milestoneHeadline(milestone))
                        .font(.headline)
                        .foregroundStyle(SnappetColor.workout)
                        .accessibilityIdentifier("freeform.milestone")
                }
                HStack(spacing: 28) {
                    statCell(stats.duration)
                    statCell(stats.sets)
                    statCell(stats.headline)
                }
                .padding(.top, 8)
            }

            Spacer()

            VStack(spacing: 12) {
                Button { finish(saved: true) } label: {
                    Text("Done").font(.headline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(SnappetColor.workout)
                .accessibilityIdentifier("freeform.done")

                Button { onViewDetail(session) } label: {
                    Text("View detail").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("freeform.viewDetail")

                Button("Discard workout", role: .destructive) { showingDiscard = true }
                    .font(.footnote)
                    .accessibilityIdentifier("freeform.discard")
            }
            .padding(.horizontal)
        }
        .padding(.vertical)
        .celebrates(on: celebrationTrigger)
        .confirmationDialog("Discard this workout?", isPresented: $showingDiscard, titleVisibility: .visible) {
            Button("Discard (don't save)", role: .destructive) { finish(saved: false) }
            Button("Keep going", role: .cancel) { showingSummary = false }
        }
        .onAppear {
            doneBounce += 1
            if !doneMilestones.isEmpty { celebrationTrigger += 1 }
        }
    }

    private func statCell(_ stat: FreeformSummary.Stat) -> some View {
        VStack(spacing: 4) {
            Text(stat.value).font(.title2.bold().monospacedDigit()).contentTransition(.numericText())
            Text(stat.label).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Finish from the command bar: a logged session opens the completion summary (computing milestones
    /// against prior history first); an empty session just exits (discarded — nothing to celebrate).
    private func finishTapped() {
        guard session.completedSetCount > 0 else { finish(saved: false); return }
        doneMilestones = FreeformSummary.milestones(for: session, history: history)
        showingSummary = true
    }

    // MARK: - Mutations

    private func indexOf(_ ex: SessionExercise) -> Int? {
        session.exercises.firstIndex { $0.id == ex.id }
    }

    private func addLifting(_ exercises: [Exercise]) {
        for ex in exercises {
            session.exercises.append(SessionExercise(
                exerciseId: ex.id, targetSets: 0, targetReps: "", targetRestSeconds: 0,
                sets: [], displayName: nil, kindRaw: SetKind.repsWeight.rawValue))
        }
        persist()
        pushLiveActivity()   // the new exercise becomes the current one → refresh the Lock Screen label
    }

    private func addExercise(kind: SetKind, name: String) {
        session.exercises.append(SessionExercise(
            exerciseId: "adhoc-\(kind.rawValue)", targetSets: 0, targetReps: "", targetRestSeconds: 0,
            sets: [], displayName: name, kindRaw: kind.rawValue))
        persist()
        pushLiveActivity()
    }

    private func removeExercise(_ ex: SessionExercise) {
        guard let idx = indexOf(ex) else { return }
        session.exercises.remove(at: idx)
        persist()
        pushLiveActivity()   // the current (last) exercise may have changed
    }

    private func appendLog(_ log: SetLog, toExerciseID id: UUID) {
        guard let idx = session.exercises.firstIndex(where: { $0.id == id }) else { return }
        var entry = log
        entry.completedAt = .now
        session.exercises[idx].sets.append(entry)
        persist()
        pushLiveActivity()
        Haptics.success()
    }

    /// One-tap "Repeat set": append a copy of `ex`'s most recent set (all kind-specific fields via the
    /// pure `SetMeasure.duplicate`) WITHOUT opening `LogSetSheet`, then reuse the same append+persist+haptic
    /// path the sheet commits through — `appendLog` stamps the fresh `completedAt`. No-op when the exercise
    /// has no sets (the control is hidden in that case). (workout-with-timer PR 3)
    private func repeatLastSet(_ ex: SessionExercise) {
        guard let last = ex.sets.last else { return }
        appendLog(SetMeasure.duplicate(last), toExerciseID: ex.id)
    }

    private func deleteSets(_ ex: SessionExercise, at offsets: IndexSet) {
        guard let idx = indexOf(ex) else { return }
        session.exercises[idx].sets.remove(atOffsets: offsets)
        persist()
    }

    private func finish(saved: Bool) {
        onClose(saved && session.completedSetCount > 0)
    }

    private func persist() { try? context.save() }

    /// Cache the cross-session prefill per `exerciseId` once (history is fixed for the live session), so
    /// the ~1 Hz body re-render never re-scans history. (§B; the guided player caches the same way.)
    private func recomputePrefills() {
        var map: [String: LastSetLookup.LastTime] = [:]
        for ex in session.exercises where ex.kind == .repsWeight {
            guard map[ex.exerciseId] == nil else { continue }
            if let lastTime = LastSetLookup.lastTime(exerciseId: ex.exerciseId, history: history) {
                map[ex.exerciseId] = lastTime
            }
        }
        prefills = map
    }

    // MARK: - Live clips (§F)

    /// Discover clips filmed during the live session and auto-tag them to the set they fall in. Device
    /// -only: a no-op unless Photos is fully authorized (`canAutoDiscover`). Mirrors the post-session
    /// SessionDetailView path (discover → insert auto rows → reconcile) with the live window
    /// (`completedAt: nil` ⇒ "up to now").
    @MainActor private func discoverClips() async {
        guard app.sessionMedia.canAutoDiscover else { return }
        let sid = session.id
        let existing = (try? context.fetch(FetchDescriptor<SessionMedia>(
            predicate: #Predicate { $0.sessionID == sid }))) ?? []
        let existingIDs = Set(existing.map(\.localIdentifier))
        guard let found = try? await app.sessionMedia.discover(
            startedAt: session.startedAt, completedAt: nil, existingIdentifiers: existingIDs) else { return }
        for c in found {
            context.insert(SessionMedia(
                sessionID: sid, localIdentifier: c.localIdentifier, kind: c.kind,
                offsetSec: c.offsetSec, durationSec: c.durationSec, addedManually: false))
        }
        if !found.isEmpty { try? context.save() }
        reconcileAssignments()
    }

    /// Re-place ONLY the auto-assigned clips against the running set-completion timeline (sticky manual /
    /// general rows are never touched). The pure `SessionMediaAssignment` owns the clip→set mapping.
    @MainActor private func reconcileAssignments() {
        let sid = session.id
        let media = (try? context.fetch(FetchDescriptor<SessionMedia>(
            predicate: #Predicate { $0.sessionID == sid }))) ?? []
        let autoRows = media.filter { $0.assignmentSource == .auto }
        guard !autoRows.isEmpty else { return }
        let completions = SessionMediaAssignment.completions(from: session.exercises, startedAt: session.startedAt)
        guard !completions.isEmpty else { return }
        let assigned = SessionMediaAssignment.assign(
            clips: autoRows.map { .init(id: $0.id, offsetSec: $0.offsetSec) },
            completions: completions)
        var changed = false
        for row in autoRows {
            let ref = assigned[row.id]
            if row.assignedExerciseID != ref?.exerciseID || row.assignedSetIndex != ref?.setIndex {
                row.assignedExerciseID = ref?.exerciseID
                row.assignedSetIndex = ref?.setIndex
                changed = true
            }
        }
        if changed { try? context.save() }
    }

    // MARK: - Live Activity

    /// Push the current freeform state to the Live Activity so the Lock Screen / Dynamic Island show
    /// live HR, the exercise being worked (the most recently added), and the paused state — instead of
    /// the stale seed. The exercise label is the latest non-skipped exercise (a freeform logbook has no
    /// fixed cursor); `setProgress` stays empty since there's no "Set N of M" target. No-op where Live
    /// Activities are unavailable; the controller diffs/throttles so a ~1 Hz HR stream is rate-limited.
    private func pushLiveActivity() {
        let current = session.exercises.last { !$0.skipped }
        let name = current.map { resolver.name(for: $0.exerciseId, override: $0.displayName) } ?? "Workout"
        let profile = app.userProfile.profile
        let ready = RecoveryReadiness.evaluate(currentBpm: app.liveWorkout.latestHR,
                                               restBpm: profile.restingBound,
                                               maxBpm: profile.resolvedMaxHR).state == .ready
        app.liveActivity.update(WorkoutLiveSnapshot(
            startedAt: session.startedAt,
            hrBpm: app.liveWorkout.latestHR.map { Int($0.rounded()) },
            exerciseName: name,
            setProgress: "",
            paused: app.liveWorkout.isPaused,
            recoveryReady: ready))
    }

    // MARK: - Pause

    private var isPaused: Bool { app.liveWorkout.isPaused }
    private func togglePause() {
        if isPaused { app.liveWorkout.resume() } else { app.liveWorkout.pause() }
        Haptics.tap()
    }
}

/// Which exercise a new set/attempt is being logged into (drives the `LogSetSheet`). Carries the
/// catalog `exerciseId` too so the sheet can pull the cross-session prefill for that exercise. (§B)
private struct LogTarget: Identifiable {
    let exerciseID: UUID
    let kind: SetKind
    let exerciseId: String
    var id: UUID { exerciseID }
}

/// Inline-editable climb name (§C): replaces the blocking "Name this climb" alert. Seeds from the
/// climb's current `displayName`, commits on return/blur through `SetMeasure.climbName` (trim, blank →
/// "Climbing"). A leaf TextField with its own id (`freeform.climbName`) so it's directly queryable.
private struct ClimbNameHeader: View {
    let onCommit: (String) -> Void
    @State private var draft: String
    @FocusState private var focused: Bool

    init(initialName: String, onCommit: @escaping (String) -> Void) {
        self.onCommit = onCommit
        _draft = State(initialValue: initialName)
    }

    var body: some View {
        TextField("Climb name", text: $draft)
            .font(.headline)
            .focused($focused)
            .submitLabel(.done)
            .onSubmit(commit)
            .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
            .accessibilityIdentifier("freeform.climbName")
    }

    private func commit() {
        let normalized = SetMeasure.climbName(draft)
        draft = normalized
        onCommit(normalized)
    }
}

/// Keyboard-free inline quick-add for reps & weight (§B): `[−] value [+]` steppers + a one-tap Log that
/// funnels through `appendLog`. Custom leaf `+`/`−` buttons (not a native `Stepper`) so each control has
/// its own queryable accessibilityIdentifier (`freeform.quickReps.plus`, …) and the value text carries
/// the base id — the leaf-only a11y rule. Its own `@State` (re-seeded by the parent's `.id(ex.sets.count)`)
/// so adjusting once and tapping Log repeatedly logs a quick loop without the keyboard. The Log button
/// label stays plain ("Log set") so it never collides with a set row's value text in tests.
private struct QuickAddRow: View {
    let onLog: (SetLog) -> Void
    let hint: String?
    @State private var reps: Int
    @State private var weight: Double
    @State private var unitSel: WeightUnit

    init(reps: Int, weight: Double, unitSel: WeightUnit, hint: String?,
         onLog: @escaping (SetLog) -> Void) {
        self.hint = hint
        self.onLog = onLog
        _reps = State(initialValue: max(0, reps))
        _weight = State(initialValue: max(0, weight))
        _unitSel = State(initialValue: unitSel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let hint {
                Text(hint).font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("lastTimeHint")
            }
            stepper(idBase: "freeform.quickReps", label: "Reps", value: "\(reps)",
                    dec: { reps = max(0, reps - 1) }, inc: { reps = min(999, reps + 1) })
            stepper(idBase: "freeform.quickWeight", label: "Weight",
                    value: weight > 0 ? "\(SetMeasure.formatWeight(weight)) \(unitSel.display)" : "Body",
                    dec: { weight = max(0, weight - 2.5) }, inc: { weight = min(2000, weight + 2.5) })
            Button {
                onLog(SetLog(actualReps: reps > 0 ? reps : nil,
                             actualWeight: weight > 0 ? weight : nil,
                             weightUnit: unitSel))
            } label: {
                Label("Log set", systemImage: "bolt.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(SnappetColor.workout)
            .accessibilityIdentifier("freeform.quickLog")
        }
        .padding(.vertical, 4)
    }

    private func stepper(idBase: String, label: String, value: String,
                         dec: @escaping () -> Void, inc: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            Spacer(minLength: 0)
            Button(action: dec) { Image(systemName: "minus.circle.fill").font(.title3) }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("\(idBase).minus")
                .accessibilityLabel("Decrease \(label.lowercased())")
            Text(value).font(.subheadline.weight(.semibold).monospacedDigit())
                .frame(minWidth: 80)
                .accessibilityIdentifier(idBase)
            Button(action: inc) { Image(systemName: "plus.circle.fill").font(.title3) }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("\(idBase).plus")
                .accessibilityLabel("Increase \(label.lowercased())")
        }
    }
}

/// How a `.duration` set's seconds are entered: time it live with the stopwatch (default), or type
/// minutes/seconds. Both write the same `minutes`/`seconds` state the save path reads. (workout-with-timer PR 2)
private enum DurationInputMode: String, CaseIterable, Identifiable {
    case timer, manual
    var id: String { rawValue }
    var label: String {
        switch self {
        case .timer: return "Timer"
        case .manual: return "Manual"
        }
    }
}

/// A focused sheet to log one set/attempt, with fields that adapt to the exercise's `SetKind`. Builds a
/// `SetLog` and hands it back; the player stamps `completedAt` and appends it.
private struct LogSetSheet: View {
    let kind: SetKind
    let unit: WeightUnit
    let onAdd: (SetLog) -> Void

    @Environment(\.dismiss) private var dismiss

    // reps & weight
    @State private var reps = ""
    @State private var weight = ""
    @State private var unitSel: WeightUnit
    // duration — Timer (live `StopwatchView`) or Manual (Min/Sec fields); a Stop capture fills the same
    // `minutes`/`seconds` the Manual fields write, so `build()` stays one expression. (workout-with-timer PR 2)
    @State private var durationMode: DurationInputMode = .timer
    @State private var timerRunning = false
    @State private var minutes = ""
    @State private var seconds = ""
    // climb
    @State private var grade = ""
    @State private var status: KilterAscentStatus = .sent
    @State private var tries = 1
    // climb — OPTIONAL per-attempt timer (workout-with-timer PR 4): off by default so quick logging is
    // unchanged. When on, a StopwatchView(.countUp) Stop capture fills `climbDurationSec`, which `build()`
    // writes into the (otherwise-unused-for-climbs) SetLog.durationSec. `climbTimerRunning` gates the
    // disclosure toggle while running so it can't be collapsed mid-run (tearing down the timer without a
    // Stop, silently dropping the capture — the timed-set lesson).
    @State private var climbTimed = false
    @State private var climbTimerRunning = false
    @State private var climbDurationSec: Double?

    init(kind: SetKind, unit: WeightUnit, prefill: LastSetLookup.LastTime?,
         onAdd: @escaping (SetLog) -> Void) {
        self.kind = kind
        self.unit = unit
        self.onAdd = onAdd
        // Prefill the reps/weight/unit from the last time this exercise was done (§B) so the "log
        // something different" sheet opens on the user's last values to tweak, not blank.
        _unitSel = State(initialValue: prefill?.unit ?? unit)
        _reps = State(initialValue: prefill?.reps.map(String.init) ?? "")
        _weight = State(initialValue: prefill?.weight.map(SetMeasure.formatWeight) ?? "")
    }

    @FocusState private var keypadFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                switch kind {
                case .repsWeight:
                    TextField("Reps", text: $reps).keyboardType(.numberPad)
                        .focused($keypadFocused)
                        .accessibilityIdentifier("logset.reps")
                    HStack {
                        TextField("Weight", text: $weight).keyboardType(.decimalPad)
                            .focused($keypadFocused)
                            .accessibilityIdentifier("logset.weight")
                        Picker("Unit", selection: $unitSel) {
                            ForEach(WeightUnit.allCases) { Text($0.display).tag($0) }
                        }
                        .pickerStyle(.segmented).frame(width: 110).labelsHidden()
                    }
                case .duration:
                    Picker("Input", selection: $durationMode) {
                        ForEach(DurationInputMode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    // Lock the mode while the stopwatch runs: switching to Manual would remove the
                    // StopwatchView, whose onDisappear cancels the ticker without a Stop — silently
                    // dropping the capture. The user must Stop first (onStop fills Min/Sec).
                    .disabled(timerRunning)
                    .accessibilityIdentifier("logset.durationMode")
                    switch durationMode {
                    case .timer:
                        // Press Start → do the hold → Stop captures the elapsed seconds into the same
                        // minutes/seconds the save path reads (PR 1's StopwatchView, first real consumer).
                        StopwatchView(mode: .countUp) { elapsed in
                            let split = SetMeasure.splitDuration(elapsed)
                            minutes = split.minutes
                            seconds = split.seconds
                        } onRunningChange: { timerRunning = $0 }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        // NOTE: no .accessibilityIdentifier on the StopwatchView itself — on iOS 26 that
                        // collapses the composite view into one accessibility element and hides its inner
                        // `stopwatch.toggle` button from XCUITest. The test queries the child ids directly.
                    case .manual:
                        HStack {
                            TextField("Min", text: $minutes).keyboardType(.numberPad)
                                .focused($keypadFocused)
                            Text(":").foregroundStyle(.secondary)
                            TextField("Sec", text: $seconds).keyboardType(.numberPad)
                                .focused($keypadFocused)
                        }
                        .accessibilityIdentifier("logset.duration")
                    }
                case .climbAttempt:
                    TextField("Grade (e.g. V4, 6c)", text: $grade)
                        .accessibilityIdentifier("logset.grade")
                    Picker("Outcome", selection: $status) {
                        ForEach(KilterAscentStatus.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Stepper("Attempts: \(tries)", value: $tries, in: 1...50)
                    // Optional: time how long the attempt took (the climb-side analogue of the timed-set
                    // timer, PR 2). Off by default → existing quick-logging is unchanged; the leaf Toggle
                    // is locked while the stopwatch runs so it can't tear the timer down without a Stop.
                    Toggle("Time the attempt", isOn: $climbTimed)
                        .disabled(climbTimerRunning)
                        .accessibilityIdentifier("logset.climbTimerToggle")
                    if climbTimed {
                        // Stop captures the elapsed seconds into `climbDurationSec`, which `build()` writes
                        // into SetLog.durationSec (the count-up StopwatchView from PR 1; same consumer
                        // shape as the timed-set Timer mode). NOTE: no .accessibilityIdentifier on the
                        // StopwatchView itself — on iOS 26 that collapses the composite into one element
                        // and hides its inner `stopwatch.toggle`; the test queries the child ids directly.
                        StopwatchView(mode: .countUp) { elapsed in
                            climbDurationSec = elapsed > 0 ? elapsed : nil
                        } onRunningChange: { climbTimerRunning = $0 }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle(kind.addLabel)
            .keypadDoneToolbar($keypadFocused)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { onAdd(build()); dismiss() }
                        .disabled(!SetMeasure.hasInput(build(), kind: kind))
                        .accessibilityIdentifier("logset.add")
                }
            }
            .presentationDetents([.medium])
        }
    }

    private func build() -> SetLog {
        switch kind {
        case .repsWeight:
            return SetLog(actualReps: Int(reps.trimmingCharacters(in: .whitespaces)),
                          actualWeight: Double(weight.replacingOccurrences(of: ",", with: ".")
                            .trimmingCharacters(in: .whitespaces)),
                          weightUnit: unitSel)
        case .duration:
            let total = (Double(minutes) ?? 0) * 60 + (Double(seconds) ?? 0)
            return SetLog(durationSec: total > 0 ? total : nil)
        case .climbAttempt:
            let g = grade.trimmingCharacters(in: .whitespaces)
            // Reuse `durationSec` for the optional per-attempt time (PR 4): nil unless the timer was used
            // and captured a non-zero hold, so untimed attempts log exactly as before.
            return SetLog(durationSec: climbTimed ? climbDurationSec : nil,
                          climbGradeLabel: g.isEmpty ? nil : g,
                          climbStatusRaw: status.rawValue, climbAttempts: tries)
        }
    }
}
