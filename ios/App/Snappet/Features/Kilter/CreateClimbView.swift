import SwiftUI
import SwiftData

/// Author a brand-new climb by hand: pick the layout / board size / angle, then tap holes on the editable
/// board to cycle each through start → middle → finish → foot. On Save the climb is validated against the
/// downloaded dataset *and* your previously-created climbs (`KilterDuplicateChecker`); a stable
/// content-derived uuid (`KilterClimbIdentity`) is assigned, and it's stored as a `KilterCreatedClimb` that
/// flows through the normal detail/render/BLE/logging path. (The ✨ Generate tab — the on-device model —
/// is added in the next change; this is the manual half.)
struct CreateClimbView: View {
    /// Called with the new (or existing duplicate's) uuid after a successful save, so the caller can open
    /// it. The sheet dismisses itself.
    var onCreated: (String) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(SnappetCore.self) private var core
    @Query private var created: [KilterCreatedClimb]

    private let catalog = KilterCatalog.shared
    @AppStorage("kilter.layout") private var layoutId = 1
    @AppStorage("kilter.productSizeId") private var productSizeId = 0
    @AppStorage("kilter.angle") private var angle = 40

    @State private var name = ""
    @State private var isNoMatch = false
    @State private var assignments: [Int: KilterAuthorRole] = [:]
    @State private var placeable: [KilterPlaceableHold] = []
    @State private var geometry: KilterBoardGeometry = .empty

    @State private var duplicate: KilterDuplicateChecker.Duplicate?
    @State private var showingDuplicate = false

    private var layouts: [KilterLayout] { catalog.layouts() }
    private var sizes: [KilterBoardSize] { catalog.sizes(forLayout: layoutId) }
    private var availableAngles: [Int] { catalog.angles() }
    private var frames: String { kilterFrames(from: assignments) }
    private var validation: KilterClimbValidationError? { kilterValidate(assignments) }

    var body: some View {
        NavigationStack {
            Form {
                detailsSection
                boardSection
            }
            .navigationTitle("Create climb")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("kilter.create.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { attemptSave(force: false) }
                        .disabled(validation != nil)
                        .accessibilityIdentifier("kilter.create.save")
                }
            }
            .onAppear { syncBoardSize(); reloadBoard() }
            .onChange(of: layoutId) { syncBoardSize(); assignments = [:]; reloadBoard() }
            .onChange(of: productSizeId) { reloadBoard() }
            .alert("Climb already exists", isPresented: $showingDuplicate, presenting: duplicate) { dup in
                Button("Open existing") { onCreated(dup.uuid); dismiss() }
                Button("Save anyway") { attemptSave(force: true) }
                Button("Keep editing", role: .cancel) {}
            } message: { dup in
                Text(dup.origin == .catalog
                     ? "These exact holds are already “\(dup.name)” by \(dup.setter) in your catalog."
                     : "You already created this climb as “\(dup.name)”.")
            }
        }
    }

    private var detailsSection: some View {
        Section("Details") {
            TextField("Name", text: $name).accessibilityIdentifier("kilter.create.name")
            Picker("Layout", selection: $layoutId) {
                ForEach(layouts) { Text($0.name).tag($0.id) }
            }
            if sizes.count > 1 {
                Picker("Board size", selection: $productSizeId) {
                    ForEach(sizes) { Text($0.label).tag($0.id) }
                }
            }
            Picker("Angle", selection: $angle) {
                ForEach(availableAngles, id: \.self) { Text("\($0)°").tag($0) }
            }
            Toggle("No matching", isOn: $isNoMatch)
                .accessibilityIdentifier("kilter.create.noMatch")
        }
    }

    private var boardSection: some View {
        Section {
            KilterEditableBoardView(geometry: geometry, placeable: placeable, assignments: $assignments)
                .frame(maxHeight: 420)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            roleCounts
            validityRow
            if !assignments.isEmpty {
                Button(role: .destructive) { assignments = [:] } label: {
                    Label("Clear all holds", systemImage: "trash")
                }
                .accessibilityIdentifier("kilter.create.clear")
            }
        } header: {
            Text("Holds")
        } footer: {
            Text("Tap a hole to cycle: start → middle → finish → foot → off.")
        }
    }

    /// Live tally per role — the same counts the user is reasoning about as they set.
    private var roleCounts: some View {
        let counts = Dictionary(grouping: assignments.values, by: { $0 }).mapValues(\.count)
        return HStack(spacing: 14) {
            roleTally("Start", counts[.start] ?? 0, "00DD00")
            roleTally("Hand", counts[.middle] ?? 0, "00FFFF")
            roleTally("Finish", counts[.finish] ?? 0, "FF00FF")
            roleTally("Foot", counts[.foot] ?? 0, "FFA500")
        }
        .font(.caption)
        .frame(maxWidth: .infinity)
    }

    private func roleTally(_ label: String, _ n: Int, _ hex: String) -> some View {
        VStack(spacing: 2) {
            Text("\(n)").font(.headline.monospacedDigit()).foregroundStyle(Color(hex: hex))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var validityRow: some View {
        if let validation {
            Label(validation.message, systemImage: "exclamationmark.circle")
                .font(.caption).foregroundStyle(.orange)
                .accessibilityIdentifier("kilter.create.invalid")
        } else {
            Label("Ready to save · \(assignments.count) holds", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
                .accessibilityIdentifier("kilter.create.valid")
        }
    }

    // MARK: - Actions

    /// Keep the chosen size valid for the layout (seed the default when unset) — same guard as browse.
    private func syncBoardSize() {
        if !sizes.contains(where: { $0.id == productSizeId }) {
            productSizeId = catalog.defaultSizeId(forLayout: layoutId)
        }
    }

    private func reloadBoard() {
        placeable = catalog.placeableHolds(forLayout: layoutId, sizeId: productSizeId)
        geometry = catalog.boardGeometry(forLayout: layoutId, sizeId: productSizeId)
    }

    /// Validate → dedupe (unless the user chose "Save anyway") → assign the deterministic uuid → persist.
    private func attemptSave(force: Bool) {
        guard validation == nil else { return }
        let canonical = KilterClimbIdentity.canonicalFrames(frames)

        if !force {
            let checker = KilterDuplicateChecker.build(layoutId: layoutId, created: created)
            if let dup = checker.find(layoutId: layoutId, frames: canonical) {
                duplicate = dup
                showingDuplicate = true
                return
            }
        }

        let uuid = KilterClimbIdentity.uuid(forLayout: layoutId, frames: canonical)
        // The uuid is content-derived, so re-saving the same holds maps onto the existing row — open it
        // rather than inserting a conflicting unique key.
        if let existing = created.first(where: { $0.uuid == uuid }) {
            onCreated(existing.uuid); dismiss(); return
        }

        let box = catalog.boardBounds(forPlacementIds: Array(assignments.keys))
        let climb = KilterCreatedClimb(
            uuid: uuid, name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Untitled climb" : name.trimmingCharacters(in: .whitespacesAndNewlines),
            setterUsername: "You", layoutId: layoutId, sizeId: productSizeId, angle: angle,
            frames: canonical,
            edgeLeft: box?.left ?? 0, edgeRight: box?.right ?? 0,
            edgeBottom: box?.bottom ?? 0, edgeTop: box?.top ?? 0,
            isNoMatch: isNoMatch, predictedGrade: nil, source: "manual")
        modelContext.insert(climb)
        try? modelContext.save()
        core.log(module: "kilter", action: "created", summary: "Created \(climb.name)")
        onCreated(uuid)
        dismiss()
    }
}
