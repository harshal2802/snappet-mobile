import SwiftUI
import SwiftData
import HighlightEngine

/// Route values pushed onto the App Library's shared `SuiteRouter` path.
struct KilterClimbRoute: Hashable { let uuid: String }
struct KilterHistoryRoute: Hashable {}
struct KilterSettingsRoute: Hashable {}
/// A finished (or active) board session's rich summary — HR zones, grade pyramid, per-climb
/// timeline, media + highlight reel.
struct KilterSessionRoute: Hashable { let id: UUID }

/// Kilter Board catalog: browse climbs from the user-installed, read-only catalog, filtered by layout,
/// angle, and grade (plus a Saved filter), and open a climb for the board render + logging.
///
/// Pushed into the suite's NavigationStack by the App Library — owns no NavigationStack of its own;
/// deeper screens (detail, history) push onto the shared `SuiteRouter` path.
struct KilterRootView: View {
    @Environment(SuiteRouter.self) private var router
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var modelContext
    @Environment(SnappetCore.self) private var core
    @Query private var favorites: [KilterFavorite]
    @Query private var allEntries: [KilterLogEntry]
    /// Climbs the user authored on this device (manual editor / generator) — the "Mine" filter's source.
    @Query private var createdClimbs: [KilterCreatedClimb]

    private let catalog = KilterCatalog.shared
    /// Whether a catalog is installed — flips the view between the browse list and the opt-in
    /// `KilterCatalogSyncView`. Kept current via `KilterCatalogStore.didChangeNotification`.
    @State private var catalogInstalled = KilterCatalogStore.shared.isInstalled
    /// Shared across the module's screens (detail illuminates / sessions group history).
    @State private var board = KilterBoardController()
    /// P1 board memory: recognizes a board this phone has connected to before and restores its layout +
    /// size, pre-selecting the usual angle. `UserDefaults`-backed (no `@Model`); injectable for tests.
    @State private var boardMemory = KilterBoardMemory()
    /// P1 coarse, on-device place match for the **pre-connect** arrival suggestion. Degrades to BLE-only
    /// when location is denied/unavailable; the coarse place never leaves the phone.
    @State private var location = KilterLocationService()
    /// A recognized board awaiting the user's one-tap angle confirm (the post-connect glass ribbon). The
    /// restore (layout/size/angle pre-select) is applied immediately; the ribbon only confirms the angle.
    @State private var pendingConfirm: (id: UUID, board: RememberedBoard)?
    /// A remembered board suggested on arrival at a known coarse place, BEFORE BLE connects. A suggestion
    /// only — "Set it up" applies it; "Not now" dismisses it for this visit.
    @State private var arrivalSuggestion: (id: UUID, board: RememberedBoard)?
    /// Dismiss the arrival suggestion for the rest of this visit once acted on / declined.
    @State private var arrivalDismissed = false
    /// The session manager is owned by `AppModel` (not `@State` here) so it survives navigating out of
    /// and back into the module — this view is a `navigationDestination` SwiftUI destroys on pop, which
    /// is exactly what used to strand the active session. Recovered from the store on appear.
    private var sessions: KilterSessionManager { app.kilterSessions }

    @AppStorage("kilter.angle") private var angle: Int = 40
    @AppStorage("kilter.layout") private var layoutId: Int = 1
    /// The user's physical board size (`product_size_id`) — drives the on-screen render size *and* the
    /// LED map. Picked inline on the filter bar (when the layout has >1 size), cached, seeded to the
    /// layout default, reset when the layout changes. Shared with Settings + the detail screen.
    @AppStorage("kilter.productSizeId") private var productSizeId = 0
    @AppStorage("kilter.minGrade") private var minGrade: Int = 10
    @AppStorage("kilter.maxGrade") private var maxGrade: Int = 33
    /// P1: whether to surface the pre-connect arrival suggestion at a remembered coarse place. On by
    /// default; the off switch (Settings) skips location entirely (BLE-only recognition still works).
    @AppStorage("kilter.suggestOnArrival") private var suggestOnArrival = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var savedOnly = false
    /// Browse only climbs the user created (mutually exclusive with `savedOnly`).
    @State private var mineOnly = false
    @State private var showingCreate = false
    @State private var items: [KilterListItem] = []
    // Created-climb lifecycle from the Mine list (#76): edit re-opens authoring; delete confirms first.
    @State private var editingCreated: KilterCreatedClimb?
    @State private var deletingCreated: KilterCreatedClimb?
    /// True number of climbs matching the current filter + search (not capped by the list's limit) —
    /// shown live as "N climbs" so the user sees how their search/filters narrow the catalog.
    @State private var count = 0
    @State private var showingScanner = false
    /// A shared climb that arrived (QR scan or `snappet://` URL, #75) but isn't on this device —
    /// drives the graceful "not in your catalog" alert instead of a dead detail screen. Works over
    /// the catalog gate too (no catalog installed yet is just the empty-catalog case of "missing").
    @State private var missingSharedClimb: KilterClimbLink?

    // Search + advanced filters.
    @State private var search = ""
    @State private var sort: KilterSort = .popular
    @State private var benchmarksOnly = false
    @State private var minAscents = 0
    @State private var minQuality = 0.0
    @State private var showingFilters = false

