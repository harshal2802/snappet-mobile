import SwiftUI
import SwiftData

/// "Add a send" (prompt 209, wireframe `docs/ux-research/kilter-plan-edit/` frame 3): pick climbs to add to a planned
/// session, with the SAME filters as the main Kilter browse (user, 2026-10-29: "give me all the filters we have on the
/// main kilter app on this screen too") — the grade-range slider (starting at the section's band), Saved, Mine,
/// All / Not tried / Projects / Sent, and the Filters sheet (sort, Classics only, min ascents, min quality) with its
/// live count. Board size and angle are the plan's (one board, one angle); only climbs the board can fully light.
/// Climbs already in the plan show ✓ and can't be added twice.
struct KilterPlanAddClimbSheet: View {
    let title: String
    let layoutId: Int
    let angle: Int
    let sizeBox: KilterSizeBox?
    /// The section's grade band — the grade slider's starting range; `nil` = every grade.
    let gradeWindow: (min: Double, max: Double)?
    let ascents: KilterAscentIndex
    /// Climbs already in the plan.
    let inPlan: Set<String>
    let gradeFormat: KilterGradeFormat
    let onAdd: (KilterListItem) -> Void

    @Environment(\.dismiss) private var dismiss
    @Query private var favorites: [KilterFavorite]
    @Query private var createdClimbs: [KilterCreatedClimb]
    private let catalog = KilterCatalog.shared

    @State private var search = ""
    @State private var minGrade = 1
    @State private var maxGrade = 39
    @State private var sort: KilterSort = .popular
    @State private var benchmarksOnly = false
    @State private var minAscents = 0
    @State private var minQuality = 0.0
    @State private var savedOnly = false
    @State private var mineOnly = false
    @State private var ascentFilter: KilterAscentFilter = .any
    @State private var items: [KilterListItem] = []
    @State private var count = 0
    @State private var added: Set<String> = []
    @State private var showingGrade = false
    @State private var showingFilters = false
    @State private var seeded = false

    private var gradeScale: [(difficulty: Int, label: String)] { catalog.gradeScale() }

    private var key: String {
        "\(search)|\(minGrade)|\(maxGrade)|\(sort.rawValue)|\(benchmarksOnly)|\(minAscents)|\(minQuality)|"
        + "\(savedOnly)|\(mineOnly)|\(ascentFilter.rawValue)|\(seeded)"
    }

