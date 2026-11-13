import SwiftUI
import HighlightEngine

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
    /// Doubles (device feedback round 2): the other team's two players and its team name (auto from them until typed).
    var opponents = RacketOpponentTeam()
    var partner: String = ""
    /// `nil` ⇒ open play.
    var bestOf: Int?
    var pointsTo: Int
    var superTiebreak: Bool = false
    /// Padel "At 40–40: Golden point" (PdDeuce, prompt 249); `false` ⇒ Advantage.
    var goldenPoint: Bool = false
    var event: String = ""
    var round: String = ""
    /// How this match is filmed (prompt 244) — chosen here, defaulted from Settings → Racket recording.
    var recording: RacketRecordingMode = .byUnit

    init(sport: RacketSport, recording: RacketRecordingMode = .byUnit) {
        self.sport = sport
        doubles = sport.defaultsToDoubles
        bestOf = sport.defaultBestOf
        pointsTo = sport.defaultPointsTo
        self.recording = recording
    }

    init(from ex: SessionExercise) {
        let format = ex.racketFormat
        sport = format.sport
        opponent = ex.opponent ?? ""
        partner = ex.partner ?? ""
        doubles = ex.isDoubles
        if doubles {
            let p1 = ex.racketOpponentPlayer1 ?? "", p2 = ex.racketOpponentPlayer2 ?? ""
            // An older doubles match named only the team: it reads as typed by hand, so it's kept as is.
            let hand = ex.racketOpponentTeamNameEdited == true || (p1.isEmpty && p2.isEmpty && !opponent.isEmpty)
            opponents = RacketOpponentTeam(player1: p1, player2: p2, teamName: opponent, edited: hand)
        }
        bestOf = format.bestOf
        pointsTo = format.pointsTo
        superTiebreak = format.superTiebreak
        goldenPoint = format.goldenPoint
        event = ex.racketEvent ?? ""
        round = ex.racketRound ?? ""
        recording = ex.racketRecording
    }

    /// "Next match": same sport, format, event and partner; the next round; a new opponent.
    func next() -> RacketMatchParams {
        var p = self
        p.opponent = ""
        p.opponents = RacketOpponentTeam()
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
        ex.opponent = clean(doubles ? opponents.teamName : opponent)
        ex.racketOpponentPlayer1 = doubles ? clean(opponents.player1) : nil
        ex.racketOpponentPlayer2 = doubles ? clean(opponents.player2) : nil
        ex.racketOpponentTeamNameEdited = doubles && opponents.edited ? true : nil
        ex.partner = doubles ? (clean(partner) ?? "Partner") : nil
        ex.racketBestOf = bestOf ?? 0
        ex.racketPointsTo = pointsTo == sport.defaultPointsTo ? nil : pointsTo
        ex.racketSuperTiebreak = sport.usesSets && superTiebreak ? true : nil
        ex.racketGoldenPoint = sport == .padel && goldenPoint ? true : nil
        ex.racketEvent = clean(event)
        ex.racketRound = clean(round)
        ex.racketRecordingRaw = recording == .byUnit ? nil : recording.rawValue
    }
}