    // Discovery + display preference.
    @State private var cotd: KilterListItem?
    @AppStorage("kilter.gradeFormat") private var gradeFormatRaw = KilterGradeFormat.both.rawValue
    private var gradeFormat: KilterGradeFormat { KilterGradeFormat(rawValue: gradeFormatRaw) ?? .both }
    /// Board-protocol dialect (Standard/Legacy), persisted; pushed into the shared controller so any
    /// screen that changes it (Settings, or the detail view's "wrong holds?" fix) takes effect at once.
    @AppStorage("kilter.apiLevel") private var apiLevelRaw = KilterProtocol.APILevel.v3.rawValue
    private var apiLevel: KilterProtocol.APILevel { .init(rawValue: apiLevelRaw) ?? .v3 }
    /// Discovery (climb-of-the-day) shows only on the plain browse view, not while searching/saved.
    private var showDiscovery: Bool {
        search.trimmingCharacters(in: .whitespaces).isEmpty && !savedOnly && !mineOnly
    }

    /// The current browse criteria assembled into one value (drives the catalog query + `.task` id).
    private var filter: KilterFilter {
        KilterFilter(layoutId: layoutId, angle: angle,
                     minDifficulty: Double(minGrade), maxDifficulty: Double(maxGrade),
                     search: search, sort: sort, benchmarksOnly: benchmarksOnly,
                     minAscents: minAscents, minQuality: minQuality)
    }

