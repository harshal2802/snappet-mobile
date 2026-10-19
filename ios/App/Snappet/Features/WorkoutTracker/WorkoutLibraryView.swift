import SwiftUI
import SwiftData

/// **The workout Library** — **Yours | Explore** (Library redesign L1, prompt 183; was the catalog-only E3 library).
///
/// - **Yours**: every activity you've logged — lifts, climbs (per gym-reset set), runs, holds — from session history
///   via the pure `LibraryCatalog`, with usage and a headline number, sortable per discipline (Most used by
///   default; remembered per discipline). Tapping one opens its progress dashboard (`ActivityRoute`).
/// - **Explore**: the catalog (bundled + custom strength, timed protocols, climb/run templates) with the
///   discipline-swapping facets, unchanged from E3.
///
/// With no history yet the Library opens on Explore (a new user has nothing of their own); an explicit choice
/// is remembered. Lives inside the App Library's `NavigationStack` — no stack of its own.
struct WorkoutLibraryView: View {
    let resolver: ExerciseResolver
    let history: [WorkoutSession]
    let unit: WeightUnit
    let open: (LibraryItem) -> Void
    /// One of your activities → its dashboard.
    let openActivity: (ActivityRoute) -> Void

    enum Mode: String { case yours, explore }

    /// Saved timed exercises, newest-used first — folded into the timed discipline of Explore.
    @Query(sort: \TimedExerciseCatalog.lastUsedAt, order: .reverse) private var timed: [TimedExerciseCatalog]
    /// Your pins / hides (prompt 185).
    @Query private var entries: [LibraryEntry]
    /// Your Kilter board logs (prompt 188) — board climbs show in Yours with a KILTER badge.
    @Query private var kilterLogs: [KilterLogEntry]
    /// Climbs you authored on the board — "installed" even though they're not in the downloaded catalog.
    @Query private var kilterCreated: [KilterCreatedClimb]
    /// A board climb tapped that this device's catalog doesn't have — explained here, not in the Kilter module.
    @State private var missingKilterClimb: String?
    @Environment(\.modelContext) private var context
    @State private var showHidden = false

    /// `""` = automatic (Yours when you have history, else Explore); otherwise the user's explicit choice.
    @AppStorage("library.mode") private var modeRaw = ""
    /// Per-discipline sort, "all=mostUsed;climb=best" (prompt 183) — one string because @AppStorage can't hold a map.
    @AppStorage("library.sorts") private var sortsRaw = ""
    /// Per-discipline count unit ("dance=efforts"), same encoding — what a row's number means (Days by default).
    @AppStorage("library.counts") private var countsRaw = ""
    @State private var query = ""
    /// `nil` ⇒ the "All types" facet.
    @State private var discipline: WorkoutDiscipline?
    @State private var facets = LibraryFacets()
    @State private var showingFilters = false
    @State private var climbFilter: LibraryCatalog.ClimbFilter = .all
    /// Your activities — rebuilt when history changes (never in `body`: it scans every session).
    @State private var yours: [LibraryCatalog.Row] = []

    /// Yours once you have history, else Explore.
    private var automaticMode: Mode { history.contains { !$0.isActive } ? .yours : .explore }
    private var mode: Mode { Mode(rawValue: modeRaw) ?? automaticMode }