/// How the match form starts a match (Match board): "Set up camera" → Camera → Warmup, or "Play without video" →
/// ScoreOnly (prompt 249).
enum RacketMatchStartAction: Equatable, Sendable { case setUpCamera, playWithoutVideo }

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
    /// Save (editing a match), or a start when `onStartMatch` is nil.
    let onMatch: (RacketMatchParams) -> Void
    let onDrill: (RacketSport, String, RacketDrillMeasure, RacketDrillPlan) -> Void
    /// "Set up camera" / "Play without video" (prompt 249); nil ⇒ `onMatch`.
    var onStartMatch: ((RacketMatchParams, RacketMatchStartAction) -> Void)? = nil
    /// Settings → Racket recording: the recording mode, drill plan and timers a new match / drill starts with.
    var recordingDefaults = RacketRecordingDefaults()
    /// The plan last used for this drill (sport, name) — the plan step opens on it so one tap starts the drill.
    var rememberedPlan: (RacketSport, String) -> RacketDrillPlan? = { _, _ in nil }
    /// Past sessions: the library's Recent / New, SetupFirst, "Last time" (prompt 250).
    var drillHistory: [WorkoutSession] = []

    private enum Step { case sport, padelRules, match, drill, newDrill, drillPlan, customize }

    @Environment(\.dismiss) private var dismiss
    @State private var step: Step = .sport
    @State private var sport: RacketSport = .tableTennis
    @State private var mode: RacketMode = .match
    @State private var params = RacketMatchParams(sport: .tableTennis)
    @State private var drillQuery = ""
    @State private var newDrillName = ""
    @State private var newDrillMeasure: RacketDrillMeasure = .madeTried
    @State private var started = false
    /// The drill picked (or created), set up on the plan step before it starts (prompt 244).
    @State private var pickedDrill: (name: String, measure: RacketDrillMeasure)?
    @State private var drillPlan = RacketDrillPlan()
    @State private var pickedDrillIsNew = false
    @State private var planIsLastTime = false
    @State private var drillIsFirstTime = false
    @State private var drillCategory = RacketDrillLibrary.all
    @State private var restCustom = false
    /// Customize edits a copy; Save writes it back to the setup.
    @State private var customizeDraft = RacketDrillPlan()
    @State private var customizeMeasure: RacketDrillMeasure?

    private var accent: Color { SnappetColor.brand }
    private var isEditing: Bool { if case .editMatch = start { return true } else { return false } }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .sport: sportStep
                case .padelRules: padelRulesStep
                case .match: matchStep
                case .drill: drillStep
                case .newDrill: newDrillStep
                case .drillPlan: drillPlanStep
                case .customize: customizeStep
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if step == .sport || isEditing || isNext {
                        Button("Cancel") { dismiss() }
                    } else if step == .customize {
                        // DrillCustomize: "Cancel · Drill details · Save" — Cancel drops the edits.
                        Button("Cancel") { customizeMeasure = nil; withAnimation { step = .drillPlan } }
                            .accessibilityIdentifier("racket.custom.cancel")
                    } else {
                        Button { withAnimation { step = backStep } } label: {
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

    private var backStep: Step {
        switch step {
        case .newDrill: return .drill
        case .drillPlan: return pickedDrillIsNew ? .newDrill : .drill
        case .customize: return .drillPlan
        case .match where sport == .padel && !isEditing && !isNext: return .padelRules
        default: return .sport
        }
    }

    private func configure() {
        guard !started else { return }
        started = true
        switch start {
        case .new(let lastSport, let lastMode):
            sport = lastSport ?? .tableTennis
            mode = lastMode ?? .match
            params = RacketMatchParams(sport: sport, recording: recordingDefaults.matchMode)
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
                    params = RacketMatchParams(sport: sport, recording: recordingDefaults.matchMode)
                    // Padel sets its deuce rule, final set and players first (PdDeuce → Match).
                    withAnimation { step = mode == .match ? (sport == .padel ? .padelRules : .match) : .drill }
                } label: {
                    Text("Next").font(.headline).frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(SnappetWidePrimaryStyle())
                .accessibilityIdentifier("racket.next")
            }
            .padding(16)
        }
        .navigationTitle("Racket sport")
    }

    // MARK: Step 2a — match details (Match / XxMatch board, prompt 249)

    private var matchStep: some View {
        let format = RacketFormat(sport: params.sport, bestOf: params.bestOf, pointsTo: params.pointsTo,
                                  superTiebreak: params.superTiebreak, goldenPoint: params.goldenPoint)
        let head = RacketGameCopy.formatHeader(format)
        let sides = RacketWatchCopy.sides(opponent: params.opponent, doubles: params.doubles)
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // The live header: "You 0 · Best of 3 / Games to 21 · Alex 0".
                HStack {
                    headerSide(sides.us, alignment: .leading)
                    Spacer()
                    VStack(spacing: 2) {
                        Text(head.top).font(.system(size: 14, weight: .semibold))
                        Text(head.bottom).font(.system(size: 12)).foregroundStyle(SnappetColor.textSecondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("racket.match.format")
                    Spacer()
                    headerSide(sides.them, alignment: .trailing)
                }
                .padding(14)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("racket.match.header")
                if params.sport != .padel { formatBox }
                if params.sport != .padel { playersBox }
                RacketBox {
                    Text("Film this match").font(.system(size: 15, weight: .semibold))
                    Text(RacketGameCopy.filmHelper).font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    RacketRecordingChoice(selection: $params.recording, mode: .match, unit: params.sport.unit)
                    if RacketWatchRelay.shared.isAvailable || ProcessInfo.processInfo.arguments.contains("-uiTestWatchReady") {
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.circle").foregroundStyle(SnappetColor.perfFresh)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Apple Watch ready").font(.system(size: 15, weight: .semibold))
                                Text("Score from your wrist while you play").font(SnappetType.detail)
                                    .foregroundStyle(SnappetColor.textSecondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("racket.match.watchReady")
                    }
                }
                // Prompt 203's Event · round (not on the board) sits under Film this match so the board's order holds.
                RacketBox {
                    Text("Event · round").font(.system(size: 15, weight: .semibold))
                    TextField("Event (e.g. City Open)", text: $params.event)
                        .textInputAutocapitalization(.words)
                        .accessibilityIdentifier("racket.event")
                    if !recentEvents.isEmpty { chipRow(recentEvents) { params.event = $0 } }
                    TextField("Round (e.g. R16, QF)", text: $params.round)
                        .textInputAutocapitalization(.characters)
                        .accessibilityIdentifier("racket.round")
                    Text("Optional. Matches with the same event read as one tournament.")
                        .font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                }
                if isEditing {
                    RacketWideButton("Save", id: "racket.startMatch") { onMatch(params); dismiss() }
                } else {
                    RacketWideButton("Set up camera", id: "racket.match.setUpCamera") { start(.setUpCamera) }
                    Button("Play without video") { start(.playWithoutVideo) }
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .accessibilityIdentifier("racket.match.playWithoutVideo")
                }
                NavigationLink {
                    RacketCapabilitiesScreen(sport: params.sport, onPreviewNoModel: nil)
                } label: {
                    Text("What works for \(params.sport.label.lowercased())").underline()
                        .font(SnappetType.detail.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("racket.match.whatWorks")
            }
            .padding(16)
        }
        .navigationTitle(isEditing ? "Match details" : params.sport.label)
    }

    private func start(_ action: RacketMatchStartAction) {
        var p = params
        switch action {
        case .setUpCamera: if p.recording == .off { p.recording = .byUnit }
        case .playWithoutVideo: p.recording = .off
        }
        if let onStartMatch { onStartMatch(p, action) } else { onMatch(p) }
        dismiss()
    }

    private func headerSide(_ who: String, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 0) {
            Text(who).font(.system(size: 13)).foregroundStyle(SnappetColor.textSecondary).lineLimit(1)
            Text("0").font(.system(size: 34, weight: .light)).monospacedDigit()
        }
    }

    /// Format chips per sport (BdMatch "Best of 3 / One game / Games to 15", TnMatch "Sets" + "Options").
    private var formatBox: some View {
        let sport = params.sport
        let bestOfs = RacketMatchFormChoices.bestOf(sport)
        return RacketBox {
            Text(sport == .tennis ? "Sets" : "Format").font(.system(size: 15, weight: .semibold))
            RacketWrapLayout(spacing: 8) {
                ForEach(bestOfs, id: \.self) { n in
                    formChip(RacketMatchFormChoices.bestOfLabel(sport, n), on: params.bestOf == n, id: "racket.format.bestOf\(n)") {
                        params.bestOf = n
                    }
                }
                if let alt = RacketMatchFormChoices.altPointsTo(sport) {
                    formChip("\(sport.unit.noun.capitalized)s to \(alt)", on: params.pointsTo == alt, id: "racket.format.pointsTo\(alt)") {
                        params.pointsTo = params.pointsTo == alt ? sport.defaultPointsTo : alt
                    }
                }
            }
            if sport == .pickleball {
                RacketWrapLayout(spacing: 8) {
                    ForEach(sport.pointsToOptions, id: \.self) { n in
                        formChip("Games to \(n)", on: params.pointsTo == n, id: "racket.format.pointsTo\(n)") { params.pointsTo = n }
                    }
                }
            }
            if sport == .tennis {
                Text("Options").font(.system(size: 15, weight: .semibold))
                formChip("Match tiebreak", on: params.superTiebreak, id: "racket.superTiebreak") {
                    params.superTiebreak.toggle()
                }
                .disabled((params.bestOf ?? 0) <= 1)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("racket.format")
    }

    private var playersBox: some View {
        RacketBox {
            Text("Players").font(.system(size: 15, weight: .semibold))
            RacketChips(options: [false, true], label: { $0 ? "Doubles" : "Singles" }, selection: $params.doubles,
                        idPrefix: "racket.doubles", idFor: { $0 ? "doubles" : "singles" })
            let recents = recentOpponents(params.sport)
            if params.doubles {
                // Doubles (device feedback round 2): your partner, then the other team — its name follows the two
                // players until you type one (clear it to go back to automatic).
                nameField("Your partner", text: $params.partner, id: "racket.partner")
                Text("Opponents").font(.system(size: 13)).foregroundStyle(SnappetColor.textSecondary)
                nameField("Team name (e.g. Jordan & Lee)",
                          text: Binding(get: { params.opponents.teamName }, set: { params.opponents.setTeamName($0) }),
                          id: "racket.opponentTeam")
                if !recents.isEmpty { chipRow(recents) { params.opponents.pickTeam($0) } }
                nameField("Player 1", text: Binding(get: { params.opponents.player1 }, set: { params.opponents.setPlayer1($0) }),
                          id: "racket.opponentPlayer1")
                nameField("Player 2", text: Binding(get: { params.opponents.player2 }, set: { params.opponents.setPlayer2($0) }),
                          id: "racket.opponentPlayer2")
                Text(params.opponents.edited ? "Clear the team name to make it from the players’ names again."
                                             : "The team name follows the players’ names until you type one.")
                    .font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("racket.opponentTeamHint")
            } else {
                Text("Opponent").font(.system(size: 13)).foregroundStyle(SnappetColor.textSecondary)
                nameField("Optional", text: $params.opponent, id: "racket.opponent")
                if !recents.isEmpty { chipRow(recents) { params.opponent = $0 } }
            }
            Text(RacketGameCopy.doublesHelper).font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func nameField(_ prompt: String, text: Binding<String>, id: String) -> some View {
        TextField(prompt, text: text)
            .textInputAutocapitalization(.words)
            .padding(10)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityIdentifier(id)
    }

    // MARK: Step 2a′ — padel rules (PdDeuce "Match setup")

    private var padelRulesStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("At 40–40").font(.system(size: 20, weight: .bold))
                optionCard("Advantage", "Keep playing until 2 points clear", on: !params.goldenPoint, id: "racket.deuce.advantage") {
                    params.goldenPoint = false
                }
                optionCard("Golden point", "Next point wins the game", on: params.goldenPoint, id: "racket.deuce.golden") {
                    params.goldenPoint = true
                }
                Text("Final set").font(.system(size: 20, weight: .bold)).padding(.top, 6)
                optionCard("Full set", "Play a normal set", on: !params.superTiebreak, id: "racket.deuce.fullSet") {
                    params.superTiebreak = false
                }
                optionCard("Super tiebreak", "First to 10, win by 2", on: params.superTiebreak, id: "racket.deuce.superTiebreak") {
                    params.superTiebreak = true
                }
                playersBox
                RacketWideButton("Continue", id: "racket.deuce.continue") { withAnimation { step = .match } }
            }
            .padding(16)
        }
        .navigationTitle("Match setup")
    }

    private func optionCard(_ title: String, _ sub: String, on: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button { action(); Haptics.tap() } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(SnappetColor.ink)
                Text(sub).font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(on ? SnappetColor.brand.opacity(0.14) : Color.white.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(on ? SnappetColor.brand : .clear, lineWidth: 1.2))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func formChip(_ label: String, on: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button { action(); Haptics.tap() } label: {
            Text(label).font(.system(size: 14, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? SnappetColor.brand : SnappetColor.ink)
                .padding(.horizontal, 14).frame(minHeight: 38)
                .background(on ? SnappetColor.brand.opacity(0.14) : Color.white.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(on ? SnappetColor.brand : .clear, lineWidth: 1.2))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: Step 2b — drill library (DrillLibrary / XxDrills, prompt 250)

    private var drillStep: some View {
        let recent = recentDrills(sport).map { d in
            RacketDrillLibraryItem(name: d.name, measure: d.measure,
                                   categories: RacketDrillLibrary.items(sport).first { RacketStats.normalize($0.name) == RacketStats.normalize(d.name) }?.categories ?? [])
        }
        let rows = RacketDrillLibrary.filtered(sport, category: drillCategory, query: drillQuery, recent: recent)
        let recentNames = Set(recent.map { RacketStats.normalize($0.name) })
        let showRecentSection = drillCategory == RacketDrillLibrary.all && drillQuery.isEmpty && !recent.isEmpty
        return ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Search drills").font(.system(size: 13)).foregroundStyle(SnappetColor.textSecondary)
                TextField("Search", text: $drillQuery)
                    .padding(.horizontal, 12).frame(minHeight: 44)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .accessibilityIdentifier("racket.drillSearch")
                RacketWrapLayout(spacing: 8) {
                    ForEach([RacketDrillLibrary.all, RacketDrillLibrary.recent] + RacketDrillLibrary.categories(sport), id: \.self) { c in
                        formChip(c, on: drillCategory == c, id: "racket.drillCat.\(c)") { drillCategory = c }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("racket.drillCats")
                if showRecentSection {
                    Text("Recent").font(.system(size: 14, weight: .bold)).foregroundStyle(SnappetColor.textSecondary)
                    ForEach(recent.prefix(2)) { d in libraryRow(d, recent: true, isNew: false) }
                    Text("All drills").font(.system(size: 14, weight: .bold)).foregroundStyle(SnappetColor.textSecondary)
                        .padding(.top, 2)
                } else if drillCategory == RacketDrillLibrary.all {
                    Text("All drills").font(.system(size: 14, weight: .bold)).foregroundStyle(SnappetColor.textSecondary)
                }
                ForEach(rows) { d in
                    libraryRow(d, recent: drillCategory == RacketDrillLibrary.recent,
                               isNew: !recentNames.contains(RacketStats.normalize(d.name))
                                   && RacketDrillHistory.isFirstTime(sport: sport, name: d.name, history: drillHistory))
                }
                if rows.isEmpty {
                    Text(drillCategory == RacketDrillLibrary.recent ? "No recent drills yet." : "No drills match.")
                        .font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                }
            }
            .padding(16)
        }
        .navigationTitle("\(sport.label) drill")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("+ New") {
                    newDrillName = drillQuery
                    withAnimation { step = .newDrill }
                }
                .accessibilityIdentifier("racket.newDrill")
            }
        }
    }

    private func libraryRow(_ d: RacketDrillLibraryItem, recent: Bool, isNew: Bool) -> some View {
        let last = RacketDrillHistory.lastValue(sport: sport, name: d.name, measure: d.measure, history: drillHistory)
        return Button { pickDrill(d.name, d.measure, isNew: false) } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(d.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(SnappetColor.ink)
                    Text(recent ? RacketDrillLibrary.recentDetail(d.measure, last: last) : d.measure.label)
                        .font(.system(size: 13)).foregroundStyle(SnappetColor.textSecondary)
                }
                Spacer(minLength: 6)
                if isNew { tagLabel("New", SnappetColor.brand) }
                tagLabel(d.tag, SnappetColor.textSecondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(SnappetColor.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("racket.drill")
    }

    private func tagLabel(_ s: String, _ c: Color) -> some View {
        Text(s).font(.system(size: 12, weight: .bold)).foregroundStyle(c)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(c))
            .fixedSize()
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
                    pickDrill(name.isEmpty ? "\(sport.label) drill" : name, newDrillMeasure, isNew: true)
                } label: {
                    Text("Next").font(.headline).frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("racket.startDrill")
            }
        }
        .navigationTitle("New drill")
    }

    private func pickDrill(_ name: String, _ measure: RacketDrillMeasure, isNew: Bool) {
        pickedDrill = (name, measure)
        pickedDrillIsNew = isNew
        let remembered = isNew ? nil : rememberedPlan(sport, name)
        planIsLastTime = remembered != nil
        drillIsFirstTime = isNew || RacketDrillHistory.isFirstTime(sport: sport, name: name, history: drillHistory)
        var plan = remembered ?? RacketDrillPlan(defaults: recordingDefaults)
        if remembered == nil || plan.details.goal == nil {
            // "Beat 24 shots · Last time 24": the goal starts at last time's number; first time, there's none yet.
            plan.details.goal = RacketDrillHistory.lastValue(sport: sport, name: name, measure: measure, history: drillHistory)
        }
        drillPlan = plan
        withAnimation { step = .drillPlan }
    }

    // MARK: Step 3 — PracticeSetup / SetupFirst / SqSolo (prompts 244, 250)

    private var isSolo: Bool {
        RacketDrillLibrary.isSolo(sport: sport, name: pickedDrill?.name ?? "", practising: drillPlan.details.practising)
    }

    private var drillPlanStep: some View {
        let measure = pickedDrill?.measure ?? .time
        let d = drillPlan.details
        let gated = drillIsFirstTime && !isSolo && !d.canStart
        let last = pickedDrill.flatMap { RacketDrillHistory.lastValue(sport: sport, name: $0.name, measure: $0.measure, history: drillHistory) }
        return ScrollView {
            VStack(alignment: .leading, spacing: 11) {
                // The start button sits at the top (user, 2026-11-06: one-tap start); the board has it at the bottom.
                RacketWideButton(drillPlan.recording == .off ? "Start drill" : "Set up camera", id: "racket.plan.start") {
                    guard let p = pickedDrill else { return }
                    onDrill(sport, p.name, p.measure, drillPlan)
                    dismiss()
                }
                .disabled(gated)
                if gated {
                    Text("Choose what you’re practising and your focus first.")
                        .font(SnappetType.detail).foregroundStyle(SnappetColor.perfModerate)
                        .accessibilityIdentifier("racket.plan.gate")
                }
                if isSolo {
                    Text("Solo drill").font(.system(size: 22, weight: .bold)).accessibilityIdentifier("racket.plan.heading")
                    Text("Just you on court, so there’s no opponent or winner.")
                        .font(.system(size: 15)).foregroundStyle(SnappetColor.textSecondary)
                } else if drillIsFirstTime {
                    Text("First time with this drill").font(.system(size: 22, weight: .bold))
                        .accessibilityIdentifier("racket.plan.heading")
                    Text("We’ve suggested a plan. There’s no goal until you’ve done it once.")
                        .font(.system(size: 15)).foregroundStyle(SnappetColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack {
                        Text(planIsLastTime ? "Same as last time" : "Suggested plan").font(.system(size: 22, weight: .bold))
                            .accessibilityIdentifier("racket.plan.heading")
                        Spacer()
                        Button("Change all") { openCustomize() }.font(.system(size: 15))
                            .accessibilityIdentifier("racket.plan.changeAll")
                    }
                }
                VStack(spacing: 0) {
                    if !isSolo {
                        setRow("Practising", d.practising ?? (drillIsFirstTime ? "Choose" : "Not set"), id: "practising")
                    }
                    setRow("Focus", d.focusLine ?? (drillIsFirstTime ? "Choose" : "Not set"), id: "focus")
                    setRow("Pattern", d.pattern ?? "Optional", id: "pattern")
                    setRow("Plan", drillPlan.summary + (drillIsFirstTime && !planIsLastTime ? ", suggested" : ""), id: "plan")
                    setRow("Measure", measure.label, id: "measure")
                    if isSolo {
                        setRow("Recording", drillPlan.recording.label(for: .drill), id: "recordingRow")
                        setRow("Rest", "\(RacketClock.mmss(TimeInterval(drillPlan.restSec))) · auto-start \(drillPlan.autoStart ? "on" : "off")", id: "restRow")
                    } else {
                        setRow("Goal", RacketDrillGoal.text(d.goal, measure: measure) ?? (drillIsFirstTime ? "None yet" : "None"), id: "goal")
                    }
                }
                if isSolo {
                    // SqSolo: "Longest solo rally" — your goal for the solo rally.
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Longest solo rally").font(.system(size: 14, weight: .semibold)).foregroundStyle(SnappetColor.textSecondary)
                        HStack(spacing: 8) {
                            soloStep("−", id: "racket.solo.minus") { drillPlan.details.goal = max(0, (drillPlan.details.goal ?? 0) - 1) }
                            Text("\(drillPlan.details.goal ?? 0)").font(.system(size: 40, weight: .light)).monospacedDigit()
                                .frame(maxWidth: .infinity).accessibilityIdentifier("racket.solo.value")
                            soloStep("+", id: "racket.solo.plus") { drillPlan.details.goal = (drillPlan.details.goal ?? 0) + 1 }
                        }
                        Text(last == nil ? "You enter this" : "Last time \(last!)").font(.system(size: 12))
                            .foregroundStyle(SnappetColor.textSecondary)
                    }
                    .padding(11)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                } else {
                    recordingAndBetween
                }
            }
            .padding(16)
        }
        .navigationTitle(pickedDrill?.name ?? "Drill")
    }

    @ViewBuilder private var recordingAndBetween: some View {
        Text("Recording").font(.system(size: 17, weight: .bold)).padding(.top, 4)
        RacketRecordingChoice(selection: $drillPlan.recording, mode: .drill)
        if !drillIsFirstTime { liveTrackingSwitch }
        Text("Between blocks").font(.system(size: 17, weight: .bold)).padding(.top, 4)
        RacketBox {
            Text("Rest time").font(.system(size: 14, weight: .semibold)).foregroundStyle(SnappetColor.textSecondary)
            RacketWrapLayout(spacing: 8) {
                ForEach(RacketRecordingDefaults.restOptions, id: \.self) { sec in
                    formChip(RacketClock.mmss(TimeInterval(sec)), on: !restCustom && drillPlan.restSec == sec, id: "racket.plan.rest.\(sec)") {
                        restCustom = false; drillPlan.restSec = sec
                    }
                }
                formChip("Custom", on: restCustom, id: "racket.plan.rest.custom") { restCustom = true }
            }
            if restCustom {
                Stepper("Rest \(RacketClock.mmss(TimeInterval(drillPlan.restSec)))", value: $drillPlan.restSec, in: 15...600, step: 15)
                    .accessibilityIdentifier("racket.plan.rest.customStepper")
            }
            Toggle(isOn: $drillPlan.autoStart) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Start next block automatically").font(.system(size: 15, weight: .semibold))
                    Text("When the rest timer ends").font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                }
            }
            .tint(SnappetColor.brand)
            .accessibilityIdentifier("racket.plan.autoStart")
            Text("Countdown before it starts").font(.system(size: 14, weight: .semibold)).foregroundStyle(SnappetColor.textSecondary)
            RacketChips(options: RacketRecordingDefaults.countdownOptions, label: { "\($0) s" }, selection: $drillPlan.countdownSec,
                        idPrefix: "racket.plan.countdown")
        }
        if drillIsFirstTime { liveTrackingSwitch }
    }

    /// "Live tracking · Off: rallies are found after the drill" — not built (step 6): off, disabled, says so.
    private var liveTrackingSwitch: some View {
        RacketBox {
            Toggle(isOn: .constant(false)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Live tracking").font(.system(size: 15, weight: .semibold))
                    Text("Off: rallies are found after the drill").font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                    Text(RacketFeatureState.notAvailableYet.label).font(SnappetType.detail.weight(.semibold))
                        .foregroundStyle(SnappetColor.textSecondary)
                }
            }
            .disabled(true)
            .accessibilityIdentifier("racket.plan.tracking")
        }
    }

    private func setRow(_ label: String, _ value: String, id: String) -> some View {
        Button { openCustomize() } label: {
            HStack(spacing: 12) {
                Text(label).font(.system(size: 14)).foregroundStyle(SnappetColor.textSecondary)
                Spacer()
                Text("\(value) ›").font(.system(size: 15, weight: .semibold)).foregroundStyle(SnappetColor.ink)
                    .multilineTextAlignment(.trailing)
            }
            .frame(minHeight: 46)
            .overlay(alignment: .bottom) { Rectangle().fill(SnappetColor.hairline).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("racket.plan.row.\(id)")
    }

    private func soloStep(_ s: String, id: String, action: @escaping () -> Void) -> some View {
        Button { action(); Haptics.tap() } label: {
            Text(s).font(.system(size: 22, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 48)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private func openCustomize() {
        customizeDraft = drillPlan
        // The board's court shows a From cell and a To cell; start on its pair until you pick your own (prompt 251).
        if customizeDraft.details.fromZone == nil && customizeDraft.details.toZone == nil {
            (customizeDraft.details.fromZone, customizeDraft.details.toZone) = RacketCourtZoneRule.boardDefault
        }
        withAnimation { step = .customize }
    }

    // MARK: Step 3′ — Customize (DrillCustomize · XxCustomize)

    private var customizeStep: some View {
        let measure = pickedDrill?.measure ?? .time
        let last = pickedDrill.flatMap { RacketDrillHistory.lastValue(sport: sport, name: $0.name, measure: $0.measure, history: drillHistory) }
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                section("How are you practising?") {
                    RacketWrapLayout(spacing: 8) {
                        ForEach(RacketDrillChoices.practising(sport), id: \.self) { p in
                            formChip(p, on: customizeDraft.details.practising == p, id: "racket.custom.practising.\(p)") {
                                customizeDraft.details.practising = p
                            }
                        }
                    }
                }
                section("Focus") {
                    RacketWrapLayout(spacing: 8) {
                        ForEach(RacketDrillChoices.hands, id: \.self) { h in
                            formChip(h, on: customizeDraft.details.hand == h, id: "racket.custom.hand.\(h)") {
                                customizeDraft.details.hand = customizeDraft.details.hand == h ? nil : h
                            }
                        }
                    }
                    RacketWrapLayout(spacing: 8) {
                        ForEach(RacketDrillChoices.strokes(sport), id: \.self) { st in
                            formChip(st, on: customizeDraft.details.stroke == st, id: "racket.custom.stroke.\(st)") {
                                customizeDraft.details.stroke = customizeDraft.details.stroke == st ? nil : st
                            }
                        }
                    }
                }
                section("Pattern", hint: "Optional") {
                    RacketWrapLayout(spacing: 8) {
                        ForEach(RacketDrillChoices.patterns(sport), id: \.self) { pt in
                            formChip(pt, on: customizeDraft.details.pattern == pt, id: "racket.custom.pattern.\(pt)") {
                                customizeDraft.details.pattern = customizeDraft.details.pattern == pt ? nil : pt
                            }
                        }
                    }
                    RacketCourtZones(sport: sport, from: $customizeDraft.details.fromZone, to: $customizeDraft.details.toZone)
                }
                section("Plan") {
                    HStack(alignment: .top, spacing: 10) {
                        planStepper("Blocks", "\(customizeDraft.blocks)", id: "racket.custom.blocks") { up in
                            customizeDraft.blocks = min(RacketDrillChoices.blockRange.upperBound,
                                                        max(RacketDrillChoices.blockRange.lowerBound, customizeDraft.blocks + (up ? 1 : -1)))
                        }
                        planStepper("Each block", RacketClock.mmss(TimeInterval(customizeDraft.blockSec)), id: "racket.custom.blockSec") { up in
                            let s = customizeDraft.blockSec + (up ? 1 : -1) * RacketDrillChoices.blockSecStep
                            customizeDraft.blockSec = min(RacketDrillChoices.blockSecRange.upperBound,
                                                          max(RacketDrillChoices.blockSecRange.lowerBound, s))
                        }
                        Text("Rest is set on the ready screen").font(.system(size: 12)).foregroundStyle(SnappetColor.textSecondary)
                            .frame(maxWidth: .infinity).padding(.top, 20)
                    }
                    .padding(11)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                section("Measure each block by") {
                    RacketWrapLayout(spacing: 8) {
                        ForEach(RacketDrillMeasure.allCases, id: \.self) { m in
                            formChip(m.label, on: (customizeMeasure ?? measure) == m, id: "racket.custom.measure.\(m.rawValue)") {
                                customizeMeasure = m
                            }
                        }
                    }
                    // Longest rally from video is the placeholder model's (Capabilities: Placeholder): honest wording.
                    Text((customizeMeasure ?? measure) == .time ? "Logged from the block timer."
                         : "Suggested from video by the placeholder model. You confirm it.")
                        .font(.system(size: 13)).foregroundStyle(SnappetColor.textSecondary)
                }
                section("Goal", hint: "Optional") {
                    let m = customizeMeasure ?? measure
                    HStack {
                        Text(RacketDrillGoal.text(customizeDraft.details.goal, measure: m) ?? (m == .time ? "No goal for a timed drill" : "No goal"))
                            .font(.system(size: 15, weight: .semibold))
                            .accessibilityIdentifier("racket.custom.goal")
                        Spacer()
                        if let l = RacketDrillGoal.lastTime(last, measure: m) {
                            Text(l).font(.system(size: 13)).foregroundStyle(SnappetColor.textSecondary)
                        }
                    }
                    .padding(12)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    if m != .time {
                        HStack(spacing: 8) {
                            formChip("−", on: false, id: "racket.custom.goal.minus") {
                                customizeDraft.details.goal = max(0, (customizeDraft.details.goal ?? last ?? 0) - RacketDrillGoal.step(m))
                            }
                            formChip("+", on: false, id: "racket.custom.goal.plus") {
                                customizeDraft.details.goal = (customizeDraft.details.goal ?? last ?? 0) + RacketDrillGoal.step(m)
                            }
                            formChip("No goal", on: customizeDraft.details.goal == nil, id: "racket.custom.goal.none") {
                                customizeDraft.details.goal = nil
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle("Drill details")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    drillPlan = customizeDraft
                    if let m = customizeMeasure, let p = pickedDrill { pickedDrill = (p.name, m) }
                    customizeMeasure = nil
                    withAnimation { step = .drillPlan }
                }
                .accessibilityIdentifier("racket.custom.save")
            }
        }
    }

    private func section<C: View>(_ title: String, hint: String? = nil, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 16, weight: .bold))
                if let hint { Text(hint).font(.system(size: 13)).foregroundStyle(SnappetColor.textSecondary) }
            }
            content()
        }
    }

    private func planStepper(_ label: String, _ value: String, id: String, change: @escaping (Bool) -> Void) -> some View {
        VStack(spacing: 4) {
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(SnappetColor.textSecondary)
            Text(value).font(.system(size: 22, weight: .light)).monospacedDigit().accessibilityIdentifier(id)
            HStack(spacing: 4) {
                formChip("−", on: false, id: "\(id).minus") { change(false) }
                formChip("+", on: false, id: "\(id).plus") { change(true) }
            }
        }
        .frame(maxWidth: .infinity)
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
    private var accent: Color { SnappetColor.brand }

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
                Text(format.label.sentenceCased)
                    .font(SnappetType.label)
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
            Text(who.sentenceCased).font(SnappetType.label)
                .foregroundStyle(SnappetColor.textSecondary).lineLimit(1)
            Text("\(n)")
                .font(.system(size: 46, weight: .light)).monospacedDigit()
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
        // One chip per logged unit, scored or "Score unconfirmed" (review5 M5); the id is the set index.
        var items: [RacketUnitChips.Item] = ex.sets.enumerated().compactMap { i, set in
            switch set.racketScoreState {
            case .confirmed(let u):
                let prefix = u.superTiebreak ? "STB" : "\(unit.shortPrefix)\(i + 1)"
                return RacketUnitChips.Item(id: "u\(i)", text: "\(prefix) \(u.label)", camera: clipUnits.contains(i),
                                            tone: u.won == true ? .won : u.won == false ? .lost : .neutral)
            case .fromWatch(let u):
                // Tallied on the Watch (prompt 245): counts, amber until it's confirmed here.
                let prefix = u.superTiebreak ? "STB" : "\(unit.shortPrefix)\(i + 1)"
                return RacketUnitChips.Item(id: "u\(i)", text: "\(prefix) \(u.label) \(RacketScoreState.fromWatchSuffix)",
                                            camera: clipUnits.contains(i), tone: .unconfirmed)
            case .unconfirmed:
                return RacketUnitChips.Item(id: "u\(i)", text: "\(unit.shortPrefix)\(i + 1) \(RacketScoreState.unconfirmedLabel)",
                                            camera: clipUnits.contains(i), tone: .unconfirmed)
            case nil:
                return nil
            }
        }
        if !state.isDecided {
            let next = ex.sets.count
            let label = format.isSuperTiebreak(index: next) ? "Super TB" : "\(unit.shortPrefix)\(next + 1)"
            items.append(.init(id: "cur", text: "\(label) …", camera: false, tone: .current))
        }
        return items
    }

    private var currentUnit: some View {
        let next = ex.sets.count
        let isSTB = format.isSuperTiebreak(index: next)
        let noun = isSTB ? "super tiebreak" : unit.noun
        return VStack(spacing: 10) {
            VStack(spacing: 2) {
                Text("\(noun) \(isSTB ? "" : "\(next + 1) ")· \(unitStartedAt == nil ? "up next" : "in play")".sentenceCased)
                    .font(SnappetType.label)
                    .foregroundStyle(SnappetColor.textSecondary)
                if let started = unitStartedAt {
                    Text(timerInterval: started...Date.distantFuture, countsDown: false)
                        .font(.system(size: 52, weight: .light)).monospacedDigit()
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
            .buttonStyle(SnappetWidePrimaryStyle())
            .accessibilityIdentifier("racket.endUnit")
            if unitStartedAt == nil {
                Button(action: onStartUnit) {
                    Label("Start \(noun) timer", systemImage: "stopwatch")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 42)
                }
                .buttonStyle(.plain)
                .pagerOutline()
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
            Text("\(won ? "Match won" : "Match lost")\(ex.racketRound.map { " · \($0)" } ?? "")".sentenceCased)
                .font(SnappetType.label)
                .foregroundStyle(won ? SnappetColor.perfFresh : SnappetColor.perfHard)
            Text(state.end.map { _ in state.shortResult } ?? "\(state.won) – \(state.lost)")
                .font(.system(size: 56, weight: .light)).monospacedDigit()
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
            .buttonStyle(SnappetWidePrimaryStyle())
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
            Text(k.sentenceCased).font(SnappetType.label)
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
    enum Tone { case won, lost, neutral, current, unconfirmed }
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
                    Text(item.text).font(.caption.weight(.medium)).monospacedDigit()
                    if item.camera { Image(systemName: "video.fill").font(.system(size: 9)) }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .foregroundStyle(color(item.tone))
                .background(background(item.tone), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay {
                    if item.tone == .current {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(SnappetColor.brand.opacity(0.7), style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                    }
                }
    }

    private func color(_ t: Tone) -> Color {
        switch t {
        case .won: return SnappetColor.perfFresh
        case .lost: return SnappetColor.perfHard
        case .neutral: return SnappetColor.textSecondary
        case .current: return SnappetColor.ink
        case .unconfirmed: return SnappetColor.perfModerate
        }
    }
    private func background(_ t: Tone) -> Color {
        switch t {
        case .won: return SnappetColor.perfFresh.opacity(0.12)
        case .lost: return SnappetColor.perfHard.opacity(0.11)
        case .neutral: return .white.opacity(0.05)
        case .current: return .clear
        case .unconfirmed: return SnappetColor.perfModerate.opacity(0.11)
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
        // By set index, so a game confirmed after "Score unconfirmed" lands in its own place.
        var sets = ex.sets.map(\.racketScore)
        if unitIndex < sets.count { sets[unitIndex] = score } else { sets.append(score) }
        return RacketScoring.state(units: sets.compactMap { $0 }, format: format, end: ex.racketEnd)
    }
    private var themLabel: String {
        if ex.isDoubles { return "Them" }
        let first = (ex.opponent ?? "").split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty ? "Them" : first
    }
    private var title: String {
        isSTB ? "Super tiebreak score" : "\(unit.noun.capitalized) \(unitIndex + 1) score"
    }
    private var maxValue: Int { isSTB ? 40 : format.sport.usesSets ? 13 : (format.cap ?? 60) }

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
            .buttonStyle(SnappetWidePrimaryStyle())
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
    }

    private func column(_ who: String, value: Binding<Int>, winning: Bool, id: String) -> some View {
        VStack(spacing: 6) {
            Text(who.sentenceCased).font(SnappetType.label)
                .foregroundStyle(SnappetColor.textSecondary).lineLimit(1)
            Text("\(value.wrappedValue)")
                .font(.system(size: 52, weight: .light)).monospacedDigit()
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
            Text("\(ex.drillMeasure == .time ? "Block" : ex.drillMeasure.label) · block \(ex.sets.count + 1)".sentenceCased)
                .font(SnappetType.label)
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
                    .font(.system(size: 40, weight: .light)).monospacedDigit()
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
            .buttonStyle(SnappetWidePrimaryStyle())
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
                            .font(.caption.weight(.medium))
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
                Text(label.sentenceCased).font(SnappetType.label)
                    .foregroundStyle(SnappetColor.textSecondary)
                Text("\(value.wrappedValue)")
                    .font(.system(size: 34, weight: .light)).monospacedDigit()
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
    /// Tapping a game row: the host presents the sheet (session detail — outside its lazy list); `nil` = this card does.
    var onOpenGame: ((RacketGameTarget) -> Void)? = nil
    /// Your videos / Keep rallies only (TtSessionRecap, prompt 246): the host presents them (session detail — outside its
    /// lazy list); `nil` = this card does.
    var onOpenVideos: ((RacketVideosTarget) -> Void)? = nil
    /// "Make a reel" (TtSessionRecap, prompt 249): the host opens the session in Studio; nil ⇒ hidden.
    var onMakeReel: (() -> Void)? = nil
    @State private var gameTarget: RacketGameTarget?
    @State private var videos: RacketVideosTarget?

    private var summary: RacketStats.SessionSummary? { RacketStats.summary(session.exercises) }
    private var hasRecordings: Bool { session.exercises.contains { $0.discipline == .racket && $0.racketRecordingLog != nil } }
    private var matches: [SessionExercise] { session.exercises.filter(\.isRacketMatch) }
    private var drills: [SessionExercise] { session.exercises.filter(\.isRacketDrill) }

    var body: some View {
        if let summary {
            VStack(alignment: .leading, spacing: 12) {
                header(summary)
                ForEach(matches) { matchRow($0) }
                ForEach(drills) { drillRow($0) }
                if hasRecordings || onMakeReel != nil { videoActions }
                if showsHR { hrSection }
            }
            .snappetPanel()
            .sheet(item: $gameTarget) { RacketGameHRSheet(session: session, target: $0, maxHR: maxHR) }
            .fullScreenCover(item: $videos) { t in
                RacketVideosCover(session: session, start: t.start) { videos = nil }
            }
        }
    }

    private func header(_ s: RacketStats.SessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // Sentence label + a light record (prompt 224 — was racket-colour tracked caps + bold).
            Text([s.event, s.sport?.label].compactMap { $0 }.joined(separator: " · ")).snappetLabel()
            // TtSessionRecap: "1:24:10 · average heart rate 132".
            Text(RacketRecapLine.line(durationSec: (session.completedAt ?? .now).timeIntervalSince(session.startedAt),
                                      bpms: session.hrSeries.map(\.bpm)))
                .font(SnappetType.detail.monospacedDigit()).foregroundStyle(SnappetColor.textSecondary)
                .accessibilityIdentifier("racket.recap.timeLine")
            if s.matches > 0 {
                Text(s.record.label).font(.system(size: 28, weight: .light).monospacedDigit())
                    .accessibilityIdentifier("racket.recap.record")
            }
            Text([s.matches > 0 ? "\(s.matches) \(s.matches == 1 ? "match" : "matches")" : nil,
                  s.units > 0 ? "\(s.units) \(s.sport?.usesSets == true ? "sets" : "games")" : nil,
                  s.drills > 0 ? "\(s.drills) \(s.drills == 1 ? "drill" : "drills")" : nil]
                .compactMap { $0 }.joined(separator: " · "))
                .font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
        }
    }

    private func open(_ start: RacketVideosStart) {
        let t = RacketVideosTarget(start: start)
        if let onOpenVideos { onOpenVideos(t) } else { videos = t }
    }

    /// "Keep rallies only…" and "Your videos" (TtSessionRecap).
    private var videoActions: some View {
        let keep = RacketKeepRallies.plan(session.exercises)
        return HStack(spacing: 10) {
            if keep.canKeep {
                Button("Keep rallies only…") { open(.keepRallies) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("racket.recap.keepRallies")
            }
            if let onMakeReel {
                Button("Make a reel") { onMakeReel() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("racket.recap.reel")
            }
            if hasRecordings {
                Button("Your videos") { open(.videos) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("racket.recap.videos")
            }
        }
        .font(.system(size: 14, weight: .semibold))
    }

    private func matchRow(_ ex: SessionExercise) -> some View {
        let state = ex.racketState
        return HStack(spacing: 10) {
            Image(systemName: ex.racketSport?.symbol ?? "tennis.racket")
                .foregroundStyle(SnappetColor.textSecondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(RacketStats.matchRowTitle(ex)).font(.system(size: 15, weight: .medium)).lineLimit(1)
                Text(ex.sets.isEmpty ? (state.end?.label ?? "Not started") : RacketStats.unitsLine(ex))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                if let v = RacketVideoRows.recapLine(ex) {
                    Text(v).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("racket.recap.videoLine")
                }
            }
            Spacer(minLength: 4)
            Text(state.shortResult)
                .font(.caption.weight(.medium).monospacedDigit())
                .padding(.horizontal, 8).padding(.vertical, 3)
                .foregroundStyle(state.result == true ? SnappetColor.perfFresh
                                 : state.result == false ? SnappetColor.perfHard : SnappetColor.textSecondary)
                .overlay(Capsule().strokeBorder(SnappetColor.hairline))
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("racket.recap.match")
    }

    private func drillRow(_ ex: SessionExercise) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "target").foregroundStyle(SnappetColor.textSecondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(ex.displayName ?? "Drill").font(.system(size: 15, weight: .medium)).lineLimit(1)
                Text(RacketVideoRows.recapLine(ex)
                     ?? "\(ex.completedSetCount) \(ex.completedSetCount == 1 ? "block" : "blocks")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if let line = RacketStats.drillLine(ex) {
                Text(line).font(.caption.weight(.medium).monospacedDigit())
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
            // HRV per game — only with a chest strap's beat-to-beat data; `[:]` otherwise.
            let hrv = HRVReads.perSet(for: session.exercises, sessionStart: session.startedAt,
                                      hr: session.hrSeries.map { HRSample(t: $0.t, bpm: $0.bpm, rrIntervalsMs: $0.rrIntervalsMs) })
            ForEach(rows.filter { !$0.hr.isEmpty }, id: \.ex.id) { row in
                VStack(alignment: .leading, spacing: 6) {
                    Text("Heart rate · \(RacketStats.matchRowTitle(row.ex))").snappetLabel()
                    ForEach(row.hr, id: \.index) { u in
                        unitHRRow(row.ex, u, hrv: hrv[.init(exerciseID: row.ex.id, setIndex: u.index)] ?? .empty)
                    }
                }
            }
        }
    }

    private func unitHRRow(_ ex: SessionExercise, _ u: RacketStats.UnitHR, hrv: HRVMetrics) -> some View {
        let unit = ex.racketFormat.sport.unit
        let score = u.index < ex.sets.count ? ex.sets[u.index].racketScoreState?.label : nil
        let total = max(1, u.zoneSeconds.reduce(0, +))
        return Button {
            let t = RacketGameTarget(exerciseID: ex.id, index: u.index)
            if let onOpenGame { onOpenGame(t) } else { gameTarget = t }
        } label: {
            HStack(spacing: 8) {
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
                if let rmssd = hrv.rmssd {
                    Text("\(Int(rmssd.rounded())) ms").font(.caption2.weight(.medium).monospacedDigit())
                        .foregroundStyle(HRVBadge.recoveryColor(rmssd))
                        .accessibilityIdentifier("racket.recap.unitHRV")
                }
                Text("avg \(Int(u.avg.rounded()))").font(.caption.weight(.medium).monospacedDigit())
                    .frame(width: 60, alignment: .trailing)
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(SnappetColor.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

private extension String {
    /// "Set 2 · in play" — the first letter up, the rest as written (prompt 223 — the heroes were tracked ALL CAPS).
    var sentenceCased: String { prefix(1).uppercased() + dropFirst() }
}
