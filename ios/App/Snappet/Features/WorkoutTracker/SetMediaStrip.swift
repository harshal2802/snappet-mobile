import SwiftUI
import SwiftData

/// M3 — the live player's **per-set media strip**: shows the clips already tagged to the current
/// set and an "Attach to this set" action (PHPicker) that files the picked photos/videos against
/// **this** set with `manual` provenance, so the post-session auto-assigner leaves them put. The
/// caller keys it by exercise+set (`.id`), so the `@Query` re-scopes as the user advances through
/// the workout. The PHPicker pick + real thumbnails are device-only (the simulator has no Photos);
/// the affordance itself renders everywhere, so the "attach during the session" flow is reachable
/// the moment a clip exists in the library.
struct SetMediaStrip: View {
    let session: WorkoutSession
    let exerciseID: UUID
    let setIndex: Int

    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Query private var media: [SessionMedia]
    @State private var showingPicker = false

    init(session: WorkoutSession, exerciseID: UUID, setIndex: Int) {
        self.session = session
        self.exerciseID = exerciseID
        self.setIndex = setIndex
        let sid = session.id
        // Compare against optionals explicitly (the stored fields are UUID? / Int?).
        let exID: UUID? = exerciseID
        let sIdx: Int? = setIndex
        _media = Query(filter: #Predicate<SessionMedia> {
            $0.sessionID == sid && $0.assignedExerciseID == exID && $0.assignedSetIndex == sIdx
        }, sort: \SessionMedia.offsetSec, order: .forward)
    }

    var body: some View {
        VStack(spacing: 8) {
            if !media.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(media) { SessionMediaThumb(item: $0) }
                    }
                    .padding(.horizontal, 2)
                }
            }
            Button {
                Task { await ensureAccessThenPick() }
            } label: {
                Label(media.isEmpty ? "Attach clip to this set" : "Attach another clip",
                      systemImage: "paperclip")
                    .font(.subheadline)
            }
            .accessibilityIdentifier("attachClipToSet")
        }
        .sheet(isPresented: $showingPicker) {
            MediaPicker { ids in attach(ids) }
        }
    }

    @MainActor private func ensureAccessThenPick() async {
        if app.sessionMedia.currentStatus == .notDetermined {
            app.photoAccess = await app.sessionMedia.requestAccess()
        }
        showingPicker = true
    }

    /// File the picked clips against this set. `candidates(forIdentifiers:)` resolves each PHAsset's
    /// kind/duration and maps its capture time to a session-relative offset; we stamp the set
    /// assignment as `manual` so it's sticky against post-session reconciliation.
    private func attach(_ ids: [String]) {
        let existing = Set(media.map(\.localIdentifier))
        let cands = app.sessionMedia.candidates(
            forIdentifiers: ids, startedAt: session.startedAt, existingIdentifiers: existing)
        for c in cands {
            context.insert(SessionMedia(
                sessionID: session.id, localIdentifier: c.localIdentifier, kind: c.kind,
                offsetSec: c.offsetSec, durationSec: c.durationSec, addedManually: true,
                assignedExerciseID: exerciseID, assignedSetIndex: setIndex, source: .manual))
        }
        try? context.save()
    }
}
