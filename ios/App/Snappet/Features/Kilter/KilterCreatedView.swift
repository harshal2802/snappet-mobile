import SwiftUI
import SwiftData

/// Route value for the first-class **Your Climbs** gallery — pushed onto the suite's shared
/// `SuiteRouter` path the same way `KilterSessionRoute` is (`KilterRootView`). Hashable + empty: the
/// gallery reads its data from `@Query`, so the route carries no payload.
struct KilterCreatedRoute: Hashable {}

/// **Your Climbs** (P2): the first-class gallery of climbs you authored — promoting the buried,
/// layout-scoped, text-only "Mine" filter into a board-thumbnail grid that is **global across layouts**
/// (a climb you set on another board still shows). The lit-holds render *is* the climb's identity, so the
/// grid leads with thumbnails. Header = a `DisciplineHero` "N climbs set" + a coral "Set a climb" CTA.
/// A Draft/Saved/All status segment, filter + sort chips (layout · angle · source; Recently-set [default]
/// / Grade / Most-climbed), and name search. Per card: grade badge, provenance (Hand-set / Generated),
/// angle, and the user's OWN logbook status (Sent / Project / Untried — never community signals). Per-card
/// Edit / Duplicate / Share / Delete (delete keeps logged ascents). Tap → the existing climb detail.
///
/// All query/sort/filter/own-status logic lives in the pure `KilterCreatedGallery`; this view feeds it
/// device-free snapshots of its `@Query` rows and renders the ordered items.
struct KilterCreatedView: View {
    @Environment(SuiteRouter.self) private var router
    @Environment(\.modelContext) private var modelContext
    @Environment(SnappetCore.self) private var core
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Query(sort: \KilterCreatedClimb.createdAt, order: .reverse) private var createdClimbs: [KilterCreatedClimb]
    @Query private var logEntries: [KilterLogEntry]

    private let catalog = KilterCatalog.shared
    /// Lazily-built, cached board thumbnails so a large grid doesn't re-hit SQLite on every scroll frame.
    @State private var thumbs = KilterThumbnailCache()
    /// Memoizes the per-climb draft/savable derivation (parses `frames` via `kilterValidate` once per
    /// uuid) so it isn't re-run on every body re-render — e.g. every search keystroke (F8).
    @State private var rows = KilterCreatedRowCache()
    /// The shared board controller, so the create / edit sheets can live-light a connected board.
    @State private var board = KilterBoardController()

    // Display + facet state (the toggle + grid/list mode persist; the rest reset per visit).
    @AppStorage("kilter.created.grid") private var gridMode = true
    @State private var segment: KilterCreatedGallery.Segment = .all
    @State private var sort: KilterCreatedGallery.Sort = .recent
    @State private var search = ""
    /// Optional facets — `nil` means "any" (the global default).
    @State private var layoutFacet: Int?
    @State private var angleFacet: Int?
    @State private var sourceFacet: String?

    // Sheets + confirmations.
    @State private var showingCreate = false
    /// The editor target — a STABLE value-type identity (self-assigned `UUID`), never a `@Model`'s
    /// `persistentModelID` (which is temporary/unstable for an un-inserted Duplicate clone). Keying the
    /// sheet on this makes two Duplicates in a row, or Edit→cancel→Edit, present reliably (F2).
    @State private var editorTarget: EditorTarget?
    @State private var sharingClimb: KilterCreatedClimb?
    /// A value-type SNAPSHOT of the climb being deleted (name + its ascent count, captured BEFORE the
    /// delete). The dialog reads only this — never the live `@Model`, which SwiftUI would re-evaluate on a
    /// row that's already gone from the store after `delete` + save → crash (F1).
    @State private var deleteTarget: DeleteTarget?

    /// A stable, value-type editor target so `.sheet(item:)` keys on a self-owned `UUID`, not a `@Model`'s
    /// `persistentModelID`. `.edit` carries the existing climb's stable content uuid; `.duplicate` carries
    /// the seed frames/data for a fresh-from-frames clone (never an un-inserted model whose id is unstable).
    /// Each case carries a fresh `UUID` (assigned by the factories below) as its `Identifiable.id`, so two
    /// consecutive Duplicates — or Edit→cancel→Edit — produce *distinct* identities and reliably re-present.
    private enum EditorTarget: Identifiable {
        case edit(uuid: String, id: UUID)
        case duplicate(seed: DuplicateSeed, id: UUID)