    /// Remember only a choice that DIFFERS from the automatic one. A pick that matches it is stored as automatic — so
    /// a write of the current value (a picker re-asserting its selection while history is still loading) can never
    /// pin the Library to Explore. It once did: the tab stuck on Explore with history present.
    private func choose(_ m: Mode) {
        modeRaw = m == automaticMode ? "" : m.rawValue
    }
    private var allItems: [LibraryItem] { resolver.library(timed: timed) }
    private var disciplines: [WorkoutDiscipline] {
        mode == .yours ? WorkoutDiscipline.allCases.filter { d in yours.contains { $0.discipline == d } }
                       : LibraryBuilder.disciplines(in: allItems)
    }
    private var results: [LibraryItem] {
        LibraryBuilder.apply(allItems, query: query, discipline: discipline, facets: facets)
    }
    private var sort: LibraryCatalog.Sort {
        let saved = Self.parseSorts(sortsRaw)[discipline?.rawValue ?? "all"].flatMap(LibraryCatalog.Sort.init)
        return saved.flatMap { LibraryCatalog.sorts(for: discipline).contains($0) ? $0 : nil } ?? .mostUsed
    }
    private var countUnit: LibraryCatalog.CountUnit {
        Self.parseSorts(countsRaw)[discipline?.rawValue ?? "all"].flatMap(LibraryCatalog.CountUnit.init) ?? .days
    }
    private var pinnedKeys: Set<ActivityKey> { Set(entries.filter(\.isPinned).compactMap(\.key)) }
    private var hiddenKeys: Set<ActivityKey> { Set(entries.filter(\.isHidden).compactMap(\.key)) }
    /// Filtered + sorted; hidden activities are left out unless "Show hidden" is on (prompt 185).
    private var yoursShown: [LibraryCatalog.Row] {
        let hidden = hiddenKeys
        let rows = yours.filter { showHidden || !hidden.contains($0.key) }
        return LibraryCatalog.sorted(LibraryCatalog.filter(rows, query: query, discipline: discipline,
                                                           climbFilter: discipline == .climb ? climbFilter : .all),
                                     by: sort)
    }
    private var hiddenCount: Int {
        let hidden = hiddenKeys
        return yours.filter { hidden.contains($0.key) && (discipline == nil || $0.discipline == discipline) }.count
    }

