import SwiftUI
import SwiftData
import UIKit

/// Author a brand-new climb — two ways, in one sheet:
/// - **Manual**: pick layout / board size / angle / no-match, then tap holes on `KilterEditableBoardView`
///   to cycle each through start → middle → finish → foot.
/// - **✨ Generate**: the on-device transformer (`KilterClimbGenerator`, model lazy-downloaded by
///   `KilterGeneratorAssets`) designs a climb for a chosen size / angle / target grade.
///
/// Either way, Save validates against the downloaded dataset + previously-created climbs
/// (`KilterDuplicateChecker`) — offering Open existing / Save anyway / Keep editing — assigns the
/// deterministic content uuid (`KilterClimbIdentity`) and persists a `KilterCreatedClimb` that flows
/// through the normal detail / render / BLE / logging path.
struct CreateClimbView: View {
    /// Called with the new (or existing duplicate's) uuid after a successful save. The sheet dismisses.
    var onCreated: (String) -> Void = { _ in }
    /// The shared board controller, so the climb being authored / generated can be previewed on a
    /// physically-connected board over BLE. `nil` (e.g. previews) simply disables the live-light affordance.
    var board: KilterBoardController? = nil
    /// Non-nil to **re-open an existing created climb in the editor** (#76): its holds/name/conditions seed
    /// the manual tab. Saving re-derives the content uuid — unchanged holds update it in place, changed
    /// holds migrate its logged ascents to the new identity and remove the old row.
    var editing: KilterCreatedClimb? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(SnappetCore.self) private var core
    @Query private var created: [KilterCreatedClimb]

    private let catalog = KilterCatalog.shared
    @AppStorage("kilter.layout") private var layoutId = 1
    @AppStorage("kilter.productSizeId") private var productSizeId = 0
    @AppStorage("kilter.angle") private var angle = 40

    enum Mode: String, CaseIterable { case manual = "Manual", generate = "✨ Generate" }
    @State private var mode: Mode = .manual
    @State private var name = ""

    // Manual editor state.
    @State private var isNoMatch = false
    @State private var assignments: [Int: KilterAuthorRole] = [:]
    @State private var placeable: [KilterPlaceableHold] = []
    @State private var geometry: KilterBoardGeometry = .empty

    // Generator state.
    @State private var genModel: KilterGeneratorModel?
    @State private var genRuntime: KilterGeneratorRuntime?
    @State private var genPhase: GenPhase = .needsModel
    @State private var genSizeId = 0
    @State private var genAngle = 40
    @State private var genGrade = 17
    @State private var genNoMatch = false
    @State private var genResult: KilterGeneratedClimb?
    @State private var genHolds: [KilterHold] = []
    @State private var genGeometry: KilterBoardGeometry = .empty

    // Duplicate handling (shared by both tabs).
    @State private var duplicate: KilterDuplicateChecker.Duplicate?
    @State private var pendingSave: SavePayload?
    @State private var showingDuplicate = false

    /// The generator meta (just `meta.json`, no ONNX runtime) for the manual tab's live grade estimate —
    /// loaded only when already installed, never downloaded here (#76). `nil` ⇒ no estimate shown.
    @State private var gradeModel: KilterGeneratorModel?
    /// Guards the one-time seed of the manual editor when re-opening an existing climb (`editing`).
    @State private var didSeedEdit = false
    /// Set while seeding so the `layoutId` change that seeding triggers doesn't wipe the seeded holds.
    @State private var skipNextLayoutClear = false

    enum GenPhase: Equatable {
        case needsModel, preparing, idle, generating, ready, error(String)
    }

    /// Everything needed to persist a climb — built by either tab, replayed on "Save anyway".
    private struct SavePayload {
        let frames: String, layoutId: Int, sizeId: Int, angle: Int
        let isNoMatch: Bool, predictedGrade: Double?, source: String
    }