        var id: UUID {
            switch self {
            case .edit(_, let id), .duplicate(_, let id): return id
            }
        }

        static func edit(uuid: String) -> EditorTarget { .edit(uuid: uuid, id: UUID()) }
        static func duplicate(seed: DuplicateSeed) -> EditorTarget { .duplicate(seed: seed, id: UUID()) }
    }

    /// The frames/conditions a Duplicate seeds the editor from — a pure value snapshot, so the clone never
    /// depends on a `@Model`'s identity and re-opens with the correct content every time.
    private struct DuplicateSeed {
        var name: String, setterUsername: String
        var layoutId: Int, sizeId: Int, angle: Int, frames: String
        var isNoMatch: Bool, predictedGrade: Double?, source: String
    }

    /// A value snapshot for the delete confirmation — captured before the model leaves the store (F1).
    private struct DeleteTarget: Identifiable {
        let uuid: String, name: String, ascentCount: Int
        var id: String { uuid }
    }

    private var layouts: [KilterLayout] { catalog.layouts() }

    /// Device-free snapshots fed to the pure engine. Draft = a climb whose holds fail `kilterValidate`
    /// (the same save floor the editor enforces) — **no schema field**, derived from the stored `frames`.
    /// Memoized per uuid (F8): the expensive `frames` parse runs once per climb, not on every keystroke.
    private var createdRows: [KilterCreatedGallery.CreatedRow] {
        rows.rows(for: createdClimbs)
    }

    private var logRows: [KilterCreatedGallery.LogRow] {
        logEntries.map { KilterCreatedGallery.LogRow(climbUUID: $0.climbUUID, status: $0.status) }
    }

    /// The ordered display items — the single call into the pure engine. Only the cheap filter/sort/search
    /// runs per keystroke; the per-climb draft derivation is memoized in `createdRows` (F8).
    private var items: [KilterCreatedGallery.Item] {
        KilterCreatedGallery.items(created: createdRows, logs: logRows, segment: segment, sort: sort,
                                   search: search, layoutId: layoutFacet, angle: angleFacet,
                                   source: sourceFacet)
    }

    /// The angle facet options — the DISTINCT angles in the user's created climbs, NOT the installed
    /// catalog (the gallery is global across layouts, so an off-catalog angle must stay reachable) (F5).
    private var availableAngles: [Int] {
        KilterCreatedGallery.angleFacets(created: createdRows)
    }

    /// Re-derive the Draft state from a climb's holds: a climb that would fail the save floor
    /// (`kilterValidate`) is incomplete → a Draft. Keeps Draft a *derived* facet, never a schema column.
    static func isSavable(frames: String) -> Bool {
        kilterValidate(CreateClimbView.assignments(fromFrames: frames)) == nil
    }