    /// The climbs currently on screen, in display order — handed to the detail view so the user can
    /// swipe left/right between them. Climb-of-the-day leads when shown; deduped (it often recurs in
    /// the list).
    private var browseUUIDs: [String] {
        var ids: [String] = []
        if showDiscovery, let cotd { ids.append(cotd.uuid) }
        ids.append(contentsOf: items.map(\.uuid))
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    private var layouts: [KilterLayout] { catalog.layouts() }
    /// Board sizes for the current layout (for the inline Size chip — shown only when there's a choice).
    private var sizes: [KilterBoardSize] { catalog.sizes(forLayout: layoutId) }
    private var availableAngles: [Int] { catalog.angles() }
    private var gradeScale: [(difficulty: Int, label: String)] { catalog.gradeScale() }
    private var favoriteUUIDs: Set<String> { Set(favorites.map(\.climbUUID)) }
    /// Bool binding for the Mine-list delete dialog, derived from the `presenting` optional (#76).
    private var deletingDialogBinding: Binding<Bool> {
        Binding(get: { deletingCreated != nil }, set: { if !$0 { deletingCreated = nil } })
    }

    var body: some View {
        Group {
            if catalogInstalled && catalog.isAvailable {
                content
            } else {
                // No catalog on this device yet — Snappet ships none (issue #42). Offer the opt-in
                // import flow instead of an empty list.
                KilterCatalogSyncView(onInstalled: reloadCatalog)
            }
        }
        .navigationTitle("Kilter Board")
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic),
                    prompt: "Search climbs or setters")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingFilters = true } label: {
                    Label("Filters", systemImage: filter.activeExtras > 0
                          ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .accessibilityIdentifier("kilter.filtersButton")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { router.push(KilterHistoryRoute()) } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                .accessibilityIdentifier("kilter.history")
            }
            // Create climb is a headline differentiator — a visible `+`, not a menu item (#75,
            // the iOS mirror of Android #94's extended FAB).
            ToolbarItem(placement: .primaryAction) {
                Button { showingCreate = true } label: {
                    Label("Create climb", systemImage: "plus")
                }
                .accessibilityIdentifier("kilter.create")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { router.push(KilterCreatedRoute()) } label: {
                        Label("Your Climbs", systemImage: "hammer")
                    }
                    .accessibilityIdentifier("kilter.yourClimbs")
                    Button { router.push(KilterPlanRoute()) } label: {
                        Label("Plan a session", systemImage: "wand.and.stars")
                    }
                    .accessibilityIdentifier("kilter.plan")
                    Button { surpriseMe() } label: { Label("Surprise me", systemImage: "dice") }
                        .accessibilityIdentifier("kilter.surprise")
                    Button { showingScanner = true } label: {
                        Label("Scan QR code", systemImage: "qrcode.viewfinder")
                    }
                    .accessibilityIdentifier("kilter.scan")
                    Divider()
                    Button { router.push(KilterSettingsRoute()) } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .accessibilityIdentifier("kilter.more")
            }
        }
        .sheet(isPresented: $showingFilters) {
            KilterFiltersSheet(sort: $sort, benchmarksOnly: $benchmarksOnly,
                               minAscents: $minAscents, minQuality: $minQuality)
        }
        .sheet(isPresented: $showingCreate) {
            CreateClimbView(onCreated: { uuid in
                // Open the freshly-created climb in the normal detail screen.
                router.push(KilterClimbRoute(uuid: uuid))
            }, board: board)
        }
        // Re-open an authored climb in the editor from a Mine swipe (#76).
        .sheet(item: $editingCreated) { climb in
            CreateClimbView(onCreated: { _ in }, board: board, editing: climb)
        }
        // Confirm before removing an authored climb; its logged ascents stay in History.
        .confirmationDialog("Delete this climb?", isPresented: deletingDialogBinding,
                            titleVisibility: .visible, presenting: deletingCreated) { climb in
            Button("Delete climb", role: .destructive) {
                core.log(module: "kilter", action: "deleted", summary: "Deleted \(climb.name)")
                KilterCreatedClimb.delete(climb, in: modelContext)
            }
            .accessibilityIdentifier("kilter.created.swipeDeleteConfirm")
            Button("Cancel", role: .cancel) {}
        } message: { climb in
            // `#Predicate` can't capture `climb.uuid` (a model property access) — hoist to a local.
            let uuid = climb.uuid
            let n = (try? modelContext.fetchCount(FetchDescriptor<KilterLogEntry>(
                predicate: #Predicate { $0.climbUUID == uuid }))) ?? 0
            Text(n == 0 ? "“\(climb.name)” is removed from Mine. It can't be undone."
                 : "“\(climb.name)” is removed from Mine. Its \(n) logged ascent\(n == 1 ? "" : "s") stay in History.")
        }
        .sheet(isPresented: $showingScanner) {
            // Same routing decision as the URL-scheme path (`open(link:)`) — the scanner used to
            // push blindly, dead-ending on a climb the local catalog doesn't have (#75).
            KilterScannerView { link in open(link: link) }
        }
        // Graceful landing for a shared climb this device can't resolve (#75): explain instead of
        // a dead detail screen. Reads right over the catalog gate too (install first, then rescan).
        .alert("Climb not in your catalog",
               isPresented: Binding(get: { missingSharedClimb != nil },
                                    set: { if !$0 { missingSharedClimb = nil } }),
               presenting: missingSharedClimb) { _ in
            Button("OK", role: .cancel) {}
        } message: { link in
            Text("This shared climb isn't in the catalog on this device. Get a catalog that "
                 + "includes it — the sharer's board, or a bigger download — then open the link "
                 + "or scan the code again. (Climb id \(link.uuid).)")
        }
        .navigationDestination(for: KilterClimbRoute.self) { route in
            KilterClimbDetailView(uuid: route.uuid, siblings: browseUUIDs, board: board, sessions: sessions)
        }
        .navigationDestination(for: KilterHistoryRoute.self) { _ in
            KilterHistoryView()
        }
        .navigationDestination(for: KilterSettingsRoute.self) { _ in
            KilterSettingsView(catalog: catalog)
        }
        .navigationDestination(for: KilterSessionRoute.self) { route in
            KilterSessionDetailView(sessionID: route.id, board: board, sessions: sessions)
        }
        // P2: the first-class "Your Climbs" gallery (the promoted, global-across-layouts Mine).
        .navigationDestination(for: KilterCreatedRoute.self) { _ in
            KilterCreatedView()
        }
        .navigationDestination(for: KilterPlanRoute.self) { _ in
            KilterPlanView(sessions: sessions)
        }
        .task(id: filterKey) { refresh() }
        // Re-open the reader + refresh when the installed catalog changes (import here, or "Remove"
        // in Settings), wherever the change originated.
        .onReceive(NotificationCenter.default.publisher(for: KilterCatalogStore.didChangeNotification)) { _ in
            reloadCatalog()
        }
        // The session manager arrives already bound to the live-metrics / Live-Activity / media
        // services (once, in `AppModel.init`) — binding here would reintroduce the appear-order
        // dependency a plan deep link skips (#71 pre-merge review).
        .onAppear {
            // Hide the cross-screen Kilter live chip while the user is anywhere in Kilter (the root
            // stays in the stack under pushed Kilter screens, so this covers the whole module).
            app.kilterScreenVisible = true
            // Keep the board-size selection valid for the current layout (seed the default when unset).
            syncBoardSize()
            // Re-sync with the persisted store: re-adopt a session left open by a prior visit / relaunch
            // (and auto-close any duplicate or long-abandoned ones) so the bar, HR, Live Activity, and
            // log-grouping never go stale after navigating away and back.
            sessions.recover(in: modelContext)
            // Own the board→session bridge here (stable for the module's lifetime) rather than in the
            // transient climb-detail view: a board connect opens/adopts the single session; a
            // disconnect does NOT end it — a brief BLE drop shouldn't kill an in-progress session (the
            // user ends it explicitly via the bar / summary / History).
            board.onConnectionChange = { connected in
                if connected { sessions.start(angle: angle, source: "ble", in: modelContext) }
            }
            // P1: on a confirmed connect, recognize the board and (if known) restore its layout/size +
            // pre-select the usual angle, then surface the one-tap confirm ribbon. An unknown board is
            // remembered from scratch on this first connect (no restore, nothing overwritten).
            board.onBoardRecognized = { identifier, serial in
                recognizeBoard(identifier: identifier, serial: serial)
            }
            board.setAPILevel(apiLevel)
            // Pre-connect arrival suggestion: ask for a coarse fix (only if the user opted in and we have
            // boards with a stored place) so the suggestion can appear before BLE. `requestIfNeeded`
            // already requests a fix when authorized (and the auth-change delegate fetches one when the
            // user first grants), so a follow-up `refresh()` here would no-op on `.notDetermined`. Denied
            // → BLE-only.
            if suggestOnArrival && !boardMemory.isEmpty {
                location.requestIfNeeded()
            }
        }
        // When a fresh coarse fix arrives at a remembered place, raise the arrival suggestion (once per
        // visit, never over a deliberate manual change the user just made).
        .onChange(of: location.currentPlace) { _, place in updateArrivalSuggestion(place) }
        // Leaving Kilter entirely (the root pops off the stack) re-reveals the cross-screen live chip.
        .onDisappear { app.kilterScreenVisible = false }
        // A protocol change from Settings (or the detail "wrong holds?" fix) re-lights the board live.
        .onChange(of: apiLevelRaw) { board.setAPILevel(apiLevel) }
        // Switching layout can invalidate the chosen size (each layout offers different ones) — reseed.
        .onChange(of: layoutId) { syncBoardSize() }
        // Keep the Live Activity's HR / climb count current while any Kilter screen is up (the root
        // view stays in the nav stack), throttled inside the controller.
        .onChange(of: app.liveWorkout.latestHR) { pushLiveActivity() }
        .onChange(of: sessions.activeClimbName) { pushLiveActivity() }
        .onChange(of: currentClimbCount) { pushLiveActivity() }
        // Consume the one-shot `snappet://` climb intent (#75): `initial: true` covers the
        // cold-start case (the intent was set before this view existed), the change closure the
        // warm case (the shell replaced the path with this root, then set a new intent). Clearing
        // before routing makes it one-shot even if routing pushes/alerts re-render us.
        .onChange(of: router.pendingKilterClimb, initial: true) { _, pending in
            guard let pending else { return }
            router.pendingKilterClimb = nil
            // Same store re-sync the normal appear path runs — a deep link must not strand a
            // recoverable open session any more than a manual entry would (#54/#71 semantics).
            sessions.recover(in: modelContext)
            open(link: pending)
        }
    }

    /// Route an arriving shared climb (QR scan or URL open) through the pure routing decision:
    /// installed → adopt the shared angle when this board offers it and push the climb; missing →
    /// the graceful alert. One path for both entries so they can't drift (#75).
    private func open(link: KilterClimbLink) {
        let installed = catalog.climb(link.uuid) != nil
            || createdClimbs.contains { $0.uuid == link.uuid }
        switch KilterDeepLinkRouting.destination(for: link, climbInstalled: installed,
                                                 availableAngles: availableAngles) {
        case .openClimb(let uuid, let adoptAngle):
            if let adoptAngle { angle = adoptAngle }
            router.push(KilterClimbRoute(uuid: uuid))
        case .explainMissing:
            missingSharedClimb = link
        }
    }

    /// Climbs logged so far in the active session (the count shown in the banner + Live Activity).
    private var currentClimbCount: Int {
        guard let id = sessions.currentId else { return 0 }
        return allEntries.filter { $0.sessionId == id }.count
    }

    private func pushLiveActivity() {
        guard sessions.isActive else { return }
        sessions.pushLiveActivity(hrBpm: app.liveWorkout.latestHR.map { Int($0.rounded()) },
                                  climbCount: currentClimbCount)
    }

    /// Push a random climb from the current filters (Discovery "Surprise me").
    private func surpriseMe() {
        if let pick = catalog.randomClimb(filter) { router.push(KilterClimbRoute(uuid: pick.uuid)) }
    }

    /// Snap `productSizeId` to a size that exists for the current layout — seeds it to the layout default
    /// when unset, and resets it when the layout no longer offers the old size. Same guard Settings uses,
    /// so the inline Size chip and Settings can't disagree.
    private func syncBoardSize() {
        if !catalog.sizes(forLayout: layoutId).contains(where: { $0.id == productSizeId }) {
            productSizeId = catalog.defaultSizeId(forLayout: layoutId)
        }
    }

    // MARK: - P1 board recognition (auto-detect)

    /// A board just confirmed its connection. If we've seen it before, restore its layout + size and
    /// pre-select its usual angle, then raise the one-tap confirm ribbon. Either way, remember it (with
    /// the confirmed angle + current coarse place) so the next visit recognizes it.
    private func recognizeBoard(identifier: UUID, serial: String?) {
        let known = boardMemory.recall(identifier: identifier, serial: serial)
        if let known {
            applyRestore(known)
            withAnimation(.snappy) { pendingConfirm = (id: identifier, board: known) }
            // A successful BLE connect makes the on-arrival card redundant — clear it AND mark this
            // visit's arrival resolved, so a later coarse-fix update can't re-pop the card for a board
            // we're already connected to.
            arrivalSuggestion = nil
            arrivalDismissed = true
        }
        // Remember (or update) the board's IDENTITY on every confirmed connect — first-time boards are
        // learned here, returning boards refresh their place / last-seen. The angle is NOT recorded here;
        // it's appended only when the user confirms it in the ribbon (so an ignored connect adds nothing).
        boardMemory.remember(identifier: identifier,
                             layoutId: layoutId, productSizeId: productSizeId,
                             label: known?.label, defaultLabel: defaultBoardLabel(serial: serial),
                             serial: serial,
                             coarsePlace: suggestOnArrival ? location.currentPlace : nil)
    }

    /// A clearer default label for a never-renamed board, derived from the catalog's layout + size name
    /// at the call site (the view has the catalog) so two boards at two gyms aren't both the generic
    /// "Kilter board" — e.g. "Original 8×12" or "Board A1B2C3" when a serial is known.
    private func defaultBoardLabel(serial: String?) -> String {
        if let serial, !serial.isEmpty { return "Board \(serial)" }
        let layoutName = layouts.first { $0.id == layoutId }?.name
        let sizeName = catalog.sizes(forLayout: layoutId).first { $0.id == productSizeId }?.name
        let parts = [layoutName, sizeName].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? "Kilter board" : parts.joined(separator: " ")
    }

    /// Restore a remembered board's selection through the same `effectiveSizeId` guard the render + LED
    /// map use, and pre-select its usual angle. Suggestion-not-overwrite: the angle pre-select is still
    /// confirmed in the ribbon; layout/size are restored (the ribbon shows what was restored). When the
    /// usual angle isn't in this catalog's angles, pre-select the **nearest** available one — the same
    /// value `restoreSummary` prints, so the picker and the summary never diverge.
    private func applyRestore(_ board: RememberedBoard) {
        layoutId = board.layoutId
        productSizeId = catalog.effectiveSizeId(forLayout: board.layoutId, requested: board.productSizeId)
        if let usual = board.usualAngle, let pre = Self.nearestAngle(to: usual, in: availableAngles) {
            angle = pre
        }
    }

    /// The available angle closest to `target` (ties → the lower angle, via `min`'s stable first-best),
    /// or `nil` when the catalog has no angles. Keeps the ribbon's pre-selected picker and its printed
    /// summary on the SAME value even when the remembered angle isn't offered here.
    static func nearestAngle(to target: Int, in available: [Int]) -> Int? {
        available.min { abs($0 - target) < abs($1 - target) }
    }

    /// Confirm (or adjust then confirm) the angle from the ribbon — this is the ONLY place an angle is
    /// appended to the board's history (so the most-frequent angle tracks the climber's real, explicit
    /// habit and a pre-select can't self-reinforce), then dismisses the ribbon.
    private func confirmPendingBoard() {
        if let pending = pendingConfirm {
            boardMemory.confirmAngle(identifier: pending.id, angle: angle)
        }
        withAnimation(.snappy) { pendingConfirm = nil }
    }

    /// Raise the arrival suggestion when a coarse fix lands on a remembered place — pre-connect, opt-in,
    /// once per visit, and never while a confirm ribbon (a real connect) is already up.
    private func updateArrivalSuggestion(_ place: CoarsePlace?) {
        guard suggestOnArrival, !arrivalDismissed, pendingConfirm == nil,
              let place, let match = KilterPlaceMatcher.suggestion(for: place, in: boardMemory.rememberedSorted)
        else { return }
        withAnimation(.snappy) { arrivalSuggestion = (id: match.id, board: match.board) }
    }

    /// "Set it up" on the arrival card: restore the suggested board's layout/size + usual angle (the same
    /// restore a connect does) WITHOUT a BLE connection, then dismiss the card.
    private func acceptArrivalSuggestion() {
        if let s = arrivalSuggestion { applyRestore(s.board) }
        dismissArrivalSuggestion()
    }

    private func dismissArrivalSuggestion() {
        arrivalDismissed = true
        withAnimation(.snappy) { arrivalSuggestion = nil }
    }

    /// Re-open the reader after the installed catalog changes, then refresh the list.
    private func reloadCatalog() {
        catalog.reload()
        catalogInstalled = KilterCatalogStore.shared.isInstalled
        refresh()
    }

    private var content: some View {
        VStack(spacing: 0) {
            filterBar
            // P1 board-detect surfaces (suggestion-not-overwrite, never blocking):
            //  • the pre-connect arrival suggestion at a remembered coarse place, and
            //  • the post-connect confirm ribbon when a known board restored its layout/size.
            if let suggestion = arrivalSuggestion { arrivalSuggestionCard(suggestion) }
            if let pending = pendingConfirm { boardConfirmRibbon(pending) }
            // The slot between the filters and the list belongs to the session: the green live
            // bar when one is active, a first-class **Start session** control when idle (#75 —
            // start/end no longer hide in the More menu; the bars own the lifecycle).
            if sessions.isActive { sessionBar } else { idleSessionBar }
            countBar
            List {
                if showDiscovery, let cotd {
                    Section("Climb of the day") {
                        Button { router.push(KilterClimbRoute(uuid: cotd.uuid)) } label: {
                            KilterClimbRow(item: cotd, isFavorite: favoriteUUIDs.contains(cotd.uuid),
                                           gradeFormat: gradeFormat, featured: true)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("kilter.cotd")
                    }
                }
                Section {
                    ForEach(items) { item in
                        Button { router.push(KilterClimbRoute(uuid: item.uuid)) } label: {
                            KilterClimbRow(item: item, isFavorite: favoriteUUIDs.contains(item.uuid),
                                           gradeFormat: gradeFormat)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("kilter.climbRow")
                        // Edit / delete a climb the user authored, right from the Mine list (#76).
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if let created = createdClimbs.first(where: { $0.uuid == item.uuid }) {
                                Button(role: .destructive) { deletingCreated = created } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .accessibilityIdentifier("kilter.created.swipeDelete")
                                Button { editingCreated = created } label: { Label("Edit", systemImage: "pencil") }
                                    .tint(.blue)
                                    .accessibilityIdentifier("kilter.created.swipeEdit")
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if items.isEmpty && !(showDiscovery && cotd != nil) {
                    let searching = !search.trimmingCharacters(in: .whitespaces).isEmpty
                    if mineOnly && !searching {
                        ContentUnavailableView(
                            "No climbs yet", systemImage: "hammer",
                            description: Text("Tap + to design your first climb for this layout."))
                    } else {
                        ContentUnavailableView(
                            searching ? "No matches" : (savedOnly ? "No saved climbs" : "No climbs match"),
                            systemImage: searching ? "magnifyingglass" : (savedOnly ? "star" : "line.3.horizontal.decrease.circle"),
                            description: Text(searching ? "No climbs match “\(search)” with the current filters."
                                              : (savedOnly ? "Star climbs to find them here."
                                                           : "Try a wider grade range, another angle, or fewer filters.")))
                    }
                }
            }
        }
    }

    /// The idle counterpart of `sessionBar` (#75): one visible **Start session** button + the
    /// one-line pitch for what a session buys (the rich layer a menu-buried Start silently cost).
    /// Same start path as everything else — `start` folds recovery, so a stale open session is
    /// adopted/closed per the #54 policy, never forked.
    private var idleSessionBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "figure.climbing")
                .font(.subheadline)
                .foregroundStyle(SnappetColor.moduleAccent("kilter"))
            Text("Live HR, per-climb timing & a highlight reel")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Button {
                // Discard the created-fresh flag: the explicit Start button needs no undo capsule
                // (that's the auto-log path only), and the non-Void return would otherwise conflict
                // with this Void action closure.
                withAnimation(.snappy) { _ = sessions.start(angle: angle, source: "manual", in: modelContext) }
            } label: {
                Label("Start session", systemImage: "play.fill")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityIdentifier("kilter.session.start")
        }
        .padding(.horizontal).padding(.vertical, 6)
    }

    // MARK: - P1 board-detect surfaces

    /// Pre-connect arrival suggestion (wireframe `01c_arrival`): "Looks like you're at <gym>. Set up your
    /// usual board?" — a single coral CTA + a quiet "Not now", and the on-device privacy reassurance. A
    /// suggestion only; "Set it up" restores the board, it never auto-applies.
    @ViewBuilder private func arrivalSuggestionCard(_ suggestion: (id: UUID, board: RememberedBoard)) -> some View {
        let b = suggestion.board
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "mappin.circle.fill")
                    .foregroundStyle(SnappetColor.moduleAccent("kilter"))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Looks like you're at")
                        .font(.caption).foregroundStyle(SnappetColor.textSecondary)
                    Text(b.label).font(.headline).lineLimit(1)
                }
                Spacer()
            }
            Text("Set up your usual board? \(restoreSummary(b))")
                .font(.subheadline).foregroundStyle(SnappetColor.textSecondary).lineLimit(2)
            HStack(spacing: 16) {
                Button { acceptArrivalSuggestion() } label: {
                    Text("Set it up").font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent).tint(SnappetColor.brand).controlSize(.small)
                .accessibilityIdentifier("kilter.arrival.setup")
                Button { dismissArrivalSuggestion() } label: {
                    Text("NOT NOW").font(.caption.weight(.bold)).tracking(0.5)
                        .foregroundStyle(SnappetColor.textSecondary)
                }
                .accessibilityIdentifier("kilter.arrival.dismiss")
                Spacer()
            }
            Label("Matched on-device — your location never leaves your phone", systemImage: "mappin.and.ellipse")
                .font(.caption2).foregroundStyle(SnappetColor.textSecondary).lineLimit(2)
        }
        .padding(12)
        .pulseGlassChrome(reduceTransparency: reduceTransparency)
        .padding(.horizontal).padding(.top, 6)
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityIdentifier("kilter.arrivalSuggestion")
    }

    /// Post-connect confirm ribbon (wireframe `01_autodetect`): a known board has restored its
    /// layout + size; the climber confirms the (pre-selected) angle with one tap, or adjusts it inline
    /// first. Never blocking — browse stays fully usable underneath.
    @ViewBuilder private func boardConfirmRibbon(_ pending: (id: UUID, board: RememberedBoard)) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "checklist").foregroundStyle(SnappetColor.moduleAccent("kilter"))
                VStack(alignment: .leading, spacing: 2) {
                    Text(pending.board.label.uppercased())
                        .font(.caption.weight(.bold)).tracking(0.5)
                        .foregroundStyle(SnappetColor.textSecondary).lineLimit(1)
                    Text("Restored \(restoreSummary(pending.board))")
                        .font(.subheadline.weight(.medium)).lineLimit(1)
                }
                Spacer()
            }
            // Inline angle adjust (Picker over the board's angles), pre-selected to the usual angle.
            Picker("Angle", selection: $angle) {
                ForEach(availableAngles, id: \.self) { Text("\($0)°").tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("kilter.confirm.anglePicker")
            HStack(spacing: 16) {
                Button { confirmPendingBoard() } label: {
                    Text("Got it").font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent).tint(SnappetColor.brand).controlSize(.small)
                .accessibilityIdentifier("kilter.confirm.gotIt")
                Spacer()
            }
        }
        .padding(12)
        .pulseGlassChrome(reduceTransparency: reduceTransparency)
        .padding(.horizontal).padding(.top, 6)
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityIdentifier("kilter.confirmRibbon")
    }

    /// A short "<board size> · <angle>°" line for the ribbon / card (e.g. "8×12 Home · 40°"), built from
    /// the catalog's size label for the remembered layout/size and the **same** angle `applyRestore`
    /// pre-selected (the nearest available angle to the usual one), so summary and picker never diverge.
    private func restoreSummary(_ board: RememberedBoard) -> String {
        let sizeId = catalog.effectiveSizeId(forLayout: board.layoutId, requested: board.productSizeId)
        let sizeName = catalog.sizes(forLayout: board.layoutId).first { $0.id == sizeId }?.name
        let a = board.usualAngle.flatMap { Self.nearestAngle(to: $0, in: availableAngles) } ?? angle
        return [sizeName, "\(a)°"].compactMap { $0 }.joined(separator: " · ")
    }

    /// Active-session banner: a live timer, climb count, live HR (when a source is connected), and
    /// the current climb, with End. Tapping it opens the live summary. Logs made while it's up are
    /// grouped under the session in History.
    @ViewBuilder private var sessionBar: some View {
        if let s = sessions.current {
            let count = allEntries.filter { $0.sessionId == s.id }.count
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "record.circle").foregroundStyle(.green)
                        .symbolEffect(.pulse, options: .repeating)
                        .font(.subheadline)
                    Text("Session").font(.subheadline.weight(.semibold))
                    Text(s.startedAt, style: .timer).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    Text("· \(count) climb\(count == 1 ? "" : "s")").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    if app.liveWorkout.state != .unavailable {
                        KilterHRPill(bpm: app.liveWorkout.latestHR, compact: true,
                                     contactLost: app.liveWorkout.isContactLost == true,
                                     readiness: RecoveryReadiness.evaluate(
                                        currentBpm: app.liveWorkout.latestHR,
                                        restBpm: app.userProfile.profile.restingBound,
                                        maxBpm: app.userProfile.profile.resolvedMaxHR))
                    }
                    Button("End") { withAnimation(.snappy) { sessions.end(in: modelContext) } }
                        .font(.subheadline.weight(.semibold))
                        .accessibilityIdentifier("kilter.session.end")
                }
                Button {
                    // Converge with the live chip + Home card: a plan-backed run opens the plan-home
                    // (re-enterable list with progress); an ad-hoc session opens its live summary.
                    if sessions.currentPlanId != nil { router.push(KilterPlanRoute()) }
                    else { router.push(KilterSessionRoute(id: s.id)) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "figure.climbing").font(.caption)
                        Text(sessions.activeClimbName).font(.caption.weight(.medium)).lineLimit(1)
                        if !sessions.activeClimbGrade.isEmpty {
                            Text(sessions.activeClimbGrade).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("kilter.session.open")
            }
            .padding(.horizontal).padding(.vertical, 8)
            .background(Color.green.opacity(0.12))
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var filterBar: some View {
        // The Layout/Angle/Grade menus scroll horizontally; the Saved toggle is pinned at the trailing
        // edge so it's always reachable (it used to overflow off-screen on narrower devices).
        HStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    Menu {
                        Picker("Layout", selection: $layoutId) {
                            ForEach(layouts) { Text($0.name).tag($0.id) }
                        }
                    } label: { chip("Layout", layouts.first { $0.id == layoutId }?.name ?? "—") }
                    .accessibilityIdentifier("kilter.layout")

                    // Board size, right beside Layout — only when the layout offers a choice. Drives the
                    // size the board renders at (and the LED map); persisted in `kilter.productSizeId`.
                    if sizes.count > 1 {
                        Menu {
                            Picker("Board size", selection: $productSizeId) {
                                ForEach(sizes) { Text($0.label).tag($0.id) }
                            }
                        } label: { chip("Size", sizes.first { $0.id == productSizeId }?.name ?? "—") }
                        .accessibilityIdentifier("kilter.size")
                    }

                    Menu {
                        Picker("Angle", selection: $angle) {
                            ForEach(availableAngles, id: \.self) { Text("\($0)°").tag($0) }
                        }
                    } label: { chip("Angle", "\(angle)°") }
                    .accessibilityIdentifier("kilter.angle")

                    // Lower/upper grade are two independent chips. Selecting a min above the current
                    // max (or a max below the min) drags the other end along so the range stays valid.
                    Menu {
                        Picker("Min grade", selection: $minGrade) {
                            ForEach(gradeScale, id: \.difficulty) { Text($0.label).tag($0.difficulty) }
                        }
                    } label: { chip("Min", catalog.gradeLabel(Double(minGrade))) }
                    .accessibilityIdentifier("kilter.minGrade")
                    .onChange(of: minGrade) { _, newMin in if newMin > maxGrade { maxGrade = newMin } }

                    Menu {
                        Picker("Max grade", selection: $maxGrade) {
                            ForEach(gradeScale, id: \.difficulty) { Text($0.label).tag($0.difficulty) }
                        }
                    } label: { chip("Max", catalog.gradeLabel(Double(maxGrade))) }
                    .accessibilityIdentifier("kilter.maxGrade")
                    .onChange(of: maxGrade) { _, newMax in if newMax < minGrade { minGrade = newMax } }
                }
                .padding(.leading)
                .padding(.vertical, 8)
            }

            Button { withAnimation(.snappy) { mineOnly.toggle(); if mineOnly { savedOnly = false } } } label: {
                chip("", "Mine", filled: mineOnly, systemImage: mineOnly ? "hammer.fill" : "hammer")
            }
            .accessibilityIdentifier("kilter.mineToggle")

            Button { withAnimation(.snappy) { savedOnly.toggle(); if savedOnly { mineOnly = false } } } label: {
                chip("", "Saved", filled: savedOnly, systemImage: savedOnly ? "star.fill" : "star")
            }
            .accessibilityIdentifier("kilter.savedToggle")
            .padding(.trailing)
        }
    }

    /// Live count of climbs matching the current search + filters, with a quick **Clear** when any
    /// search / Saved / extra filter is active — immediate feedback that makes searching feel responsive.
    @ViewBuilder private var countBar: some View {
        HStack(spacing: 8) {
            Text(count == 0 ? "No climbs" : "\(count) climb\(count == 1 ? "" : "s")")
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .animation(.snappy, value: count)
                .accessibilityIdentifier("kilter.count")
            Spacer()
            if hasActiveFilters {
                Button("Clear") { withAnimation(.snappy) { clearFilters() } }
                    .font(.caption.weight(.semibold))
                    .accessibilityIdentifier("kilter.clearFilters")
            }
        }
        .padding(.horizontal).padding(.bottom, 4)
    }

    /// Whether the user has narrowed beyond the board/grade context (search text, the Saved filter, or a
    /// Filters-sheet extra) — gates the Clear button.
    private var hasActiveFilters: Bool {
        !search.trimmingCharacters(in: .whitespaces).isEmpty || savedOnly || mineOnly || filter.activeExtras > 0
    }

    /// Clear the search + Saved/Mine + Filters-sheet extras (keeps the board/angle/grade the user set).
    private func clearFilters() {
        search = ""; savedOnly = false; mineOnly = false
        sort = .popular; benchmarksOnly = false; minAscents = 0; minQuality = 0
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

    /// Identity for `.task(id:)` — recompute the list whenever any criterion (or the favorites set) changes.
    private var filterKey: String {
        "\(layoutId)|\(angle)|\(minGrade)|\(maxGrade)|\(savedOnly)|\(mineOnly)|\(favoriteUUIDs.count)"
        + "|\(createdClimbs.count)|\(search)|\(sort.rawValue)|\(benchmarksOnly)|\(minAscents)|\(minQuality)"
    }

    private func refresh() {
        guard catalog.isAvailable else { items = []; cotd = nil; count = 0; return }
        cotd = showDiscovery ? catalog.climbOfTheDay(layoutId: layoutId, angle: angle) : nil
        if mineOnly {
            items = createdListItems()
        } else if savedOnly {
            // Saved list isn't grade/angle-restricted, but still honor the search box (name/setter).
            let saved = favorites.sorted { $0.addedAt > $1.addedAt }.map(\.climbUUID)
            let all = catalog.climbsByUUID(saved)
            let term = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            items = term.isEmpty ? all
                : all.filter { $0.name.lowercased().contains(term) || $0.setter.lowercased().contains(term) }
        } else {
            items = catalog.list(filter)
        }
        // True match count (Saved/Mine are already the full set; the catalog list is capped, so query it).
        count = (savedOnly || mineOnly) ? items.count : catalog.count(filter)
    }

    /// The user's created climbs for the current layout, newest first, honoring the search box — mapped to
    /// `KilterListItem` so they render in the same rows as catalog climbs (grade = the predicted/chosen
    /// grade; quality/ascents are 0, since a brand-new climb has none).
    private func createdListItems() -> [KilterListItem] {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let mine = createdClimbs
            .filter { $0.layoutId == layoutId }
            .sorted { $0.createdAt > $1.createdAt }
        let filtered = term.isEmpty ? mine
            : mine.filter { $0.name.lowercased().contains(term) || $0.setterUsername.lowercased().contains(term) }
        return filtered.map { c in
            KilterListItem(uuid: c.uuid, name: c.name, setter: c.setterUsername,
                           difficulty: c.predictedGrade ?? 0,
                           gradeLabel: c.predictedGrade.map { catalog.gradeLabel($0) } ?? "—",
                           quality: 0, ascents: 0)
        }
    }
}

