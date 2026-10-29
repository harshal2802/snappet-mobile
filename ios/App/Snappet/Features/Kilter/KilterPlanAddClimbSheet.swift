import SwiftUI

/// "Add a send" (prompt 209, wireframe `docs/ux-research/kilter-plan-edit/` frame 3): pick climbs to add to a planned
/// session. Search plus the browse chips — near this section's grade, Not tried / Projects / Sent, Classics — and
/// only climbs your board can fully light. Climbs already in the plan show ✓ and can't be added twice.
struct KilterPlanAddClimbSheet: View {
    let title: String
    let layoutId: Int
    let angle: Int
    let sizeBox: KilterSizeBox?
    /// The section's grade band; `nil` (or the chip switched off) = any grade.
    let gradeWindow: (min: Double, max: Double)?
    let ascents: KilterAscentIndex
    /// Climbs already in the plan.
    let inPlan: Set<String>
    let gradeFormat: KilterGradeFormat
    let onAdd: (KilterListItem) -> Void

    @Environment(\.dismiss) private var dismiss
    private let catalog = KilterCatalog.shared
    @State private var search = ""
    @State private var nearGrade = true
    @State private var ascentFilter: KilterAscentFilter = .any
    @State private var classics = false
    @State private var items: [KilterListItem] = []
    @State private var added: Set<String> = []

    private var key: String { "\(search)|\(nearGrade)|\(ascentFilter.rawValue)|\(classics)" }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            if gradeWindow != nil {
                                chip("Near this grade", on: nearGrade) { nearGrade.toggle() }
                                    .accessibilityIdentifier("kilter.planAdd.nearGrade")
                            }
                            ForEach(KilterAscentFilter.allCases, id: \.self) { f in
                                chip(f.label, on: ascentFilter == f) { ascentFilter = f }
                                    .accessibilityIdentifier("kilter.planAdd.ascents.\(f.rawValue)")
                            }
                            chip("Classics", on: classics) { classics.toggle() }
                                .accessibilityIdentifier("kilter.planAdd.classics")
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                }
                Section {
                    ForEach(items) { row($0) }
                } footer: {
                    Text("Only climbs your board can light.")
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $search, prompt: "Search climbs")
            .overlay { if items.isEmpty { ContentUnavailableView.search(text: search) } }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("kilter.planAdd.done")
                }
            }
            .task(id: key) { await load() }
        }
    }

    private func row(_ item: KilterListItem) -> some View {
        let already = inPlan.contains(item.uuid) || added.contains(item.uuid)
        return HStack(spacing: 10) {
            Text(kilterDisplayGrade(item.gradeLabel, gradeFormat))
                .font(.caption.weight(.bold)).monospacedDigit()
                .frame(width: 52, height: 26)
                .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text([ascents.badge(item.uuid, angle: angle), "by \(item.setter)"].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if already {
                Label("Added", systemImage: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            } else {
                Button("Add") {
                    onAdd(item)
                    added.insert(item.uuid)
                    Haptics.tap()
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .accessibilityIdentifier("kilter.planAdd.add")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("kilter.planAdd.row")
    }

    private func chip(_ label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(on ? AnyShapeStyle(.tint.opacity(0.22)) : AnyShapeStyle(Color(.secondarySystemBackground)),
                            in: Capsule())
                .overlay(Capsule().strokeBorder(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear)))
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        try? await Task.sleep(for: .milliseconds(150))   // debounce typing
        if Task.isCancelled { return }
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ascentFilter == .projects || ascentFilter == .sent {
            // Your own climbs — like the browse lists, not grade-restricted.
            let uuids = ascentFilter == .projects ? ascents.projectUUIDs : ascents.sentUUIDs
            let mine = catalog.climbsByUUID(uuids)
            items = term.isEmpty ? mine : mine.filter { $0.name.lowercased().contains(term) || $0.setter.lowercased().contains(term) }
            return
        }
        let window = (nearGrade ? gradeWindow : nil) ?? (1, 39)
        let filter = KilterFilter(layoutId: layoutId, angle: angle, minDifficulty: window.min, maxDifficulty: window.max,
                                  search: search, benchmarksOnly: classics, sizeBox: sizeBox,
                                  excludeUUIDs: ascentFilter == .notTried ? ascents.loggedUUIDs : [])
        guard let page = await catalog.browser.browse(filter, limit: 200, includeDiscovery: false),
              !Task.isCancelled else { return }
        items = page.items
    }
}