    var body: some View {
        Group {
            if createdClimbs.isEmpty {
                emptyState
            } else {
                gallery
            }
        }
        .navigationTitle("Your Climbs")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic),
                    prompt: "Search your climbs")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { gridMode.toggle() } label: {
                    Label(gridMode ? "List" : "Grid",
                          systemImage: gridMode ? "list.bullet" : "square.grid.2x2")
                }
                .accessibilityIdentifier("kilter.created.viewToggle")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showingCreate = true } label: { Label("Set a climb", systemImage: "plus") }
                    .accessibilityIdentifier("kilter.created.add")
            }
        }
        .sheet(isPresented: $showingCreate) {
            CreateClimbView(onCreated: { uuid in router.push(KilterClimbRoute(uuid: uuid)) }, board: board)
        }
        .sheet(item: $editorTarget) { target in
            editorSheet(target)
        }
        .sheet(item: $sharingClimb) { climb in
            KilterShareView(climb: climb.asClimb,
                            gradeLabel: climb.predictedGrade.map { catalog.gradeLabel($0) } ?? "—",
                            angle: climb.angle)
        }
        .confirmationDialog("Delete this climb?",
                            isPresented: Binding(get: { deleteTarget != nil },
                                                 set: { if !$0 { deleteTarget = nil } }),
                            titleVisibility: .visible, presenting: deleteTarget) { target in
            // Read only the value snapshot — by the time these closures re-evaluate post-delete, the live
            // model is gone from the store (F1).
            Button("Delete climb", role: .destructive) {
                guard let climb = climb(target.uuid) else { return }
                core.log(module: "kilter", action: "deleted", summary: "Deleted \(target.name)")
                KilterCreatedClimb.delete(climb, in: modelContext)
            }
            .accessibilityIdentifier("kilter.created.deleteConfirm")
            Button("Cancel", role: .cancel) {}
        } message: { target in
            // The keep-ascents guarantee, made visible (wireframe 02b): a real send never vanishes. The
            // ascent count was computed once when the dialog opened — never re-fetched off a deleted model.
            Text(target.ascentCount == 0
                 ? "“\(target.name)” will be removed. It can't be undone."
                 : "“\(target.name)” will be removed — but your \(target.ascentCount) logged ascent\(target.ascentCount == 1 ? "" : "s") stay in History.")
        }
        .onChange(of: createdClimbs.map(\.uuid)) {
            let live = Set(createdClimbs.map(\.uuid))
            thumbs.evict(keeping: live)
            rows.evict(keeping: live)
        }
    }

    /// Build the editor from the STABLE value-type target (F2) — never a `@Model` whose `persistentModelID`
    /// is unstable for an un-inserted clone. `.edit` re-resolves the live row by its content uuid; `.duplicate`
    /// seeds `CreateClimbView` from a fresh-from-frames transient clone built off the value seed each time it
    /// presents, so two Duplicates in a row (and Edit→cancel→Edit) reliably open the correct content.
    @ViewBuilder private func editorSheet(_ target: EditorTarget) -> some View {
        switch target {
        case .edit(let uuid, _):
            if let climb = climb(uuid) {
                CreateClimbView(onCreated: { _ in }, board: board, editing: climb)
            }
        case .duplicate(let seed, _):
            CreateClimbView(onCreated: { _ in }, board: board, editing: draft(from: seed))
        }
    }

    /// A transient (un-inserted) draft clone built from a pure value seed: identical holds/conditions, a
    /// "Copy" name, and a throwaway uuid (the editor re-derives the real content uuid on save). Built fresh
    /// each presentation so it never carries a stale `persistentModelID`. Deleting an un-inserted model on a
    /// hold-change save is a safe no-op, so the clone never leaks a phantom row if the user cancels.
    private func draft(from seed: DuplicateSeed) -> KilterCreatedClimb {
        KilterCreatedClimb(
            uuid: "draft-\(UUID().uuidString.lowercased())",
            name: seed.name, setterUsername: seed.setterUsername,
            layoutId: seed.layoutId, sizeId: seed.sizeId, angle: seed.angle, frames: seed.frames,
            edgeLeft: 0, edgeRight: 0, edgeBottom: 0, edgeTop: 0,
            isNoMatch: seed.isNoMatch, predictedGrade: seed.predictedGrade, source: seed.source)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                DisciplineHero(value: "\(createdClimbs.count)", caption: "Climbs set",
                               systemImage: "hammer.fill", accent: SnappetColor.kilter)
                Button { showingCreate = true } label: {
                    Label("Set a climb", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent).tint(SnappetColor.brand).controlSize(.regular)
                .accessibilityIdentifier("kilter.created.setCTA")
            }
            Picker("Status", selection: $segment) {
                ForEach(KilterCreatedGallery.Segment.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("kilter.created.segment")
            facetChips
        }
        .padding(.horizontal)
        .padding(.top, 4)
    }

    /// The filter + sort chips: sort · layout · angle · source. Each `nil` facet reads "All".
    private var facetChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach(KilterCreatedGallery.Sort.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                } label: { chip("Sort", sort.label, systemImage: "arrow.up.arrow.down") }
                .accessibilityIdentifier("kilter.created.sort")

                Menu {
                    Picker("Layout", selection: $layoutFacet) {
                        Text("All layouts").tag(Int?.none)
                        ForEach(layouts) { Text($0.name).tag(Int?.some($0.id)) }
                    }
                } label: {
                    chip("Layout", layoutFacet.flatMap { id in layouts.first { $0.id == id }?.name } ?? "All",
                         filled: layoutFacet != nil)
                }
                .accessibilityIdentifier("kilter.created.layoutFacet")

                Menu {
                    Picker("Angle", selection: $angleFacet) {
                        Text("All angles").tag(Int?.none)
                        ForEach(availableAngles, id: \.self) { Text("\($0)°").tag(Int?.some($0)) }
                    }
                } label: { chip("Angle", angleFacet.map { "\($0)°" } ?? "All", filled: angleFacet != nil) }
                .accessibilityIdentifier("kilter.created.angleFacet")

                Menu {
                    Picker("Source", selection: $sourceFacet) {
                        Text("Any source").tag(String?.none)
                        Text("Hand-set").tag(String?.some("manual"))
                        Text("Generated").tag(String?.some("generated"))
                    }
                } label: {
                    chip("Source", sourceFacet.map { $0 == "generated" ? "Generated" : "Hand-set" } ?? "All",
                         filled: sourceFacet != nil)
                }
                .accessibilityIdentifier("kilter.created.sourceFacet")

                if hasActiveFacet {
                    Button { withAnimation(.snappy) { clearFacets() } } label: {
                        chip("", "Clear", systemImage: "xmark.circle.fill")
                    }
                    .accessibilityIdentifier("kilter.created.clearFacets")
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var hasActiveFacet: Bool { layoutFacet != nil || angleFacet != nil || sourceFacet != nil }
    private func clearFacets() { layoutFacet = nil; angleFacet = nil; sourceFacet = nil }

    // MARK: - Gallery (grid + list)

    @ViewBuilder private var gallery: some View {
        ScrollView {
            header
            if items.isEmpty {
                noMatches
            } else if gridMode {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)],
                          spacing: 14) {
                    ForEach(items) { item in card(item) }
                }
                .padding(.horizontal).padding(.top, 12)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(items) { item in listRow(item) }
                }
                .padding(.horizontal).padding(.top, 12)
            }
        }
        .scrollDismissesKeyboard(.immediately)
    }

    /// A grid card: the board thumbnail with a grade badge, then name + provenance · angle · own-status.
    private func card(_ item: KilterCreatedGallery.Item) -> some View {
        Button { router.push(KilterClimbRoute(uuid: item.uuid)) } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    thumbnail(item)
                    gradeBadge(item).padding(6)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(item.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                        if item.isDraft { draftPill }
                    }
                    HStack(spacing: 8) {
                        provenanceLabel(item.provenance)
                        Text("\(item.angle)°").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        ownStatusChip(item.ownStatus, count: item.logCount)
                    }
                }
            }
            .padding(10)
            .background(SnappetColor.surface, in: RoundedRectangle(cornerRadius: SnappetRadius.lg, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: SnappetRadius.lg, style: .continuous)
                .strokeBorder(SnappetColor.hairline, lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("kilter.created.card")
        .contextMenu { cardActions(item) }
    }

    /// A compact list row: a small thumbnail, name + meta, grade — with swipe-free context-menu actions
    /// (list mode is a ScrollView/LazyVStack, so actions live in the context menu, like the grid).
    private func listRow(_ item: KilterCreatedGallery.Item) -> some View {
        Button { router.push(KilterClimbRoute(uuid: item.uuid)) } label: {
            HStack(spacing: 12) {
                thumbnail(item).frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(item.name).font(.headline).lineLimit(1)
                        if item.isDraft { draftPill }
                    }
                    HStack(spacing: 8) {
                        provenanceLabel(item.provenance)
                        Text("\(item.angle)°").font(.caption2).foregroundStyle(.secondary)
                        ownStatusChip(item.ownStatus, count: item.logCount)
                    }
                }
                Spacer()
                gradeBadge(item)
            }
            .padding(10)
            .background(SnappetColor.surface, in: RoundedRectangle(cornerRadius: SnappetRadius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: SnappetRadius.md, style: .continuous)
                .strokeBorder(SnappetColor.hairline, lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("kilter.created.card")
        .contextMenu { cardActions(item) }
    }

    /// The canonical per-card actions (context menu): Edit · Duplicate · Share · Delete.
    @ViewBuilder private func cardActions(_ item: KilterCreatedGallery.Item) -> some View {
        if let climb = climb(item.uuid) {
            Button { editorTarget = .edit(uuid: climb.uuid) } label: { Label("Edit", systemImage: "pencil") }
                .accessibilityIdentifier("kilter.created.edit")
            Button { duplicate(climb) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                .accessibilityIdentifier("kilter.created.duplicate")
            Button { sharingClimb = climb } label: { Label("Share (QR)", systemImage: "qrcode") }
                .accessibilityIdentifier("kilter.created.share")
            Button(role: .destructive) { beginDelete(climb) } label: {
                Label("Delete", systemImage: "trash")
            }
            .accessibilityIdentifier("kilter.created.delete")
        }
    }

    // MARK: - Card sub-views

    /// The cached board thumbnail for a created climb (the lit-holds render that *is* the climb).
    private func thumbnail(_ item: KilterCreatedGallery.Item) -> some View {
        Group {
            if let climb = climb(item.uuid), let render = thumbs.render(for: climb, catalog: catalog) {
                KilterBoardView(geometry: render.geometry, holds: render.holds)
            } else {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(SnappetColor.surfaceMuted)
                    .aspectRatio(0.62, contentMode: .fit)
                    .overlay(Image(systemName: "square.grid.3x3")
                        .font(.title2).foregroundStyle(.tertiary))
            }
        }
        .accessibilityHidden(true)
    }

    private func gradeBadge(_ item: KilterCreatedGallery.Item) -> some View {
        Text(item.predictedGrade.map { catalog.gradeLabel($0) } ?? "—")
            .font(.caption.weight(.bold)).monospacedDigit()
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(SnappetColor.kilter.opacity(0.18), in: Capsule())
            .foregroundStyle(SnappetColor.kilter)
    }

    private func provenanceLabel(_ p: KilterCreatedGallery.Provenance) -> some View {
        Label(p.label, systemImage: p.glyph)
            .font(.caption2).foregroundStyle(.secondary).labelStyle(.titleAndIcon).lineLimit(1)
    }

    /// The user's OWN status chip — glyph + label (never colour-only), in the perf-ramp colours. Sent
    /// shows the ascent count (e.g. "Sent ×2", matching wireframe 02b).
    private func ownStatusChip(_ status: KilterCreatedGallery.OwnStatus, count: Int) -> some View {
        let (glyph, tint): (String, Color) = {
            switch status {
            case .sent:    return ("checkmark.seal.fill", SnappetColor.perfFresh)
            case .project: return ("hourglass", SnappetColor.perfModerate)
            case .attempt: return ("figure.climbing", SnappetColor.perfHard)
            case .untried: return ("circle.dashed", SnappetColor.textSecondary)
            }
        }()
        let text = (status == .sent && count > 1) ? "\(status.label) ×\(count)" : status.label
        return Label(text, systemImage: glyph)
            .font(.caption2.weight(.semibold)).labelStyle(.titleAndIcon).lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
            .accessibilityIdentifier("kilter.created.ownStatus")
    }

    /// A neutral/muted DRAFT pill (F9) — distinct from the amber grade badge (`SnappetColor.kilter`) and
    /// the amber Project chip (`perfModerate`), which previously all read as the same amber on a
    /// draft/project card. Neutral here lets the three signals read distinctly.
    private var draftPill: some View {
        Text("DRAFT").font(.caption2.weight(.bold)).tracking(0.5)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(SnappetColor.surfaceMuted, in: Capsule())
            .foregroundStyle(SnappetColor.textSecondary)
            .accessibilityIdentifier("kilter.created.draftPill")
    }

    // MARK: - Empty / no-match states

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No climbs yet", systemImage: "figure.climbing")
        } description: {
            Text("Set your first climb — design it hold by hold, or generate one on-device.")
        } actions: {
            Button { showingCreate = true } label: { Text("Set a climb") }
                .buttonStyle(.borderedProminent).tint(SnappetColor.brand)
                .accessibilityIdentifier("kilter.created.emptySet")
            Button { showingCreate = true } label: { Text("Generate one") }
                .accessibilityIdentifier("kilter.created.emptyGenerate")
        }
        .accessibilityIdentifier("kilter.created.empty")
    }

    private var noMatches: some View {
        let searching = !search.trimmingCharacters(in: .whitespaces).isEmpty
        return ContentUnavailableView(
            searching ? "No matches" : "Nothing here",
            systemImage: searching ? "magnifyingglass" : "line.3.horizontal.decrease.circle",
            description: Text(searching
                              ? "No climbs match “\(search)” with the current filters."
                              : "No climbs in this view — try another status or clear the filters."))
            .padding(.top, 40)
    }

    // MARK: - Actions

    /// The model row for a uuid (the engine works on snapshots; mutations need the live `@Model`).
    private func climb(_ uuid: String) -> KilterCreatedClimb? {
        createdClimbs.first { $0.uuid == uuid }
    }

    /// **Duplicate**: clone a climb's holds as a NEW draft on the same layout. A created climb's identity
    /// is its *content* (the hold set), so an exact clone would collapse onto the source's uuid. Rather
    /// than persist a phantom row, we open the editor seeded from a **transient** clone (a "Copy" name,
    /// same holds/conditions, never inserted): the user evolves it — change a hold → a genuinely new
    /// content identity on save; keep the holds → the editor's own dup check (self-excluding the source,
    /// `KilterDuplicateChecker`, run at save) offers *Open existing*. Nothing is written until they save.
    ///
    /// The target is a value-type seed with a fresh `EditorTarget.id` (F2), so consecutive Duplicates each
    /// present their own sheet — they no longer key on a clone model's unstable `persistentModelID`.
    private func duplicate(_ climb: KilterCreatedClimb) {
        core.log(module: "kilter", action: "duplicated", summary: "Duplicated \(climb.name)")
        editorTarget = .duplicate(seed: DuplicateSeed(
            name: climb.name + " (Copy)", setterUsername: climb.setterUsername,
            layoutId: climb.layoutId, sizeId: climb.sizeId, angle: climb.angle, frames: climb.frames,
            isNoMatch: climb.isNoMatch, predictedGrade: climb.predictedGrade, source: climb.source))
    }

    /// Open the delete confirmation with a value SNAPSHOT (name + ascent count computed once, here) so the
    /// dialog never dereferences the live `@Model` after it's been deleted + saved (F1).
    private func beginDelete(_ climb: KilterCreatedClimb) {
        let uuid = climb.uuid
        let n = (try? modelContext.fetchCount(FetchDescriptor<KilterLogEntry>(
            predicate: #Predicate { $0.climbUUID == uuid }))) ?? 0
        deleteTarget = DeleteTarget(uuid: uuid, name: climb.name, ascentCount: n)
    }

    // MARK: - Chip builder (matches KilterRootView's filter chips)

    private func chip(_ title: String, _ value: String, filled: Bool = false,
                      systemImage: String? = nil) -> some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage) }
            if !title.isEmpty { Text(title).foregroundStyle(.secondary) }
            Text(value).fontWeight(.medium)
        }
        .font(.subheadline)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(filled ? AnyShapeStyle(SnappetColor.kilter) : AnyShapeStyle(Color(.secondarySystemBackground)),
                    in: Capsule())
        .foregroundStyle(filled ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
    }
}