    var body: some View {
        List {
            Picker("Library", selection: Binding(get: { mode }, set: { choose($0) })) {
                Text("Yours").tag(Mode.yours)
                Text("Explore").tag(Mode.explore)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("library.mode")
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 2, trailing: 12))

            disciplineChipBar

            if mode == .yours { yoursSection } else { exploreSection }
        }
        .listStyle(.plain)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: searchPrompt)
        .overlay {
            if mode == .explore && results.isEmpty {
                ContentUnavailableView.search(text: query.isEmpty ? "—" : query)
            }
        }
        .toolbar {
            if mode == .explore {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingFilters = true } label: {
                        Label("Filters", systemImage: facets.isEmpty
                              ? "line.3.horizontal.decrease.circle"
                              : "line.3.horizontal.decrease.circle.fill")
                    }
                    // No facets apply to "All types" → the sheet would be empty; hide the entry.
                    .disabled(discipline == nil)
                    .accessibilityIdentifier("library.filters")
                }
            }
        }
        .sheet(isPresented: $showingFilters) {
            LibraryFilterSheet(discipline: discipline ?? .strength, facets: $facets)
        }
        .alert("Climb not in your catalog",
               isPresented: Binding(get: { missingKilterClimb != nil }, set: { if !$0 { missingKilterClimb = nil } }),
               presenting: missingKilterClimb) { _ in
            Button("OK", role: .cancel) {}
        } message: { _ in
            Text("This board climb isn't in the Kilter catalog on this phone — it may have been logged on another "
                 + "board. Get a catalog that includes it in the Kilter Board app.")
        }
        .task(id: "\(history.count)|\(entries.filter { $0.templateData != nil }.count)|\(kilterLogs.count)") {
            rebuildYours()
        }
        .onChange(of: modeRaw) { _, _ in
            // A discipline that has nothing in the other tab would leave an empty list behind the chip.
            if let d = discipline, !disciplines.contains(d) { discipline = nil }
        }
    }

    // MARK: - Yours

    @ViewBuilder private var yoursSection: some View {
        let rows = yoursShown
        Section {
            if yours.isEmpty {
                VStack(spacing: 10) {
                    Text("Nothing logged yet").font(.headline)
                    Text("Everything you log in a session — lifts, climbs, runs, holds — shows up here with how often you do it.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Explore the catalog") { choose(.explore) }
                        .buttonStyle(.borderedProminent).tint(SnappetColor.workout)
                        .accessibilityIdentifier("library.yours.explore")
                }
                .frame(maxWidth: .infinity).padding(.vertical, 30)
                .listRowSeparator(.hidden)
            } else if rows.isEmpty {
                Text("Nothing matches.").foregroundStyle(.secondary)
            } else {
                // Pinned activities lead every sort (prompt 185), then what you've created but not done yet (186) —
                // it would otherwise sink under "Most used" right after you made it.
                let pinned = pinnedKeys
                let ordered = rows.filter { pinned.contains($0.key) }
                    + rows.filter { !pinned.contains($0.key) && $0.notDoneYet }
                    + rows.filter { !pinned.contains($0.key) && !$0.notDoneYet }
                ForEach(ordered) { row in
                    yoursRow(row, pinned: pinned.contains(row.key))
                }
            }
            // Hidden activities are one visible tap away (device feedback on prompt 188 — the toggle alone, inside
            // the sort menu, was undiscoverable).
            if hiddenCount > 0 || showHidden {
                Button { showHidden.toggle() } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(showHidden ? "Hide hidden" : "Show \(hiddenCount) hidden",
                              systemImage: showHidden ? "eye.slash" : "eye")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(SnappetColor.workout)
                        if showHidden && hiddenCount > 0 {
                            Text("Swipe a dimmed one left to unhide it.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .listRowSeparator(.hidden)
                .accessibilityIdentifier("library.showHidden")
            }
        } header: {
            if !yours.isEmpty { yoursHeader(count: rows.count) }
        }
    }

    private func yoursRow(_ row: LibraryCatalog.Row, pinned: Bool) -> some View {
        let hidden = hiddenKeys.contains(row.key)
        return Button { open(row) } label: {
            LibraryYoursRow(row: row, unit: unit, count: countUnit, pinned: pinned, hidden: hidden)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("library.yours.row")
        .swipeActions(edge: .leading) {
            Button { setFlag(row.key, pin: !pinned) } label: {
                Label(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin")
            }
            .tint(SnappetColor.workout)
        }
        .swipeActions(edge: .trailing) {
            Button { setFlag(row.key, hide: !hidden) } label: {
                Label(hidden ? "Unhide" : "Hide", systemImage: hidden ? "eye" : "eye.slash")
            }
            .tint(.gray)
        }
    }

    /// A board climb opens straight on its Kilter page (device feedback on prompt 188 — going through the Kilter
    /// module's home first was confusing): the same installed check + angle adoption as a shared Kilter link.
    private func open(_ row: LibraryCatalog.Row) {
        guard LibraryCatalog.isKilter(row.key) else {
            openActivity(ActivityRoute(key: row.key, title: row.title))
            return
        }
        let uuid = row.key.nameKey
        let installed = KilterCatalog.shared.climb(uuid) != nil || kilterCreated.contains { $0.uuid == uuid }
        switch KilterDeepLinkRouting.destination(for: KilterClimbLink(uuid: uuid, angle: row.climb?.angle),
                                                 climbInstalled: installed,
                                                 availableAngles: KilterCatalog.shared.angles()) {
        case .openClimb(_, let adoptAngle):
            if let adoptAngle { UserDefaults.standard.set(adoptAngle, forKey: "kilter.angle") }
            openActivity(ActivityRoute(key: row.key, title: row.title))
        case .explainMissing:
            missingKilterClimb = uuid
        }
    }

    private func setFlag(_ key: ActivityKey, pin: Bool? = nil, hide: Bool? = nil) {
        guard let e = LibraryEntry.entry(for: key, in: context, create: true) else { return }
        if let pin { e.isPinned = pin }
        if let hide { e.isHidden = hide }
        e.updatedAt = .now
        if !e.isPinned && !e.isHidden && e.templateData == nil { context.delete(e) }      // nothing to remember
        try? context.save()
    }

    private func yoursHeader(count: Int) -> some View {
        HStack {
            Text(countLabel(count)).font(.caption).foregroundStyle(.secondary).textCase(nil)
            Spacer()
            Menu {
                Picker("Sort by", selection: Binding(get: { sort }, set: { setSort($0) })) {
                    ForEach(LibraryCatalog.sorts(for: discipline)) { s in
                        Text(s.label(for: discipline)).tag(s)
                    }
                }
                Picker("Count by", selection: Binding(get: { countUnit }, set: { setCount($0) })) {
                    ForEach(LibraryCatalog.CountUnit.allCases) { u in Text(u.label(for: discipline)).tag(u) }
                }
                if hiddenCount > 0 || showHidden {
                    Toggle("Show hidden (\(hiddenCount))", isOn: $showHidden)
                }
                if discipline == .climb {
                    Picker("Show", selection: $climbFilter) {
                        Text("All climbs").tag(LibraryCatalog.ClimbFilter.all)
                        Text("Projects only").tag(LibraryCatalog.ClimbFilter.projects)
                        Text("Sent only").tag(LibraryCatalog.ClimbFilter.sent)
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(sort.label(for: discipline))
                    Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                }
                .font(.caption.weight(.semibold)).foregroundStyle(SnappetColor.workout).textCase(nil)
            }
            .accessibilityIdentifier("library.sort")
        }
    }

    private func countLabel(_ n: Int) -> String {
        switch discipline {
        case .climb?:
            let sent = yoursShown.filter { $0.climb?.sent == true }.count
            return "\(n) \(n == 1 ? "climb" : "climbs") · \(sent) sent"
        case let d?: return "\(n) \(d.label.lowercased())"
        case nil: return "\(n) \(n == 1 ? "activity" : "activities")"
        }
    }

    private func rebuildYours() {
        let identity = ActivityIdentity(sessions: history)
        let created = entries.compactMap { e -> LibraryCatalog.CreatedInput? in
            guard let key = e.key, let t = e.template else { return nil }
            return LibraryCatalog.CreatedInput(key: key, template: t, createdAt: e.createdAt ?? e.updatedAt)
        }
        yours = LibraryCatalog.yours(history: history, identity: identity, unit: unit, created: created) { ex in
            Self.title(ex, resolver: resolver)
        }
        yours += LibraryCatalog.kilterRows(kilterLogs.map {
            .init(uuid: $0.climbUUID, name: $0.climbName, angle: $0.angle, gradeLabel: $0.gradeLabel,
                  status: $0.status, attempts: $0.attempts, date: $0.date, sessionId: $0.sessionId)
        })
    }

    /// An activity's display name: a catalog lift by the catalog (or your rename), anything else as typed.
    static func title(_ ex: SessionExercise, resolver: ExerciseResolver) -> String {
        ex.discipline == .strength && !ex.exerciseId.hasPrefix("adhoc-")
            ? resolver.name(for: ex.exerciseId, override: ex.displayName)
            : LibraryCatalog.fallbackTitle(ex)
    }

    private func setSort(_ s: LibraryCatalog.Sort) {
        var map = Self.parseSorts(sortsRaw)
        map[discipline?.rawValue ?? "all"] = s.rawValue
        sortsRaw = map.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ";")
    }

    private func setCount(_ u: LibraryCatalog.CountUnit) {
        var map = Self.parseSorts(countsRaw)
        map[discipline?.rawValue ?? "all"] = u.rawValue
        countsRaw = map.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ";")
    }

    static func parseSorts(_ raw: String) -> [String: String] {
        Dictionary(raw.split(separator: ";").compactMap { pair -> (String, String)? in
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            return kv.count == 2 ? (kv[0], kv[1]) : nil
        }, uniquingKeysWith: { _, b in b })
    }

    // MARK: - Explore

    @ViewBuilder private var exploreSection: some View {
        Section {
            ForEach(results) { item in
                Button { open(item) } label: { LibraryItemRow(item: item, doneDays: doneDays(item)) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("exerciseRow")
            }
        } header: {
            Text("\(results.count) \(discipline?.label.lowercased() ?? "item")\(results.count == 1 ? "" : "s")")
        }
        if !facets.isEmpty {
            Section {
                Button(role: .destructive) { facets.clear() } label: {
                    Label("Clear \(facets.activeCount) filter\(facets.activeCount == 1 ? "" : "s")",
                          systemImage: "xmark.circle")
                }
            }
        }
    }

    /// Days you've done a catalog item (prompt 184 — the "done" badge). A lift by its id; a timed protocol by its
    /// id (routine-started) or its name (picked in a Quick Session, which logs `adhoc-duration` + the name).
    private func doneDays(_ item: LibraryItem) -> Int? {
        var keys = [ActivityKey(exerciseId: item.id, nameKey: "")]
        if item.discipline == .timed {
            keys.append(ActivityKey(exerciseId: "adhoc-\(SetKind.duration.rawValue)",
                                    nameKey: ActivityKey.normalize(item.title)))
        }
        let days = keys.compactMap { k in yours.first { $0.key == k }?.days }.max()
        return days.flatMap { $0 > 0 ? $0 : nil }
    }

    private var searchPrompt: String {
        if mode == .yours {
            switch discipline {
            case .climb?: return "Search your climbs"
            case .run?: return "Search your runs"
            default: return "Search your activities"
            }
        }
        switch discipline {
        case .strength?: return "Search exercises or muscles"
        case .climb?:    return "Search climbs"
        case .run?:      return "Search runs"
        case .timed?:    return "Search timed exercises"
        default:         return "Search the library"
        }
    }

    // MARK: - Discipline chip bar (the top facet)

    private var disciplineChipBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                disciplineChip(nil, label: "All", symbol: "square.grid.2x2",
                               accent: SnappetColor.workout)
                ForEach(disciplines) { d in
                    disciplineChip(d, label: d.label, symbol: d.symbol, accent: d.accent)
                }
            }
            .padding(.vertical, 4)
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
        .listRowSeparator(.hidden)
    }

    private func disciplineChip(_ d: WorkoutDiscipline?, label: String, symbol: String,
                                accent: Color) -> some View {
        let on = discipline == d
        return Button {
            withAnimation(SnappetMotion.quick) {
                discipline = d
                facets.keepOnly(d)   // drop now-irrelevant facets so a stale filter never hides everything
                if d != .climb { climbFilter = .all }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.caption.weight(.semibold))
                Text(label).font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .foregroundStyle(on ? accent : SnappetColor.textSecondary)
            .background(on ? accent.opacity(0.15) : SnappetColor.surfaceMuted, in: Capsule())
            .overlay(Capsule().strokeBorder(on ? accent.opacity(0.4) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("library.chip.\(d?.rawValue ?? "all")")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// One of YOUR activities (prompt 183): a climb shows its grade badge, type · gym · set date and its outcome; anything
/// else its discipline glyph and headline number. The trailing column is how much you do it (sessions · last done).
/// The whole row is the tap target (prompt 182).
struct LibraryYoursRow: View {
    let row: LibraryCatalog.Row
    let unit: WeightUnit
    /// What the trailing count means (prompt 183 follow-up) — days unless the user picked otherwise.
    var count: LibraryCatalog.CountUnit = .days
    var pinned = false
    var hidden = false

    var body: some View {
        HStack(spacing: 12) {
            if let c = row.climb {
                Text(c.grade ?? "–").font(.caption.weight(.heavy)).monospacedDigit()
                    .foregroundStyle(SnappetColor.kilter)
                    .frame(width: 36, height: 30)
                    .background(SnappetColor.kilter.opacity(0.15), in: RoundedRectangle(cornerRadius: 7))
            } else {
                Image(systemName: row.discipline.symbol)
                    .font(.title3).foregroundStyle(row.discipline.accent)
                    .frame(width: 36, height: 30)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(row.title).font(.headline).lineLimit(1)
                    if LibraryCatalog.isKilter(row.key) {
                        Text("KILTER").font(.caption2.weight(.heavy)).foregroundStyle(SnappetColor.kilter)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(SnappetColor.kilter.opacity(0.15), in: Capsule())
                    }
                    if pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(SnappetColor.workout) }
                    if hidden { Image(systemName: "eye.slash").font(.caption2).foregroundStyle(.secondary) }
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 2) {
                if row.notDoneYet {
                    Text("New").font(.caption.weight(.bold)).foregroundStyle(SnappetColor.workout)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(SnappetColor.workout.opacity(0.15), in: Capsule())
                } else if let c = row.climb {
                    Text(statusLabel(c)).font(.caption.weight(.bold))
                        .foregroundStyle(c.sent ? SnappetColor.perfFresh : SnappetColor.kilter)
                    Text(LibraryCatalog.countLabel(row, count))
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text(LibraryCatalog.countLabel(row, count)).font(.subheadline.weight(.bold)).monospacedDigit()
                    Text(Self.ago(row.lastDate)).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .opacity(hidden ? 0.5 : 1)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        if row.notDoneYet {
            var parts = [row.climb.map(\.type.label) ?? row.discipline.label]
            if let gym = row.climb?.gym, !gym.isEmpty { parts.append(gym) }
            if let grade = row.climb?.grade, !grade.isEmpty, row.climb != nil { parts.insert(grade, at: 1) }
            parts.append(row.headline ?? "Not done yet")
            return parts.joined(separator: " · ")
        }
        if let c = row.climb, LibraryCatalog.isKilter(row.key) {
            // A board climb (prompt 188): the angle you last climbed it at, and your attempts.
            return ["Kilter Board", c.angle.map { "\($0)°" }, "\(c.attempts) \(c.attempts == 1 ? "attempt" : "attempts")"]
                .compactMap { $0 }.joined(separator: " · ")
        }
        if let c = row.climb {
            var parts = [c.type.label]
            if let gym = c.gym, !gym.isEmpty { parts.append(gym) }
            parts.append("set \(c.setStart.formatted(.dateTime.day().month(.abbreviated)))" + (c.isReset ? " · reset" : ""))
            parts.append("\(c.attempts) \(c.attempts == 1 ? "attempt" : "attempts")")
            return parts.joined(separator: " · ")
        }
        return [row.discipline.label, row.headline].compactMap { $0 }.joined(separator: " · ")
    }

    private func statusLabel(_ c: LibraryCatalog.Row.Climb) -> String {
        switch c.status {
        case .flash?: return "Flash"
        case .sent?: return c.type.statusLabel(.sent)
        case nil: return "Not tried"
        default: return "Project"
        }
    }

    /// "today", "yesterday", "5d ago", "3w ago", then the date.
    static func ago(_ d: Date, now: Date = .now) -> String {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: now)).day ?? 0
        switch days {
        case ..<1: return "today"
        case 1: return "yesterday"
        case 2..<14: return "\(days)d ago"
        case 14..<60: return "\(days / 7)w ago"
        default: return d.formatted(.dateTime.day().month(.abbreviated))
        }
    }
}

/// A single library row: discipline glyph (in its accent) + title + subtitle, with a "Custom" badge for
/// user-created exercises. The accent makes the discipline legible at a glance (the wayfinding axis).
struct LibraryItemRow: View {
    let item: LibraryItem
    /// Days you've done it, for the "done" badge in Explore (prompt 184); `nil` = never.
    var doneDays: Int? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.symbol)
                .font(.title3)
                .foregroundStyle(item.discipline.accent)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.headline).lineLimit(1)
                Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let doneDays {
                Text("Done · \(doneDays) \(doneDays == 1 ? "day" : "days")")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(SnappetColor.workout.opacity(0.15), in: Capsule())
                    .foregroundStyle(SnappetColor.workout)
            }
            if item.isCustom {
                Text("Custom")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(item.discipline.accent.opacity(0.15), in: Capsule())
                    .foregroundStyle(item.discipline.accent)
            }
        }
        .padding(.vertical, 2)
        // The whole row is the tap target. Under `.buttonStyle(.plain)` only drawn content hit-tests, so a short
        // title/subtitle (every climb/run starter) left the empty middle and right of the row dead — tapping a
        // climb "did nothing" unless you hit the text.
        .contentShape(Rectangle())
    }
}

// MARK: - Discipline-adaptive filter sheet (the facet swap)

/// The faceted filter whose facets SWAP by active discipline: strength → muscle + equipment + "no
/// equipment"; climb → style; timed → protocol category; run → terrain. One sheet, one `LibraryFacets`
/// value — the discipline decides which sections render.
private struct LibraryFilterSheet: View {
    let discipline: WorkoutDiscipline
    @Binding var facets: LibraryFacets
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                switch discipline {
                case .strength:
                    Section { Toggle("No equipment", isOn: $facets.noEquipment)
                        .accessibilityIdentifier("library.facet.noEquipment") }
                    chipSection("Muscle", ExerciseFilters.allMuscles, label: \.display,
                                isOn: { facets.muscles.contains($0) }, toggle: { toggle(\.muscles, $0) })
                    chipSection("Equipment", ExerciseFilters.allEquipment, label: \.display,
                                isOn: { facets.equipment.contains($0) }, toggle: { toggle(\.equipment, $0) })
                case .climb:
                    chipSection("Style", ClimbType.allCases, label: \.label,
                                isOn: { facets.climbTypes.contains($0) }, toggle: { toggle(\.climbTypes, $0) })
                case .timed:
                    chipSection("Protocol", TimedExerciseCategory.allCases, label: \.display,
                                isOn: { facets.timedCategories.contains($0) },
                                toggle: { toggle(\.timedCategories, $0) })
                case .run:
                    chipSection("Terrain", RunTerrain.allCases, label: \.display,
                                isOn: { facets.runTerrains.contains($0) }, toggle: { toggle(\.runTerrains, $0) })
                case .dance, .other:
                    Section { Text("No filters for this type yet.").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("\(discipline.label) filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear") { facets.clear() }.disabled(facets.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func toggle<T: Hashable>(_ keyPath: WritableKeyPath<LibraryFacets, Set<T>>, _ value: T) {
        if facets[keyPath: keyPath].contains(value) { facets[keyPath: keyPath].remove(value) }
        else { facets[keyPath: keyPath].insert(value) }
    }

    @ViewBuilder
    private func chipSection<T: Identifiable & Hashable>(
        _ title: String, _ items: [T], label: KeyPath<T, String>,
        isOn: @escaping (T) -> Bool, toggle: @escaping (T) -> Void
    ) -> some View {
        Section(title) {
            LibraryFlowChips(items: items, label: label, isOn: isOn, toggle: toggle)
        }
    }
}

/// A wrapping row of selectable chips (the generalized `FlowChips`, now discipline-tint-agnostic — it uses
/// the gym ember as the on-tint since the sheet is already scoped to one discipline).
private struct LibraryFlowChips<T: Identifiable & Hashable>: View {
    let items: [T]
    let label: KeyPath<T, String>
    let isOn: (T) -> Bool
    let toggle: (T) -> Void

    private let columns = [GridItem(.adaptive(minimum: 90), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(items) { item in
                let on = isOn(item)
                Button { toggle(item) } label: {
                    Text(item[keyPath: label])
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(on ? SnappetColor.workout.opacity(0.2) : Color(.secondarySystemFill),
                                    in: Capsule())
                        .foregroundStyle(on ? SnappetColor.workout : Color.primary)
                }
                .buttonStyle(.plain)
                .snappetAnimation(SnappetMotion.quick, value: on)
            }
        }
        .padding(.vertical, 4)
    }
}
