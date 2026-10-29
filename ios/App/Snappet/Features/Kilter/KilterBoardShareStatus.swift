import SwiftUI

/// "Lit — Snappet lets go in 0:08 so others can connect · Let go now" (prompt 207, wireframe
/// `docs/ux-research/kilter-board-sharing/` frame 1). Shown under a connected board's light button while the idle
/// countdown runs; hidden when sharing is off for this board (Snappet then stays connected).
struct KilterBoardShareStatus: View {
    let board: KilterBoardController

    var body: some View {
        if let at = board.letGoAt, at > .now {
            HStack(spacing: 8) {
                Image(systemName: "person.2.fill").font(.caption).foregroundStyle(.green)
                (Text("Lets go of the board in ") + Text(timerInterval: Date.now...at, countsDown: true).monospacedDigit()
                 + Text(" so others can connect — the climb stays lit."))
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Let go now") { board.letGo() }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered).controlSize(.small)
                    .accessibilityIdentifier("kilter.board.letGo")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("kilter.board.shareStatus")
        }
    }
}
