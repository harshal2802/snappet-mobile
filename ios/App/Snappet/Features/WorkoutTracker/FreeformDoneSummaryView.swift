import SwiftUI
import SwiftData
import HighlightEngine

/// The **type-adaptive completion summary** (Quick Session redesign Phase 7) — the post-workout recap the
/// freeform player shows on Finish. Since workout-redesign E0 the hero + per-discipline cards are the
/// SHARED `SessionRecapHero` + `SessionRecapCards` (so the completed-session detail, E2, renders the same
/// recap instead of a poorer flat list). This view keeps the Finish-specific chrome: the milestone seal +
/// `CelebrationBurst`, the "Keep going" top bar, the "Turn N clips into a reel" Studio CTA, the
/// **"Save as routine"** affordance (E5), and the Done / View detail / Discard action bar — all with the
/// same a11y ids as before.
///
/// **Save as routine (workout-redesign E5).** A coral affordance (`freeform.saveAsRoutine`) — shown only
/// when the session has ≥ 1 completed set — presents a `RoutineEditorView` PRE-FILLED from the pure
/// `SessionToRoutine` converter (actuals → a per-discipline prescription draft). The user reviews/trims/
/// renames before the editor's own Save INSERTS a new routine; this view never writes the routine itself.
struct FreeformDoneSummaryView: View {
    @Bindable var session: WorkoutSession
    let resolver: ExerciseResolver
    let unit: WeightUnit
    /// Milestones reached this session (computed by the player against prior history before presenting).
    let milestones: [FreeformSummary.Milestone]
    /// The zone ceiling for the Effort block — the session's snapshot, else the live profile, else default.
    let maxHR: Double

    let onDone: () -> Void
    let onViewDetail: () -> Void
    let onKeepGoing: () -> Void
    let onDiscard: () -> Void
    /// Open the whole-session project in the shared Studio editor (the "Turn N clips into a reel" CTA).
    let onOpenStudio: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.modelContext) private var context

    @State private var doneBounce = 0
    @State private var celebrationTrigger = 0
    @State private var showingDiscard = false
    /// The pre-filled save-as-routine editor draft (E5); non-nil → the editor sheet is presented.
    @State private var savingRoutineDraft: RoutineDraft?
    @ScaledMetric(relativeTo: .largeTitle) private var sealSize: CGFloat = 64

    /// Video clips filmed during this session — gate the "Turn N clips into a reel" CTA. Counted on
    /// appear (the recap is read-only, so a one-shot count is enough); device-only clips are 0 on the sim.
    @State private var videoClipCount = 0

    private var stats: FreeformSummary.Stats { FreeformSummary.stats(for: session, unit: unit) }

    /// Climbing stats with HR — computed once for the hero's climbing cells (the cards compute their own).
    private var climbStats: KilterSessionStats {
        FreeformClimbStats.stats(for: session, now: .now,
                                 hrSeries: session.hrSeries.map {
                                     HRSample(t: $0.t, bpm: $0.bpm, rrIntervalsMs: $0.rrIntervalsMs)
                                 })
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(spacing: 20) {
                    seal
                    SessionRecapHero(cells: SessionRecap.heroCells(stats: stats, climbStats: climbStats,
                                                                   session: session, unit: unit,
                                                                   milestones: milestones))
                    SessionRecapCards(session: session, resolver: resolver, unit: unit,
                                      maxHR: maxHR, milestones: milestones)
                    if videoClipCount > 0 { studioCTA }
                }
                .padding(.horizontal)
                .padding(.bottom, 12)
            }
            actionBar
        }
        .padding(.vertical)
        .celebrates(on: celebrationTrigger)
        .confirmationDialog("Discard this workout?", isPresented: $showingDiscard, titleVisibility: .visible) {
            Button("Discard (don't save)", role: .destructive) { onDiscard() }
            Button("Keep going", role: .cancel) { onKeepGoing() }
        }
        // Save as routine (E5): the pre-filled editor for review — its own Save inserts a new routine. The
        // recap stays put underneath (the workout is still saved on Done), so the user can dismiss the
        // editor and continue.
        .sheet(item: $savingRoutineDraft) { draft in
            RoutineEditorView(routine: nil, prefill: draft, resolver: resolver, defaultUnit: unit)
        }
        .onAppear {
            doneBounce += 1
            if !milestones.isEmpty { celebrationTrigger += 1 }
            videoClipCount = countVideoClips()
        }
    }

    // MARK: - Top bar (Keep going)

    private var topBar: some View {
        HStack {
            Button("Keep going") { onKeepGoing() }
                .accessibilityIdentifier("freeform.keepGoing")
            Spacer()
        }
        .padding(.horizontal)
    }

    // MARK: - Seal + milestone headline

    private var seal: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: sealSize))
                .foregroundStyle(SnappetColor.workout)
                .symbolEffect(.bounce, value: reduceMotion ? 0 : doneBounce)
            Text("Workout Complete").font(.title.bold())
            Text(session.routineName).foregroundStyle(.secondary)
            if let milestone = milestones.first {
                Text(FreeformSummary.milestoneHeadline(milestone))
                    .font(.headline)
                    .foregroundStyle(SnappetColor.workout)
                    .accessibilityIdentifier("freeform.milestone")
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Studio CTA

    private var studioCTA: some View {
        Button { onOpenStudio() } label: {
            HStack(spacing: 10) {
                Image(systemName: "film.stack")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Turn \(videoClipCount) \(videoClipCount == 1 ? "clip" : "clips") into a reel")
                        .font(.subheadline.weight(.semibold))
                    Text("Open in Studio").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("freeform.summaryReel")
    }

    // MARK: - Action bar

    private var actionBar: some View {
        VStack(spacing: 12) {
            Button { onDone() } label: {
                Text("Done").font(.headline).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(SnappetColor.workout)
            .accessibilityIdentifier("freeform.done")

            // Save as routine (E5): close the runtime→template loop. The single coral (brand) affordance on
            // this screen — the type-aware "make this repeatable" moment — shown only when there's something
            // to prescribe (≥ 1 completed set). Opens the pre-filled editor for review (it never silently
            // inserts). The neutral Done/View-detail stay bordered so the coral reads as the one CTA.
            if SessionToRoutine.canConvert(session) {
                Button { saveAsRoutineTapped() } label: {
                    Label("Save as routine", systemImage: "square.and.arrow.down.on.square")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).tint(SnappetColor.brand)
                .accessibilityIdentifier("freeform.saveAsRoutine")
            }

            Button { onViewDetail() } label: {
                Text("View detail").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("freeform.viewDetail")

            Button("Discard workout", role: .destructive) { showingDiscard = true }
                .font(.footnote)
                .accessibilityIdentifier("freeform.discard")
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    /// Build the reviewable draft from the finished session (pure `SessionToRoutine`) and present the
    /// pre-filled editor. The conversion is lossy by design — the user trims warm-ups / renames / adjusts
    /// targets before the editor's Save inserts a new routine.
    private func saveAsRoutineTapped() {
        savingRoutineDraft = SessionToRoutine.draft(from: session, defaultUnit: unit)
    }

    // MARK: - Video clip count

    /// Count video clips filmed in this session (the reel CTA gate). Device-only clips are 0 on the sim.
    private func countVideoClips() -> Int {
        let sid = session.id
        let media = (try? context.fetch(FetchDescriptor<SessionMedia>(
            predicate: #Predicate { $0.sessionID == sid }))) ?? []
        return media.filter { $0.kind == .video }.count
    }
}
