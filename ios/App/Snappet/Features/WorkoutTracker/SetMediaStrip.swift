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
    /// Tap a VIDEO clip → open it in the shared Studio editor (#158 §G). `nil` ⇒ thumbnails aren't
    /// tappable (e.g. the guided player, which doesn't wire an editor entry).
    var onEdit: ((SessionMedia) -> Void)? = nil
    /// Deep-tap (long-press) clip-lifecycle wiring (prompt 11), threaded from `FreeformPlayerView` for the
    /// climb-attempt strips. `nil` (the default, e.g. lifting/timed strips + the guided player) ⇒ no
    /// context menu, so those strips are unchanged.
    /// — `moveTargets`: the entity's efforts a clip can be reassigned to.
    var moveTargets: [ClipMoveTarget] = []
    /// The discipline-aware "Move to …" submenu label ("Move to attempt…" climb / "Move to set…" strength /
    /// "Move to leg…" run). Defaults to the climb wording so the climb strips are unchanged.
    var moveTargetsLabel: String = "Move to attempt…"
    /// Reassign a clip to `(exerciseID, setIndex)` — `nil` exerciseID = the General bucket (untie it,
    /// keep the file). The owner pins `.manual` / `.general` so the move is sticky vs auto-reconcile.
    var onReassign: ((SessionMedia, UUID?, Int?) -> Void)? = nil
    /// Ask the owner to confirm + perform a permanent delete (Photos-aware confirmation hosted on the player).
    var onRequestDelete: ((SessionMedia) -> Void)? = nil

    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Query private var media: [SessionMedia]
    @State private var showingPicker = false

    /// True when the deep-tap clip menu should be offered (the climb-attempt strips wire the closures).
    private var hasClipMenu: Bool { onReassign != nil || onRequestDelete != nil }

    init(session: WorkoutSession, exerciseID: UUID, setIndex: Int,
         onEdit: ((SessionMedia) -> Void)? = nil,
         moveTargets: [ClipMoveTarget] = [],
         moveTargetsLabel: String = "Move to attempt…",
         onReassign: ((SessionMedia, UUID?, Int?) -> Void)? = nil,
         onRequestDelete: ((SessionMedia) -> Void)? = nil) {
        self.session = session
        self.exerciseID = exerciseID
        self.setIndex = setIndex
        self.onEdit = onEdit
        self.moveTargets = moveTargets
        self.moveTargetsLabel = moveTargetsLabel
        self.onReassign = onReassign
        self.onRequestDelete = onRequestDelete
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
                        ForEach(media) { clip in
                            // Videos open the scoped Studio editor on tap (#158 §G); photos aren't
                            // clip-editable, so they stay plain thumbnails. A deep-tap (long-press)
                            // surfaces the clip-lifecycle menu — move/remove/delete — on either kind
                            // (prompt 11), wired only on the climb-attempt strips.
                            Group {
                                if clip.kind == .video, let onEdit {
                                    Button { onEdit(clip) } label: { SessionMediaThumb(item: clip) }
                                        .buttonStyle(.plain)
                                        .accessibilityIdentifier("freeform.editClip")
                                } else {
                                    SessionMediaThumb(item: clip)
                                }
                            }
                            .modifier(ClipContextMenu(clip: clip, enabled: hasClipMenu,
                                                      moveTargets: moveTargets, moveTargetsLabel: moveTargetsLabel,
                                                      onReassign: onReassign, onRequestDelete: onRequestDelete))
                        }
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

/// The deep-tap (long-press) **clip-lifecycle** context menu (prompt 11), ported from
/// `SessionDetailView.thumbMenu`: "Move to attempt…" (a submenu over the climb's attempts) · "Remove from
/// attempt" (→ General; untie, keep the file) · "Delete clip…" (destructive → the player's Photos-aware
/// confirmation). A `ViewModifier` so the strip's thumbnail stays simple and the menu attaches to either a
/// video Button or a plain photo thumbnail. When `enabled` is false (lifting/timed/guided strips) it's a
/// pass-through, so those strips have no menu. The thumbnail carries `freeform.clipMenu` so the menu is
/// queryable; each leaf has its own id (the leaf-only a11y rule).
private struct ClipContextMenu: ViewModifier {
    let clip: SessionMedia
    let enabled: Bool
    let moveTargets: [ClipMoveTarget]
    var moveTargetsLabel: String = "Move to attempt…"
    let onReassign: ((SessionMedia, UUID?, Int?) -> Void)?
    let onRequestDelete: ((SessionMedia) -> Void)?

    func body(content: Content) -> some View {
        if enabled {
            content
                .accessibilityIdentifier("freeform.clipMenu")
                .contextMenu {
                    Menu {
                        ForEach(Array(moveTargets.enumerated()), id: \.element.id) { i, target in
                            Button(target.title) { onReassign?(clip, target.exerciseID, target.setIndex) }
                                .accessibilityIdentifier("freeform.clipMove.\(i)")
                        }
                    } label: {
                        Label(moveTargetsLabel, systemImage: "arrow.left.arrow.right")
                    }
                    Button { onReassign?(clip, nil, nil) } label: {
                        Label("Remove from attempt", systemImage: "rectangle.badge.minus")
                    }
                    .accessibilityIdentifier("freeform.clipRemove")
                    Button(role: .destructive) { onRequestDelete?(clip) } label: {
                        Label("Delete clip…", systemImage: "trash")
                    }
                    .accessibilityIdentifier("freeform.clipDelete")
                }
        } else {
            content
        }
    }
}
