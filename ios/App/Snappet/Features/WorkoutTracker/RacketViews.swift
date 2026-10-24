import SwiftUI

// MARK: - Racket sports views (prompt 203)
//
// Leaf views for the `.racket` discipline in the Quick Session pager. The host (`FreeformPlayerView`) owns
// every mutation, sheet and cover; these take values + callbacks, like the other pager leaves. Wireframe:
// `docs/ux-research/racket-sports/wireframes.html`.

// MARK: - Params

/// What the new-match sheet captures, and what "Edit details" / "Next match" prefill.
struct RacketMatchParams: Equatable {
    var sport: RacketSport
    var opponent: String = ""
    var doubles: Bool
    var partner: String = ""
    /// `nil` ⇒ open play.
    var bestOf: Int?
    var pointsTo: Int
    var superTiebreak: Bool = false
    var event: String = ""
    var round: String = ""

    init(sport: RacketSport) {
        self.sport = sport
        doubles = sport.defaultsToDoubles
        bestOf = sport.defaultBestOf
        pointsTo = sport.defaultPointsTo
    }

    init(from ex: SessionExercise) {
        let format = ex.racketFormat
        sport = format.sport
        opponent = ex.opponent ?? ""
        partner = ex.partner ?? ""
        doubles = ex.isDoubles
        bestOf = format.bestOf
        pointsTo = format.pointsTo
        superTiebreak = format.superTiebreak
        event = ex.racketEvent ?? ""
        round = ex.racketRound ?? ""
    }

    /// "Next match": same sport, format, event and partner; the next round; a new opponent.
    func next() -> RacketMatchParams {
        var p = self
        p.opponent = ""
        p.round = RacketRounds.next(after: round) ?? ""
        return p
    }

    /// Write the match identity onto an entity (results — the `sets` — are untouched).
    func apply(to ex: inout SessionExercise) {
        func clean(_ s: String) -> String? {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        ex.racketSportRaw = sport.rawValue
        ex.racketModeRaw = RacketMode.match.rawValue
        ex.opponent = clean(opponent)
        ex.partner = doubles ? (clean(partner) ?? "Partner") : nil
        ex.racketBestOf = bestOf ?? 0
        ex.racketPointsTo = pointsTo == sport.defaultPointsTo ? nil : pointsTo
        ex.racketSuperTiebreak = sport.usesSets && superTiebreak ? true : nil
        ex.racketEvent = clean(event)
        ex.racketRound = clean(round)
    }
}

/// Where the setup sheet opens: the sport picker for a new entity, or the match form prefilled.
enum RacketSetupStart: Equatable {
    case new(lastSport: RacketSport?, lastMode: RacketMode?)
    case editMatch(RacketMatchParams)
    case nextMatch(RacketMatchParams)
}

// MARK: - Setup sheet (sport + mode → match details | drill picker)

struct RacketSetupSheet: View {
    let start: RacketSetupStart
    let recentOpponents: (RacketSport) -> [String]
    let recentEvents: [String]
    let recentDrills: (RacketSport) -> [(name: String, measure: RacketDrillMeasure)]
    let onMatch: (RacketMatchParams) -> Void
    let onDrill: (RacketSport, String, RacketDrillMeasure) -> Void

    private enum Step { case sport, match, drill, newDrill }

    @Environment(\.dismiss) private var dismiss
    @State private var step: Step = .sport
    @State private var sport: RacketSport = .tableTennis
    @State private var mode: RacketMode = .match
    @State private var params = RacketMatchParams(sport: .tableTennis)
    @State private var drillQuery = ""
    @State private var newDrillName = ""
    @State private var newDrillMeasure: RacketDrillMeasure = .madeTried
    @State private var started = false

    private var accent: Color { WorkoutDiscipline.racket.accent }
    private var isEditing: Bool { if case .editMatch = start { return true } else { return false } }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .sport: sportStep
                case .match: matchStep
                case .drill: drillStep
                case .newDrill: newDrillStep
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if step == .sport || isEditing || isNext {
                        Button("Cancel") { dismiss() }
                    } else {
                        Button { withAnimation { step = step == .newDrill ? .drill : .sport } } label: {
                            Label("Back", systemImage: "chevron.left")
                        }
                        .accessibilityIdentifier("racket.back")
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
        .onAppear(perform: configure)
    }

    private var isNext: Bool { if case .nextMatch = start { return true } else { return false } }

    private func configure() {
        guard !started else { return }
        started = true
        switch start {
        case .new(let lastSport, let lastMode):
            sport = lastSport ?? .tableTennis
            mode = lastMode ?? .match
            params = RacketMatchParams(sport: sport)
        case .editMatch(let p), .nextMatch(let p):
            sport = p.sport
            params = p
            step = .match
        }
    }

    // MARK: Step 1 — sport + mode

