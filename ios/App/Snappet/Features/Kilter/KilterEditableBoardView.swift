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

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            Canvas { ctx, _ in draw(ctx, size) }
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { handleTap($0.location, in: size) })
        }
        .aspectRatio(geometry.aspect > 0 ? geometry.aspect : 1, contentMode: .fit)
        .background(
            LinearGradient(colors: [Color(.secondarySystemBackground), Color(.tertiarySystemBackground)],
                           startPoint: .top, endPoint: .bottom)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .accessibilityElement()
        .accessibilityLabel("Editable board, \(assignments.count) holds placed. Tap a hole to cycle its role.")
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
        let current = assignments[best.pid]
        let next = current?.next ?? (current == nil ? .start : nil)
        if let next { assignments[best.pid] = next } else { assignments[best.pid] = nil }
    }
}
