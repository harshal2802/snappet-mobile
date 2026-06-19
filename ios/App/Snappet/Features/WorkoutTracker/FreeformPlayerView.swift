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
    /// The "Pick or create a timed exercise" sheet (Quick Session redesign Phase 5): the timed-first
    /// entry point both the empty-state Timed card and the add-menu's "Timed exercise" button now present.
    @State private var addingTimed = false
    /// Which climb cards are expanded (by `SessionExercise.id`) to their attempt list + footer. A new
    /// climb auto-expands; "Add & log first attempt" also auto-opens its inline outcome strip.
    @State private var expandedClimbs: Set<UUID> = []
    /// Climbs showing their inline outcome strip (the "+ Log attempt" footer toggled open).
    @State private var loggingAttemptFor: Set<UUID> = []
    /// The climb a minimal timed-attempt sheet is open for (Phase 2 replaces this with a FOCUS cover).
    @State private var timingAttemptFor: TimedAttemptTarget?
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
        NavigationStack {
            ScrollViewReader { proxy in
            List {
                titleSection
                // Live climbing stats ribbon (Phase 3): docked above the climb cards, only once any
                // climbing has been logged. A full-width tappable row → the expanded stats sheet.
                if FreeformClimbStats.hasClimbing(session) { statsRibbonSection }
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
            // At-logging milestone banner (Phase 3 §3): a brief glass headline over the top of the
            // logbook for a genuine new best (first-of-grade send / new hardest / flash). The burst +
            // haptic fire via `.celebrates(on:)`; Reduce Motion shows the static text + haptic only.
            .overlay(alignment: .top) { milestoneBanner }
        }
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
                attemptNumber: (climb?.sets.count ?? 0) + 1) { status, duration in
                    logAttempt(toExerciseID: target.exerciseID, status: status, durationSec: duration)
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
            Button("Timed exercise") { addingTimed = true }
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
        .onAppear {
            app.workoutNotifications.requestAuthorization()
            recomputePrefills()
            recomputeClimbStats()
            rebuildPreviousClimbs()
            pushLiveActivity()
        }
        .onChange(of: session.exercises.count) { _, _ in
            recomputePrefills()
            recomputeClimbStats()
            rebuildPreviousClimbs()
        }
        // Keep the Live Activity (Lock Screen / Dynamic Island) in sync with the freeform session:
        // live HR and the paused state push as they change. The overall timer self-ticks off
        // `startedAt`; these refresh HR + the exercise line + the paused flag. Mirrors `WorkoutPlayerView`.
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

    // MARK: - Sections

    /// Inline-editable session title (§A). Commits to `WorkoutSession.routineName` (default "Quick
    /// session") and refreshes the Live Activity's live state. NOTE: the Lock-Screen session title is an
    /// immutable ActivityKit *attribute* fixed at start — it won't change mid-session; only the live
    /// fields (HR / current exercise / paused) refresh here. A leaf TextField.
    private var titleSection: some View {
        Section {
            TextField("Session name", text: $session.routineName)
                .font(.title3.weight(.semibold))
                .submitLabel(.done)
                .onSubmit { persist(); pushLiveActivity() }
                .accessibilityIdentifier("freeform.sessionTitle")
        }
    }

    // MARK: - Live stats ribbon (Phase 3)

    /// The docked climbing stats ribbon: a full-width tappable row — hero "N sends", "hardest <grade>"
    /// (omitted until a send exists), and an inline mini-pyramid (bars by grade). Before the first send
    /// it teaches ("Send one to start your pyramid"). Reads the cached `climbStats` (recomputed on
    /// `session.exercises` change). Tapping presents the expanded `LiveClimbStatsSheet`.
    private var statsRibbonSection: some View {
        Section {
            Button { showingClimbStats = true } label: { statsRibbonContent }
                .buttonStyle(.plain)
                .accessibilityIdentifier("freeform.statsRibbon")
                .accessibilityLabel(statsRibbonAccessibilityLabel)
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
                        rebuildPreviousClimbs()   // fresh previews/counts on open (media added mid-session)
                        addingClimb = true
                    }
                    typeCard("Timed", symbol: "timer",
                             id: "freeform.cardTimed", accLabel: "Start a timed exercise") {
                        addingTimed = true
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
        }
    }

    /// Seed values for an exercise's inline quick-add (§B). The weight AND its unit come from the SAME
    /// source (this session's last set, else the cross-session prefill, else bodyweight) so the pair
    /// never crosses — e.g. a prefill weight recorded in lb is never shown beside this session's kg.
    private func quickAddSeed(for ex: SessionExercise) -> (reps: Int, weight: Double, unit: WeightUnit, hint: String?) {
        let last = ex.sets.last
        let pf = prefills[ex.exerciseId]
        let reps = last?.actualReps ?? pf?.reps ?? 8
        let hint = last == nil ? pf?.hint : nil
        if let w = last?.actualWeight {
            return (reps, w, last?.weightUnit ?? unit, hint)
        } else if let w = pf?.weight {
            return (reps, w, pf?.unit ?? unit, hint)
        }
        return (reps, 0, last?.weightUnit ?? pf?.unit ?? unit, hint)
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

    @ViewBuilder
    private func exerciseSection(_ ex: SessionExercise) -> some View {
        // Climbs are a climb-first hierarchy (Quick Session redesign Phase 1): the `.climbAttempt`
        // exercise IS the climb, its `sets` are the attempts logged underneath an expandable card. The
        // lifting / timed flows keep the flat set-list rendering below.
        if ex.kind == .climbAttempt {
            climbSection(ex)
        } else if ex.kind == .duration {
            // Timed exercises are a timed-first hierarchy (Quick Session redesign Phase 5): the `.duration`
            // exercise IS the named timed exercise, its `sets` are the timed holds logged underneath a
            // climb-style card. The lifting flow keeps the flat set-list rendering below.
            timedSection(ex)
        } else {
            liftingOrTimedSection(ex)
        }
    }

    // MARK: - Timed card (Quick Session redesign Phase 5)

    /// A named timed exercise renders like a climb card: a header (timer icon · name · the spec's
    /// structure summary · "N sets" · total hold time) with its timed sets underneath; "Add set" runs the
    /// timer (the simple `StopwatchView` Timer path — the structured repeaters/tabata/emom runner is
    /// Phase 6, armed to count down for max-hang / count-down targets), and a one-tap Repeat.
    private func timedSection(_ ex: SessionExercise) -> some View {
        Section {
            ForEach(Array(ex.sets.enumerated()), id: \.offset) { i, set in
                HStack {
                    Text("\(i + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 20, alignment: .leading)
                    Text(SetMeasure.summary(set, kind: .duration, unit: unit))
                        .font(.body.weight(.medium))
                    Spacer()
                }
                .accessibilityIdentifier("freeform.setRow")
            }
            .onDelete { offsets in deleteSets(ex, at: offsets) }

            Button {
                // Quick Session redesign Phase 6: a structured spec (repeaters/tabata/emom) runs the
                // full-cover interval runner; the simple modes keep the Phase-5 `LogSetSheet` stopwatch.
                if let spec = ex.timedSpec, spec.mode.isStructured {
                    runningInterval = IntervalRunTarget(exerciseID: ex.id, spec: spec,
                                                        name: resolver.name(for: ex.exerciseId, override: ex.displayName))
                } else {
                    logging = LogTarget(exerciseID: ex.id, kind: .duration, exerciseId: ex.exerciseId,
                                        timedSpec: ex.timedSpec)
                }
            } label: {
                Label("Add set", systemImage: "plus.circle.fill")
            }
            .accessibilityIdentifier("freeform.addSet")

            // One-tap repeat of the most recent timed hold (re-logs its duration), via the shared funnel.
            if let last = ex.sets.last {
                Button {
                    repeatLastSet(ex)
                } label: {
                    Label(FreeformSummary.repeatLabel(for: last, kind: .duration, unit: unit),
                          systemImage: "arrow.clockwise")
                }
                .accessibilityIdentifier("freeform.repeatSet")
            }

            if let lastIndex = ex.sets.indices.last {
                SetMediaStrip(session: session, exerciseID: ex.id, setIndex: lastIndex,
                              onEdit: { presentStudio($0) })
                    .id("set-media-\(ex.id)-\(lastIndex)")
            }
        } header: {
            timedHeader(ex)
        }
    }

    /// The timed card header: timer icon · name · the spec's structure summary · "N sets" · total hold time.
    private func timedHeader(_ ex: SessionExercise) -> some View {
        let spec = ex.timedSpec
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: "timer").foregroundStyle(SnappetColor.workout)
                Text(resolver.name(for: ex.exerciseId, override: ex.displayName))
                    .accessibilityIdentifier("freeform.timedName")
                Spacer()
                Menu {
                    Button(role: .destructive) { removeExercise(ex) } label: {
                        Label("Remove exercise", systemImage: "trash")
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
            HStack(spacing: 6) {
                if let spec { Text(spec.summary) }
                Text("· \(ex.sets.count) \(ex.sets.count == 1 ? "set" : "sets")")
                if let hold = timedHoldTotal(ex) { Text("· \(hold)") }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .textCase(nil)
    }

    /// Total logged hold time across this timed exercise's sets — the timed analogue of time-on-climb.
    private func timedHoldTotal(_ ex: SessionExercise) -> String? {
        let total = ex.sets.compactMap { $0.durationSec }.reduce(0, +)
        return total > 0 ? SetMeasure.formatDuration(total) : nil
    }

    private func liftingOrTimedSection(_ ex: SessionExercise) -> some View {
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
                let seed = quickAddSeed(for: ex)
                QuickAddRow(reps: seed.reps, weight: seed.weight, unitSel: seed.unit, hint: seed.hint) { log in
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
            // Reuse the existing repeat affordance for timed sets (climbs have their own card footer).

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
                SetMediaStrip(session: session, exerciseID: ex.id, setIndex: lastIndex,
                              onEdit: { presentStudio($0) })
                    .id("set-media-\(ex.id)-\(lastIndex)")
            }
        } header: {
            HStack {
                Image(systemName: ex.kind.symbol).foregroundStyle(.secondary)
                Text(resolver.name(for: ex.exerciseId, override: ex.displayName))
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

    // MARK: - Climb card (Quick Session redesign Phase 1)

    /// A climb renders as an **expandable card**: a rolled-up header (type icon · inline-editable name ·
    /// grade pill · status badge · "N attempts" · time-on-climb) that toggles open to the attempt list +
    /// a footer ("+ Log attempt" → inline outcome strip · "Timed attempt" · one-tap "Repeat last").
    /// Attempts are stamped with the climb's grade so the pure send/pyramid/milestone reads stay
    /// per-`SetLog`; the per-attempt row (`SetMeasure.attemptRow`) shows only the outcome + duration.
    @ViewBuilder
    private func climbSection(_ ex: SessionExercise) -> some View {
        let expanded = expandedClimbs.contains(ex.id)
        Section {
            climbHeader(ex, expanded: expanded)

            if expanded {
                ForEach(Array(ex.sets.enumerated()), id: \.offset) { i, set in
                    HStack {
                        Text("\(i + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 20, alignment: .leading)
                        Text(SetMeasure.attemptRow(set, type: ex.climbType))
                            .font(.body.weight(.medium))
                        Spacer()
                    }
                    .accessibilityIdentifier("freeform.setRow")
                    // Per-attempt media (prompt 09): a clip filmed during / attached to THIS attempt shows
                    // under it; a video tap opens the Studio editor. Auto-assignment already tags
                    // `.climbAttempt` sets (`SessionMediaAssignment.completions`), so this is a pure UI add.
                    // Keyed by exercise+attempt so its @Query re-scopes per attempt. Device-only for the
                    // PHPicker/Photos pick; the affordance renders everywhere.
                    // Deep-tap clip lifecycle (prompt 11): the move-targets are this climb's attempts, and
                    // the reassign/delete closures pin `.manual`/`.general` (sticky) or host the Photos-aware
                    // delete confirmation.
                    SetMediaStrip(session: session, exerciseID: ex.id, setIndex: i,
                                  onEdit: { presentStudio($0) },
                                  moveTargets: climbClipMoveTargets(for: ex),
                                  onReassign: { reassignClip($0, to: $1, set: $2) },
                                  onRequestDelete: { pendingClipDeletion = $0 })
                        .id("climb-media-\(ex.id)-\(i)")
                }
                .onDelete { offsets in deleteSets(ex, at: offsets) }

                climbFooter(ex)
            }
        } header: {
            EmptyView()
        }
    }

    /// The rolled-up climb header: type icon · name LABEL (`freeform.climbName`) · grade pill · status
    /// badge · "N attempts" · time-on-climb. The name + chevron together are the expand/collapse
    /// affordance (prompt 10 — tapping the name no longer inline-edits it; editing the name is now solely
    /// via the ⋯ menu → "Edit details"). The remove/edit menu stays an individually tappable leaf.
    private func climbHeader(_ ex: SessionExercise, expanded: Bool) -> some View {
        let name = ex.displayName ?? SetMeasure.climbName("")
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: ex.climbType.symbol).foregroundStyle(SnappetColor.workout)
                // Name + chevron = the expand/collapse affordance (prompt 10). The name is a plain,
                // non-editing label (still `freeform.climbName`, now a label not a field) so it stays
                // queryable; tapping it (or the chevron) toggles the card.
                Button {
                    toggleExpanded(ex)
                } label: {
                    Text(name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                // The id lives on the tappable label so it stays queryable (`freeform.climbName`); it's
                // now a tap-to-expand control whose `.label` is the climb name, not a text field (prompt 10).
                .accessibilityIdentifier("freeform.climbName")
                Spacer(minLength: 4)
                colorSwatch(ex)
                gradePill(ex)
                Button {
                    toggleExpanded(ex)
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("freeform.climbExpand")
                .accessibilityLabel(expanded ? "Collapse climb" : "Expand climb")
                Menu {
                    climbMenuContent(ex)
                } label: { Image(systemName: "ellipsis.circle").foregroundStyle(.secondary) }
                    .accessibilityIdentifier("freeform.climbMenu")
                    .accessibilityLabel("Climb options")
            }
            climbLocationLine(ex)
            HStack(spacing: 8) {
                statusBadge(ex)
                Text(attemptCountLabel(ex))
                    .font(.caption).foregroundStyle(.secondary)
                if let time = climbTimeOnWall(ex) {
                    Text("· \(time)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .textCase(nil)
        .padding(.vertical, 2)
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

    /// The footer of an expanded climb card: "+ Log attempt" → an inline outcome strip (four type-aware
    /// buttons, NO grade prompt), a "Timed attempt" button, and a one-tap "Repeat last".
    @ViewBuilder
    private func climbFooter(_ ex: SessionExercise) -> some View {
        if loggingAttemptFor.contains(ex.id) {
            // The inline outcome strip — four type-aware outcome buttons. Each appends an attempt stamped
            // with the climb's grade (no per-attempt grade entry); a leaf button per outcome.
            VStack(alignment: .leading, spacing: 8) {
                Text("Outcome").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(KilterAscentStatus.allCases, id: \.self) { status in
                        Button {
                            logAttempt(toExerciseID: ex.id, status: status, durationSec: nil)
                            loggingAttemptFor.remove(ex.id)
                        } label: {
                            Text(ex.climbType.statusLabel(status))
                                .font(.caption.weight(.medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(SnappetColor.surfaceMuted, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("freeform.outcome.\(status.rawValue)")
                    }
                }
            }
            .padding(.vertical, 4)
        } else {
            Button {
                loggingAttemptFor.insert(ex.id)
            } label: {
                Label("Log attempt", systemImage: "plus.circle.fill")
            }
            .accessibilityIdentifier("freeform.logAttempt")
        }

        Button {
            timingAttemptFor = TimedAttemptTarget(exerciseID: ex.id, type: ex.climbType)
        } label: {
            Label("Timed attempt", systemImage: "stopwatch")
        }
        .accessibilityIdentifier("freeform.timedAttempt")

        // One-tap repeat of the most recent attempt (re-logs its outcome + duration, stamped grade).
        if let last = ex.sets.last {
            Button {
                appendLog(SetMeasure.duplicate(last), toExerciseID: ex.id)
            } label: {
                Label("Repeat \(SetMeasure.attemptRow(last, type: ex.climbType))",
                      systemImage: "arrow.clockwise")
            }
            .accessibilityIdentifier("freeform.repeatSet")
        }
    }

    /// The grade pill: the climb's grade label on a `SnappetColor.kilter` (boulder) / cool (route) capsule.
    private func gradePill(_ ex: SessionExercise) -> some View {
        let isBoulder = !ex.climbType.isRoute
        return Text(ex.climbGradeLabel ?? "—")
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(isBoulder ? SnappetColor.kilter : SnappetColor.budget, in: Capsule())
            .accessibilityIdentifier("freeform.gradePill")
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

    /// The persistent bottom command bar (§A): wall-clock total timer · compact live-HR chip · the
    /// always-available Finish. The timer/HR are non-interactive labels (a labelled composite is fine —
    /// the leaf-only rule is about interactive controls); Finish keeps its `freeform.finish` id. A thin
    /// rest-timer banner (Phase 7) floats ABOVE it (an overlay, not a stacked row) while a rest count-down
    /// is active — so the bar's `safeAreaInset` height (which the List's bottom content-margin is sized
    /// to) is unchanged when there's no rest, keeping the last set's controls hittable.
    private var commandBar: some View {
        commandBarRow
            .background(.bar)
            .overlay(alignment: .top) {
                if restRunning {
                    restBar.alignmentGuide(.top) { $0[.bottom] }   // sit just above the bar
                }
            }
    }

    /// The non-blocking rest count-down banner (Phase 7): a label · −/+ nudges (remembered per context) ·
    /// a dismiss. Shown only while a rest is running; logging the next set is never gated by it. At zero
    /// it reads "Rest done" (the at-zero haptic already fired in the view model).
    private var restBar: some View {
        let remaining = restTimer.reading.remaining ?? 0
        let done = restTimer.reading.reachedZero
        return HStack(spacing: 10) {
            Image(systemName: "hourglass").foregroundStyle(SnappetColor.workout)
            if done {
                Text("Rest done").font(.subheadline.weight(.semibold)).foregroundStyle(SnappetColor.workout)
            } else {
                Text("Rest").font(.subheadline).foregroundStyle(.secondary)
                Text(SetMeasure.formatDuration(remaining))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .contentTransition(.numericText())
                    .accessibilityIdentifier("freeform.restTimer")
            }
            Spacer(minLength: 8)
            if !done {
                Button { adjustRest(by: -RestTimerDefaults.stepSeconds) } label: {
                    Image(systemName: "minus.circle.fill").font(.title3)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("freeform.restMinus")
                .accessibilityLabel("Shorten rest")
                Button { adjustRest(by: RestTimerDefaults.stepSeconds) } label: {
                    Image(systemName: "plus.circle.fill").font(.title3)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("freeform.restPlus")
                .accessibilityLabel("Lengthen rest")
            }
            Button { dismissRest() } label: {
                Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("freeform.restDismiss")
            .accessibilityLabel("Dismiss rest timer")
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(SnappetColor.workout.opacity(0.10))
    }

    private var commandBarRow: some View {
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

            // Auto-rest opt-in (Phase 7): a glanceable toggle so the remembered count-down can be turned
            // on/off without leaving the player. Dimmed when off; a filled hourglass when armed.
            Button { restAutoStart.toggle(); Haptics.tap() } label: {
                Image(systemName: restAutoStart ? "hourglass.circle.fill" : "hourglass.circle")
                    .font(.title3)
                    .foregroundStyle(restAutoStart ? SnappetColor.workout : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("freeform.restToggle")
            .accessibilityLabel(restAutoStart ? "Auto rest timer on" : "Auto rest timer off")

            Button { finishTapped() } label: {
                Text("Finish").font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .tint(SnappetColor.workout)
            .accessibilityIdentifier("freeform.finish")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
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
            session.exercises.append(SessionExercise(
                exerciseId: ex.id, targetSets: 0, targetReps: "", targetRestSeconds: 0,
                sets: [], displayName: nil, kindRaw: SetKind.repsWeight.rawValue))
        }
        persist()
        pushLiveActivity()   // the new exercise becomes the current one → refresh the Lock Screen label
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
        expandedClimbs.insert(climb.id)
        if logFirstAttempt { loggingAttemptFor.insert(climb.id) }
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
        expandedClimbs.insert(id)
    }

    private func toggleExpanded(_ ex: SessionExercise) {
        if expandedClimbs.contains(ex.id) { expandedClimbs.remove(ex.id) }
        else { expandedClimbs.insert(ex.id) }
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
        let seconds = RestTimerDefaults.remembered(for: ctx, in: restDefaults)
        restContext = ctx
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
