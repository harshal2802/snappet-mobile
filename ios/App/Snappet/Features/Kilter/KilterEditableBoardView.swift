import SwiftUI

/// The **authoring** board: the same schematic backdrop as `KilterBoardView` (faint full hole grid +
/// role-shaped, role-colored lit holds), but interactive — tapping the nearest hole cycles its role
/// (unset → start → middle → finish → foot → unset). Built on the exact same normalized geometry
/// (`KilterCatalog.placeableHolds` shares `holds(for:)`'s render extent), so a climb the user draws here
/// lines up pixel-for-pixel with how it renders everywhere else.
///
/// Drawn with one `Canvas` (cheap for ~700 holes); taps hit-test against the placeable set in point space,
/// so a tap *near* a hole still lands on it. A clear hint dot marks every placeable hole so the user knows
/// where the targets are.
struct KilterEditableBoardView: View {
    let geometry: KilterBoardGeometry
    let placeable: [KilterPlaceableHold]
    @Binding var assignments: [Int: KilterAuthorRole]

    /// When VoiceOver is running, a per-hole accessible overlay makes non-visual authoring possible —
    /// the Canvas itself is one opaque element a VoiceOver user can't author in (#79). The overlay is
    /// only built under VoiceOver, so sighted tap (the near-hit `SpatialTapGesture`) is untouched.
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                Canvas { ctx, _ in draw(ctx, size) }
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { handleTap($0.location, in: size) })
                if voiceOver {
                    accessibilityOverlay(size)
                }
            }
        }
        .aspectRatio(geometry.aspect > 0 ? geometry.aspect : 1, contentMode: .fit)
        .background(
            LinearGradient(colors: [Color(.secondarySystemBackground), Color(.tertiarySystemBackground)],
                           startPoint: .top, endPoint: .bottom)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        // Under VoiceOver the per-hole children carry the interaction; otherwise it's one element.
        .accessibilityElement(children: voiceOver ? .contain : .ignore)
        .accessibilityLabel(voiceOver
            ? "Editable board, \(assignments.count) holds placed. Each hole is an element — double-tap to cycle its role."
            : "Editable board, \(assignments.count) holds placed. Tap a hole to cycle its role.")
    }

    /// One accessible, hittable element per placeable hole — labelled with its rough board position and
    /// current role, with a double-tap (default action) that cycles the role exactly like a sighted tap.
    private func accessibilityOverlay(_ size: CGSize) -> some View {
        let holdD = holdDiameter(size)
        return ForEach(placeable, id: \.placementId) { h in
            let c = point(h.x, h.y, size, holdD)
            Button { cycle(h.placementId) } label: { Color.clear }
                .frame(width: 44, height: 44)   // ≥44pt VoiceOver target (#79)
                .position(c)
                .accessibilityLabel("\(positionLabel(x: h.x, y: h.y)) hole")
                .accessibilityValue(assignments[h.placementId]?.roleName ?? "unset")
                .accessibilityHint("Cycles unset, start, middle, finish, foot")
        }
    }

    /// A coarse spoken position (left/centre/right × top/middle/bottom) so a VoiceOver user can tell the
    /// holes apart. `y` is top-down (0 = top), so it's inverted for "top/bottom".
    private func positionLabel(x: Double, y: Double) -> String {
        let col = x < 0.34 ? "left" : x < 0.67 ? "centre" : "right"
        let row = y < 0.34 ? "top" : y < 0.67 ? "middle" : "bottom"
        return "\(row) \(col)"
    }

    // Same point transform as KilterBoardView, so targets and the render agree.
    private func holdDiameter(_ size: CGSize) -> CGFloat { max(12, min(size.width, size.height) * 0.052) }
    private func point(_ x: Double, _ y: Double, _ size: CGSize, _ holdD: CGFloat) -> CGPoint {
        CGPoint(x: holdD / 2 + x * (size.width - holdD), y: holdD / 2 + y * (size.height - holdD))
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let holdD = holdDiameter(size)

        // 1) Faint grid backdrop.
        let gd = holdD * 0.32
        for p in geometry.grid {
            let c = point(p.x, p.y, size, holdD)
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - gd / 2, y: c.y - gd / 2, width: gd, height: gd)),
                     with: .color(.gray.opacity(0.28)))
        }

        // 2) A clear hint ring at every placeable hole, so targets are discoverable.
        let hd = holdD * 0.5
        for h in placeable where assignments[h.placementId] == nil {
            let c = point(h.x, h.y, size, holdD)
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - hd / 2, y: c.y - hd / 2, width: hd, height: hd)),
                       with: .color(.gray.opacity(0.22)), lineWidth: 1)
        }

        // 3) Placed holds, role-colored + role-shaped (same channel as the read-only board).
        for h in placeable {
            guard let role = assignments[h.placementId] else { continue }
            let d = holdD * scale(role)
            let c = point(h.x, h.y, size, holdD)
            let rect = CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
            let color = Color(hex: roleColorHex(role))
            ctx.stroke(KilterBoardView.holdPath(KilterHoldShape.forRole(role.roleName), in: rect),
                       with: .color(color), style: StrokeStyle(lineWidth: max(2.5, d * 0.17), lineJoin: .round))
        }
    }

    /// Foot smaller; start/finish a touch larger — matches `KilterBoardView`.
    private func scale(_ role: KilterAuthorRole) -> CGFloat {
        switch role {
        case .foot: return 0.74
        case .start, .finish: return 1.14
        case .middle: return 1.0
        }
    }

    /// On-screen role colors (mirror the catalog's `screen_color` for the four roles + the detail legend).
    private func roleColorHex(_ role: KilterAuthorRole) -> String {
        switch role {
        case .start: return "00DD00"
        case .middle: return "00FFFF"
        case .finish: return "FF00FF"
        case .foot: return "FFA500"
        }
    }

    /// Cycle the role of the nearest placeable hole to a tap (within a hold's reach), else ignore the tap.
    private func handleTap(_ location: CGPoint, in size: CGSize) {
        let holdD = holdDiameter(size)
        var best: (pid: Int, dist: CGFloat)?
        for h in placeable {
            let c = point(h.x, h.y, size, holdD)
            let dist = hypot(c.x - location.x, c.y - location.y)
            if best == nil || dist < best!.dist { best = (h.placementId, dist) }
        }
        guard let best, best.dist <= holdD else { return }   // tap must be near a hole
        cycle(best.pid)
    }

    /// Cycle one hole's role: unset → start → middle → finish → foot → unset. Shared by the sighted
    /// near-hit tap and the per-hole VoiceOver action so both behave identically (#79).
    private func cycle(_ pid: Int) {
        let current = assignments[pid]
        assignments[pid] = current?.next ?? (current == nil ? .start : nil)
    }
}