    private var layouts: [KilterLayout] { catalog.layouts() }
    private var sizes: [KilterBoardSize] { catalog.sizes(forLayout: layoutId) }
    private var availableAngles: [Int] { catalog.angles() }
    private var manualFrames: String { kilterFrames(from: assignments) }
    private var validation: KilterClimbValidationError? { kilterValidate(assignments) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Mode", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("kilter.create.mode")
                    TextField("Name", text: $name).accessibilityIdentifier("kilter.create.name")
                }
                if mode == .manual {
                    manualDetailsSection
                    manualBoardSection
                } else {
                    generateSection
                }
            }
            .navigationTitle(editing == nil ? "Create climb" : "Edit climb")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("kilter.create.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    if mode == .manual {
                        Button("Save") { saveManual() }
                            .disabled(validation != nil)
                            .accessibilityIdentifier("kilter.create.save")
                    }
                }
            }
            .onAppear { seedFromEditingIfNeeded(); syncBoardSize(); reloadBoard(); loadGradeModelIfInstalled() }
            .onChange(of: layoutId) {
                syncBoardSize()
                // A layout change normally invalidates placed holds — except the one triggered by
                // seeding the editor with an existing climb, whose holds belong to that layout (#76).
                if skipNextLayoutClear { skipNextLayoutClear = false } else { assignments = [:] }
                reloadBoard()
            }
            .onChange(of: productSizeId) { reloadBoard(); liveLight(manualLitHolds) }
            // Light the draft on a connected board as holds are placed/cleared.
            .onChange(of: assignments) { liveLight(manualLitHolds) }
            .onChange(of: mode) { _, m in if m == .generate { Task { await prepareModelIfNeeded() } } }
            .alert("Climb already exists", isPresented: $showingDuplicate, presenting: duplicate) { dup in
                Button("Open existing") { onCreated(dup.uuid); dismiss() }
                Button("Save anyway") { if let p = pendingSave { commit(p) } }
                Button("Keep editing", role: .cancel) {}
            } message: { dup in
                Text(dup.origin == .catalog
                     ? "These exact holds are already “\(dup.name)” by \(dup.setter) in your catalog."
                     : "You already created this climb as “\(dup.name)”.")
            }
        }
    }

    // MARK: - Manual tab

    private var manualDetailsSection: some View {
        Section("Details") {
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
            Toggle("No matching", isOn: $isNoMatch).accessibilityIdentifier("kilter.create.noMatch")
        }
    }

    private var manualBoardSection: some View {
        Section {
            KilterEditableBoardView(geometry: geometry, placeable: placeable, assignments: $assignments)
                .frame(maxHeight: 420)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            roleCounts(for: assignments.values)
            if let validation {
                Label(validation.message, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange)
                    .accessibilityIdentifier("kilter.create.invalid")
            } else {
                Label("Ready to save · \(assignments.count) holds", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
                    .accessibilityIdentifier("kilter.create.valid")
            }
            if let estimate = manualGradeLabel {
                Label("Estimated grade ≈ \(estimate)", systemImage: "chart.bar")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("kilter.create.gradeEstimate")
            }
            if !assignments.isEmpty {
                copyFramesButton(manualFrames, enabled: true)
                Button(role: .destructive) { assignments = [:] } label: {
                    Label("Clear all holds", systemImage: "trash")
                }
                .accessibilityIdentifier("kilter.create.clear")
            }
            bleRow(holds: manualLitHolds)
        } header: {
            Text("Holds")
        } footer: {
            Text("Tap a hole to cycle: start → middle → finish → foot → off.")
        }
    }

    /// The manual draft's holds, positioned for render / BLE (empty when nothing is placed).
    private var manualLitHolds: [KilterHold] {
        guard !assignments.isEmpty else { return [] }
        let draft = KilterClimb(uuid: "draft", name: "", setter: "", layoutId: layoutId,
                                edgeLeft: 0, edgeRight: 0, edgeBottom: 0, edgeTop: 0,
                                frames: manualFrames, description: "", isNoMatch: isNoMatch)
        return catalog.holds(for: draft, sizeId: productSizeId)
    }

    // MARK: - Generate tab

    @ViewBuilder private var generateSection: some View {
        switch genPhase {
        case .needsModel:
            Section {
                Button { Task { await prepareModelIfNeeded(force: true) } } label: {
                    Label("Download generator model (~9 MB)", systemImage: "arrow.down.circle")
                }
                .accessibilityIdentifier("kilter.generate.download")
            } footer: {
                Text("A small transformer runs entirely on your device. Downloaded once from the Snappet host.")
            }
        case .preparing:
            Section { busyRow("Loading the generator model…") }
        case .error(let message):
            Section {
                Label(message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                Button("Try again") { Task { await prepareModelIfNeeded(force: true) } }
            }
        case .idle, .generating, .ready:
            generateControls
            if genPhase == .generating { Section { busyRow("Generating…") } }
            if genPhase == .ready, let result = genResult { generatePreview(result) }
        }
    }

    @ViewBuilder private var generateControls: some View {
        if let model = genModel {
            Section("Conditions") {
                Picker("Board size", selection: $genSizeId) {
                    ForEach(model.meta.sizes) { Text($0.name).tag($0.id) }
                }
                Picker("Angle", selection: $genAngle) {
                    ForEach(model.meta.angles, id: \.self) { Text("\($0)°").tag($0) }
                }
                Picker("Target grade", selection: $genGrade) {
                    ForEach(model.meta.grades, id: \.self) { Text(model.gradeLabel($0)).tag($0) }
                }
                Toggle("No matching", isOn: $genNoMatch)
                Button { generate() } label: {
                    Label(genResult == nil ? "Generate climb" : "Generate another",
                          systemImage: "sparkles")
                }
                .disabled(genPhase == .generating)
                .accessibilityIdentifier("kilter.generate.run")
            }
        }
    }

    @ViewBuilder private func generatePreview(_ result: KilterGeneratedClimb) -> some View {
        Section {
            KilterBoardView(geometry: genGeometry, holds: genHolds)
                .frame(maxHeight: 380)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            HStack {
                Label("Predicted \(genModel?.gradeLabel(Int(result.predictedGrade.rounded())) ?? "—")",
                      systemImage: "chart.bar")
                Spacer()
                Text("target \(genModel?.gradeLabel(genGrade) ?? "\(genGrade)")")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            roleCounts(for: genHolds.compactMap { KilterAuthorRole(roleId: roleId(forRole: $0.role)) })
            Button { useGeneratedClimb(result) } label: {
                Label("Use this climb", systemImage: "checkmark.circle.fill")
            }
            .accessibilityIdentifier("kilter.generate.use")
            copyFramesButton(result.frames, enabled: true)
            bleRow(holds: genHolds)
        } footer: {
            Text("Generated on-device — the grade is a model estimate. Valid by construction (fits the size, has a start & finish).")
        }
    }

    // MARK: - Shared bits

    private func roleCounts<S: Sequence>(for roles: S) -> some View where S.Element == KilterAuthorRole {
        let counts = Dictionary(grouping: roles, by: { $0 }).mapValues(\.count)
        return HStack(spacing: 14) {
            roleTally("Start", counts[.start] ?? 0, "00DD00")
            roleTally("Hand", counts[.middle] ?? 0, "00FFFF")
            roleTally("Finish", counts[.finish] ?? 0, "FF00FF")
            roleTally("Foot", counts[.foot] ?? 0, "FFA500")
        }
        .font(.caption).frame(maxWidth: .infinity)
    }

    private func roleTally(_ label: String, _ n: Int, _ hex: String) -> some View {
        VStack(spacing: 2) {
            Text("\(n)").font(.headline.monospacedDigit()).foregroundStyle(Color(hex: hex))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func busyRow(_ text: String) -> some View {
        HStack(spacing: 8) { ProgressView(); Text(text).foregroundStyle(.secondary) }
            .accessibilityIdentifier("kilter.generate.busy")
    }

    /// Copy the climb's canonical frames (the `p<placement>r<role>` string) to the clipboard — the same
    /// format the catalog stores and the board-explorer's "Copy frames" emits, so a draft can be pasted
    /// into another tool / shared as text.
    private func copyFramesButton(_ frames: String, enabled: Bool) -> some View {
        Button { UIPasteboard.general.string = KilterClimbIdentity.canonicalFrames(frames) } label: {
            Label("Copy frames", systemImage: "doc.on.doc")
        }
        .disabled(!enabled)
        .accessibilityIdentifier("kilter.create.copyFrames")
    }

    /// When a board is connected over BLE, a row to light the in-progress climb on the physical board
    /// (the draft also auto-lights as you build / after generating). Hidden when no board is connected.
    @ViewBuilder private func bleRow(holds: [KilterHold]) -> some View {
        if let board, board.isConnected {
            Button { board.illuminate(holds) } label: {
                Label(holds.isEmpty ? "Board connected — place holds to light it"
                                    : "Light \(holds.count) holds on board",
                      systemImage: "lightbulb.fill")
            }
            .disabled(holds.isEmpty)
            .accessibilityIdentifier("kilter.create.illuminate")
        }
    }

    /// Light the holds on a connected board (no-op otherwise) — called as the draft changes.
    private func liveLight(_ holds: [KilterHold]) {
        if board?.isConnected == true { board?.illuminate(holds) }
    }

    /// Role name → main-line role id (inverse of `KilterCatalog.roleName`), for counting preview holds.
    private func roleId(forRole role: String) -> Int {
        switch role {
        case "start": return 12
        case "finish": return 14
        case "foot": return 15
        default: return 13
        }
    }

    // MARK: - Actions: manual

    /// The live grade estimate label for the current manual draft (#76) — `nil` (chip hidden) when the
    /// generator meta isn't installed or no placed hold maps to the model vocab.
    private var manualGradeLabel: String? {
        guard mode == .manual, let model = gradeModel,
              let grade = KilterClimbGenerator.estimateManualGrade(
                assignments: assignments, angle: angle, nomatch: isNoMatch, model: model)
        else { return nil }
        return model.gradeLabel(Int(grade.rounded()))
    }

    /// Load just the generator meta (no ONNX runtime, no download) for the manual grade estimate —
    /// only when the model is already installed, so authoring never triggers a 9 MB fetch (#76).
    private func loadGradeModelIfInstalled() {
        guard gradeModel == nil, KilterGeneratorAssets.shared.isInstalled else { return }
        gradeModel = try? KilterGeneratorModel.load(metaURL: KilterGeneratorAssets.shared.metaURL)
    }

    /// Seed the manual editor from the climb being edited (#76), once. Sets `skipNextLayoutClear` so the
    /// `layoutId` assignment below doesn't wipe the holds we're about to restore.
    private func seedFromEditingIfNeeded() {
        guard let e = editing, !didSeedEdit else { return }
        didSeedEdit = true
        mode = .manual
        name = e.name
        isNoMatch = e.isNoMatch
        angle = e.angle
        if layoutId != e.layoutId { skipNextLayoutClear = true; layoutId = e.layoutId }
        productSizeId = e.sizeId
        assignments = Self.assignments(fromFrames: e.frames)
    }

    /// Parse a climb's `p<placement>r<role>` frames back into the editor's `placementId → role` map.
    static func assignments(fromFrames frames: String) -> [Int: KilterAuthorRole] {
        var out: [Int: KilterAuthorRole] = [:]
        for (placementId, roleId) in KilterCatalog.parseFrames(frames) {
            if let role = KilterAuthorRole(roleId: roleId) { out[placementId] = role }
        }
        return out
    }

    private func syncBoardSize() {
        if !sizes.contains(where: { $0.id == productSizeId }) {
            productSizeId = catalog.defaultSizeId(forLayout: layoutId)
        }
    }

    private func reloadBoard() {
        placeable = catalog.placeableHolds(forLayout: layoutId, sizeId: productSizeId)
        geometry = catalog.boardGeometry(forLayout: layoutId, sizeId: productSizeId)
    }

    private func saveManual() {
        guard validation == nil else { return }
        // Persist the model's grade estimate when available (meta installed) so a hand-authored climb
        // is no longer saved ungraded — its detail screen reads a grade like a generated one (#76).
        let estimate = gradeModel.flatMap {
            KilterClimbGenerator.estimateManualGrade(assignments: assignments, angle: angle,
                                                     nomatch: isNoMatch, model: $0)
        }
        attemptSave(SavePayload(frames: manualFrames, layoutId: layoutId, sizeId: productSizeId,
                                angle: angle, isNoMatch: isNoMatch, predictedGrade: estimate, source: "manual"))
    }

    // MARK: - Actions: generate

    /// Ensure the model is downloaded + a runtime is ready. `force` re-attempts after an error.
    private func prepareModelIfNeeded(force: Bool = false) async {
        if genModel != nil, !force { if genPhase == .needsModel { genPhase = .idle }; return }
        if !force, !KilterGeneratorAssets.shared.isInstalled { genPhase = .needsModel; return }
        genPhase = .preparing
        do {
            let model = try await KilterGeneratorAssets.shared.ensureInstalled()
            genModel = model
            genRuntime = KilterGeneratorRuntime(model: model, modelURL: KilterGeneratorAssets.shared.modelURL)
            seedGenPickers(model)
            genPhase = .idle
        } catch {
            genPhase = .error(error.localizedDescription)
        }
    }

    private func seedGenPickers(_ model: KilterGeneratorModel) {
        if !model.meta.sizes.contains(where: { $0.id == genSizeId }) {
            genSizeId = model.meta.sizes.contains(where: { $0.id == productSizeId }) ? productSizeId : model.meta.defaultSize
        }
        if !model.meta.angles.contains(genAngle) { genAngle = model.meta.angles.contains(angle) ? angle : (model.meta.angles.first ?? 40) }
        if !model.meta.grades.contains(genGrade) { genGrade = model.meta.grades[model.meta.grades.count / 2] }
    }

    private func generate() {
        guard let runtime = genRuntime else { return }
        genPhase = .generating
        let request = KilterGenerateRequest(sizeId: genSizeId, angle: genAngle, grade: genGrade,
                                            nomatch: genNoMatch, candidates: 3)
        Task {
            do {
                let result = try await runtime.generate(request)
                let layout = layoutForSize(genSizeId)
                let preview = KilterClimb(uuid: "preview", name: "", setter: "", layoutId: layout,
                                          edgeLeft: 0, edgeRight: 0, edgeBottom: 0, edgeTop: 0,
                                          frames: result.frames, description: "", isNoMatch: genNoMatch)
                genHolds = catalog.holds(for: preview, sizeId: genSizeId)
                genGeometry = catalog.boardGeometry(forLayout: layout, sizeId: genSizeId)
                genResult = result
                genPhase = .ready
                liveLight(genHolds)
            } catch {
                genPhase = .error(error.localizedDescription)
            }
        }
    }

    private func useGeneratedClimb(_ result: KilterGeneratedClimb) {
        attemptSave(SavePayload(frames: result.frames, layoutId: layoutForSize(genSizeId), sizeId: genSizeId,
                                angle: genAngle, isNoMatch: genNoMatch,
                                predictedGrade: result.predictedGrade, source: "generated"))
    }

    /// The layout that owns a `product_size` (the model only knows sizes; a climb needs its layout).
    private func layoutForSize(_ sizeId: Int) -> Int {
        for l in catalog.layouts() where catalog.sizes(forLayout: l.id).contains(where: { $0.id == sizeId }) {
            return l.id
        }
        return layoutId
    }

    // MARK: - Save (shared)

    /// Run the duplicate check, then persist (or surface the duplicate alert). When editing, the climb
    /// being edited is excluded from the check — re-saving its own holds isn't a self-duplicate (#76).
    private func attemptSave(_ payload: SavePayload) {
        let canonical = KilterClimbIdentity.canonicalFrames(payload.frames)
        let pool = editing.map { e in created.filter { $0.uuid != e.uuid } } ?? created
        let checker = KilterDuplicateChecker.build(layoutId: payload.layoutId, created: pool)
        if let dup = checker.find(layoutId: payload.layoutId, frames: canonical) {
            duplicate = dup
            pendingSave = payload
            showingDuplicate = true
            return
        }
        commit(payload)
    }

    /// Assign the deterministic uuid and write the climb (opening an existing row if the same holds were
    /// already saved, since the uuid is content-derived). When editing (#76): unchanged holds update the
    /// existing row in place; changed holds re-derive the identity, migrate the climb's logged ascents to
    /// the new uuid, and remove the old row.
    private func commit(_ payload: SavePayload) {
        let canonical = KilterClimbIdentity.canonicalFrames(payload.frames)
        let uuid = KilterClimbIdentity.uuid(forLayout: payload.layoutId, frames: canonical)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "Untitled climb" : trimmed

        if let editing {
            if uuid == editing.uuid {
                // Same holds — a rename / angle / no-match / re-grade edit in place.
                editing.name = finalName
                editing.angle = payload.angle
                editing.isNoMatch = payload.isNoMatch
                if let g = payload.predictedGrade { editing.predictedGrade = g }
                try? modelContext.save()
                onCreated(editing.uuid); dismiss(); return
            }
            // Holds changed → new identity. Carry the climb's logged ascents + favorite over, then drop
            // the old row, and fall through to create the new one.
            migrateReferences(from: editing.uuid, to: uuid, name: finalName)
            modelContext.delete(editing)
        }

        if let existing = created.first(where: { $0.uuid == uuid && $0 !== editing }) {
            onCreated(existing.uuid); dismiss(); return
        }
        let box = catalog.boardBounds(forPlacementIds: KilterCatalog.parseFrames(canonical).map(\.0))
        let climb = KilterCreatedClimb(
            uuid: uuid, name: finalName,
            setterUsername: "You", layoutId: payload.layoutId, sizeId: payload.sizeId, angle: payload.angle,
            frames: canonical,
            edgeLeft: box?.left ?? 0, edgeRight: box?.right ?? 0,
            edgeBottom: box?.bottom ?? 0, edgeTop: box?.top ?? 0,
            isNoMatch: payload.isNoMatch, predictedGrade: payload.predictedGrade, source: payload.source)
        modelContext.insert(climb)
        try? modelContext.save()
        core.log(module: "kilter", action: editing == nil ? "created" : "edited",
                 summary: "\(editing != nil ? "Edited" : payload.source == "generated" ? "Generated" : "Created") \(climb.name)")
        onCreated(uuid)
        dismiss()
    }

    /// Re-point a climb's logged ascents (and its favorite, if any) from `oldUUID` to `newUUID` when an
    /// edit changes the holds — a logged send should follow the climb across an identity change (#76).
    private func migrateReferences(from oldUUID: String, to newUUID: String, name: String) {
        let logs = (try? modelContext.fetch(FetchDescriptor<KilterLogEntry>(
            predicate: #Predicate { $0.climbUUID == oldUUID }))) ?? []
        for log in logs { log.climbUUID = newUUID; log.climbName = name }
        // KilterFavorite.climbUUID is unique: move it only if the new uuid isn't already favorited,
        // else drop the now-stale old favorite.
        if let fav = (try? modelContext.fetch(FetchDescriptor<KilterFavorite>(
            predicate: #Predicate { $0.climbUUID == oldUUID })))?.first {
            let alreadyFav = (try? modelContext.fetch(FetchDescriptor<KilterFavorite>(
                predicate: #Predicate { $0.climbUUID == newUUID })))?.isEmpty == false
            if alreadyFav { modelContext.delete(fav) } else { fav.climbUUID = newUUID }
        }
    }
}