/// `KilterThumbnailCache` (the shared, cross-feature board-render cache) lives in its own file
/// (`KilterThumbnailCache.swift`, F5) so On the Board's timeline rows + the root recent rail reuse the
/// SAME cache instead of each re-resolving `catalog.climb/holds/boardGeometry` on the main thread per row.

/// Memoizes the per-climb engine snapshot (`KilterCreatedGallery.CreatedRow`) so the gallery doesn't
/// re-parse every climb's `frames` (`KilterCreatedView.isSavable`, an O(holds) parse) on every body
/// re-render — e.g. each search keystroke (F8). The expensive bit is the validity derivation; it's cached
/// keyed by `uuid`, invalidated whenever the climb's `frames` change (an in-place edit that keeps the same
/// uuid). The cheap fields (name/angle/grade/source) are read fresh each time, so a rename/re-grade is
/// never stale. `@Observable` so a re-parse triggers a redraw. Mirrors the thumbnail cache's discipline.
@Observable @MainActor
final class KilterCreatedRowCache {
    /// The cached validity for a uuid, plus the `frames` it was computed from (the invalidation key).
    private var validity: [String: (frames: String, isValid: Bool)] = [:]

    /// Build the engine snapshots for the current climbs, memoizing each climb's `isValid` parse.
    func rows(for climbs: [KilterCreatedClimb]) -> [KilterCreatedGallery.CreatedRow] {
        climbs.map { c in
            let isValid: Bool
            if let hit = validity[c.uuid], hit.frames == c.frames {
                isValid = hit.isValid
            } else {
                isValid = KilterCreatedView.isSavable(frames: c.frames)
                validity[c.uuid] = (c.frames, isValid)
            }
            return KilterCreatedGallery.CreatedRow(
                uuid: c.uuid, name: c.name, setterUsername: c.setterUsername,
                layoutId: c.layoutId, angle: c.angle, predictedGrade: c.predictedGrade,
                source: c.source, isValid: isValid, createdAt: c.createdAt)
        }
    }

    /// Drop cache entries for climbs that no longer exist (deleted / edited into a new identity).
    func evict(keeping uuids: Set<String>) {
        validity = validity.filter { uuids.contains($0.key) }
    }
}
