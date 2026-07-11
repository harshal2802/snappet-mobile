import SwiftUI

/// The "Set up this board" verifier (prompt 120): a guided sheet for a climber standing at a board the app
/// hasn't confirmed yet. Pick a **layout + size**, light it, and check the wall — every change re-lights
/// instantly, so the user cycles until the LEDs land right, then taps "This looks right". The confirmed
/// choice is persisted against *this physical board* by the caller (`KilterBoardMemory.confirmSetup`), so it
/// auto-restores on every future connect and the prompt never fires again.
///
/// Because a catalog climb's layout is intrinsic (`KilterCatalog.holds(for:)` resolves from `climb.layoutId`),
/// cycling **layouts** lights a corner+center **calibration pattern** (`calibrationHolds`), while cycling
/// **sizes** within the climb's own layout lights the real climb — the `KilterBoardSetup.target` branch. The
/// preview mirrors exactly what the board shows so the on-screen check and the wall check agree.
struct KilterBoardSetupSheet: View {
    let board: KilterBoardController
    let catalog: KilterCatalog
    /// The climb being viewed, if any — when the chosen layout is its own, we light the real climb.
    let climb: KilterClimb?
    /// The board's friendly label (from `KilterBoardMemory` at connect), shown in the confirmation.
    let boardLabel: String
    /// Invoked with the confirmed `(layoutId, productSizeId)` on "This looks right". The caller persists it
    /// and updates the active layout/size.
    let onConfirm: (_ layoutId: Int, _ sizeId: Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var layoutId: Int
    @State private var sizeId: Int

    init(board: KilterBoardController, catalog: KilterCatalog, climb: KilterClimb?, boardLabel: String,
         initialLayoutId: Int, initialSizeId: Int, onConfirm: @escaping (Int, Int) -> Void) {
        self.board = board
        self.catalog = catalog
        self.climb = climb
        self.boardLabel = boardLabel
        self.onConfirm = onConfirm
        _layoutId = State(initialValue: initialLayoutId)
        _sizeId = State(initialValue: catalog.effectiveSizeId(forLayout: initialLayoutId, requested: initialSizeId))
    }

    private var layouts: [KilterLayout] { catalog.layouts() }
    private var sizes: [KilterBoardSize] { catalog.sizes(forLayout: layoutId) }

    /// What the board should light for the current picker state (pure decision), and the resolved holds.
    private var target: KilterBoardSetup.LightTarget {
        KilterBoardSetup.target(climbLayoutId: climb?.layoutId, chosenLayoutId: layoutId, chosenSizeId: sizeId)
    }
    private var resolvedHolds: [KilterHold] {
        switch target {
        case .climb(let s):
            return climb.map { catalog.holds(for: $0, sizeId: s) } ?? []
        case .calibration(let l, let s):
            return catalog.calibrationHolds(forLayout: l, sizeId: s)
        }
    }
    private var isCalibrating: Bool {
        if case .calibration = target { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    header
                    pickers
                    preview
                    hint
                    buttons
                }
                .padding()
            }
            .navigationTitle("Set up this board")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("kilter.setup.cancel")
                }
            }
            // Light the moment the sheet appears, and on every layout/size change (that's the whole loop —
            // "Try another" is just moving a picker). A layout switch first clamps the size to one valid for
            // it, then the size `onChange` re-lights (so we don't double-send).
            .onAppear { relight() }
            .onChange(of: layoutId) {
                let eff = catalog.effectiveSizeId(forLayout: layoutId, requested: sizeId)
                if eff != sizeId { sizeId = eff } else { relight() }
            }
            .onChange(of: sizeId) { relight() }
        }
        .presentationDetents([.large])
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "bolt.badge.checkmark")
                .font(.largeTitle).foregroundStyle(SnappetColor.moduleAccent("kilter"))
            Text("Which board is this?").font(.title3.weight(.bold))
            Text("Pick a layout and size, then look at the wall. When the lit holds match your board, tap confirm.")
                .font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private var pickers: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Layout").font(.subheadline.weight(.medium))
                Spacer()
                Picker("Layout", selection: $layoutId) {
                    ForEach(layouts) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("kilter.setup.layout")
            }
            if sizes.count > 1 {
                Divider()
                HStack {
                    Text("Size").font(.subheadline.weight(.medium))
                    Spacer()
                    Picker("Size", selection: $sizeId) {
                        ForEach(sizes) { Text($0.label).tag($0.id) }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("kilter.setup.size")
                }
            }
        }
        .padding()
        .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
    }

    private var preview: some View {
        KilterBoardView(geometry: catalog.boardGeometry(forLayout: layoutId, sizeId: sizeId),
                        holds: resolvedHolds)
            .frame(maxHeight: 300)
            .accessibilityIdentifier("kilter.setup.preview")
    }

    @ViewBuilder private var hint: some View {
        if isCalibrating {
            Label("Lighting the four corners + center — do they land on your board's edges?",
                  systemImage: "viewfinder")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        } else {
            Label("Lighting this climb — do the holds match the wall?", systemImage: "checklist")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var buttons: some View {
        VStack(spacing: 10) {
            Button { relight(); Haptics.tap() } label: {
                Label("Light on board", systemImage: "bolt.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(SnappetColor.moduleAccent("kilter"))
            .accessibilityIdentifier("kilter.setup.light")

            Button {
                onConfirm(layoutId, sizeId)
                Haptics.success()
                dismiss()
            } label: {
                Label("This looks right", systemImage: "checkmark.circle.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .accessibilityIdentifier("kilter.setup.confirm")
        }
    }

    /// Send the current target's holds to the board (no-op off a real connection — the sheet still shows the
    /// on-screen preview so the flow is checkable on the simulator).
    private func relight() {
        board.illuminate(resolvedHolds)
    }
}