/// One catalog row: name + setter, grade badge, quality stars, ascent count.
private struct KilterClimbRow: View {
    let item: KilterListItem
    let isFavorite: Bool

    var gradeFormat: KilterGradeFormat = .both
    /// Featured (climb-of-the-day) rows get a small ribbon accent.
    var featured: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            if featured {
                Image(systemName: "sparkles").foregroundStyle(SnappetColor.moduleAccent("kilter"))
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name).font(.headline).lineLimit(1)
                    if isFavorite { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow) }
                }
                Text("by \(item.setter)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(kilterDisplayGrade(item.gradeLabel, gradeFormat))
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

/// Bottom sheet of advanced browse criteria: sort order, a classics/benchmarks toggle, and minimum
/// ascents/quality. The quick layout/angle/grade/saved chips stay inline; this holds the rest so the
/// filter row doesn't get crowded.
struct KilterFiltersSheet: View {
    @Binding var sort: KilterSort
    @Binding var benchmarksOnly: Bool
    @Binding var minAscents: Int
    @Binding var minQuality: Double
    @Environment(\.dismiss) private var dismiss

    private let ascentChoices = [0, 10, 50, 100, 500, 1000]

    var body: some View {
        NavigationStack {
            Form {
                Section("Sort by") {
                    Picker("Sort", selection: $sort) {
                        ForEach(KilterSort.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline).labelsHidden()
                    .accessibilityIdentifier("kilter.filter.sort")
                }
                Section("Refine") {
                    Toggle(isOn: $benchmarksOnly) {
                        Label("Classics only", systemImage: "rosette")
                    }
                    .accessibilityIdentifier("kilter.filter.benchmarks")
                    Picker("Min ascents", selection: $minAscents) {
                        ForEach(ascentChoices, id: \.self) { Text($0 == 0 ? "Any" : "\($0)+").tag($0) }
                    }
                    Picker("Min quality", selection: $minQuality) {
                        Text("Any").tag(0.0)
                        Text("★ 1+").tag(1.0)
                        Text("★ 2+").tag(2.0)
                        Text("★ 3").tag(3.0)
                    }
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") {
                        sort = .popular; benchmarksOnly = false; minAscents = 0; minQuality = 0
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("kilter.filter.done")
                }
            }
            .presentationDetents([.medium, .large])
        }
    }
}
