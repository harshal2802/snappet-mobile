import SwiftUI
import SwiftData
import HighlightEngine

/// The **type-adaptive completion summary** (Quick Session redesign Phase 7) — the post-workout recap the
/// freeform player shows on Finish. Since workout-redesign E0 the hero + per-discipline cards are the
/// SHARED `SessionRecapHero` + `SessionRecapCards` (so the completed-session detail, E2, renders the same
/// recap instead of a poorer flat list). This view keeps the Finish-specific chrome: the milestone seal +
/// `CelebrationBurst`, the "Keep going" top bar, the "Turn N clips into a reel" Studio CTA, and the
/// Done / View detail / Discard action bar — all with the same a11y ids as before. **No behavior change**
/// from the pre-E0 screen: it composes the exact hero cells + cards that used to live here inline.
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

    // MARK: - Video clip count

    /// Count video clips filmed in this session (the reel CTA gate). Device-only clips are 0 on the sim.
    private func countVideoClips() -> Int {
        let sid = session.id
        let media = (try? context.fetch(FetchDescriptor<SessionMedia>(
            predicate: #Predicate { $0.sessionID == sid }))) ?? []
        return media.filter { $0.kind == .video }.count
    }
}
