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
    /// Boards you listed when downloading that aren't matched to a physical board yet (prompt 205) — offered
    /// as one-tap answers to "which of your boards is this?".
    let myBoards: [KilterMyBoard]
    /// Invoked on "This looks right" with the confirmed layout + size, the board's name, and the "my board" it
    /// was matched to (if any). The caller persists them and updates the active layout/size.
    let onConfirm: (_ layoutId: Int, _ sizeId: Int, _ name: String, _ myBoardID: UUID?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var layoutId: Int
    @State private var sizeId: Int
    @State private var name: String
    @State private var matchedMyBoard: UUID?
    private let defaultName: String

    init(board: KilterBoardController, catalog: KilterCatalog, climb: KilterClimb?, boardLabel: String,
         initialLayoutId: Int, initialSizeId: Int, myBoards: [KilterMyBoard] = [],
         onConfirm: @escaping (Int, Int, String, UUID?) -> Void) {
        self.board = board
        self.catalog = catalog
        self.climb = climb
        self.boardLabel = boardLabel
        self.myBoards = myBoards
        self.onConfirm = onConfirm
        self.defaultName = boardLabel
        _layoutId = State(initialValue: initialLayoutId)
        _sizeId = State(initialValue: catalog.effectiveSizeId(forLayout: initialLayoutId, requested: initialSizeId))
        _name = State(initialValue: boardLabel)
    }

    /// Quick names for the name field (prompt 205 frame 1).
    private var nameSuggestions: [String] {
        var out = ["Home", "Gym · left", "Gym · right", "Spray wall"]
        if !out.contains(defaultName) { out.append(defaultName) }
        return out
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
                    if !myBoards.isEmpty { myBoardsSection }
                    nameSection
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
            Text("Set up this board").font(.title3.weight(.bold))
            Text("Pick a layout and size, then look at the wall. When the lit holds match your board, tap confirm.")
                .font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    /// "Which of your boards is this?" — one tap sets the name, layout and size (prompt 205 frame B).
    private var myBoardsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("WHICH OF YOUR BOARDS IS THIS?").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.bottom, 6)
            ForEach(myBoards) { mine in
                Button {
                    matchedMyBoard = mine.id
                    name = mine.name
                    layoutId = mine.layoutId
                    sizeId = catalog.effectiveSizeId(forLayout: mine.layoutId, requested: mine.productSizeId)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(mine.name).font(.subheadline.weight(.semibold))
                            Text(KilterCatalogOptions.sizeName(layoutId: mine.layoutId, sizeId: mine.productSizeId) ?? "")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: matchedMyBoard == mine.id ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(SnappetColor.moduleAccent("kilter"))
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("kilter.setup.myBoard")
                Divider()
            }
            Button {
                matchedMyBoard = nil
                name = defaultName
            } label: {
                HStack {
                    Text("A different board…").font(.subheadline)
                    Spacer()
                    Image(systemName: matchedMyBoard == nil ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(SnappetColor.moduleAccent("kilter"))
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("kilter.setup.differentBoard")
        }
        .padding()
        .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
    }

    /// Name this board (prompt 205 frame 1): pre-filled with its size + serial; quick picks for the usual names.
    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NAME THIS BOARD").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            TextField("Board name", text: $name)
                .font(.body.weight(.semibold))
                .textInputAutocapitalization(.words)
                .padding(10)
                .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityIdentifier("kilter.setup.name")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(nameSuggestions, id: \.self) { suggestion in
                        Button(suggestion) { name = suggestion }
                            .font(.caption.weight(.semibold))
                            .buttonStyle(.bordered).controlSize(.small)
                            .tint(name == suggestion ? SnappetColor.moduleAccent("kilter") : .secondary)
                    }
                }
            }
        }
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
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                onConfirm(layoutId, sizeId, trimmed.isEmpty ? defaultName : trimmed, matchedMyBoard)
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
