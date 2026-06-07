import SwiftUI
import SwiftData

/// Container that wraps the **scoped** multi-clip `StudioEditorView` with a floating **"Climb ✎"**
/// button presenting the `KilterClimbPanel`. The button shows only when a single climb is known
/// (per-clip / per-climb scopes); session-wide presentations pass `climbUUID == nil` (multiple
/// climbs, no single panel target) and get the bare studio.
///
/// The studio itself is the shared one the workout side uses — scoping is just the
/// `visibleClipMediaIDs` filter, so per-clip / per-climb / session edits all land in the same
/// session `StudioProject` and carry over.
struct KilterClipStudio: View {
    let project: StudioProject
    let context: ModelContext
    let visibleClipMediaIDs: Set<UUID>?
    let focusClipMediaID: UUID?
    let sessionId: UUID
    /// The climb this scope belongs to (nil = session-wide → no Climb panel).
    let climbUUID: String?
    /// The single clip when scoped to one clip (enables "Move clip to another climb"); nil otherwise.
    let singleClip: SessionMedia?
    let climbTargets: [KilterClimbTarget]

    @State private var showingClimbPanel = false

    /// The climb to show the panel for: the scope's climb, or — for a per-clip scope — the single
    /// clip's *current* assignment. Reading the `@Model` clip here tracks its changes, so assigning an
    /// unassigned clip from the panel upgrades the button/panel to the full Climb panel in place.
    private var resolvedClimbUUID: String? { climbUUID ?? singleClip?.assignedClimbUUID }

    /// Show the Climb affordance for any per-clip / per-climb scope (a known climb, or a single clip
    /// to assign). Session-wide scopes (no climb, no single clip) get the bare studio.
    private var showsClimbButton: Bool { resolvedClimbUUID != nil || singleClip != nil }

    var body: some View {
        StudioEditorView(project: project, context: context,
                         focusClipMediaID: focusClipMediaID,
                         visibleClipMediaIDs: visibleClipMediaIDs)
            .overlay(alignment: .topTrailing) {
                if showsClimbButton {
                    climbButton
                        // Float over the preview canvas, clear of the studio's top bar (Export) and
                        // the bottom action bar.
                        .padding(.top, 64)
                        .padding(.trailing, 16)
                        .sheet(isPresented: $showingClimbPanel) {
                            KilterClimbPanel(sessionId: sessionId, climbUUID: resolvedClimbUUID,
                                             singleClip: singleClip, climbTargets: climbTargets)
                                .presentationDetents([.medium, .large])
                                .presentationDragIndicator(.visible)
                        }
                }
            }
    }

    private var climbButton: some View {
        let hasClimb = resolvedClimbUUID != nil
        return Button { showingClimbPanel = true } label: {
            Label(hasClimb ? "Climb" : "Assign",
                  systemImage: hasClimb ? "pencil" : "arrow.left.arrow.right")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.2)))
        }
        .tint(.white)
        .accessibilityIdentifier("kilter.clipStudio.climb")
    }
}