    private var sportStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(RacketSport.allCases) { s in
                        Button { sport = s; Haptics.tap() } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Image(systemName: s.symbol).font(.title2).foregroundStyle(accent)
                                Text(s.label).font(.subheadline.weight(.bold)).foregroundStyle(SnappetColor.ink)
                                Text(s.formatSummary).font(.caption2).foregroundStyle(SnappetColor.textSecondary)
                                    .lineLimit(1).minimumScaleFactor(0.8)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .pagerGlass(cornerRadius: 18)
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(sport == s ? accent : .clear, lineWidth: 1.5))
                        .accessibilityIdentifier("racket.sport.\(s.rawValue)")
                        .accessibilityAddTraits(sport == s ? .isSelected : [])
                    }
                }
                Picker("Mode", selection: $mode) {
                    Text("Match").tag(RacketMode.match)
                    Text("Drill").tag(RacketMode.drill)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("racket.mode")
                Text(mode == .match ? "Against an opponent — scored game by game." : "Practice — timed blocks, made / tried or longest rally.")
                    .font(.caption).foregroundStyle(SnappetColor.textSecondary)
                Button {
                    params = RacketMatchParams(sport: sport)
                    withAnimation { step = mode == .match ? .match : .drill }
                } label: {
                    Text("Next").font(.headline).frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .tint(SnappetColor.brand)
                .accessibilityIdentifier("racket.next")
            }
            .padding(16)
        }
        .navigationTitle("Racket sport")
    }

    // MARK: Step 2a — match details

    private var matchStep: some View {
        Form {
            Section("Opponent") {
                TextField(params.doubles ? "Opponents (e.g. Jordan & Lee)" : "Opponent name", text: $params.opponent)
                    .textInputAutocapitalization(.words)
                    .accessibilityIdentifier("racket.opponent")
                let recents = recentOpponents(params.sport)
                if !recents.isEmpty {
                    chipRow(recents) { params.opponent = $0 }
                }
            }
            Section("Play") {
                Picker("Play", selection: $params.doubles) {
                    Text("Singles").tag(false)
                    Text("Doubles").tag(true)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("racket.doubles")
                if params.doubles {
                    TextField("Your partner", text: $params.partner)
                        .textInputAutocapitalization(.words)
                        .accessibilityIdentifier("racket.partner")
                }
            }
            Section("Format") {
                Picker("Format", selection: $params.bestOf) {
                    ForEach(params.sport.bestOfOptions, id: \.self) { n in
                        Text(RacketFormat(sport: params.sport, bestOf: n).label).tag(Int?.some(n))
                    }
                    Text("Open play").tag(Int?.none)
                }
                .accessibilityIdentifier("racket.format")
                if params.sport.pointsToOptions.count > 1 {
                    Picker("Games to", selection: $params.pointsTo) {
                        ForEach(params.sport.pointsToOptions, id: \.self) { Text("\($0)").tag($0) }
                    }
                }
                if params.sport.usesSets, (params.bestOf ?? 0) > 1 {
                    Toggle("Super tiebreak decider (to 10)", isOn: $params.superTiebreak)
                        .accessibilityIdentifier("racket.superTiebreak")
                }
            }
            Section {
                TextField("Event (e.g. City Open)", text: $params.event)
                    .textInputAutocapitalization(.words)
                    .accessibilityIdentifier("racket.event")
                if !recentEvents.isEmpty { chipRow(recentEvents) { params.event = $0 } }
                TextField("Round (e.g. R16, QF)", text: $params.round)
                    .textInputAutocapitalization(.characters)
                    .accessibilityIdentifier("racket.round")
            } header: {
                Text("Event · round")
            } footer: {
                Text("Optional. Matches with the same event read as one tournament.")
            }
            Section {
                Button {
                    onMatch(params)
                    dismiss()
                } label: {
                    Text(isEditing ? "Save" : "Start match").font(.headline).frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("racket.startMatch")
            }
        }
        .navigationTitle(isEditing ? "Match details" : "\(params.sport.label) match")
    }

    // MARK: Step 2b — drill picker

    private var drillStep: some View {
        let yours = recentDrills(sport)
        let yoursNames = Set(yours.map { RacketStats.normalize($0.name) })
        let suggested = RacketDrillCatalog.suggestions(for: sport).filter { !yoursNames.contains(RacketStats.normalize($0.name)) }
        let q = RacketStats.normalize(drillQuery)
        let matches: (String) -> Bool = { q.isEmpty || RacketStats.normalize($0).contains(q) }
        return List {
            if !yours.filter({ matches($0.name) }).isEmpty {
                Section("Yours") {
                    ForEach(yours.filter { matches($0.name) }, id: \.name) { d in drillRow(d.name, d.measure) }
                }
            }
            Section("Suggested") {
                ForEach(suggested.filter { matches($0.name) }) { d in drillRow(d.name, d.measure) }
            }
            Section {
                Button {
                    newDrillName = drillQuery
                    withAnimation { step = .newDrill }
                } label: {
                    Label("New drill", systemImage: "plus.circle.fill")
                }
                .accessibilityIdentifier("racket.newDrill")
            }
        }
        .searchable(text: $drillQuery, prompt: "Search \(sport.label.lowercased()) drills")
        .navigationTitle("Pick a drill")
    }

    private func drillRow(_ name: String, _ measure: RacketDrillMeasure) -> some View {
        Button {
            onDrill(sport, name, measure)
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).foregroundStyle(SnappetColor.ink)
                    Text(measure.label).font(.caption).foregroundStyle(SnappetColor.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .accessibilityIdentifier("racket.drill")
    }

    private var newDrillStep: some View {
        Form {
            Section("Drill") {
                TextField("Name (e.g. Serve practice)", text: $newDrillName)
                    .textInputAutocapitalization(.sentences)
                    .accessibilityIdentifier("racket.newDrillName")
            }
            Section("Measure each block by") {
                Picker("Measure", selection: $newDrillMeasure) {
                    ForEach(RacketDrillMeasure.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Section {
                Button {
                    let name = newDrillName.trimmingCharacters(in: .whitespacesAndNewlines)
                    onDrill(sport, name.isEmpty ? "\(sport.label) drill" : name, newDrillMeasure)
                    dismiss()
                } label: {
                    Text("Start drill").font(.headline).frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("racket.startDrill")
            }
        }
        .navigationTitle("New drill")
    }

    private func chipRow(_ values: [String], pick: @escaping (String) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(values, id: \.self) { v in
                    Button(v) { pick(v) }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.bordered)
                        .tint(accent)
                }
            }
        }
    }
}

// MARK: - Match hero

/// The match page's hero: scoreboard · unit chips · the current unit (timer + "Game over") — or, once the
/// match is decided, the result with "Next match".
struct RacketMatchHero: View {
    let ex: SessionExercise
    /// When the current unit's timer was started; `nil` ⇒ not timing.
    let unitStartedAt: Date?
    let headToHead: RacketStats.Record
    let clipUnits: Set<Int>
    let onStartUnit: () -> Void
    let onEndUnit: () -> Void
    /// Tap a logged unit's chip → edit its score.
    let onEditUnit: (Int) -> Void
    let onNextMatch: () -> Void
    let onFinish: () -> Void

    private var format: RacketFormat { ex.racketFormat }
    private var state: RacketScoring.MatchState { ex.racketState }
    private var unit: RacketUnit { format.sport.unit }
    private var accent: Color { WorkoutDiscipline.racket.accent }

    private var themLabel: String {
        if ex.isDoubles { return "Them" }
        let first = (ex.opponent ?? "").split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty ? "Them" : first
    }

    var body: some View {
        VStack(spacing: 14) {
            if state.isDecided { resultHeader } else { scoreboard }
            unitChips
            if state.isDecided { resultActions } else { currentUnit }
        }
        .frame(maxWidth: .infinity)
    }

    private var scoreboard: some View {
        HStack {
            side(ex.isDoubles ? "Us" : "You", state.won, highlight: state.won > state.lost)
            Spacer()
            VStack(spacing: 2) {
                Text(format.label.uppercased())
                    .font(.system(size: 11, weight: .heavy)).tracking(0.8)
                    .foregroundStyle(accent)
                Text(format.sublabel).font(.caption2).foregroundStyle(SnappetColor.textSecondary)
            }
            Spacer()
            side(themLabel, state.lost, highlight: false)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .pagerGlass(cornerRadius: 22)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("racket.scoreboard")
        .accessibilityLabel("Match score \(state.won) to \(state.lost)")
    }

    private func side(_ who: String, _ n: Int, highlight: Bool) -> some View {
        VStack(spacing: 0) {
            Text(who.uppercased()).font(.system(size: 11, weight: .heavy)).tracking(0.6)
                .foregroundStyle(SnappetColor.textSecondary).lineLimit(1)
            Text("\(n)")
                .font(.system(size: 46, weight: .heavy, design: .rounded)).monospacedDigit()
                .foregroundStyle(highlight ? SnappetColor.perfFresh : SnappetColor.ink)
                .contentTransition(.numericText())
        }
        .frame(minWidth: 70)
    }

    @ViewBuilder private var unitChips: some View {
        if !state.units.isEmpty || !state.isDecided {
            RacketUnitChips(items: chipItems) { id in
                if id.hasPrefix("u"), let i = Int(id.dropFirst()) { onEditUnit(i) }
            }
        }
    }

    private var chipItems: [RacketUnitChips.Item] {
        var items: [RacketUnitChips.Item] = state.units.enumerated().map { i, u in
            let prefix = u.superTiebreak ? "STB" : "\(unit.shortPrefix)\(i + 1)"
            return RacketUnitChips.Item(id: "u\(i)", text: "\(prefix) \(u.label)", camera: clipUnits.contains(i),
                                  tone: u.won == true ? .won : u.won == false ? .lost : .neutral)
        }
        if !state.isDecided {
            let next = state.units.count
            let label = format.isSuperTiebreak(index: next) ? "Super TB" : "\(unit.shortPrefix)\(next + 1)"
            items.append(.init(id: "cur", text: "\(label) …", camera: false, tone: .current))
        }
        return items
    }

    private var currentUnit: some View {
        let next = state.units.count
        let isSTB = format.isSuperTiebreak(index: next)
        let noun = isSTB ? "super tiebreak" : unit.noun
        return VStack(spacing: 10) {
            VStack(spacing: 2) {
                Text("\(noun) \(isSTB ? "" : "\(next + 1) ")· \(unitStartedAt == nil ? "up next" : "in play")".uppercased())
                    .font(.system(size: 11, weight: .heavy)).tracking(1.4)
                    .foregroundStyle(SnappetColor.textSecondary)
                if let started = unitStartedAt {
                    Text(timerInterval: started...Date.distantFuture, countsDown: false)
                        .font(.system(size: 52, weight: .heavy, design: .rounded)).monospacedDigit()
                        .accessibilityIdentifier("racket.unitTimer")
                }
                if let hint = pressureLine {
                    Text(hint).font(.caption.weight(.semibold)).foregroundStyle(accent)
                }
            }
            Button(action: onEndUnit) {
                Text(unitStartedAt == nil ? "Log \(noun) \(isSTB ? "" : "\(next + 1) ")score"
                                          : "\(noun.capitalized) over · enter score")
                    .font(.headline).frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            .tint(SnappetColor.brand)
            .accessibilityIdentifier("racket.endUnit")
            if unitStartedAt == nil {
                Button(action: onStartUnit) {
                    Label("Start \(noun) timer", systemImage: "stopwatch")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 42)
                }
                .buttonStyle(.plain)
                .pagerGlass(cornerRadius: 14)
                .accessibilityIdentifier("racket.startUnit")
            }
        }
    }

    private var pressureLine: String? {
        switch RacketScoring.pressure(state, format: format) {
        case .none: return nil
        case .matchPointFor: return "Win this one and the match is yours"
        case .matchPointAgainst: return "Must win to stay in it"
        case .decider: return "Decider — winner takes the match"
        }
    }

    private var resultHeader: some View {
        let won = state.result == true
        return VStack(spacing: 2) {
            Text("\(won ? "Match won" : "Match lost")\(ex.racketRound.map { " · \($0)" } ?? "")".uppercased())
                .font(.system(size: 11, weight: .heavy)).tracking(1.6)
                .foregroundStyle(won ? SnappetColor.perfFresh : SnappetColor.perfHard)
            Text(state.end.map { _ in state.shortResult } ?? "\(state.won) – \(state.lost)")
                .font(.system(size: 56, weight: .black, design: .rounded)).monospacedDigit()
                .shadow(color: (won ? SnappetColor.perfFresh : SnappetColor.perfHard).opacity(0.35), radius: 18, y: 6)
            if let end = state.end {
                Text(end.label).font(.caption).foregroundStyle(SnappetColor.textSecondary)
            }
        }
        .padding(.top, 6)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("racket.result")
    }

    private var resultActions: some View {
        let totals = RacketScoring.totals(state.units)
        return VStack(spacing: 10) {
            HStack(spacing: 8) {
                stat(format.sport.usesSets ? "Games" : "Points", "\(totals.forTotal)", "–\(totals.against)")
                stat("Clips", "\(clipUnits.count)", nil)
                if headToHead.played > 0 {
                    stat("H2H", headToHead.shortLabel, nil)
                }
            }
            Button(action: onNextMatch) {
                Text(ex.racketRound.flatMap { RacketRounds.next(after: $0) }.map { "Next match · \($0)" } ?? "Next match")
                    .font(.headline).frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            .tint(SnappetColor.brand)
            .accessibilityIdentifier("racket.nextMatch")
            Button(action: onFinish) {
                Text("Done for now").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 42)
            }
            .buttonStyle(.plain)
            .pagerGlass(cornerRadius: 14)
            .accessibilityIdentifier("racket.doneForNow")
        }
    }

    private func stat(_ k: String, _ v: String, _ small: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(k.uppercased()).font(.system(size: 9.5, weight: .heavy)).tracking(0.8)
                .foregroundStyle(SnappetColor.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(v).font(.headline.monospacedDigit())
                if let small { Text(small).font(.caption2.weight(.bold)).foregroundStyle(SnappetColor.textSecondary) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .pagerGlass(cornerRadius: 14)
    }
}

/// Wrapping result chips ("G1 11–7 🎥").
struct RacketUnitChips: View {
    enum Tone { case won, lost, neutral, current }
    struct Item: Identifiable, Equatable {
        var id: String
        var text: String
        var camera: Bool
        var tone: Tone
    }
    let items: [Item]
    var onTap: ((String) -> Void)? = nil

    var body: some View {
        RacketWrapLayout(spacing: 6) {
            ForEach(items) { item in
                Button { onTap?(item.id) } label: { chip(item) }
                    .buttonStyle(.plain)
                    .disabled(onTap == nil || item.tone == .current)
                    .accessibilityIdentifier("racket.unitChip")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chip(_ item: Item) -> some View {
                HStack(spacing: 4) {
                    Text(item.text).font(.caption.weight(.heavy)).monospacedDigit()
                    if item.camera { Image(systemName: "video.fill").font(.system(size: 9)) }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .foregroundStyle(color(item.tone))
                .background(background(item.tone), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay {
                    if item.tone == .current {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(WorkoutDiscipline.racket.accent.opacity(0.7), style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                    }
                }
    }

    private func color(_ t: Tone) -> Color {
        switch t {
        case .won: return SnappetColor.perfFresh
        case .lost: return SnappetColor.perfHard
        case .neutral: return SnappetColor.textSecondary
        case .current: return SnappetColor.ink
        }
    }
    private func background(_ t: Tone) -> Color {
        switch t {
        case .won: return SnappetColor.perfFresh.opacity(0.12)
        case .lost: return SnappetColor.perfHard.opacity(0.11)
        case .neutral: return .white.opacity(0.05)
        case .current: return .clear
        }
    }
}

/// A minimal left-aligned wrapping layout.
struct RacketWrapLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing
            maxX = max(maxX, x - spacing)
            rowH = max(rowH, s.height)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}

// MARK: - Score sheet

/// Enter one unit's score: two big steppers (the winner's target prefilled), quick chips, swap, a tiebreak
/// row for 7–6 sets, and a live rules check that warns but never blocks.
struct RacketScoreSheet: View {
    let ex: SessionExercise
    /// The unit this score is for (0-based) — the next one for a new score.
    let unitIndex: Int
    let durationSec: Double?
    let onSave: (SetLog) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var mine = 0
    @State private var theirs = 0
    @State private var tbMine = 7
    @State private var tbTheirs = 5
    @State private var configured = false

    private var format: RacketFormat { ex.racketFormat }
    private var isSTB: Bool { format.isSuperTiebreak(index: unitIndex) }
    private var unit: RacketUnit { format.sport.unit }
    private var needsTB: Bool {
        !isSTB && format.sport.usesSets && RacketScoring.needsTiebreak(mine, theirs, gamesTo: format.pointsTo)
    }
    private var score: RacketUnitScore {
        RacketUnitScore(scoreFor: mine, scoreAgainst: theirs,
                        tiebreakFor: needsTB ? tbMine : nil, tiebreakAgainst: needsTB ? tbTheirs : nil,
                        superTiebreak: isSTB)
    }
    private var check: RacketScoreCheck { RacketScoring.check(score, format: format) }
    private var after: RacketScoring.MatchState {
        var units = ex.racketUnits
        if unitIndex < units.count { units[unitIndex] = score } else { units.append(score) }
        return RacketScoring.state(units: units, format: format, end: ex.racketEnd)
    }
    private var themLabel: String {
        if ex.isDoubles { return "Them" }
        let first = (ex.opponent ?? "").split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty ? "Them" : first
    }
    private var title: String {
        isSTB ? "Super tiebreak score" : "\(unit.noun.capitalized) \(unitIndex + 1) score"
    }
    private var maxValue: Int { isSTB ? 40 : format.sport.usesSets ? 13 : (format.sport.cap ?? 60) }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Button("Cancel") { dismiss() }.accessibilityIdentifier("racket.score.cancel")
                Spacer()
                Text(title).font(.headline)
                Spacer()
                Button("Cancel") {}.hidden()
            }
            HStack(spacing: 10) {
                column(ex.isDoubles ? "Us" : "You", value: $mine, winning: check == .valid(won: true), id: "mine")
                column(themLabel, value: $theirs, winning: check == .valid(won: false), id: "theirs")
            }
            if needsTB { tiebreakRow }
            HStack(spacing: 6) {
                ForEach(Array(RacketScoring.quickScores(format: format, superTiebreak: isSTB).enumerated()), id: \.offset) { _, q in
                    Button("\(q.0)–\(q.1)") { mine = q.0; theirs = q.1; if q.0 == format.pointsTo + 1 && q.1 == format.pointsTo { tbMine = 7; tbTheirs = 5 } }
                        .font(.caption.weight(.bold)).buttonStyle(.bordered).tint(.white.opacity(0.6))
                }
                Button { swap(&mine, &theirs); swap(&tbMine, &tbTheirs) } label: {
                    Label("Swap", systemImage: "arrow.left.arrow.right").labelStyle(.titleAndIcon)
                }
                .font(.caption.weight(.bold)).buttonStyle(.bordered).tint(.white.opacity(0.6))
                .accessibilityIdentifier("racket.score.swap")
            }
            verdict
            Spacer(minLength: 0)
            Button {
                var log = SetLog(durationSec: (durationSec ?? 0) > 0 ? durationSec : nil)
                log.scoreFor = mine
                log.scoreAgainst = theirs
                if needsTB { log.tiebreakFor = tbMine; log.tiebreakAgainst = tbTheirs }
                if isSTB { log.superTiebreak = true }
                onSave(log)
                dismiss()
            } label: {
                Text(isSTB ? "Save super tiebreak" : "Save \(unit.noun) \(unitIndex + 1)")
                    .font(.headline).frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            .tint(SnappetColor.brand)
            .accessibilityIdentifier("racket.score.save")
        }
        .padding(20)
        .presentationDetents([.height(needsTB ? 520 : 470), .large])
        .preferredColorScheme(.dark)
        .onAppear {
            guard !configured else { return }
            configured = true
            if unitIndex < ex.sets.count, let existing = ex.sets[unitIndex].racketScore {
                mine = existing.scoreFor; theirs = existing.scoreAgainst
                tbMine = existing.tiebreakFor ?? 7; tbTheirs = existing.tiebreakAgainst ?? 5
            } else {
                (mine, theirs) = RacketScoring.initialScore(format: format, superTiebreak: isSTB)
            }
        }
        .accessibilityIdentifier("racket.scoreSheet")
    }

    private func column(_ who: String, value: Binding<Int>, winning: Bool, id: String) -> some View {
        VStack(spacing: 6) {
            Text(who.uppercased()).font(.system(size: 11, weight: .heavy)).tracking(0.8)
                .foregroundStyle(SnappetColor.textSecondary).lineLimit(1)
            Text("\(value.wrappedValue)")
                .font(.system(size: 52, weight: .heavy, design: .rounded)).monospacedDigit()
                .foregroundStyle(winning ? SnappetColor.perfFresh : SnappetColor.ink)
                .contentTransition(.numericText())
                .accessibilityIdentifier("racket.score.\(id)")
            HStack(spacing: 10) {
                stepButton("minus", id: "\(id).minus") { value.wrappedValue = max(0, value.wrappedValue - 1) }
                stepButton("plus", id: "\(id).plus") { value.wrappedValue = min(maxValue, value.wrappedValue + 1) }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background((winning ? SnappetColor.perfFresh.opacity(0.08) : Color.white.opacity(0.05)),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(winning ? SnappetColor.perfFresh.opacity(0.55) : .white.opacity(0.12)))
    }

    private func stepButton(_ symbol: String, id: String, action: @escaping () -> Void) -> some View {
        Button { action(); Haptics.tap() } label: {
            Image(systemName: symbol).font(.system(size: 18, weight: .semibold))
                .frame(width: 42, height: 42)
                .background(.white.opacity(0.09), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("racket.score.\(id)")
    }

    private var tiebreakRow: some View {
        HStack {
            Text("Tiebreak").font(.subheadline.weight(.semibold))
            Spacer()
            miniStepper($tbMine, id: "tbMine")
            Text("–").foregroundStyle(SnappetColor.textSecondary)
            miniStepper($tbTheirs, id: "tbTheirs")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityIdentifier("racket.tiebreak")
    }

    private func miniStepper(_ v: Binding<Int>, id: String) -> some View {
        HStack(spacing: 4) {
            Button { v.wrappedValue = max(0, v.wrappedValue - 1) } label: { Image(systemName: "minus.circle") }
            Text("\(v.wrappedValue)").font(.headline.monospacedDigit()).frame(minWidth: 24)
            Button { v.wrappedValue = min(40, v.wrappedValue + 1) } label: { Image(systemName: "plus.circle") }
        }
        .buttonStyle(.plain)
        .font(.title3)
        .accessibilityIdentifier("racket.\(id)")
    }

    private var verdict: some View {
        let line = RacketScoring.verdictLine(check, unitNumber: unitIndex + 1,
                                             unit: isSTB ? .game : unit, after: after)
        return HStack(spacing: 6) {
            Image(systemName: check.isValid ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            Text(isSTB ? line.replacingOccurrences(of: "game \(unitIndex + 1)", with: "the super tiebreak") : line)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(check.isValid ? SnappetColor.perfFresh : SnappetColor.perfModerate)
        .multilineTextAlignment(.center)
        .accessibilityIdentifier("racket.score.verdict")
    }
}

// MARK: - Drill hero

/// A drill block: made/tried steppers (accuracy vs last time) or a longest-rally stepper, then Log; time-only
/// drills log their timed block.
struct RacketDrillHero: View {
    let ex: SessionExercise
    /// The last block of this drill — this session's, else last time's — seeds the steppers.
    let seed: SetLog?
    /// Last session's best accuracy for the compare line.
    let lastTimeAccuracy: Double?
    let blockStartedAt: Date?
    let onLog: (SetLog) -> Void
    let onToggleTimer: () -> Void

    @State private var made = 0
    @State private var tried = 50
    @State private var rally = 10
    @State private var seeded = false

    var body: some View {
        VStack(spacing: 12) {
            Text("\(ex.drillMeasure == .time ? "Block" : ex.drillMeasure.label) · block \(ex.sets.count + 1)".uppercased())
                .font(.system(size: 11, weight: .heavy)).tracking(1.4)
                .foregroundStyle(SnappetColor.textSecondary)
            switch ex.drillMeasure {
            case .madeTried:
                stepCard("Made", $made, id: "made")
                stepCard("Tried", $tried, id: "tried")
                compareLine
            case .longestRally:
                stepCard("Longest rally", $rally, id: "rally")
            case .time:
                if blockStartedAt == nil {
                    Text("Start the timer, play the block, then log it.")
                        .font(.caption).foregroundStyle(SnappetColor.textSecondary)
                }
            }
            if let started = blockStartedAt {
                Text(timerInterval: started...Date.distantFuture, countsDown: false)
                    .font(.system(size: 40, weight: .heavy, design: .rounded)).monospacedDigit()
                    .accessibilityIdentifier("racket.blockTimer")
            }
            Button {
                var log = SetLog(durationSec: blockStartedAt.map { Date.now.timeIntervalSince($0) })
                switch ex.drillMeasure {
                case .madeTried: log.drillMade = min(made, tried); log.drillTried = tried
                case .longestRally: log.longestRally = rally
                case .time: break
                }
                onLog(log)
            } label: {
                Text("Log block \(ex.sets.count + 1)").font(.headline).frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            .tint(SnappetColor.brand)
            .accessibilityIdentifier("racket.logBlock")
            Button(action: onToggleTimer) {
                Label(blockStartedAt == nil ? "Time this block" : "Stop timer", systemImage: "stopwatch")
                    .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 42)
            }
            .buttonStyle(.plain)
            .pagerGlass(cornerRadius: 14)
            .accessibilityIdentifier("racket.timeBlock")
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            guard !seeded else { return }
            seeded = true
            if let seed {
                made = seed.drillMade ?? 0
                tried = seed.drillTried ?? 50
                rally = seed.longestRally ?? 10
            }
        }
    }

    @ViewBuilder private var compareLine: some View {
        let acc = RacketScoring.accuracy(made: min(made, tried), tried: tried)
        HStack(spacing: 4) {
            Text(acc.map(RacketStats.percent) ?? "—").font(.caption.weight(.bold))
            if let last = lastTimeAccuracy {
                Text("· last time \(RacketStats.percent(last))").font(.caption).foregroundStyle(SnappetColor.textSecondary)
                if let acc {
                    let diff = Int(((acc - last) * 100).rounded())
                    if diff != 0 {
                        Text(diff > 0 ? "▲ \(diff) pts" : "▼ \(-diff) pts")
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(diff > 0 ? SnappetColor.perfFresh : SnappetColor.perfHard)
                    }
                }
            }
        }
        .accessibilityIdentifier("racket.accuracy")
    }

    private func stepCard(_ label: String, _ value: Binding<Int>, id: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 0) {
                Text(label.uppercased()).font(.system(size: 10.5, weight: .heavy)).tracking(1)
                    .foregroundStyle(SnappetColor.textSecondary)
                Text("\(value.wrappedValue)")
                    .font(.system(size: 34, weight: .heavy, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
                    .accessibilityIdentifier("racket.\(id)")
            }
            Spacer()
            HStack(spacing: 8) {
                circleButton("minus", id: "\(id).minus") { value.wrappedValue = max(0, value.wrappedValue - 1) }
                circleButton("plus", id: "\(id).plus") { value.wrappedValue += 1 }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .pagerGlass(cornerRadius: 22)
    }

    private func circleButton(_ symbol: String, id: String, action: @escaping () -> Void) -> some View {
        Button { action(); Haptics.tap() } label: {
            Image(systemName: symbol).font(.system(size: 18, weight: .semibold))
                .frame(width: 40, height: 40)
                .background(.white.opacity(0.09), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("racket.\(id)")
    }
}

// MARK: - Recap / session detail

/// The racket roll-up for the Finish summary and the session detail: the record, one row per match with its
/// game scores, drills with their best block, and per-game heart rate (or an honest "waiting for your
/// wearable to sync").
struct RacketRecapCards: View {
    let session: WorkoutSession
    var maxHR: Double = HeartRateZone.defaultMaxHR
    /// Per-game HR rows (the session detail shows them; the in-cover summary may too).
    var showsHR: Bool = true

    private var summary: RacketStats.SessionSummary? { RacketStats.summary(session.exercises) }
    private var matches: [SessionExercise] { session.exercises.filter(\.isRacketMatch) }
    private var drills: [SessionExercise] { session.exercises.filter(\.isRacketDrill) }

    var body: some View {
        if let summary {
            VStack(alignment: .leading, spacing: 12) {
                header(summary)
                ForEach(matches) { matchRow($0) }
                ForEach(drills) { drillRow($0) }
                if showsHR { hrSection }
            }
            .padding()
            .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
            .accessibilityIdentifier("racket.recap")
        }
    }

    private func header(_ s: RacketStats.SessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text([s.event, s.sport?.label].compactMap { $0 }.joined(separator: " · ").uppercased())
                .font(.system(size: 10.5, weight: .heavy)).tracking(1.1)
                .foregroundStyle(WorkoutDiscipline.racket.accent)
            if s.matches > 0 {
                Text(s.record.label).font(.title.bold().monospacedDigit())
                    .accessibilityIdentifier("racket.recap.record")
            }
            Text([s.matches > 0 ? "\(s.matches) \(s.matches == 1 ? "match" : "matches")" : nil,
                  s.units > 0 ? "\(s.units) \(s.sport?.usesSets == true ? "sets" : "games")" : nil,
                  s.drills > 0 ? "\(s.drills) \(s.drills == 1 ? "drill" : "drills")" : nil]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func matchRow(_ ex: SessionExercise) -> some View {
        let state = ex.racketState
        return HStack(spacing: 10) {
            Image(systemName: ex.racketSport?.symbol ?? "tennis.racket")
                .foregroundStyle(WorkoutDiscipline.racket.accent).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(RacketStats.matchRowTitle(ex)).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(state.units.isEmpty ? (state.end?.label ?? "Not started") : RacketStats.unitsLine(ex))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(state.shortResult)
                .font(.caption.weight(.heavy).monospacedDigit())
                .padding(.horizontal, 8).padding(.vertical, 3)
                .foregroundStyle(state.result == true ? SnappetColor.perfFresh
                                 : state.result == false ? SnappetColor.perfHard : SnappetColor.textSecondary)
                .background(.quaternary.opacity(0.5), in: Capsule())
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("racket.recap.match")
    }

    private func drillRow(_ ex: SessionExercise) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "target").foregroundStyle(WorkoutDiscipline.racket.accent).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(ex.displayName ?? "Drill").font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("\(ex.completedSetCount) \(ex.completedSetCount == 1 ? "block" : "blocks")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if let line = RacketStats.drillLine(ex) {
                Text(line).font(.caption.weight(.bold).monospacedDigit())
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("racket.recap.drill")
    }

    @ViewBuilder private var hrSection: some View {
        let rows: [(ex: SessionExercise, hr: [RacketStats.UnitHR])] = matches.map {
            ($0, RacketStats.unitHR($0, series: session.hrSeries, sessionStart: session.startedAt, maxHR: maxHR))
        }
        if session.hrSeries.isEmpty {
            Label(session.isActive ? "Heart rate arrives after the session" : "Waiting for your wearable to sync heart rate",
                  systemImage: "heart.text.square")
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("racket.recap.hrWaiting")
        } else {
            ForEach(rows.filter { !$0.hr.isEmpty }, id: \.ex.id) { row in
                VStack(alignment: .leading, spacing: 6) {
                    Text("Heart rate · \(RacketStats.matchRowTitle(row.ex))".uppercased())
                        .font(.system(size: 10, weight: .heavy)).tracking(0.9).foregroundStyle(.secondary)
                    ForEach(row.hr, id: \.index) { u in unitHRRow(row.ex, u) }
                }
            }
        }
    }

    private func unitHRRow(_ ex: SessionExercise, _ u: RacketStats.UnitHR) -> some View {
        let unit = ex.racketFormat.sport.unit
        let score = u.index < ex.sets.count ? ex.sets[u.index].racketScore?.label : nil
        let total = max(1, u.zoneSeconds.reduce(0, +))
        return HStack(spacing: 8) {
            Text("\(unit.shortPrefix)\(u.index + 1)\(score.map { " \($0)" } ?? "")")
                .font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 78, alignment: .leading)
            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(0..<5, id: \.self) { z in
                        Rectangle().fill(HeartRateZone(rawValue: z + 1)?.color ?? .gray)
                            .frame(width: geo.size.width * u.zoneSeconds[z] / total)
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 8)
            Text("avg \(Int(u.avg.rounded()))").font(.caption.weight(.bold).monospacedDigit())
                .frame(width: 60, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("racket.recap.unitHR")
    }
}

// MARK: - Host presentation targets

/// The racket setup sheet's presentation: where it opens, and (Edit details) which match it rewrites.
struct RacketSetupTarget: Identifiable {
    let id = UUID()
    let start: RacketSetupStart
    var editingExerciseID: UUID? = nil
}

/// A score sheet for one unit of a match — a new one (`unitIndex == sets.count`) or an edit.
struct RacketScoreTarget: Identifiable {
    let id = UUID()
    let exerciseID: UUID
    let unitIndex: Int
    let durationSec: Double?
}
