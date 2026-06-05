import SwiftUI
import SwiftData

/// One climb's reassignment target (a unique climb in the session), passed in from the session view.
struct KilterClimbTarget: Identifiable, Hashable, Sendable {
    let uuid: String
    let name: String
    var id: String { uuid }
}

/// The **Climb panel** shown over the scoped clip studio (the floating "Climb ✎" button): read-only
/// catalog info (name / grade / board) plus the editable logging fields for this climb in the
/// session — angle, result + tries, and a personal note. Per-clip presentations also offer
/// "Move clip to another climb".
///
/// All edits mutate the **in-session `KilterLogEntry`** directly (the same row History reads) and
/// `try? context.save()` immediately — there's nothing to "apply". Catalog facts come from the
/// read-only `KilterCatalog`; the panel does no SQL of its own beyond `climb`/`stats`/`layouts`.
struct KilterClimbPanel: View {
    let sessionId: UUID
    let climbUUID: String
    /// The single clip this panel was opened for — enables "Move clip to another climb". `nil` for a
    /// per-climb / session presentation (no single clip to move).
    let singleClip: SessionMedia?
    /// The session's climbs, as "Move to climb…" targets.
    let climbTargets: [KilterClimbTarget]

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @AppStorage("kilter.gradeFormat") private var gradeFormatRaw = KilterGradeFormat.both.rawValue
    private var gradeFormat: KilterGradeFormat { KilterGradeFormat(rawValue: gradeFormatRaw) ?? .both }

    private let catalog = KilterCatalog.shared

    // The entry is fetched live (filtered from a @Query) so edits write straight to the @Model.
    @Query private var allEntries: [KilterLogEntry]

    @State private var climb: KilterClimb?
    @State private var stats: [KilterClimbStat] = []

    /// The in-session log entry for this climb — the edit target. `nil` if the climb was never logged
    /// in this session (e.g. a clip auto-tagged to a climb with no log); editing is disabled then.
    private var entry: KilterLogEntry? {
        allEntries.first { $0.sessionId == sessionId && $0.climbUUID == climbUUID }
    }

    /// Angles the catalog has stats for (the picker's options); falls back to the entry's own angle.
    private var availableAngles: [Int] {
        let fromStats = stats.map(\.angle)
        if !fromStats.isEmpty { return fromStats }
        return entry.map { [$0.angle] } ?? []
    }

    private var boardName: String? {
        guard let climb else { return nil }
        return catalog.layouts().first { $0.id == climb.layoutId }?.name
    }

    var body: some View {
        NavigationStack {
            Form {
                catalogSection
                if let entry {
                    logSection(entry)
                    noteSection(entry)
                } else {
                    Section {
                        Text("This climb wasn't logged in the session, so there's nothing to edit. Log it from the board to set angle, result, and a note.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let singleClip { moveSection(singleClip) }
            }
            .navigationTitle("Climb")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            climb = catalog.climb(climbUUID)
            stats = catalog.stats(climbUUID)
        }
    }

    // MARK: - Read-only catalog info

    @ViewBuilder private var catalogSection: some View {
        Section {
            LabeledContent("Climb", value: climb?.name ?? entry?.climbName ?? "—")
            LabeledContent("Grade", value: gradeText)
            if let boardName { LabeledContent("Board", value: boardName) }
        }
    }

    /// The displayed grade — the entry's stored label when present (kept fresh on angle change),
    /// else the catalog grade at the entry's angle. Rendered per the user's grade-format preference.
    private var gradeText: String {
        if let label = entry?.gradeLabel, !label.isEmpty {
            return kilterDisplayGrade(label, gradeFormat)
        }
        if let angle = entry?.angle, let stat = stats.first(where: { $0.angle == angle }) {
            return kilterDisplayGrade(catalog.gradeLabel(stat.difficulty), gradeFormat)
        }
        return "—"
    }

    // MARK: - Editable log fields

    @ViewBuilder private func logSection(_ entry: KilterLogEntry) -> some View {
        Section("Log") {
            Picker("Angle", selection: angleBinding(entry)) {
                ForEach(availableAngles, id: \.self) { Text("\($0)°").tag($0) }
            }
            Picker("Result", selection: resultBinding(entry)) {
                ForEach(KilterAscentStatus.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Stepper(value: triesBinding(entry), in: 1...99) {
                LabeledContent("Tries", value: "\(entry.attempts)")
            }
        }
    }

    @ViewBuilder private func noteSection(_ entry: KilterLogEntry) -> some View {
        Section("Note") {
            TextField("How it felt, beta, conditions…", text: noteBinding(entry), axis: .vertical)
                .lineLimit(2...5)
        }
    }

    // MARK: - Move clip (per-clip only)

    @ViewBuilder private func moveSection(_ clip: SessionMedia) -> some View {
        Section {
            Menu {
                ForEach(climbTargets.filter { $0.uuid != climbUUID }) { target in
                    Button(target.name) { reassign(clip, to: target.uuid) }
                }
                Divider()
                Button("Unassigned") { reassign(clip, to: nil) }
            } label: {
                Label("Move clip to another climb", systemImage: "arrow.left.arrow.right")
            }
        } footer: {
            Text("Moves this clip's tag to another climb in the session. The clip itself stays in the studio.")
        }
    }

    // MARK: - Bindings (write-through to the @Model + save)

    private func angleBinding(_ entry: KilterLogEntry) -> Binding<Int> {
        Binding(get: { entry.angle }, set: { newAngle in
            entry.angle = newAngle
            // Keep difficulty/grade consistent with the new angle (mirrors `log()`), so History and
            // the read-only grade above don't drift after a re-angle.
            if let stat = stats.first(where: { $0.angle == newAngle }) {
                entry.difficulty = stat.difficulty
                entry.gradeLabel = catalog.gradeLabel(stat.difficulty)
            }
            save()
        })
    }

    private func resultBinding(_ entry: KilterLogEntry) -> Binding<KilterAscentStatus> {
        Binding(get: { entry.status }, set: { entry.statusRaw = $0.rawValue; save() })
    }

    private func triesBinding(_ entry: KilterLogEntry) -> Binding<Int> {
        Binding(get: { entry.attempts }, set: { entry.attempts = max(1, $0); save() })
    }

    private func noteBinding(_ entry: KilterLogEntry) -> Binding<String> {
        Binding(get: { entry.note ?? "" }, set: { entry.note = $0.isEmpty ? nil : $0; save() })
    }

    private func reassign(_ clip: SessionMedia, to climbUUID: String?) {
        clip.assignedClimbUUID = climbUUID
        clip.assignmentSource = climbUUID == nil ? .general : .manual
        save()
        dismiss()
    }

    private func save() { try? modelContext.save() }
}
