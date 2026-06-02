import SwiftUI
import SwiftData

/// Route values pushed onto the App Library's shared `SuiteRouter` path.
struct KilterClimbRoute: Hashable { let uuid: String }
struct KilterHistoryRoute: Hashable {}

/// Kilter Board catalog: browse climbs from the bundled, read-only catalog, filtered by layout,
/// angle, and grade (plus a Saved filter), and open a climb for the board render + logging.
///
/// Pushed into the suite's NavigationStack by the App Library — owns no NavigationStack of its own;
/// deeper screens (detail, history) push onto the shared `SuiteRouter` path.
struct KilterRootView: View {
    @Environment(SuiteRouter.self) private var router
    @Query private var favorites: [KilterFavorite]

    private let catalog = KilterCatalog.shared
    /// Shared across the module's screens (detail illuminates / sessions group history).
    @State private var board = KilterBoardController()
    @State private var sessions = KilterSessionManager()

    @AppStorage("kilter.angle") private var angle: Int = 40
    @AppStorage("kilter.layout") private var layoutId: Int = 1
    @AppStorage("kilter.minGrade") private var minGrade: Int = 10
    @AppStorage("kilter.maxGrade") private var maxGrade: Int = 33
    @State private var savedOnly = false
    @State private var items: [KilterListItem] = []

    private var layouts: [KilterLayout] { catalog.layouts() }
    private var availableAngles: [Int] { catalog.angles() }
    private var gradeScale: [(difficulty: Int, label: String)] { catalog.gradeScale() }
    private var favoriteUUIDs: Set<String> { Set(favorites.map(\.climbUUID)) }

    var body: some View {
        Group {
            if catalog.isAvailable {
                content
            } else {
                ContentUnavailableView("Catalog unavailable", systemImage: "exclamationmark.triangle",
                    description: Text("The bundled Kilter catalog couldn't be opened."))
            }
        }
        .navigationTitle("Kilter Board")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { router.push(KilterHistoryRoute()) } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                .accessibilityIdentifier("kilter.history")
            }
        }
        .navigationDestination(for: KilterClimbRoute.self) { route in
            KilterClimbDetailView(uuid: route.uuid, board: board, sessions: sessions)
        }
        .navigationDestination(for: KilterHistoryRoute.self) { _ in
            KilterHistoryView()
        }
        .task(id: filterKey) { refresh() }
    }

    private var content: some View {
        VStack(spacing: 0) {
            filterBar
            List(items) { item in
                Button { router.push(KilterClimbRoute(uuid: item.uuid)) } label: {
                    KilterClimbRow(item: item, isFavorite: favoriteUUIDs.contains(item.uuid))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("kilter.climbRow")
            }
            .listStyle(.plain)
            .overlay {
                if items.isEmpty {
                    ContentUnavailableView(savedOnly ? "No saved climbs" : "No climbs match",
                        systemImage: savedOnly ? "star" : "line.3.horizontal.decrease.circle",
                        description: Text(savedOnly ? "Star climbs to find them here."
                                                    : "Try a wider grade range or another angle."))
                }
            }
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Menu {
                    Picker("Layout", selection: $layoutId) {
                        ForEach(layouts) { Text($0.name).tag($0.id) }
                    }
                } label: { chip("Layout", layouts.first { $0.id == layoutId }?.name ?? "—") }
                .accessibilityIdentifier("kilter.layout")

                Menu {
                    Picker("Angle", selection: $angle) {
                        ForEach(availableAngles, id: \.self) { Text("\($0)°").tag($0) }
                    }
                } label: { chip("Angle", "\(angle)°") }
                .accessibilityIdentifier("kilter.angle")

                Menu {
                    Picker("From", selection: $minGrade) {
                        ForEach(gradeScale, id: \.difficulty) { Text($0.label).tag($0.difficulty) }
                    }
                    Picker("To", selection: $maxGrade) {
                        ForEach(gradeScale, id: \.difficulty) { Text($0.label).tag($0.difficulty) }
                    }
                } label: { chip("Grade", "\(catalog.gradeLabel(Double(minGrade)))–\(catalog.gradeLabel(Double(maxGrade)))") }
                .accessibilityIdentifier("kilter.grade")

                Button { savedOnly.toggle() } label: {
                    chip("", "Saved", filled: savedOnly, systemImage: savedOnly ? "star.fill" : "star")
                }
                .accessibilityIdentifier("kilter.savedToggle")
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    private func chip(_ title: String, _ value: String, filled: Bool = false, systemImage: String? = nil) -> some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage) }
            if !title.isEmpty { Text(title).foregroundStyle(.secondary) }
            Text(value).fontWeight(.medium)
        }
        .font(.subheadline)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(filled ? AnyShapeStyle(.tint) : AnyShapeStyle(Color(.secondarySystemBackground)),
                    in: Capsule())
        .foregroundStyle(filled ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
    }

    /// Identity for `.task(id:)` — recompute the list whenever a filter (or the favorites set) changes.
    private var filterKey: String {
        "\(layoutId)-\(angle)-\(minGrade)-\(maxGrade)-\(savedOnly)-\(favoriteUUIDs.count)"
    }

    private func refresh() {
        guard catalog.isAvailable else { items = []; return }
        // Keep min ≤ max even if the user picks them out of order.
        let lo = Double(min(minGrade, maxGrade)), hi = Double(max(minGrade, maxGrade))
        if savedOnly {
            let saved = favorites.sorted { $0.addedAt > $1.addedAt }.map(\.climbUUID)
            items = catalog.climbsByUUID(saved)
        } else {
            items = catalog.list(layoutId: layoutId, angle: angle, minDifficulty: lo, maxDifficulty: hi)
        }
    }
}

/// One catalog row: name + setter, grade badge, quality stars, ascent count.
private struct KilterClimbRow: View {
    let item: KilterListItem
    let isFavorite: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name).font(.headline).lineLimit(1)
                    if isFavorite { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow) }
                }
                Text("by \(item.setter)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(item.gradeLabel)
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Color(.tertiarySystemBackground), in: Capsule())
                HStack(spacing: 6) {
                    KilterStars(quality: item.quality)
                    Label("\(item.ascents)", systemImage: "person.2.fill")
                        .font(.caption2).foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

/// 0–3 filled stars from a quality average.
struct KilterStars: View {
    let quality: Double
    var body: some View {
        let filled = Int(quality.rounded())
        HStack(spacing: 1) {
            ForEach(0..<3, id: \.self) { i in
                Image(systemName: i < filled ? "star.fill" : "star")
                    .font(.caption2).foregroundStyle(.yellow)
            }
        }
        .accessibilityLabel("Quality \(filled) of 3")
    }
}