    private var refineCount: Int {
        (benchmarksOnly ? 1 : 0) + (minAscents > 0 ? 1 : 0) + (minQuality > 0 ? 1 : 0) + (sort != .popular ? 1 : 0)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    filterChips
                        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 2, trailing: 12))
                    ascentChips
                        .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 6, trailing: 12))
                }
                Section {
                    ForEach(items) { row($0) }
                } header: {
                    Text("\(count) climb\(count == 1 ? "" : "s") · \(angle)°")
                } footer: {
                    Text("At the plan’s angle, and only climbs your board can light.")
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $search, prompt: "Search climbs")
            .overlay { if seeded && items.isEmpty { ContentUnavailableView.search(text: search) } }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("kilter.planAdd.done")
                }
            }
            .sheet(isPresented: $showingGrade) {
                KilterGradeRangeSheet(minGrade: $minGrade, maxGrade: $maxGrade,
                                      scale: gradeScale, format: gradeFormat, count: count)
            }
            .sheet(isPresented: $showingFilters) {
                KilterFiltersSheet(sort: $sort, benchmarksOnly: $benchmarksOnly, minAscents: $minAscents,
                                   minQuality: $minQuality, savedOnly: $savedOnly, mineOnly: $mineOnly,
                                   ascentFilter: $ascentFilter, count: count)
            }
            .onAppear(perform: seed)
            .task(id: key) { await load() }
        }
    }

    // MARK: - Chips (the main browse's, minus board / angle which are the plan's)

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("Grade " + gradeChipValue, on: gradeNarrowed) { showingGrade = true }
                    .accessibilityIdentifier("kilter.planAdd.grade")
                chip("Saved", on: savedOnly, icon: savedOnly ? "star.fill" : "star") {
                    savedOnly.toggle(); if savedOnly { mineOnly = false; ascentFilter = .any }
                }
                .accessibilityIdentifier("kilter.planAdd.saved")
                chip("Mine", on: mineOnly, icon: mineOnly ? "hammer.fill" : "hammer") {
                    mineOnly.toggle(); if mineOnly { savedOnly = false; ascentFilter = .any }
                }
                .accessibilityIdentifier("kilter.planAdd.mine")
                chip(refineCount > 0 ? "Filters · \(refineCount)" : "Filters", on: refineCount > 0,
                     icon: "line.3.horizontal.decrease") { showingFilters = true }
                    .accessibilityIdentifier("kilter.planAdd.filters")
            }
        }
    }

    private var ascentChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(KilterAscentFilter.allCases, id: \.self) { f in
                    let n: Int? = f == .projects ? ascents.projectUUIDs.count : f == .sent ? ascents.sentUUIDs.count : nil
                    chip(f.label + (n.map { " \($0)" } ?? ""), on: ascentFilter == f) {
                        ascentFilter = f
                        if f != .any { savedOnly = false; mineOnly = false }
                    }
                    .accessibilityIdentifier("kilter.planAdd.ascents.\(f.rawValue)")
                }
            }
        }
    }

    private var gradeNarrowed: Bool {
        guard let lo = gradeScale.first?.difficulty, let hi = gradeScale.last?.difficulty else { return false }
        return minGrade > lo || maxGrade < hi
    }

    private var gradeChipValue: String {
        gradeNarrowed
            ? "\(kilterDisplayGrade(catalog.gradeLabel(Double(minGrade)), gradeFormat))–\(kilterDisplayGrade(catalog.gradeLabel(Double(maxGrade)), gradeFormat))"
            : "Any"
    }

    private func chip(_ label: String, on: Bool, icon: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon { Image(systemName: icon) }
                Text(label)
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(on ? AnyShapeStyle(.tint.opacity(0.22)) : AnyShapeStyle(Color(.secondarySystemBackground)),
                        in: Capsule())
            .overlay(Capsule().strokeBorder(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear)))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Rows

    private func row(_ item: KilterListItem) -> some View {
        let already = inPlan.contains(item.uuid) || added.contains(item.uuid)
        let badge = ascents.badge(item.uuid, angle: angle)
        return HStack(spacing: 10) {
            Text(kilterDisplayGrade(item.gradeLabel, gradeFormat))
                .font(.caption.weight(.bold)).monospacedDigit()
                .frame(width: 56, height: 26)
                .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if favorites.contains(where: { $0.climbUUID == item.uuid }) {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                    }
                    if let badge {
                        let sent = badge.hasPrefix("✓")
                        Text(badge).font(.caption2.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background((sent ? Color.green : Color.orange).opacity(0.18), in: Capsule())
                            .foregroundStyle(sent ? Color.green : Color.orange)
                    }
                }
                HStack(spacing: 6) {
                    Text("by \(item.setter)").lineLimit(1)
                    if item.ascents > 0 { KilterStars(quality: item.quality); Text("\(item.ascents)") }
                }
                .font(.caption).foregroundStyle(.secondary)
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

    // MARK: - Data

    /// Start the grade slider at the section's band (snapped to the catalog's grade scale), else every grade.
    private func seed() {
        guard !seeded else { return }
        let lo = gradeScale.first?.difficulty ?? 1, hi = gradeScale.last?.difficulty ?? 39
        if let w = gradeWindow {
            minGrade = max(lo, min(hi, Int(w.min.rounded())))
            maxGrade = max(minGrade, min(hi, Int(w.max.rounded())))
        } else {
            minGrade = lo; maxGrade = hi
        }
        seeded = true
    }

    private func load() async {
        guard seeded else { return }
        try? await Task.sleep(for: .milliseconds(150))   // debounce typing / slider drags
        if Task.isCancelled { return }
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        func matches(_ i: KilterListItem) -> Bool {
            term.isEmpty || i.name.lowercased().contains(term) || i.setter.lowercased().contains(term)
        }
        // Your own lists — like the browse screen, not grade-restricted.
        if savedOnly || mineOnly || ascentFilter == .projects || ascentFilter == .sent {
            let list: [KilterListItem]
            if mineOnly {
                list = createdClimbs.filter { $0.layoutId == layoutId }.sorted { $0.createdAt > $1.createdAt }.map { c in
                    KilterListItem(uuid: c.uuid, name: c.name, setter: c.setterUsername,
                                   difficulty: c.predictedGrade ?? 0,
                                   gradeLabel: c.predictedGrade.map { catalog.gradeLabel($0) } ?? "—",
                                   quality: 0, ascents: 0)
                }
            } else if savedOnly {
                list = catalog.climbsByUUID(favorites.sorted { $0.addedAt > $1.addedAt }.map(\.climbUUID))
            } else {
                list = catalog.climbsByUUID(ascentFilter == .projects ? ascents.projectUUIDs : ascents.sentUUIDs)
            }
            items = list.filter(matches)
            count = items.count
            return
        }
        let filter = KilterFilter(layoutId: layoutId, angle: angle,
                                  minDifficulty: Double(minGrade), maxDifficulty: Double(maxGrade),
                                  search: search, sort: sort, benchmarksOnly: benchmarksOnly,
                                  minAscents: minAscents, minQuality: minQuality, sizeBox: sizeBox,
                                  excludeUUIDs: ascentFilter == .notTried ? ascents.loggedUUIDs : [])
        guard let page = await catalog.browser.browse(filter, limit: 300, includeDiscovery: false),
              !Task.isCancelled else { return }
        items = page.items
        count = page.count
    }
}
