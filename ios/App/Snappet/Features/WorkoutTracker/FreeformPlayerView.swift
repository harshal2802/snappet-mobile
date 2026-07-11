import SwiftUI
import SwiftData
import HighlightEngine

/// The **single** session player — for every session, routine and freeform alike. A grow-as-you-go
/// pager: swipe between exercises, add exercises and sets/attempts on the fly, of any `SetKind` (reps &
/// weight, timed, or climb attempts). A saved routine is rendered from the same model with its
/// prescription seeded in — the planned count from `targetSets` (`QuickSessionPager.plannedCount`),
/// reps/weight from `targetReps`/`targetWeight` (`quickAddSeed`), rest from `targetRestSeconds`
/// (`startRest`), climb grade from the entity-level `climbGradeLabel` — so a routine plays like Quick
/// Session and stays expandable. (dynamic-sessions D3/D5; canvas rework in issue #158; the guided
/// set-by-set `WorkoutPlayerView` was retired in the routine-in-pager convergence.)
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
    @Environment(\.scenePhase) private var scenePhase
    /// Photos library access for the deep-tap "Delete from Photos too" path (prompt 11) — the same
    /// stateless `Sendable` service `SessionDetailView` uses for its deletion confirmation.
    private let mediaLibrary = MediaLibraryService()

    @State private var pickingLift = false
    @State private var logging: LogTarget?
    @State private var showingAddMenu = false
    /// The "Add a climb" sheet (Quick Session redesign Phase 1): the climb-first entry point both the
    /// empty-state Climbing card and the add-menu's Climbing button now present.
    @State private var addingClimb = false
    /// The climb being EDITED (prompt 09): when set, the same `AddClimbSheet` opens PREFILLED in edit mode
    /// and Save overwrites that climb's fields in place (no duplicate). `nil` ⇒ no edit in flight.
    @State private var editingClimb: EditClimbTarget?
    /// The strength exercise an "Edit details" sheet is open for (Workout-Type Parity, strength polish).
    @State private var editingStrength: EditStrengthTarget?
    /// The "Pick or create a timed exercise" sheet (Quick Session redesign Phase 5): the timed-first
    /// entry point both the empty-state Timed card and the add-menu's "Timed exercise" button now present.
    @State private var addingTimed = false
    // MARK: Pager state (prompt 109)
    /// The current pager page — overview · one page per exercise (added order) · the add page.
    /// Simple value state; the pages themselves are light (no players), so the Clips-feed
    /// re-render hazard doesn't apply.
    @State private var page: QuickSessionPager.Page = .overview
    /// Whether the initial landing page was chosen (empty session → add page; resumed → last exercise).
    @State private var pagedIn = false
    /// The exercise a plan-editor sheet is open for.
    @State private var planEditing: PlanEditTarget?
    /// The exercise a history drawer is open for.
    @State private var historyFor: HistoryTarget?
    /// The catalog exercise a guide (photos + how-to) drawer is open for.
    @State private var guideFor: GuideTarget?
    /// The exercise whose page shows the rest-morph hero while a rest runs (set by `startRest`).
    @State private var restExerciseID: UUID?
    /// The armed rest total, for the rest ring's progress fraction.
    @State private var restTotalSec: TimeInterval = 0
    /// Clips recorded from the page-level record button, keyed by the exercise whose page the
    /// recorder was opened on (the record-time owner). Keyed — not a single shared array — because
    /// the Photos save is async: the user can swipe pages before the append lands, and the clip
    /// must still attach to the exercise it was filmed for, never the page that happens to be
    /// current (#273).
    @State private var pageClips: [UUID: [RecordedClip]] = [:]
    @State private var savingPageClip = false
    /// The climb a minimal timed-attempt sheet is open for (Phase 2 replaces this with a FOCUS cover).
    @State private var timingAttemptFor: TimedAttemptTarget?
    /// The strength/generic exercise a "Time this set" FOCUS cover is open for (Workout-Type Parity P3).
    @State private var timingSetFor: TimedSetTarget?
    /// The running entity a "Log a leg" sheet is open for (Workout-Type Parity P4).
    @State private var loggingRunLeg: RunLegTarget?
    /// The structured timed exercise the interval runner cover is open for (Quick Session redesign Phase 6):
    /// a `.repeaters` / `.tabata` / `.emom` spec runs the full-cover `StructuredTimedRunner` instead of the
    /// simple `LogSetSheet` stopwatch. `nil` when no runner is open.
    @State private var runningInterval: IntervalRunTarget?
    /// Cross-session prefill per exerciseId, cached so the ~1 Hz body re-render never re-scans history
    /// (history is fixed for the live session). Recomputed on appear + when an exercise is added. (§B)
    @State private var prefills: [String: LastSetLookup.LastTime] = [:]
    /// Post-workout completion moment (§D): Finish switches the cover to a summary screen (in-cover, not a
    /// push — avoids the push-vs-cover wedge `SessionRoute` exists for). The milestones drive the burst.
    @State private var showingSummary = false
    @State private var doneMilestones: [FreeformSummary.Milestone] = []
    /// The expandable live-metrics & recovery panel (§E), opened from the command-bar HR chip.
    @State private var showingMetrics = false
    /// The expanded live climbing-stats sheet (Phase 3), opened from the stat ribbon.
    @State private var showingClimbStats = false
    /// Cached climbing stats for the docked ribbon, recomputed on `session.exercises` change (like
    /// `prefills`) so the ~1 Hz body re-render never re-derives the pyramid. (Phase 3)
    @State private var climbStats: KilterSessionStats?
    /// The user's distinct previously-logged climbs (history + this session), built for the "Add a climb"
    /// sheet's one-tap re-log picker. Cached + recomputed alongside `climbStats` (on appear / exercises
    /// change) so the ~1 Hz body re-render never re-scans history or `SessionMedia`. (prompt 81)
    @State private var previousClimbs: [PreviousClimb] = []
    /// Milestones already celebrated **this session** (by a stable string key), so the at-logging
    /// celebration fires once per genuine new best — never on every attempt. (Phase 3 §3)
    @State private var celebratedMilestones: Set<String> = []
    /// The headline of the most recent at-logging milestone — shown briefly as a banner; its
    /// `.celebrates(on:)` trigger is `milestoneTrigger`. (Phase 3 §3)
    @State private var liveMilestoneHeadline: String?
    @State private var milestoneTrigger = 0
    /// A freeform clip opened in the shared Studio editor (§G).
    @State private var studioClip: FreeformStudioPresentation?
    /// A clip the user asked to permanently delete via the attempt-strip deep-tap menu (prompt 11) — drives
    /// the single Photos-aware confirmation hosted on this view (ported from `SessionDetailView`). `nil` ⇒
    /// no deletion in flight.
    @State private var pendingClipDeletion: SessionMedia?

    // MARK: Remembered rest timer (Phase 7)
    /// Opt-in: when on, completing an attempt/set auto-starts a count-down rest in the command bar.
    /// Off by default so existing logging is unchanged; toggled from the rest chip's menu.
    @AppStorage("freeform.restAutoStart") private var restAutoStart = false
    /// The per-context remembered rest durations, as a JSON `[contextKey: seconds]` blob (the only thing
    /// `@AppStorage` can hold) — decoded/encoded through the pure `RestTimerDefaults`.
    @AppStorage(RestTimerDefaults.storageKey) private var restDefaultsJSON = "{}"
    /// The live rest count-down (reused `StopwatchViewModel(.countDown)` + the at-zero `Haptics`). Held
    /// for the player's lifetime; armed + started per rest, non-blocking in the command bar.
    @State private var restTimer = StopwatchViewModel(mode: .countDown(targetSec: 120))
    /// The context the active rest belongs to (so its length is remembered back to the right bucket).
    @State private var restContext: RestTimerDefaults.Context?
    /// Whether a rest count-down is currently shown in the command bar.
    @State private var restRunning = false

    private var unit: WeightUnit { defaultUnit }
    /// Distance unit for the running discipline (Workout-Type Parity), derived from the weight-unit
    /// preference (lb users → miles). A dedicated km/mi toggle is a later refinement.
    private var distanceUnit: DistanceUnit { unit == .lb ? .mi : .km }

    /// The decoded remembered-rest map.
    private var restDefaults: [String: Int] { RestTimerDefaults.decode(restDefaultsJSON) }

    var body: some View {
        if showingSummary {
            doneScreen
        } else {
            loggingContent
        }
    }

    private var loggingContent: some View {
        pagerShell
        // The pager is a dark-glass full-screen moment like the FOCUS covers (the approved wireframes
        // are dark-glass; light surfaces stay light everywhere else in the app).
        .preferredColorScheme(.dark)
        .celebrates(on: milestoneTrigger)
        .interactiveDismissDisabled()
        .sheet(isPresented: $pickingLift) {
            ExercisePickerView(resolver: resolver) { picked in addLifting(picked) }
        }
        .sheet(item: $logging) { target in
            LogSetSheet(kind: target.kind, unit: unit, prefill: prefills[target.exerciseId],
                        timedSpec: target.timedSpec) { log in
                appendLog(log, toExerciseID: target.exerciseID)
            }
        }
        .sheet(isPresented: $showingMetrics) {
            LiveMetricsPanel(session: session)
        }
        // The expanded live climbing-stats sheet (Phase 3), presented from the stat ribbon.
        .sheet(isPresented: $showingClimbStats) {
            LiveClimbStatsSheet(session: session, maxHR: zoneMaxHR)
        }
        // Quick Session redesign Phase 1: tapping Climbing opens the climb-first "Add a climb" sheet
        // (type → scale-aware grade → name → gym) instead of dropping a bare attempt row.
        .sheet(isPresented: $addingClimb) {
            AddClimbSheet(inheritedGym: lastClimbGym, previousClimbs: previousClimbs) { params, logFirst in
                addClimbFromSheet(params, logFirstAttempt: logFirst)
            }
        }
        // Edit a climb's details (prompt 09): the same sheet PREFILLED from the climb, with a single "Save"
        // that overwrites that `SessionExercise`'s climb fields in place (attempts preserved, no duplicate).
        .sheet(item: $editingClimb) { target in
            AddClimbSheet(inheritedGym: lastClimbGym, initial: target.initial) { params, _ in
                updateClimb(target.exerciseID, params)
            }
        }
        // Strength "Edit details" (Workout-Type Parity polish): rename + set the default sets×reps×weight
        // (seeds the quick-add); the hybrid-add payoff after a fast bulk pick, reused for later edits.
        .sheet(item: $editingStrength) { target in
            StrengthEditSheet(catalogName: target.catalogName, initial: target.initial,
                              lastReps: target.lastReps, lastWeight: target.lastWeight,
                              lastUnit: target.lastUnit) { params in
                updateStrength(target.exerciseID, params)
            }
        }
        // Quick Session redesign Phase 5: tapping Timed opens the pick-or-create sheet (searchable catalog
        // · Create new · recents · seeded suggestions) instead of dropping a bare, unnamed timed row.
        .sheet(isPresented: $addingTimed) {
            PickTimedExerciseSheet { params in addTimedFromSheet(params) }
        }
        // The live timed-attempt FOCUS cover (Quick Session redesign Phase 2): a dark, glass, full-screen
        // moment that times ONE attempt off the wall clock, then reveals a 2×2 outcome grid. Replaces the
        // old half-sheet; commits through the same `logAttempt` funnel (stamps grade + completedAt + haptic).
        .fullScreenCover(item: $timingAttemptFor) { target in
            let climb = session.exercises.first { $0.id == target.exerciseID }
            TimedAttemptCover(
                climbName: resolver.name(for: climb?.exerciseId ?? "", override: climb?.displayName),
                climbType: target.type,
                gradeLabel: climb?.climbGradeLabel,
                attemptNumber: (climb?.sets.count ?? 0) + 1) { status, duration, clips in
                    // Capture the attempt's landing index before logAttempt appends, so recorded clips
                    // attach to exactly this attempt.
                    let setIndex = session.exercises.first { $0.id == target.exerciseID }?.sets.count ?? 0
                    logAttempt(toExerciseID: target.exerciseID, status: status, durationSec: duration)
                    attachRecordedClips(clips, toExerciseID: target.exerciseID, setIndex: setIndex)
                }
        }
        // "Time this set" FOCUS cover (Workout-Type Parity Phase 3): times a strength/generic set off the
        // wall clock and commits a SetLog carrying reps × weight AND the captured duration → the combined
        // "8 × 60 kg · 0:42" row. Same `appendLog` funnel + count-up StopwatchViewModel as the climb cover.
        .fullScreenCover(item: $timingSetFor) { target in
            let ex = session.exercises.first { $0.id == target.exerciseID }
            TimedSetCover(
                exerciseName: resolver.name(for: ex?.exerciseId ?? "", override: ex?.displayName),
                initialReps: target.reps, initialWeight: target.weight, initialUnit: target.unit) { reps, weight, unit, duration, clips in
                    // Don't log a completely-empty effort (instant STOP with reps/weight zeroed) — that
                    // would render a meaningless "—" row. A recorded clip counts as content, so a set is
                    // logged to host it (in practice the timer ran while recording → duration > 0).
                    guard reps != nil || weight != nil || duration > 0 || !clips.isEmpty else { return }
                    // The set lands at the exercise's current end index — capture it before the append so the
                    // recorded clips attach to exactly that set.
                    let setIndex = session.exercises.first { $0.id == target.exerciseID }?.sets.count ?? 0
                    appendLog(SetLog(actualReps: reps, actualWeight: weight, weightUnit: unit,
                                     durationSec: duration > 0 ? duration : nil),
                              toExerciseID: target.exerciseID)
                    attachRecordedClips(clips, toExerciseID: target.exerciseID, setIndex: setIndex)
                }
        }
        // "Log a leg" sheet (Workout-Type Parity Phase 4): manual distance + duration → a SetLog carrying
        // distanceMeters + durationSec (pace derived in the row via SetMeasure.runSummary).
        .sheet(item: $loggingRunLeg) { target in
            AddRunLegSheet(unit: distanceUnit) { meters, duration in
                appendLog(SetLog(durationSec: duration > 0 ? duration : nil, distanceMeters: meters),
                          toExerciseID: target.exerciseID)
            }
        }
        // The structured interval runner cover (Quick Session redesign Phase 6): a repeaters/tabata/emom
        // timed exercise runs its `IntervalSchedule` full-screen (lead-in → WORK/REST phases → capture
        // card). "Log set" commits a `SetLog(durationSec: TUT)` through the same `appendLog` funnel.
        .fullScreenCover(item: $runningInterval) { target in
            StructuredTimedRunner(exerciseName: target.name, spec: target.spec) { setLog in
                appendLog(setLog, toExerciseID: target.exerciseID)
            }
        }
        // Tap a freeform clip → the shared scoped Studio editor (§G). Hosted on the (stable) logging
        // screen — the cover must not live inside a re-rendering subview or it collapses on a clip tap.
        // The editor loads HR once on open and falls back to the live watch+BLE buffer for a still-live
        // session, so a clip opened mid-workout keeps its heart-rate overlay.
        .fullScreenCover(item: $studioClip) { p in
            StudioEditorView(project: p.project, context: context,
                             focusClipMediaID: p.focusClipMediaID, visibleClipMediaIDs: p.visibleClipMediaIDs,
                             suggestedClimbCaption: p.climbCaption,
                             suggestedAttemptNumber: p.suggestedAttemptNumber)
        }
        // Add-exercise options (§A). The button titles are the labels the freeform UITests drive.
        .confirmationDialog("Add exercise", isPresented: $showingAddMenu, titleVisibility: .visible) {
            Button("Lifting exercise") { pickingLift = true }
            Button("Climbing") { rebuildPreviousClimbs(); addingClimb = true }
            Button("Running") { addRun() }
            Button("Timed exercise") { addingTimed = true }
            Button("Dance") { addOpenEffort(.dance) }
            Button("Other") { addOpenEffort(.other) }
            Button("Cancel", role: .cancel) {}
        }
        // Deep-tap clip deletion (prompt 11), ported VERBATIM from `SessionDetailView` (incl. the Photos
        // wording): "Remove from attempt only" untie it to General (keeps the file); "Delete from Photos
        // too" permanently removes the underlying asset (iOS then asks once more). Hosted here on the
        // (stable) logging screen so the dialog survives the climb cards' re-renders.
        .confirmationDialog(
            "Delete this \(pendingClipDeletion?.kind == .video ? "video" : "photo")?",
            isPresented: Binding(get: { pendingClipDeletion != nil },
                                 set: { if !$0 { pendingClipDeletion = nil } }),
            titleVisibility: .visible, presenting: pendingClipDeletion
        ) { item in
            Button("Remove from attempt only") { reassignClip(item, to: nil, set: nil) }
            Button("Delete from Photos too", role: .destructive) { deleteClipFromPhotos(item) }
                .accessibilityIdentifier("freeform.clipDeleteConfirm")
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("“Remove from session” keeps the video in your Photos library. “Delete from Photos” permanently removes it (iOS will ask once more).")
        }
        // The plan-editor sheet (prompt 109): tapping "of N" / the plan row sets the target; Save
        // writes `plannedSets` in place. Defaults to last session's set count for this exercise.
        .sheet(item: $planEditing) { target in
            if let ex = session.exercises.first(where: { $0.id == target.exerciseID }) {
                PlanEditorSheet(
                    noun: QuickSessionPager.effortNoun(for: ex),
                    // Seed from the unified plan count so a routine's prescribed `targetSets` pre-fills
                    // the editor; saving writes `plannedSets`, which then takes precedence (user override).
                    initial: QuickSessionPager.plannedCount(for: ex),
                    lastTime: QuickSessionPager.defaultPlan(exerciseId: ex.exerciseId,
                                                            displayName: ex.displayName,
                                                            history: history),
                    onSave: { setPlan(target.exerciseID, $0) })
            }
        }
        // The history drawer (prompt 109): the full ledger with per-set deltas vs the previous
        // session + swipe-to-delete — the density the old expanding cards had, now opt-in.
        .sheet(item: $historyFor) { target in
            if let ex = session.exercises.first(where: { $0.id == target.exerciseID }) {
                HistoryDrawerView(
                    exerciseName: resolver.name(for: ex.exerciseId, override: ex.displayName),
                    rows: drawerRows(ex),
                    aggregate: nil,
                    hasComparison: drawerRows(ex).contains { $0.delta != nil },
                    onDelete: { deleteSets(ex, at: $0) })
            }
        }
        // The guide drawer (prompt 109): the ⓘ next to a catalog exercise's name — guide photos
        // (prompt 108 pack) + the first how-to steps, without leaving the set.
        .sheet(item: $guideFor) { target in
            GuideDrawer(exercise: target.exercise)
        }
        .onAppear {
            app.workoutNotifications.requestAuthorization()
            recomputePrefills()
            recomputeClimbStats()
            rebuildPreviousClimbs()
            pushLiveActivity()
            // The rest ticker is torn down whenever this screen disappears (a full-screen cover, the
            // finish summary's Keep going); a rest that survived that must restart its display refresh
            // or the ring/dock chip freezes at the last shown second.
            restTimer.resumeTicking()
            // Land somewhere useful once per presentation: an empty session opens on the add page
            // (the type chooser IS the empty state); otherwise the first **unfinished** exercise — so a
            // freshly-started routine opens on exercise 1 (not its last), and a resumed session lands on
            // what's still owed. Falls back to the last exercise when everything's already done. (Mirrors
            // the retired guided player's `resumePosition`.)
            if !pagedIn {
                pagedIn = true
                let landing = session.exercises.first(where: QuickSessionPager.isUnfinished)
                    ?? session.exercises.last
                page = landing.map { .exercise($0.id) } ?? .add
            }
        }
        .onChange(of: session.exercises.count) { old, new in
            recomputePrefills()
            recomputeClimbStats()
            rebuildPreviousClimbs()
            // Auto-advance the pager to a newly added exercise so its hero is immediately loggable.
            if new > old, let last = session.exercises.last {
                withAnimation { page = .exercise(last.id) }
            }
            // Removing the exercise whose page we're on strands the tag — fall back to overview.
            if case .exercise(let id) = page, !session.exercises.contains(where: { $0.id == id }) {
                withAnimation { page = .overview }
            }
        }
        // Clips recorded from a page's record button attach to the exercise whose page they were
        // RECORDED on — the key they were queued under — never the page that's current when the
        // async Photos save lands (#273: swiping during the save used to re-pin the clip .manual
        // to the wrong exercise, or discard it on the overview/add page). The pure plan routes a
        // deleted owner's clips to the session unassigned; a queued clip is never dropped.
        .onChange(of: pageClips) { _, queued in
            let plan = QuickSessionPager.pageClipAttachPlan(
                queued: queued, liveExerciseIDs: Set(session.exercises.map(\.id)))
            guard !plan.isEmpty else { return }
            pageClips = [:]
            for group in plan {
                attachRecordedClips(group.clips, toExerciseID: group.exerciseID, setIndex: nil)
            }
        }
        // Keep the Live Activity (Lock Screen / Dynamic Island) in sync with the freeform session:
        // live HR and the paused state push as they change. The overall timer self-ticks off
        // `startedAt`; these refresh HR + the exercise line + the paused flag.
        .onChange(of: app.liveWorkout.latestHR) { _, _ in pushLiveActivity() }
        .onChange(of: app.liveWorkout.isPaused) { _, _ in pushLiveActivity() }
        // Keep the rest count-down correct across backgrounding (it's wall-clock-backed; this just nudges
        // an immediate refresh + the at-zero haptic on return) and tear its ticker down on disappear.
        .onChange(of: scenePhase) { _, phase in if phase == .active { restTimer.syncToWallClock() } }
        .onDisappear { restTimer.endTicking() }
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

    // MARK: - Pager shell & chrome (prompt 109)

    /// The full-screen pager: ambient discipline-tinted backdrop · glass nav · the exercise rail
    /// (the page indicator) · one page per exercise · glass dock. Replaces the old scrolling List.
    private var pagerShell: some View {
        ZStack {
            ambientBackground
            VStack(spacing: 0) {
                glassNav
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                PagerRailView(
                    chips: QuickSessionPager.railChips(for: session.exercises) { ex in
                        resolver.name(for: ex.exerciseId, override: ex.displayName)
                    },
                    current: page,
                    tint: railTint,
                    onTap: { target in withAnimation { page = target } })
                    .padding(.top, 10)
                pagerPages
                glassDock
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
        }
        // At-logging milestone banner (Phase 3 §3), unchanged: a brief glass headline for a genuine
        // new best; the burst + haptic fire via the screen-level `.celebrates(on:)`.
        .overlay(alignment: .top) { milestoneBanner }
    }

    /// The paged content. Pages are light (forms — no players), so plain selection state is safe
    /// here (the Clips-feed re-render hazard was about AVPlayer feeds).
    private var pagerPages: some View {
        TabView(selection: $page) {
            overviewPage
                .tag(QuickSessionPager.Page.overview)
            ForEach(session.exercises) { ex in
                exercisePage(ex)
                    .tag(QuickSessionPager.Page.exercise(ex.id))
            }
            AddExercisePage(
                onLifting: { pickingLift = true },
                onClimbing: { rebuildPreviousClimbs(); addingClimb = true },
                onRunning: { addRun() },
                onTimed: { addingTimed = true },
                onDance: { addOpenEffort(.dance) },
                onOther: { addOpenEffort(.other) })
                .tag(QuickSessionPager.Page.add)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    /// The soft ambient tint behind everything — follows the current page's discipline accent so
    /// swiping into climbing "feels amber" (wayfinding, per the two-axis color contract).
    private var ambientBackground: some View {
        ZStack {
            SnappetColor.paper.ignoresSafeArea()
            RadialGradient(colors: [currentAccent.opacity(0.16), .clear],
                           center: UnitPoint(x: 0.85, y: -0.05), startRadius: 0, endRadius: 440)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.4), value: currentAccent)
        }
    }

    /// The current page's discipline accent (climbs use the Kilter amber like their grade pill).
    private var currentAccent: Color {
        if case .exercise(let id) = page,
           let ex = session.exercises.first(where: { $0.id == id }) {
            return ex.discipline == .climb ? SnappetColor.kilter : ex.discipline.accent
        }
        return SnappetColor.workout
    }

    private func railTint(_ chip: QuickSessionPager.RailChip) -> Color {
        if case .exercise(let id) = chip.page,
           let ex = session.exercises.first(where: { $0.id == id }) {
            return ex.discipline == .climb ? SnappetColor.kilter : ex.discipline.accent
        }
        return chip.page == .add ? SnappetColor.brand : SnappetColor.workout
    }

    /// The floating glass nav: minimize ⌄ · session title + live elapsed/HR line · the Finish pill.
    private var glassNav: some View {
        HStack(spacing: 10) {
            Button { onMinimize() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("minimizeWorkout")
            .accessibilityLabel("Minimize")
            Spacer(minLength: 4)
            VStack(spacing: 1) {
                Text(session.routineName)
                    .font(.subheadline.weight(.bold)).lineLimit(1)
                HStack(spacing: 5) {
                    if isPaused {
                        Image(systemName: "pause.fill").font(.system(size: 9)).foregroundStyle(.yellow)
                    }
                    Text(timerInterval: session.startedAt...Date.distantFuture, countsDown: false)
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(SnappetColor.textSecondary)
                        .accessibilityIdentifier("overallWorkoutTimer")
                    if let bpm = app.liveWorkout.latestHR {
                        Text("· ♥ \(Int(bpm.rounded()))")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(SnappetColor.textSecondary)
                    }
                }
            }
            Spacer(minLength: 4)
            Button { finishTapped() } label: {
                Text("Finish")
                    .font(.subheadline.weight(.bold))
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(.white.opacity(0.1), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("freeform.finish")
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .pagerGlass(cornerRadius: 24)
    }

    /// The glass dock: live-HR chip (→ metrics panel) · rest countdown while resting · the auto-rest
    /// toggle · pause · add-exercise (the dialog anchor the UITests drive).
    private var glassDock: some View {
        HStack(spacing: 10) {
            hrChip
            if restRunning, let remaining = restTimer.reading.remaining {
                HStack(spacing: 4) {
                    Image(systemName: "hourglass").font(.caption2)
                    Text(SetMeasure.formatDuration(remaining))
                        .font(.caption.weight(.bold).monospacedDigit())
                        .contentTransition(.numericText())
                }
                .foregroundStyle(SnappetColor.perfFresh)
            }
            Spacer(minLength: 4)
            Button { restAutoStart.toggle(); Haptics.tap() } label: {
                Image(systemName: restAutoStart ? "hourglass.circle.fill" : "hourglass.circle")
                    .font(.title3)
                    .foregroundStyle(restAutoStart ? SnappetColor.workout : .secondary)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("freeform.restToggle")
            .accessibilityLabel(restAutoStart ? "Auto rest timer on" : "Auto rest timer off")
            Button { togglePause() } label: {
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("pauseWorkout")
            .accessibilityLabel(isPaused ? "Resume" : "Pause")
            Button { showingAddMenu = true } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 34, height: 34)
                    .background(SnappetColor.brand.opacity(0.2), in: Circle())
                    .overlay(Circle().strokeBorder(SnappetColor.brand.opacity(0.5)))
                    .foregroundStyle(SnappetColor.brand)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("freeform.addExercise")
            .accessibilityLabel("New exercise")
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .pagerGlass(cornerRadius: 24)
    }

    /// The compact live-HR chip (zone-tinted, recovery dot) — taps into the metrics panel. Hidden
    /// until a live sample arrives, exactly like the old command bar's chip.
    @ViewBuilder
    private var hrChip: some View {
        if let bpm = app.liveWorkout.latestHR {
            let profile = app.userProfile.profile
            let zone = HeartRateZone.forBpm(bpm, maxHR: profile.resolvedMaxHR ?? HeartRateZone.defaultMaxHR)
            let recovery = RecoveryReadiness.evaluate(currentBpm: bpm, restBpm: profile.restingBound,
                                                      maxBpm: profile.resolvedMaxHR)
            Button { showingMetrics = true } label: {
                HStack(spacing: 5) {
                    Image(systemName: "heart.fill").foregroundStyle(zone.color)
                    Text("\(Int(bpm.rounded()))")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.primary)
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
    }

    // MARK: - Overview page (page 0)

    /// The leftmost page: editable session title, the elapsed hero, the discipline roll-up, one
    /// tap-to-jump row per exercise (with plan segments), and the big Finish.
    private var overviewPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                TextField("Session name", text: $session.routineName)
                    .font(.title3.weight(.semibold))
                    .submitLabel(.done)
                    .onSubmit { persist(); pushLiveActivity() }
                    .accessibilityIdentifier("freeform.sessionTitle")
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .pagerGlass(cornerRadius: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text("ELAPSED")
                        .font(.system(size: 10, weight: .heavy)).tracking(1.4)
                        .foregroundStyle(SnappetColor.textSecondary)
                    Text(timerInterval: session.startedAt...Date.distantFuture, countsDown: false)
                        .font(.system(size: 46, weight: .bold, design: .rounded)).monospacedDigit()
                        .shadow(color: SnappetColor.workout.opacity(0.3), radius: 14, y: 4)
                }
                // Climbing keeps its rich tappable ribbon (→ LiveClimbStatsSheet); other disciplines
                // the lean aggregate line — both re-homed from the old List's docked sections.
                if FreeformClimbStats.hasClimbing(session) {
                    Button { showingClimbStats = true } label: { statsRibbonContent }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .pagerGlass(cornerRadius: 18)
                        .accessibilityIdentifier("freeform.statsRibbon")
                        .accessibilityLabel(statsRibbonAccessibilityLabel)
                } else if let r = disciplineRibbon {
                    HStack(spacing: 12) {
                        Image(systemName: r.icon).foregroundStyle(r.accent)
                        Text(r.text).font(.subheadline.weight(.medium)).monospacedDigit()
                        Spacer(minLength: 4)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .pagerGlass(cornerRadius: 18)
                    .accessibilityIdentifier("freeform.disciplineRibbon")
                }
                if session.exercises.isEmpty {
                    Text("Swipe left to add your first exercise →")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 24)
                } else {
                    ForEach(session.exercises) { ex in overviewRow(ex) }
                }
                Button { finishTapped() } label: {
                    Text("Finish workout").font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.borderedProminent)
                .tint(SnappetColor.brand)
                .accessibilityIdentifier("freeform.finishSession")
                .padding(.top, 6)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
    }

    /// One overview row: discipline tile · name + metric line · plan segments (or a chevron).
    /// Tapping jumps the pager to that exercise's page.
    private func overviewRow(_ ex: SessionExercise) -> some View {
        Button { withAnimation { page = .exercise(ex.id) } } label: {
            HStack(spacing: 11) {
                Image(systemName: ex.discipline == .climb ? ex.climbType.symbol : ex.discipline.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(railTint(.init(page: .exercise(ex.id), symbol: "", title: "",
                                                    detail: nil, done: false)))
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(resolver.name(for: ex.exerciseId, override: ex.displayName))
                        .font(.subheadline.weight(.bold)).lineLimit(1)
                        .foregroundStyle(SnappetColor.ink)
                    Text(overviewMetrics(ex))
                        .font(.caption).monospacedDigit()
                        .foregroundStyle(SnappetColor.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if let plan = QuickSessionPager.planState(for: ex),
                   let planned = plan.planned, planned > 0 {
                    PlanSegmentsView(done: plan.done, planned: planned, accent: ex.discipline.accent)
                } else {
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 13).padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pagerGlass(cornerRadius: 20)
        .accessibilityIdentifier("freeform.overviewRow")
    }

    /// The overview row's one-line roll-up, per discipline.
    private func overviewMetrics(_ ex: SessionExercise) -> String {
        switch ex.discipline {
        case .climb:
            var parts = [attemptCountLabel(ex)]
            if let status = ex.resolvedClimbStatus { parts.append(ex.climbType.statusLabel(status)) }
            return parts.joined(separator: " · ")
        case .run:
            let meters = RunStats.totalDistanceMeters(ex)
            guard meters > 0 else { return "Not started" }
            var s = SetMeasure.formatDistance(meters, unit: distanceUnit)
            if let pace = RunStats.avgPaceSecPerKm(ex) {
                s += " · " + SetMeasure.formatPace(secPerKm: pace, unit: distanceUnit)
            }
            return s
        case .strength:
            guard let top = StrengthStats.topSet(ex) else { return "Not started" }
            let plan = QuickSessionPager.planState(for: ex)
            let lead = plan?.label() ?? ""
            return "\(lead) · top \(SetMeasure.summary(top, kind: .repsWeight, unit: unit))"
        default:
            guard !ex.sets.isEmpty else { return "Not started" }
            var parts = ["\(ex.sets.count) \(ex.sets.count == 1 ? "set" : "sets")"]
            if let hold = timedHoldTotal(ex) { parts.append(hold) }
            return parts.joined(separator: " · ")
        }
    }

    // MARK: - Exercise pages (prompt 109)

    /// One full-screen page per exercise: header (identity + plan) · the current-effort hero ·
    /// media shelf + record · the ghost ledger. The hero is discipline-specific; everything else
    /// is one shared skeleton.
    private func exercisePage(_ ex: SessionExercise) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                pageHeader(ex)
                pageHero(ex)
                ExerciseMediaShelf(
                    session: session, exerciseID: ex.id,
                    noun: QuickSessionPager.effortNoun(for: ex),
                    onEdit: { presentStudio($0) },
                    moveTargets: clipMoveTargets(for: ex),
                    moveTargetsLabel: moveTargetsLabel(ex),
                    onReassign: { reassignClip($0, to: $1, set: $2) },
                    onRequestDelete: { pendingClipDeletion = $0 })
                // The binding is scoped to THIS exercise's queue so the clip's owner is captured
                // when the recorder is presented, not when the async save lands (#273).
                RecordClipButton(recordedClips: Binding(get: { pageClips[ex.id] ?? [] },
                                                        set: { pageClips[ex.id] = $0 }),
                                 savingClip: $savingPageClip,
                                 idPrefix: "freeform.page",
                                 attachNoun: QuickSessionPager.effortNoun(for: ex))
                ghostLedger(ex)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
    }

    private func moveTargetsLabel(_ ex: SessionExercise) -> String {
        switch ex.discipline {
        case .climb: return "Move to attempt…"
        case .run:   return "Move to leg…"
        default:     return "Move to set…"
        }
    }

    /// The page header: discipline tag · name (+ ⓘ guide for catalog exercises, swatch/location
    /// for climbs) · the ⋯ menu · the plan row (or the climb's status line).
    @ViewBuilder
    private func pageHeader(_ ex: SessionExercise) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(ex.discipline == .climb
                     ? "\(ex.climbType.label) · \(ex.gym?.isEmpty == false ? ex.gym! : "Climb")"
                     : ex.discipline.label)
                    .font(.system(size: 10, weight: .heavy)).tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(ex.discipline == .climb ? SnappetColor.kilter : ex.discipline.accent)
                Spacer()
                pageMenu(ex)
            }
            HStack(spacing: 8) {
                Text(resolver.name(for: ex.exerciseId, override: ex.displayName))
                    .font(.title2.bold()).lineLimit(2)
                    .accessibilityIdentifier(nameIdentifier(ex))
                if ex.discipline == .climb { colorSwatch(ex) }
                if ex.discipline == .strength, let catalog = resolver.exercise(id: ex.exerciseId) {
                    Button { guideFor = GuideTarget(exercise: catalog) } label: {
                        Image(systemName: "info.circle")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("freeform.guide")
                    .accessibilityLabel("How to")
                }
                Spacer(minLength: 0)
            }
            if ex.discipline == .climb {
                climbLocationLine(ex)
                HStack(spacing: 8) {
                    statusBadge(ex)
                    Text(attemptCountLabel(ex)).font(.caption).foregroundStyle(.secondary)
                    if let time = climbTimeOnWall(ex) {
                        Text("· \(time)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                planRow(ex)
            }
        }
    }

    /// The per-discipline name identifier the UITests already query.
    private func nameIdentifier(_ ex: SessionExercise) -> String {
        switch ex.discipline {
        case .climb: return "freeform.climbName"
        case .timed, .dance, .other: return "freeform.timedName"
        default: return "freeform.entityName"
        }
    }

    /// The ⋯ menu per discipline — same items/ids as the old card headers.
    @ViewBuilder
    private func pageMenu(_ ex: SessionExercise) -> some View {
        switch ex.discipline {
        case .climb:
            Menu {
                climbMenuContent(ex)
            } label: { Image(systemName: "ellipsis.circle").foregroundStyle(.secondary) }
                .accessibilityIdentifier("freeform.climbMenu")
                .accessibilityLabel("Climb options")
        case .strength:
            Menu {
                Button {
                    let pf = prefills[ex.exerciseId]
                    editingStrength = EditStrengthTarget(
                        exerciseID: ex.id,
                        catalogName: resolver.name(for: ex.exerciseId),
                        initial: AddStrengthParams(from: ex),
                        lastReps: pf?.reps, lastWeight: pf?.weight, lastUnit: pf?.unit)
                } label: {
                    Label("Edit details", systemImage: "pencil")
                }
                .accessibilityIdentifier("freeform.editEntity")
                Button(role: .destructive) { removeExercise(ex) } label: {
                    Label("Remove exercise", systemImage: "trash")
                }
            } label: { Image(systemName: "ellipsis.circle").foregroundStyle(.secondary) }
                .accessibilityIdentifier("freeform.entityMenu")
                .accessibilityLabel("Exercise options")
        default:
            Menu {
                Button(role: .destructive) { removeExercise(ex) } label: {
                    Label("Remove exercise", systemImage: "trash")
                }
            } label: { Image(systemName: "ellipsis.circle").foregroundStyle(.secondary) }
                .accessibilityIdentifier("freeform.entityMenu")
                .accessibilityLabel("Exercise options")
        }
    }

    /// The plan row: segments + the tappable "set N of M ✎" label → the plan editor.
    private func planRow(_ ex: SessionExercise) -> some View {
        let plan = QuickSessionPager.planState(for: ex)
            ?? QuickSessionPager.PlanState(done: ex.completedSetCount, planned: nil)
        return HStack(spacing: 8) {
            if let planned = plan.planned, planned > 0 {
                PlanSegmentsView(done: plan.done, planned: planned, accent: ex.discipline.accent)
            }
            Button { planEditing = PlanEditTarget(exerciseID: ex.id) } label: {
                HStack(spacing: 3) {
                    Text(plan.label(noun: QuickSessionPager.effortNoun(for: ex)))
                    Image(systemName: "pencil").font(.system(size: 9))
                }
                .font(.caption.weight(.bold))
                .foregroundStyle(plan.isComplete ? SnappetColor.perfFresh : SnappetColor.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("freeform.planEdit")
            .accessibilityLabel("Edit planned \(QuickSessionPager.effortNoun(for: ex)) count")
            Spacer(minLength: 0)
        }
    }

    // MARK: - Discipline heroes

    /// Route the page's hero by discipline; a running rest morphs any plannable hero into the rest
    /// ring, and a met plan into the done-nudge.
    @ViewBuilder
    private func pageHero(_ ex: SessionExercise) -> some View {
        switch ex.discipline {
        case .strength: strengthHero(ex)
        case .climb:    climbHero(ex)
        case .run:      runHero(ex)
        case .timed, .dance, .other: timedHero(ex)
        }
    }

    @ViewBuilder
    private func strengthHero(_ ex: SessionExercise) -> some View {
        if restRunning, restExerciseID == ex.id {
            restHero(ex)
        } else if let plan = QuickSessionPager.planState(for: ex), plan.isComplete {
            planCompleteNudge(ex, plan: plan)
        } else {
            let seed = quickAddSeed(for: ex)
            let plan = QuickSessionPager.planState(for: ex)
            StrengthHeroCard(
                setLabel: heroSetLabel(done: ex.completedSetCount, planned: plan?.planned),
                reps: seed.reps, weight: seed.weight, unit: seed.unit, hint: seed.hint,
                onLog: { appendLog($0, toExerciseID: ex.id) },
                onTime: { reps, weight, unitSel in
                    timingSetFor = TimedSetTarget(exerciseID: ex.id, reps: reps,
                                                  weight: weight, unit: unitSel)
                },
                onLogDifferent: {
                    logging = LogTarget(exerciseID: ex.id, kind: .repsWeight, exerciseId: ex.exerciseId)
                })
                // Re-seed the steppers to the latest set after each log/delete (the QuickAddRow rule).
                .id("hero-\(ex.id)-\(ex.sets.count)")
            if let last = ex.sets.last {
                repeatButton(ex, last: last, kind: .repsWeight)
            }
        }
    }

    private func climbHero(_ ex: SessionExercise) -> some View {
        VStack(spacing: 12) {
            pageGradePill(ex)
            Text("ATTEMPT · #\(ex.sets.count + 1)")
                .font(.system(size: 11, weight: .heavy)).tracking(1.4)
                .foregroundStyle(SnappetColor.textSecondary)
            OutcomeGridView(type: ex.climbType) { status in
                logAttempt(toExerciseID: ex.id, status: status, durationSec: nil)
            }
            HStack(spacing: 8) {
                pagerGhostButton("Timed attempt", symbol: "stopwatch") {
                    timingAttemptFor = TimedAttemptTarget(exerciseID: ex.id, type: ex.climbType)
                }
                .accessibilityIdentifier("freeform.timedAttempt")
                if let last = ex.sets.last {
                    pagerGhostButton("Repeat last", symbol: "arrow.clockwise") {
                        appendLog(SetMeasure.duplicate(last), toExerciseID: ex.id)
                    }
                    .accessibilityIdentifier("freeform.repeatSet")
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func timedHero(_ ex: SessionExercise) -> some View {
        if restRunning, restExerciseID == ex.id {
            restHero(ex)
        } else if let plan = QuickSessionPager.planState(for: ex), plan.isComplete {
            planCompleteNudge(ex, plan: plan)
        } else {
            let structured = ex.timedSpec?.mode.isStructured == true
            VStack(spacing: 12) {
                if let spec = ex.timedSpec {
                    HStack(spacing: 6) {
                        Image(systemName: "timer").font(.caption)
                        Text(spec.summary).font(.caption.weight(.bold))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .pagerGlass(cornerRadius: 999)
                }
                Text(heroSetLabel(done: ex.completedSetCount,
                                  planned: QuickSessionPager.planState(for: ex)?.planned,
                                  noun: QuickSessionPager.effortNoun(for: ex)))
                    .font(.system(size: 11, weight: .heavy)).tracking(1.4)
                    .textCase(.uppercase)
                    .foregroundStyle(SnappetColor.textSecondary)
                Button {
                    // Structured specs run the full-cover interval runner; the simple modes keep the
                    // stopwatch/manual LogSetSheet — same routing as the old timed card's Add set.
                    if let spec = ex.timedSpec, spec.mode.isStructured {
                        runningInterval = IntervalRunTarget(
                            exerciseID: ex.id, spec: spec,
                            name: resolver.name(for: ex.exerciseId, override: ex.displayName))
                    } else {
                        logging = LogTarget(exerciseID: ex.id, kind: .duration,
                                            exerciseId: ex.exerciseId, timedSpec: ex.timedSpec)
                    }
                } label: {
                    Label(structured ? "Start intervals" : "Add set",
                          systemImage: structured ? "play.fill" : "plus.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.borderedProminent)
                .tint(SnappetColor.brand)
                .accessibilityIdentifier("freeform.addSet")
                if let last = ex.sets.last {
                    repeatButton(ex, last: last, kind: .duration)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func runHero(_ ex: SessionExercise) -> some View {
        if restRunning, restExerciseID == ex.id {
            restHero(ex)
        } else if let plan = QuickSessionPager.planState(for: ex), plan.isComplete {
            planCompleteNudge(ex, plan: plan)
        } else {
            VStack(spacing: 12) {
                Text(heroSetLabel(done: ex.completedSetCount,
                                  planned: QuickSessionPager.planState(for: ex)?.planned,
                                  noun: "leg"))
                    .font(.system(size: 11, weight: .heavy)).tracking(1.4)
                    .textCase(.uppercase)
                    .foregroundStyle(SnappetColor.textSecondary)
                HStack(spacing: 10) {
                    runStat("Distance",
                            RunStats.totalDistanceMeters(ex) > 0
                                ? SetMeasure.formatDistance(RunStats.totalDistanceMeters(ex), unit: distanceUnit)
                                : "—")
                    runStat("Pace",
                            RunStats.avgPaceSecPerKm(ex).map {
                                SetMeasure.formatPace(secPerKm: $0, unit: distanceUnit)
                            } ?? "—")
                }
                Button { loggingRunLeg = RunLegTarget(exerciseID: ex.id) } label: {
                    Label("Log leg \(ex.sets.count + 1)", systemImage: "plus.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.borderedProminent)
                .tint(SnappetColor.brand)
                .accessibilityIdentifier("freeform.logLeg")
            }
        }
    }

    private func runStat(_ caption: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(caption.uppercased())
                .font(.system(size: 10, weight: .heavy)).tracking(1.2)
                .foregroundStyle(SnappetColor.textSecondary)
            Text(value)
                .font(.system(size: 26, weight: .bold, design: .rounded)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 11)
        .pagerGlass(cornerRadius: 18)
    }

    /// "SET 3" / "SET 3 OF 5" — the hero's current-effort label.
    private func heroSetLabel(done: Int, planned: Int?, noun: String = "set") -> String {
        if let planned, planned > 0 { return "\(noun) \(min(done + 1, planned)) of \(planned)" }
        return "\(noun) \(done + 1)"
    }

    /// The plan-met state: summary card + advance CTA (+1 extra set bumps the plan back open).
    private func planCompleteNudge(_ ex: SessionExercise,
                                   plan: QuickSessionPager.PlanState) -> some View {
        let nextID = QuickSessionPager.nextIncomplete(after: ex.id, in: session.exercises)
        let nextName = nextID
            .flatMap { nid in session.exercises.first { $0.id == nid } }
            .map { resolver.name(for: $0.exerciseId, override: $0.displayName) }
        return PlanCompleteNudge(
            headline: "Plan complete — \(plan.planned ?? plan.done) \(QuickSessionPager.effortNoun(for: ex))s",
            sublabel: heroSummaryLine(ex),
            nextTitle: nextName.map { "Next: \($0) →" } ?? "Finish workout",
            onNext: {
                if let nextID { withAnimation { page = .exercise(nextID) } } else { finishTapped() }
            },
            onExtraSet: { setPlan(ex.id, (ex.plannedSets ?? plan.done) + 1) })
    }

    /// The nudge's one-line best ("Best: 8 × 65 kg" / total hold / total distance).
    private func heroSummaryLine(_ ex: SessionExercise) -> String? {
        switch ex.discipline {
        case .strength:
            return StrengthStats.topSet(ex).map {
                "Best: \(SetMeasure.summary($0, kind: .repsWeight, unit: unit))"
            }
        case .run:
            let meters = RunStats.totalDistanceMeters(ex)
            return meters > 0 ? "Total: \(SetMeasure.formatDistance(meters, unit: distanceUnit))" : nil
        default:
            return timedHoldTotal(ex).map { "Total hold: \($0)" }
        }
    }

    private func restHero(_ ex: SessionExercise) -> some View {
        let seed = quickAddSeed(for: ex)
        let nextUp: String? = ex.kind == .repsWeight
            ? "Up next: \(seed.reps) × \(seed.weight > 0 ? "\(SetMeasure.formatWeight(seed.weight)) \(seed.unit.display)" : "body") prefilled"
            : nil
        return RestHeroView(
            remaining: restTimer.reading.remaining ?? 0,
            total: restTotalSec,
            done: restTimer.reading.reachedZero,
            nextUpText: nextUp,
            onMinus: { adjustRest(by: -RestTimerDefaults.stepSeconds) },
            onPlus: { adjustRest(by: RestTimerDefaults.stepSeconds) },
            onSkip: { dismissRest() })
    }

    /// The big grade pill on the climb page (the caption-sized `freeform.gradePill` grown to hero).
    private func pageGradePill(_ ex: SessionExercise) -> some View {
        Text(ex.climbGradeLabel ?? "—")
            .font(.system(size: 28, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 18).padding(.vertical, 8)
            .background(!ex.climbType.isRoute ? SnappetColor.kilter : SnappetColor.budget,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .accessibilityIdentifier("freeform.gradePill")
    }

    private func repeatButton(_ ex: SessionExercise, last: SetLog, kind: SetKind) -> some View {
        pagerGhostButton(FreeformSummary.repeatLabel(for: last, kind: kind, unit: unit),
                         symbol: "arrow.clockwise") {
            repeatLastSet(ex)
        }
        .accessibilityIdentifier("freeform.repeatSet")
    }

    private func pagerGhostButton(_ title: String, symbol: String,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 42)
        }
        .buttonStyle(.plain)
        .pagerGlass(cornerRadius: 14)
    }

    // MARK: - Ghost ledger + drawer rows

    private func ghostLedger(_ ex: SessionExercise) -> some View {
        let noun = QuickSessionPager.effortNoun(for: ex)
        return GhostLedgerView(
            title: "Previous \(noun)s",
            items: ex.sets.enumerated().map { i, set in
                .init(id: i, text: ledgerText(set, ex: ex), done: set.completedAt != nil)
            },
            onHistory: { historyFor = HistoryTarget(exerciseID: ex.id) })
    }

    /// One set's compact ledger text, per discipline (the row formats the old cards used).
    private func ledgerText(_ set: SetLog, ex: SessionExercise) -> String {
        switch ex.discipline {
        case .climb:    return SetMeasure.attemptRow(set, type: ex.climbType)
        case .run:      return SetMeasure.runSummary(set, unit: distanceUnit)
        case .strength: return SetMeasure.summary(set, kind: .repsWeight, unit: unit)
        default:        return SetMeasure.summary(set, kind: .duration, unit: unit)
        }
    }

    private func drawerRows(_ ex: SessionExercise) -> [HistoryDrawerView.Row] {
        let previous = QuickSessionPager.lastSessionSets(
            exerciseId: ex.exerciseId, displayName: ex.displayName, history: history) ?? []
        let deltas = QuickSessionPager.deltas(current: ex.sets, previous: previous, kind: ex.kind)
        return ex.sets.enumerated().map { i, set in
            .init(id: i, summary: ledgerText(set, ex: ex), delta: deltas[i])
        }
    }

    // MARK: - Live stats ribbon (Phase 3 — content re-homed onto the overview page)

    /// The dominant non-climbing discipline's aggregate line, or `nil` when nothing's logged yet.
    private var disciplineRibbon: (icon: String, accent: Color, text: String)? {
        switch FreeformSummary.dominant(for: session) {
        case .lifting:
            let sets = session.completedSetCount
            guard sets > 0 else { return nil }
            let vol = WorkoutMath.formatVolume(kg: WorkoutMath.sessionVolumeKg(session), unit: unit)
            return ("scalemass.fill", WorkoutDiscipline.strength.accent,
                    "\(vol) · \(sets) \(sets == 1 ? "set" : "sets")")
        case .running:
            var meters = 0.0, seconds = 0.0
            for ex in session.exercises where ex.discipline == .run {
                for set in ex.sets where set.completedAt != nil {
                    meters += set.distanceMeters ?? 0; seconds += set.durationSec ?? 0
                }
            }
            guard meters > 0 else { return nil }
            let pace = seconds > 0
                ? " · " + SetMeasure.formatPace(secPerKm: seconds / (meters / 1000), unit: distanceUnit) : ""
            return ("figure.run", WorkoutDiscipline.run.accent,
                    SetMeasure.formatDistance(meters, unit: distanceUnit) + pace)
        case .timed:
            let tut = FreeformSummary.holdTimeSeconds(session)
            guard tut > 0 else { return nil }
            let sets = session.completedSetCount
            return ("timer", WorkoutDiscipline.timed.accent,
                    "TUT \(SetMeasure.formatDuration(tut)) · \(sets) \(sets == 1 ? "set" : "sets")")
        default:
            return nil   // climbing has its own ribbon; dance/other rely on the command-bar duration
        }
    }

    private var statsRibbonContent: some View {
        let s = climbStats
        let sends = s?.sends ?? 0
        return HStack(spacing: 12) {
            Image(systemName: "chart.bar.xaxis").foregroundStyle(SnappetColor.moduleAccent("kilter"))
            VStack(alignment: .leading, spacing: 4) {
                if sends == 0 {
                    // Pre-send teaching variant: there's logged climbing but no send yet.
                    Text("Send one to start your pyramid")
                        .font(.subheadline.weight(.medium))
                } else {
                    HStack(spacing: 8) {
                        Text("\(sends) \(sends == 1 ? "send" : "sends")")
                            .font(.headline.monospacedDigit())
                        if let hardest = s?.hardestSendGrade {
                            Text("· hardest \(hardest)")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    if let s, !s.pyramid.isEmpty { miniPyramid(s.pyramid) }
                }
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }

    /// A compact inline pyramid: a tiny bar per grade (height ∝ sends), easiest→hardest. Purely a
    /// glanceable teaser of the full pyramid in the sheet.
    private func miniPyramid(_ pyramid: [KilterSessionStats.GradeCount]) -> some View {
        let maxSends = max(1, pyramid.map(\.sends).max() ?? 1)
        return HStack(alignment: .bottom, spacing: 4) {
            ForEach(pyramid) { g in
                VStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(SnappetColor.moduleAccent("kilter"))
                        .frame(width: 10, height: 6 + 18 * CGFloat(g.sends) / CGFloat(maxSends))
                    Text(g.gradeLabel)
                        .font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private var statsRibbonAccessibilityLabel: String {
        let sends = climbStats?.sends ?? 0
        guard sends > 0 else { return "Climbing stats. Send a climb to start your pyramid." }
        var label = "Climbing stats. \(sends) \(sends == 1 ? "send" : "sends")"
        if let hardest = climbStats?.hardestSendGrade { label += ", hardest \(hardest)" }
        return label
    }

    /// The transient at-logging milestone banner (Phase 3 §3) — a glass headline pinned to the top of
    /// the logbook for a few seconds after a genuine new best. The `CelebrationBurst`/haptic fire via
    /// the screen-level `.celebrates(on:)`; this is just the text. Reduce Motion → static (no burst).
    @ViewBuilder
    private var milestoneBanner: some View {
        if let headline = liveMilestoneHeadline {
            HStack(spacing: 8) {
                Image(systemName: "trophy.fill").foregroundStyle(SnappetColor.kilter)
                Text(headline).font(.headline)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(SnappetColor.kilter.opacity(0.4)))
            .padding(.top, 8)
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityIdentifier("freeform.liveMilestone")
        }
    }

    /// Seed values for an exercise's inline quick-add (§B). The weight AND its unit come from the SAME
    /// source (this session's last set, else the cross-session prefill, else bodyweight) so the pair
    /// never crosses — e.g. a prefill weight recorded in lb is never shown beside this session's kg.
    private func quickAddSeed(for ex: SessionExercise) -> (reps: Int, weight: Double, unit: WeightUnit, hint: String?) {
        let last = ex.sets.last
        let pf = prefills[ex.exerciseId]
        // Fall back to the exercise's default prescription (target*, set via "Edit details") before the
        // hardcoded default — so the hybrid-add default seeds the first set (Workout-Type Parity polish).
        let targetReps = Int(ex.targetReps)
        let reps = last?.actualReps ?? pf?.reps ?? targetReps ?? 8
        let hint = last == nil ? pf?.hint : nil
        if let w = last?.actualWeight {
            return (reps, w, last?.weightUnit ?? unit, hint)
        } else if let w = pf?.weight {
            return (reps, w, pf?.unit ?? unit, hint)
        } else if let w = ex.targetWeight, w > 0 {
            return (reps, w, ex.targetWeightUnit ?? unit, hint)
        }
        return (reps, 0, last?.weightUnit ?? pf?.unit ?? ex.targetWeightUnit ?? unit, hint)
    }

    /// Total logged hold time across this timed exercise's sets — the timed analogue of time-on-climb.
    private func timedHoldTotal(_ ex: SessionExercise) -> String? {
        let total = ex.sets.compactMap { $0.durationSec }.reduce(0, +)
        return total > 0 ? SetMeasure.formatDuration(total) : nil
    }

    /// The climb header ⋯ menu items (extracted to keep `climbHeader`'s opaque-result type-check fast):
    /// "Edit details" (the only rename path, prompt 09/10) · "Edit all clips" when the climb has video
    /// clips (prompt 10) · "Remove climb".
    @ViewBuilder
    private func climbMenuContent(_ ex: SessionExercise) -> some View {
        // Edit details (prompt 09): open the Add-a-climb sheet PREFILLED in edit mode so the
        // type/grade/scale/name/gym/wall/colour can all be changed — and it's now the ONLY way to rename
        // (the header name is a tap-to-expand label, prompt 10).
        Button {
            editingClimb = EditClimbTarget(exerciseID: ex.id, initial: AddClimbParams(from: ex))
        } label: {
            Label("Edit details", systemImage: "pencil")
        }
        .accessibilityIdentifier("freeform.editClimb")
        // Edit all clips (prompt 10): open the shared Studio editor scoped to ALL this climb's attempt
        // video clips together — only when the climb has ≥1 video clip to edit.
        if hasVideoClips(ex) {
            Button {
                presentStudioForClimb(ex)
            } label: {
                Label("Edit all clips", systemImage: "film.stack")
            }
            .accessibilityIdentifier("freeform.editAllClips")
        }
        Button(role: .destructive) { removeExercise(ex) } label: {
            Label("Remove climb", systemImage: "trash")
        }
    }

    /// A small colour swatch (the climb's hold/tape colour) shown next to the grade pill; hidden when the
    /// climb has no colour tagged. A near-white swatch gets a hairline ring so it reads on the card.
    @ViewBuilder
    private func colorSwatch(_ ex: SessionExercise) -> some View {
        if let c = ex.climbColor {
            Circle()
                .fill(Color(hex: c.hexValue))
                .frame(width: 14, height: 14)
                .overlay(Circle().stroke(Color.primary.opacity(c.needsRing ? 0.3 : 0.12), lineWidth: 1))
                .accessibilityIdentifier("freeform.colorSwatch")
                .accessibilityLabel("\(c.label) climb")
        }
    }

    /// The "📍 gym · wall" caption under the climb name; shown only when a gym and/or wall was captured.
    @ViewBuilder
    private func climbLocationLine(_ ex: SessionExercise) -> some View {
        let parts = [ex.gym, ex.wall].compactMap { $0?.isEmpty == false ? $0 : nil }
        if !parts.isEmpty {
            Label(parts.joined(separator: " · "), systemImage: "mappin.and.ellipse")
                .font(.caption2).foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .accessibilityIdentifier("freeform.climbLocation")
        }
    }


    /// The rolled-up status badge from the climb's resolved (best) outcome, type-relabelled. Hidden
    /// until an attempt is logged.
    @ViewBuilder
    private func statusBadge(_ ex: SessionExercise) -> some View {
        if let status = ex.resolvedClimbStatus {
            let (symbol, tint): (String, Color) = {
                switch status {
                case .flash:   return ("bolt.fill", SnappetColor.kilter)
                case .sent:    return ("checkmark.seal.fill", SnappetColor.habits)
                case .project: return ("hourglass", SnappetColor.workout)
                case .attempt: return ("circle", SnappetColor.textSecondary)
                }
            }()
            HStack(spacing: 4) {
                Image(systemName: symbol)
                Text(ex.climbType.statusLabel(status))
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .accessibilityIdentifier("freeform.climbStatus")
        }
    }

    private func attemptCountLabel(_ ex: SessionExercise) -> String {
        let n = ex.sets.count
        return n == 1 ? "1 attempt" : "\(n) attempts"
    }

    /// Total time-on-climb = span of the attempt completion stamps (first→last), or `nil` when there
    /// aren't two stamps to span. Mirrors the `FreeformClimbStats` time-on-climb convention (Phase 3).
    private func climbTimeOnWall(_ ex: SessionExercise) -> String? {
        let stamps = ex.sets.compactMap(\.completedAt).sorted()
        guard let first = stamps.first, let last = stamps.last, last > first else { return nil }
        return SetMeasure.formatDuration(last.timeIntervalSince(first))
    }

    // MARK: - Completion moment (§D)

    /// The post-workout summary — the **type-adaptive** `FreeformDoneSummaryView` (Quick Session redesign
    /// Phase 7): a scrollable recap whose hero strip + cards adapt to `FreeformSummary.dominant` (climbing
    /// pyramid + timeline + Effort / timed per-exercise / strength PRs + volume), keeping the milestone
    /// seal + `CelebrationBurst` and the Done / View detail / Keep going / Discard actions. All figures
    /// are derived from the pure `FreeformSummary` + `FreeformClimbStats` — no model change. The Studio
    /// CTA (shown when video clips exist) opens the whole session in the shared editor.
    private var doneScreen: some View {
        FreeformDoneSummaryView(
            session: session, resolver: resolver, unit: unit,
            milestones: doneMilestones, maxHR: zoneMaxHR,
            onDone: { finish(saved: true) },
            onViewDetail: { onViewDetail(session) },
            onKeepGoing: { showingSummary = false },
            onDiscard: { finish(saved: false) },
            onOpenStudio: { presentSessionStudio() })
        // The summary's "Turn N clips into a reel" CTA opens the whole session in Studio — hosted here so
        // the cover is mounted on the completion screen (the logging screen's cover isn't in this branch).
        .fullScreenCover(item: $studioClip) { p in
            StudioEditorView(project: p.project, context: context,
                             focusClipMediaID: p.focusClipMediaID, visibleClipMediaIDs: p.visibleClipMediaIDs,
                             suggestedClimbCaption: p.climbCaption,
                             suggestedAttemptNumber: p.suggestedAttemptNumber)
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
            let entity = SessionExercise(
                exerciseId: ex.id, targetSets: 0, targetReps: "", targetRestSeconds: 0,
                sets: [], displayName: nil, kindRaw: SetKind.repsWeight.rawValue)
            session.exercises.append(entity)
        }
        persist()
        pushLiveActivity()   // the new exercise becomes the current one → refresh the Lock Screen label
    }

    /// Create a running entity (Workout-Type Parity Phase 4): a `.duration`-kind `SessionExercise` tagged
    /// with the `.run` discipline (so it routes to the run card and its legs carry `distanceMeters`).
    /// Auto-expanded like the other cards; legs are logged via the run card's "Log a leg".
    private func addRun() {
        var entity = SessionExercise(
            exerciseId: "adhoc-run", targetSets: 0, targetReps: "", targetRestSeconds: 0,
            sets: [], displayName: "Run", kindRaw: SetKind.duration.rawValue)
        entity.disciplineRaw = WorkoutDiscipline.run.rawValue
        session.exercises.append(entity)
        persist()
        pushLiveActivity()
    }

    /// Create a lightweight open-effort entity for the Dance / Other disciplines (Workout-Type Parity
    /// Phase 5): a `.duration`-kind `SessionExercise` tagged with the discipline. Renders via the
    /// (discipline-aware) timed card — its efforts are open count-up durations logged with "Add set".
    private func addOpenEffort(_ discipline: WorkoutDiscipline) {
        var entity = SessionExercise(
            exerciseId: "adhoc-\(discipline.rawValue)", targetSets: 0, targetReps: "", targetRestSeconds: 0,
            sets: [], displayName: discipline.label, kindRaw: SetKind.duration.rawValue)
        entity.disciplineRaw = discipline.rawValue
        session.exercises.append(entity)
        persist()
        pushLiveActivity()
    }

    /// The most recent climb's gym in this session — inherited as the default for the next "Add a climb"
    /// sheet (captured once, never re-entered per climb).
    private var lastClimbGym: String? {
        session.exercises.last { $0.kind == .climbAttempt && ($0.gym?.isEmpty == false) }?.gym
    }

    /// Create a climb from the "Add a climb" sheet (Quick Session redesign Phase 1): a `.climbAttempt`
    /// `SessionExercise` carrying the captured type/grade/scale/gym, auto-expanded; when `logFirstAttempt`
    /// the card also opens its inline outcome strip so the first attempt is one tap away.
    private func addClimbFromSheet(_ params: AddClimbParams, logFirstAttempt: Bool) {
        var climb = SessionExercise(
            exerciseId: "adhoc-\(SetKind.climbAttempt.rawValue)", targetSets: 0, targetReps: "",
            targetRestSeconds: 0, sets: [], displayName: params.name,
            kindRaw: SetKind.climbAttempt.rawValue)
        climb.climbTypeRaw = params.type.rawValue
        climb.climbGradeLabel = params.grade
        climb.climbGradeScaleRaw = params.scale.rawValue
        climb.gym = params.gym
        climb.wall = params.wall
        climb.climbColorRaw = params.color?.rawValue
        climb.setter = params.setter
        session.exercises.append(climb)
        // The pager auto-advances to the new climb's page, where the outcome grid is always
        // visible — `logFirstAttempt` needs no extra state (prompt 109).
        _ = logFirstAttempt
        // File the photos the user attached in the sheet as climb-level media now that the climb has an id.
        // The sheet can't mint the id, so it returned `localIdentifier`s; resolve kind/offset via the same
        // mapping the per-set strip uses, and pin `.manual` so the post-session auto-assigner leaves them put.
        attachClimbPhotos(params.photoLocalIdentifiers, toExerciseID: climb.id)
        persist()
        pushLiveActivity()
    }

    /// File `localIdentifier`s as climb-level `SessionMedia` (`assignedExerciseID == climb.id`,
    /// `assignedSetIndex == nil` — the whole climb, not a specific attempt; `source == .manual`). Only photos
    /// resolve (the sheet's picker is `.images`); the bytes stay in Photos (only the id is stored). No-op on
    /// the simulator / when nothing resolves.
    private func attachClimbPhotos(_ identifiers: [String], toExerciseID exID: UUID) {
        guard !identifiers.isEmpty else { return }
        // Dedup against media already tagged to this session (auto-discovered clips + per-attempt picks) so
        // re-picking an asset that's already on the session is a no-op, not a duplicate row — mirrors
        // `SetMediaStrip.attach`.
        let sid = session.id
        let existing = Set((try? context.fetch(FetchDescriptor<SessionMedia>(
            predicate: #Predicate { $0.sessionID == sid })))?.map(\.localIdentifier) ?? [])
        let cands = app.sessionMedia.candidates(
            forIdentifiers: identifiers, startedAt: session.startedAt, existingIdentifiers: existing)
        for c in cands where c.kind == .photo {
            context.insert(SessionMedia(
                sessionID: session.id, localIdentifier: c.localIdentifier, kind: .photo,
                offsetSec: c.offsetSec, durationSec: nil, addedManually: true,
                assignedExerciseID: exID, assignedSetIndex: nil, source: .manual))
        }
    }

    /// File clips recorded in-app during a timed set / attempt (already saved to Photos by the cover) against
    /// `(exerciseID, setIndex)` — the set/attempt that was just logged. Each row is `.manual` (sticky, so the
    /// auto-reconciler never re-places it) and built through the pure `SessionMediaService.candidate(for:)`
    /// (same offset-clamp + `.video` mapping as auto-discovery / manual picks). `setIndex == nil` tags the
    /// exercise as a whole.
    ///
    /// **Upsert, not insert-or-skip:** a clip is saved to Photos at record-time but only attached here at
    /// commit-time, so the live `discoverClips` tick can race ahead and insert the same asset as a window-placed
    /// `.auto` row first. If we merely skipped existing identifiers, the user's clip would stay on whatever set
    /// the timeline guessed — breaking the "filmed for THIS set" promise. So when a row already exists we
    /// re-pin it to `(exID, setIndex)` as `.manual` (authoritative); otherwise we insert. The in-call `seen`
    /// set also guards against the same identifier appearing twice in one batch.
    ///
    /// `exID == nil` (#273: a page clip whose exercise was deleted during the save) files the clip to the
    /// session **unassigned** — insert-only: an existing row keeps whatever placement it already has (a
    /// timeline guess beats un-pinning to nowhere), but the clip is never dropped.
    private func attachRecordedClips(_ clips: [RecordedClip], toExerciseID exID: UUID?, setIndex: Int?) {
        guard !clips.isEmpty else { return }
        let sid = session.id
        let existing = (try? context.fetch(FetchDescriptor<SessionMedia>(
            predicate: #Predicate { $0.sessionID == sid }))) ?? []
        var byID = Dictionary(existing.map { ($0.localIdentifier, $0) }, uniquingKeysWith: { a, _ in a })
        var changed = false
        for clip in clips {
            let c = SessionMediaService.candidate(for: clip, startedAt: session.startedAt)
            if let row = byID[c.localIdentifier] {
                // Already on the session (auto-discovery raced ahead, or a duplicate in this batch) — re-pin it
                // to the set it was filmed for instead of leaving a stale auto placement. With no target
                // (deleted owner) the existing placement stands.
                guard let exID else { continue }
                row.assignedExerciseID = exID
                row.assignedSetIndex = setIndex
                row.assignmentSource = .manual
                row.addedManually = true
                if row.durationSec == nil { row.durationSec = c.durationSec }
            } else {
                // No target ⇒ the sticky General bucket (the reassign-to-nil convention), so the
                // auto-assigner won't later guess a set for a clip whose exercise is gone.
                let row = SessionMedia(
                    sessionID: sid, localIdentifier: c.localIdentifier, kind: c.kind,
                    offsetSec: c.offsetSec, durationSec: c.durationSec, addedManually: true,
                    assignedExerciseID: exID, assignedSetIndex: setIndex,
                    source: exID == nil ? .general : .manual)
                context.insert(row)
                byID[c.localIdentifier] = row
            }
            changed = true
        }
        if changed { try? context.save() }
    }

    /// Overwrite an existing climb's identity fields IN PLACE from the edit sheet (prompt 09): the same
    /// `SessionExercise` keeps its `id` and its logged attempts (the `sets`) — only the climb-level
    /// type/grade/scale/name/gym/wall/colour change. An empty NAME falls back to the type label (the
    /// sheet's `resolvedName` already supplies that), mirroring the add path. No duplicate is created.
    /// Note: existing attempts keep the grade they were stamped with at log time (the per-`SetLog` source
    /// of truth for send/pyramid reads); the card's grade pill re-derives from the climb immediately.
    private func updateClimb(_ exID: UUID, _ params: AddClimbParams) {
        guard let idx = session.exercises.firstIndex(where: { $0.id == exID }) else { return }
        session.exercises[idx].displayName = params.name
        session.exercises[idx].climbTypeRaw = params.type.rawValue
        session.exercises[idx].climbGradeLabel = params.grade
        session.exercises[idx].climbGradeScaleRaw = params.scale.rawValue
        session.exercises[idx].gym = params.gym
        session.exercises[idx].wall = params.wall
        session.exercises[idx].climbColorRaw = params.color?.rawValue
        session.exercises[idx].setter = params.setter
        persist()
        pushLiveActivity()
    }

    /// Apply the strength "Edit details" sheet (Workout-Type Parity polish): overwrite the display-name
    /// override + the default prescription (`target*`) in place. An empty name clears the override (the
    /// catalog name shows); the default seeds the card's quick-add for a fresh exercise.
    private func updateStrength(_ exID: UUID, _ params: AddStrengthParams) {
        guard let idx = session.exercises.firstIndex(where: { $0.id == exID }) else { return }
        session.exercises[idx].displayName = params.name.isEmpty ? nil : params.name
        session.exercises[idx].targetSets = params.sets
        session.exercises[idx].targetReps = "\(params.reps)"
        session.exercises[idx].targetWeight = params.weight
        session.exercises[idx].targetWeightUnit = params.unit
        persist()
        pushLiveActivity()
    }

    /// Create a timed exercise from the "Pick or create" sheet (Quick Session redesign Phase 5): a named
    /// `.duration` `SessionExercise` carrying the chosen structure (`timedSpec`) and category. Its timed
    /// sets log underneath it like a climb's attempts. Every Timed entry point (the empty-state card + the
    /// add-menu item) now routes through the pick sheet → here, so a timed card is always named.
    private func addTimedFromSheet(_ params: AddTimedParams) {
        var timed = SessionExercise(
            exerciseId: "adhoc-\(SetKind.duration.rawValue)", targetSets: 0, targetReps: "",
            targetRestSeconds: 0, sets: [], displayName: params.name,
            kindRaw: SetKind.duration.rawValue)
        timed.timedSpec = params.spec
        timed.timedCategory = params.category.rawValue
        session.exercises.append(timed)
        persist()
        pushLiveActivity()
    }

    /// Append an attempt under a climb: a `SetLog` carrying the chosen outcome, optional captured
    /// duration, and **stamped with the climb's grade** (so the pure send/pyramid/milestone reads stay
    /// per-`SetLog` and old data still renders). Routed through the one `appendLog` funnel (stamp + haptic).
    private func logAttempt(toExerciseID id: UUID, status: KilterAscentStatus, durationSec: Double?) {
        guard let ex = session.exercises.first(where: { $0.id == id }) else { return }
        appendLog(SetLog(durationSec: (durationSec ?? 0) > 0 ? durationSec : nil,
                         climbGradeLabel: ex.climbGradeLabel,
                         climbStatusRaw: status.rawValue, climbAttempts: 1),
                  toExerciseID: id)
    }

    /// Set / clear an exercise's per-session planned count (prompt 109). Values ≤ 0 clear the plan.
    private func setPlan(_ exID: UUID, _ planned: Int?) {
        guard let idx = session.exercises.firstIndex(where: { $0.id == exID }) else { return }
        session.exercises[idx].plannedSets = planned.flatMap { $0 > 0 ? $0 : nil }
        persist()
    }

    private func removeExercise(_ ex: SessionExercise) {
        guard let idx = indexOf(ex) else { return }
        session.exercises.remove(at: idx)
        // Untie the removed exercise's media back to General: a dangling `assignedExerciseID` keeps
        // the clip out of every shelf while still counting as "assigned" everywhere else. Same
        // convention as the deep-tap "Remove from attempt only" (`reassignClip(_, to: nil, set: nil)`).
        for row in mediaRows(assignedTo: ex.id) {
            row.assignedExerciseID = nil
            row.assignedSetIndex = nil
            row.assignmentSource = .general
        }
        persist()
        pushLiveActivity()   // the current (last) exercise may have changed
    }

    private func appendLog(_ log: SetLog, toExerciseID id: UUID) {
        guard let idx = session.exercises.firstIndex(where: { $0.id == id }) else { return }
        var entry = log
        entry.completedAt = .now
        let ex = session.exercises[idx]
        session.exercises[idx].sets.append(entry)
        persist()
        recomputeClimbStats()
        pushLiveActivity()
        Haptics.success()
        // At-logging milestone (Phase 3 §3): after the append, diff the session's milestones against
        // the prior history and celebrate any NEW genuine best (first-of-grade send / new hardest /
        // flash). Fires once per milestone — never on every attempt. Reduce Motion → haptic + static
        // text only (handled by `.celebrates(on:)`).
        checkLiveMilestones()
        // Remembered rest timer (Phase 7): opt-in, NON-blocking — after the log lands, auto-start a
        // count-down rest in the command bar at the duration remembered for this exercise's context.
        // Never gates logging (the append already happened); off by default.
        if restAutoStart { startRest(for: ex) }
    }

    // MARK: - Remembered rest timer (Phase 7)

    /// The rest-timer context for an exercise — climbs key by `ClimbType`, timed by category, lifting one
    /// bucket — so the remembered duration recalls the right length for the next rest of that kind.
    private func restContext(for ex: SessionExercise) -> RestTimerDefaults.Context {
        switch ex.kind {
        case .climbAttempt: return .climb(ex.climbType)
        case .duration:     return .timed(TimedExerciseCategory(rawValue: ex.timedCategory ?? "") ?? .other)
        case .repsWeight:   return .lifting
        }
    }

    /// Arm + start the rest count-down at the remembered duration for the exercise's context. Reuses the
    /// shared `StopwatchViewModel(.countDown)` (one success `Haptics` at zero); the chip is dismissable
    /// and never blocks the next log.
    private func startRest(for ex: SessionExercise) {
        let ctx = restContext(for: ex)
        // Honor a routine's prescribed rest (`targetRestSeconds`) as this exercise's first rest, until
        // the user remembers their own ±adjustment for the context. `nil` for freeform (no prescription).
        let seconds = RestTimerDefaults.remembered(
            for: ctx, in: restDefaults,
            prescribed: ex.targetRestSeconds > 0 ? ex.targetRestSeconds : nil)
        restContext = ctx
        restExerciseID = ex.id      // the page whose hero morphs into the rest ring (prompt 109)
        restTotalSec = TimeInterval(seconds)
        restTimer.reset()
        restTimer.arm(target: TimeInterval(seconds))
        restTimer.start()
        restRunning = true
    }

    /// Nudge the active rest by ±`RestTimerDefaults.stepSeconds`, re-arming from the time remaining, and
    /// remember the new total per context so the next rest of this kind starts there. Clamped in band.
    private func adjustRest(by delta: Int) {
        guard let ctx = restContext else { return }
        let remaining = restTimer.reading.remaining ?? 0
        let next = RestTimerDefaults.clamp(Int(remaining.rounded()) + delta)
        restTotalSec = TimeInterval(next)
        restTimer.reset()
        restTimer.arm(target: TimeInterval(next))
        restTimer.start()
        restRunning = true
        restDefaultsJSON = RestTimerDefaults.encode(
            RestTimerDefaults.remembering(next, for: ctx, in: restDefaults))
        Haptics.tap()
    }

    /// Dismiss the rest chip (stop the count-down). The remembered duration is untouched — only the live
    /// timer ends.
    private func dismissRest() {
        restTimer.reset()
        restRunning = false
        restContext = nil
        restExerciseID = nil
    }

    /// Recompute milestones against prior history and celebrate each one not yet celebrated this
    /// session. `FreeformSummary.milestones` already gates to genuine new bests (a first weighted PR / a
    /// first send of a grade with no prior send in history); the `celebratedMilestones` set dedupes so a
    /// repeated send of an already-celebrated grade is silent. The most recent fresh headline shows as a
    /// banner (auto-dismissed) and bumps the burst/haptic trigger.
    private func checkLiveMilestones() {
        let milestones = FreeformSummary.milestones(for: session, history: history)
        var fresh: FreeformSummary.Milestone?
        for m in milestones {
            let key = milestoneKey(m)
            if celebratedMilestones.insert(key).inserted { fresh = m }
        }
        guard let fresh else { return }
        withAnimation { liveMilestoneHeadline = FreeformSummary.milestoneHeadline(fresh) }
        milestoneTrigger += 1   // drives `.celebrates(on:)` (burst + Haptics.success, RM-aware)
        // Auto-dismiss the banner after a beat so it doesn't linger over the logbook.
        let shown = fresh
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            if liveMilestoneHeadline == FreeformSummary.milestoneHeadline(shown) {
                withAnimation { liveMilestoneHeadline = nil }
            }
        }
    }

    /// A stable string key per milestone so `celebratedMilestones` dedupes across re-derivations.
    private func milestoneKey(_ milestone: FreeformSummary.Milestone) -> String {
        switch milestone {
        case .personalRecord(let exerciseId, _, _): return "pr:\(exerciseId)"
        case .firstSend(let grade):                 return "send:\(grade)"
        }
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
        // Keep pinned media honest across the deletion: a clip pinned to a deleted set falls back to
        // the exercise as a whole; clips pinned to later sets shift down with them. Without this,
        // every pin above a deleted index silently points at (and labels itself with) the wrong set.
        for row in mediaRows(assignedTo: ex.id) {
            guard let pinned = row.assignedSetIndex else { continue }
            let remapped = SessionMediaAssignment.reindexAfterDeletion(pinned, removing: offsets)
            if remapped != pinned { row.assignedSetIndex = remapped }
        }
        persist()
    }

    /// This session's media rows assigned to `exerciseID` (any set or the exercise as a whole).
    private func mediaRows(assignedTo exerciseID: UUID) -> [SessionMedia] {
        let sid = session.id
        let exID: UUID? = exerciseID
        return (try? context.fetch(FetchDescriptor<SessionMedia>(
            predicate: #Predicate { $0.sessionID == sid && $0.assignedExerciseID == exID }))) ?? []
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

    /// Cache the climbing stats for the ribbon (Phase 3). Pure + cheap, but cached the same way as
    /// `prefills` so the ~1 Hz command-bar re-render (HR/timer) never re-derives the pyramid. `nil` when
    /// there's no climbing yet (the ribbon is hidden via `hasClimbing`). Live "end" = now; the ribbon
    /// shows sends/hardest/pyramid only (no HR), so the empty `hrSeries` default is fine here.
    private func recomputeClimbStats() {
        climbStats = FreeformClimbStats.hasClimbing(session)
            ? FreeformClimbStats.stats(for: session, now: .now)
            : nil
    }

    /// Rebuild the distinct previous-climbs catalog for the "Add a climb" re-log picker. Flattens the live
    /// session's climbs (most-recent first) then completed history (already reverse-sorted), pairing each
    /// climb with the time it was logged (its session's `startedAt`), and resolves a photo map (any climb's
    /// attached photos, grouped by `assignedExerciseID`) for the row previews. Pure dedup/ordering lives in
    /// `PreviousClimb.catalog`. Runs on appear + exercises-change only (never the ~1 Hz re-render). (prompt 81)
    private func rebuildPreviousClimbs() {
        var entries: [(exercise: SessionExercise, loggedAt: Date)] = []
        for ex in session.exercises.reversed() where ex.kind == .climbAttempt {
            entries.append((ex, session.startedAt))
        }
        for past in history where !past.isActive {
            for ex in past.exercises.reversed() where ex.kind == .climbAttempt {
                entries.append((ex, past.startedAt))
            }
        }
        // Photo map: a climb's attached photos, keyed by its `SessionExercise.id`, most-relevant first.
        var photoMap: [UUID: [String]] = [:]
        let photoRaw = SessionMedia.Kind.photo.rawValue
        let descriptor = FetchDescriptor<SessionMedia>(
            predicate: #Predicate { $0.kindRaw == photoRaw && $0.assignedExerciseID != nil },
            sortBy: [SortDescriptor(\SessionMedia.offsetSec, order: .forward)])
        if let media = try? context.fetch(descriptor) {
            for m in media {
                guard let exID = m.assignedExerciseID else { continue }
                photoMap[exID, default: []].append(m.localIdentifier)
            }
        }
        previousClimbs = PreviousClimb.catalog(from: entries, photoLookup: { photoMap[$0] ?? [] })
    }

    /// The zone ceiling for the live stats sheet's Effort block: the session's own snapshot, else the
    /// live profile, else the fixed default. Mirrors `KilterSessionDetailView.zoneMaxHR`.
    private var zoneMaxHR: Double {
        session.maxHR ?? app.userProfile.profile.resolvedMaxHR ?? HeartRateZone.defaultMaxHR
    }

    // MARK: - Live clips (§F)

    /// Discover clips filmed during the live session and auto-tag them to the set they fall in. Device
    /// -only: a no-op unless Photos is fully authorized (`canAutoDiscover`). Mirrors the post-session
    /// SessionDetailView path (discover → insert auto rows → reconcile) with the live window
    /// (`completedAt: nil` ⇒ "up to now").
    @MainActor private func discoverClips() async {
        guard app.sessionMedia.canAutoDiscover else { return }
        let sid = session.id
        // Auto-discovery dedups GLOBALLY (any session, not just this one) so a clip in the ±90s pad overlap
        // of two adjacent sessions is auto-tagged into one, not both (R2/R4). Re-discovery of this session's
        // own clips still skips them (the global set is a superset of the session's own). Identifier-only
        // fetch — this runs every 20 s on the MainActor for the whole live session (prompt 114).
        let existingIDs = SessionMedia.allIdentifiers(in: context)
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

    // MARK: - Clip lifecycle (deep-tap: reassign / remove / delete) — prompt 11

    /// Reassign a clip to `(exerciseID, setIndex)` — the move-to-attempt and remove-from-attempt paths of
    /// the deep-tap menu (prompt 11). Ported from `SessionDetailView.reassign`: a `nil` exerciseID untie it
    /// to the **General** bucket (it leaves the strip but keeps the file); any target pins `.manual` so the
    /// auto-reconciler (`reconcileAssignments`, which only re-places `.auto` rows) never clobbers the choice.
    private func reassignClip(_ item: SessionMedia, to exerciseID: UUID?, set setIndex: Int?) {
        item.assignedExerciseID = exerciseID
        item.assignedSetIndex = setIndex
        item.assignmentSource = exerciseID == nil ? .general : .manual
        try? context.save()
    }

    /// Permanently delete a clip — the deep-tap menu's destructive "Delete clip…" → the confirmation's
    /// "Delete from Photos too". Ported VERBATIM from `SessionDetailView.deleteFromPhotos`: delete the
    /// Photos asset FIRST (iOS shows its own confirmation), and only drop the session tag if that
    /// succeeds, so a denied/cancelled delete doesn't orphan the tag from a still-present asset.
    private func deleteClipFromPhotos(_ item: SessionMedia) {
        let id = item.localIdentifier
        Task {
            do {
                try await mediaLibrary.deleteAssets(localIdentifiers: [id])
                context.delete(item)
                try? context.save()
            } catch {
                // Asset not deleted (denied/cancelled) — keep the tag so the clip still shows.
            }
        }
    }

    // MARK: - Clip → Studio (§G)

    /// Open a freeform video clip in the shared multi-clip Studio editor, scoped to that clip. Reuses the
    /// session's one `StudioProject` (`StudioEntry.resolveProject`) — the same project the post-session
    /// detail and the module-level entry resolve — so the clip is editable now and as a reel later. The
    /// editor's own HR-load handles a still-live session (live watch+BLE fallback), so no manual flush.
    @MainActor private func presentStudio(_ clip: SessionMedia) {
        guard clip.kind == .video else { return }
        let sid = session.id
        let media = (try? context.fetch(FetchDescriptor<SessionMedia>(
            predicate: #Predicate { $0.sessionID == sid }))) ?? []
        let project = StudioEntry.resolveProject(for: session, media: media, context: context)
        studioClip = FreeformStudioPresentation(
            project: project, visibleClipMediaIDs: [clip.id], focusClipMediaID: clip.id,
            climbCaption: freeformClimbCaption(for: clip),
            // The clip is attached to a specific attempt (`assignedSetIndex` is 0-based) — thread the
            // 1-based attempt number so the editor can offer the "Attempt #" climb-tag option (prompt 10).
            suggestedAttemptNumber: clip.assignedSetIndex.map { $0 + 1 })
    }

    /// Whether this climb has ≥1 video clip (a `SessionMedia` assigned to it, `kind == .video`) — gates
    /// the "Edit all clips" menu item (prompt 10). Reads the session's persisted media for the exercise.
    private func hasVideoClips(_ ex: SessionExercise) -> Bool {
        let sid = session.id
        let exID = ex.id
        let media = (try? context.fetch(FetchDescriptor<SessionMedia>(
            predicate: #Predicate { $0.sessionID == sid }))) ?? []
        return media.contains { $0.assignedExerciseID == exID && $0.kind == .video }
    }

    /// Open the shared Studio editor scoped to ALL of a climb's attempt video clips together (prompt 10).
    /// Gathers the climb's video `SessionMedia.id`s, resolves the session's single shared `StudioProject`
    /// (`StudioEntry.resolveProject`), and presents it scoped to those ids — so the per-clip edits already
    /// living on that shared project show together. `suggestedAttemptNumber` is nil here (the combined
    /// view spans many attempts, so there's no single attempt number to tag). No-op without a video clip.
    @MainActor private func presentStudioForClimb(_ ex: SessionExercise) {
        let sid = session.id
        let exID = ex.id
        let media = (try? context.fetch(FetchDescriptor<SessionMedia>(
            predicate: #Predicate { $0.sessionID == sid }))) ?? []
        let clips = media.filter { $0.assignedExerciseID == exID && $0.kind == .video }
        guard let first = clips.first else { return }
        let project = StudioEntry.resolveProject(for: session, media: media, context: context)
        let parts = [ex.displayName, ex.climbGradeLabel].compactMap { $0?.isEmpty == false ? $0 : nil }
        studioClip = FreeformStudioPresentation(
            project: project, visibleClipMediaIDs: Set(clips.map(\.id)), focusClipMediaID: first.id,
            climbCaption: parts.isEmpty ? nil : parts.joined(separator: " · "),
            suggestedAttemptNumber: nil)
    }

    /// The climb-name caption ("Cave Roof · V5") for a clip assigned to a freeform `.climbAttempt`
    /// exercise (prompt 09): name · grade, dropping either piece when blank. `nil` when the clip isn't
    /// assigned to a climb — so the editor's Kilter (`resolvedClimbUUID`) path is untouched.
    private func freeformClimbCaption(for clip: SessionMedia) -> String? {
        guard let exID = clip.assignedExerciseID,
              let ex = session.exercises.first(where: { $0.id == exID && $0.kind == .climbAttempt })
        else { return nil }
        let parts = [ex.displayName, ex.climbGradeLabel].compactMap { $0?.isEmpty == false ? $0 : nil }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Open the WHOLE session in the shared Studio editor — the completion summary's "Turn N clips into a
    /// reel" CTA (Phase 7). Reuses the same one `StudioProject` (`StudioEntry.resolveProject`) the
    /// per-clip path and the post-session detail resolve, with no clip filter so every clip is on the
    /// reel timeline. No-op when the session has no video clip (the CTA is hidden in that case anyway).
    @MainActor private func presentSessionStudio() {
        let sid = session.id
        let media = (try? context.fetch(FetchDescriptor<SessionMedia>(
            predicate: #Predicate { $0.sessionID == sid }))) ?? []
        guard media.contains(where: { $0.kind == .video }) else { return }
        let project = StudioEntry.resolveProject(for: session, media: media, context: context)
        studioClip = FreeformStudioPresentation(
            project: project, visibleClipMediaIDs: nil, focusClipMediaID: nil)
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

/// A freeform clip opened in the shared Studio editor (§G), scoped to that one clip. Mirrors the
/// session-detail / Kilter presentation structs; held in `@State` and presented via `fullScreenCover`.
private struct FreeformStudioPresentation: Identifiable {
    let id = UUID()
    let project: StudioProject
    /// `nil` = whole session; `[clip.id]` = one clip (filters the timeline by `TimelineClip.sessionMediaID`).
    let visibleClipMediaIDs: Set<UUID>?
    /// Pre-selects the tapped clip on open.
    let focusClipMediaID: UUID?
    /// The freeform climb's caption ("Cave Roof · V5") when the tapped clip belongs to a `.climbAttempt`
    /// exercise (prompt 09) — threaded to the editor so the user can drop the climb's NAME as a lower-third
    /// overlay even without a Kilter `KilterLogEntry`. `nil` for non-climb clips / the whole-session reel.
    var climbCaption: String? = nil
    /// The 1-based attempt number the focused clip belongs to (prompt 10), threaded so the editor can offer
    /// a user-toggleable "Attempt #" option on the climb-name tag. `nil` when the clip isn't a single climb
    /// attempt (whole-session reel / non-climb / the combined "Edit all clips" view spanning many attempts).
    var suggestedAttemptNumber: Int? = nil
}

/// A climb being EDITED (prompt 09): the climb's `id` to overwrite + the prefill snapshot for the sheet.
/// `Identifiable` so it drives a `.sheet(item:)` (re-presents per climb without a stale binding).
private struct EditClimbTarget: Identifiable {
    let exerciseID: UUID
    let initial: AddClimbParams
    var id: UUID { exerciseID }
}

/// The "Edit details" target for a strength exercise (Workout-Type Parity, strength polish) — the catalog
/// name (placeholder), the prefilled params, and the cross-session last set (the "Last time" chip).
private struct EditStrengthTarget: Identifiable {
    let exerciseID: UUID
    let catalogName: String
    let initial: AddStrengthParams
    let lastReps: Int?
    let lastWeight: Double?
    let lastUnit: WeightUnit?
    var id: UUID { exerciseID }
}

/// Which exercise a new set/attempt is being logged into (drives the `LogSetSheet`). Carries the
/// catalog `exerciseId` too so the sheet can pull the cross-session prefill for that exercise. (§B)
private struct LogTarget: Identifiable {
    let exerciseID: UUID
    let kind: SetKind
    let exerciseId: String
    /// The timed exercise's structure (Phase 5) — lets the `.duration` log sheet arm the stopwatch to
    /// count DOWN for a max-hang / count-down target instead of always counting up. `nil` for non-timed.
    var timedSpec: TimedExerciseSpec? = nil
    var id: UUID { exerciseID }
}

/// Which structured timed exercise the interval runner is open for (drives `StructuredTimedRunner`, Quick
/// Session redesign Phase 6). Carries the resolved display name + the spec the runner unrolls.
private struct IntervalRunTarget: Identifiable {
    let exerciseID: UUID
    let spec: TimedExerciseSpec
    let name: String
    var id: UUID { exerciseID }
}

/// Which climb a timed attempt is being logged into (drives the `TimedAttemptCover`). Carries the
/// climb's type so the cover's outcome buttons relabel for routes; the name/grade/attempt-number are
/// resolved from the session at presentation. (Quick Session redesign Phase 2)
private struct TimedAttemptTarget: Identifiable {
    let exerciseID: UUID
    let type: ClimbType
    var id: UUID { exerciseID }
}

/// The "Time this set" target for a strength/generic exercise (Workout-Type Parity Phase 3) — the
/// exercise to time + the reps/weight seed the `TimedSetCover` opens with. `id` is per-presentation (not
/// the exercise id) so re-timing the same exercise re-presents the cover.
private struct TimedSetTarget: Identifiable {
    let id = UUID()
    let exerciseID: UUID
    let reps: Int
    let weight: Double
    let unit: WeightUnit
}

/// The "Log a leg" target for a running entity (Workout-Type Parity Phase 4).
private struct RunLegTarget: Identifiable {
    let id = UUID()
    let exerciseID: UUID
}

/// The exercise a plan-editor sheet is open for (prompt 109).
private struct PlanEditTarget: Identifiable {
    let exerciseID: UUID
    var id: UUID { exerciseID }
}

/// The exercise a history drawer is open for (prompt 109).
private struct HistoryTarget: Identifiable {
    let exerciseID: UUID
    var id: UUID { exerciseID }
}

/// The catalog exercise a guide drawer (photos + how-to) is open for (prompt 109).
private struct GuideTarget: Identifiable {
    let exercise: Exercise
    var id: String { exercise.id }
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
    /// The timed exercise's structure (Phase 5) — arms the duration stopwatch to count DOWN for a
    /// max-hang / count-down target; `nil` (or an open count-up) keeps the count-up behavior.
    let timedSpec: TimedExerciseSpec?
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
         timedSpec: TimedExerciseSpec? = nil,
         onAdd: @escaping (SetLog) -> Void) {
        self.kind = kind
        self.unit = unit
        self.timedSpec = timedSpec
        self.onAdd = onAdd
        // Prefill the reps/weight/unit from the last time this exercise was done (§B) so the "log
        // something different" sheet opens on the user's last values to tweak, not blank.
        _unitSel = State(initialValue: prefill?.unit ?? unit)
        _reps = State(initialValue: prefill?.reps.map(String.init) ?? "")
        _weight = State(initialValue: prefill?.weight.map(SetMeasure.formatWeight) ?? "")
    }

    @FocusState private var keypadFocused: Bool

    /// The stopwatch mode for the duration timer: count DOWN from the target for a max-hang / count-down
    /// spec (so the dial shows the prescribed hold draining), else count up (the open default).
    private var durationStopwatchMode: StopwatchTiming.Mode {
        guard let spec = timedSpec, spec.mode == .maxHang || spec.mode == .countDown, spec.workSec > 0
        else { return .countUp }
        return .countDown(targetSec: TimeInterval(spec.workSec))
    }

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
                        // Press Start → do the hold → Stop captures the ELAPSED seconds held into the same
                        // minutes/seconds the save path reads (PR 1's StopwatchView). For a max-hang /
                        // count-down target the dial counts DOWN from `workSec` (Phase 5) — the captured
                        // value is still the elapsed time held, so logging is unchanged; the structured
                        // repeaters/tabata/emom runner is Phase 6.
                        StopwatchView(mode: durationStopwatchMode) { elapsed in
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
