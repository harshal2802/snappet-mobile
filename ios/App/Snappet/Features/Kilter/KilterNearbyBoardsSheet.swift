import SwiftUI

/// "N boards nearby" (prompt 205; wireframe `docs/ux-research/kilter-multi-board/` frames 3–4): with two or more
/// boards in range, Connect asks which one instead of picking silently. Each row shows the board's name (yours, or
/// "New board #serial"), signal strength and how you set it up; **Flash** lights its corners for a few seconds so
/// you can see which physical wall it is. Tapping a row connects. With one board in range none of this shows.
struct KilterNearbyBoardsSheet: View {
    let board: KilterBoardController
    let catalog: KilterCatalog
    /// What Flash lights: the current layout/size's corners + center.
    let flashHolds: [KilterHold]

    @State private var memory = KilterBoardMemory()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(board.nearbyBoards) { nearby in row(nearby) }
                } footer: {
                    Text("Strongest signal first. Tap a board to connect. Flash lights its corners for a few "
                         + "seconds so you can see which wall it is — it replaces whatever that board is showing.")
                }
            }
            .navigationTitle("\(board.nearbyBoards.count) boards nearby")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { board.cancel() }.accessibilityIdentifier("kilter.nearby.cancel")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { board.flashHolds = flashHolds }
    }

    private func row(_ nearby: KilterBoardController.NearbyBoard) -> some View {
        let remembered = memory.recall(identifier: nearby.id, serial: nearby.serial)
        let flashing = board.flashingID == nearby.id
        return HStack(spacing: 12) {
            SignalBars(bars: KilterConnectPolicy.bars(rssi: nearby.rssi))
            Button { board.pick(nearby.id) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(remembered?.label ?? "New board").font(.body.weight(.semibold))
                        if remembered == nil, let serial = nearby.serial {
                            Text("#\(serial)").font(.caption.weight(.bold)).foregroundStyle(.orange)
                        }
                    }
                    Text(flashing ? "Corners lit — look for the blue lights." : detail(remembered))
                        .font(.caption)
                        .foregroundStyle(flashing ? Color.blue : .secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("kilter.nearby.board")
            Button(flashing ? "Flashing…" : "Flash") { board.flash(nearby.id) }
                .buttonStyle(.bordered).controlSize(.small).tint(.blue)
                .disabled(board.flashingID != nil)
                .accessibilityIdentifier("kilter.nearby.flash")
        }
    }

    private func detail(_ remembered: RememberedBoard?) -> String {
        guard let r = remembered else { return "Never connected" }
        let layout = catalog.layouts().first { $0.id == r.layoutId }?.name
        let size = catalog.sizes(forLayout: r.layoutId).first { $0.id == r.productSizeId }?.name
        let angle = r.usualAngle.map { "\($0)°" }
        let seen = "last " + r.lastSeen.formatted(.relative(presentation: .named))
        return [layout, size, angle, seen].compactMap { $0 }.joined(separator: " · ")
    }
}

/// 0…4 signal bars.
private struct SignalBars: View {
    let bars: Int
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i <= bars ? Color.green : Color.secondary.opacity(0.3))
                    .frame(width: 3, height: CGFloat(3 + i * 3))
            }
        }
        .accessibilityLabel("Signal \(bars) of 4")
    }
}

extension View {
    /// Present the nearby-boards chooser whenever the controller is asking which board (prompt 205).
    func kilterBoardChooser(board: KilterBoardController, catalog: KilterCatalog,
                            layoutId: Int, sizeId: Int) -> some View {
        sheet(isPresented: Binding(get: { board.isChoosing }, set: { if !$0, board.isChoosing { board.cancel() } })) {
            KilterNearbyBoardsSheet(board: board, catalog: catalog,
                                    flashHolds: catalog.calibrationHolds(forLayout: layoutId, sizeId: sizeId))
        }
    }

    /// Same, for screens where the board controller is optional (the create / generate sheet).
    @ViewBuilder func kilterBoardChooser(optionalBoard board: KilterBoardController?, catalog: KilterCatalog,
                                         layoutId: Int, sizeId: Int) -> some View {
        if let board { kilterBoardChooser(board: board, catalog: catalog, layoutId: layoutId, sizeId: sizeId) }
        else { self }
    }
}
