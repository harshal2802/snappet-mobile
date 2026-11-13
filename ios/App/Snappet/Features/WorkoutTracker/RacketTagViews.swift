import SwiftUI
import AVFoundation

// MARK: - Tagging with the rally's video (prompt 251, issue #438)
//
// QuickTag / XxTag / XxNoModelTag / DoublesTag (the tag sheet), FixRally / XxFix (fix or add a rally), RallyRules /
// XxRules, ShotTags / DoublesShots (every shot, by hand) and LiveTag (the last rally, from the recording screen).
// Device feedback: a rally was tagged blind twice — every tag and fix screen now shows the rally's own video at the top
// (`RacketRallyVideo`), looping it, and the fix sheet's frame follows the handle being dragged. Pure logic in
// `RacketTagFlow.swift` / `RacketRallyTags.swift`.

// MARK: - The rally's video (loops the rally, padded a second each side)

struct RacketRallyVideo: View {
    let log: RacketRecordingLog?
    let partStart: Double
    let partEnd: Double
    /// The stretch to loop (recording time); changes when the sheet moves to another rally.
    let range: ClosedRange<Double>?
    var sport: RacketSport = .tableTennis
    var height: CGFloat = 190

    @State private var playback: RacketPlayback?
    @State private var looping = true

    private var loop: ClosedRange<Double>? {
        range.map { max(partStart, $0.lowerBound - 1)...min(partEnd, $0.upperBound + 1) }
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let pb = playback {
                RacketVideoSurface(playback: pb, sport: sport, height: height)
                Button {
                    if pb.playing { looping = false; pb.pause() } else { looping = true; replay() }
                } label: {
                    Label(pb.playing ? "Pause" : "Replay", systemImage: pb.playing ? "pause.fill" : "arrow.counterclockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.black.opacity(0.6), in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(8)
                .accessibilityIdentifier("racket.rallyVideo.play")
            } else {
                Color(white: 0.11).frame(height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("racket.rallyVideo")
        .task {
            guard playback == nil else { return }
            let pb = RacketPlayback(partStart: partStart, partEnd: partEnd, startAt: loop?.lowerBound)
            playback = pb
            if let log { await pb.load(RacketVideoMap.segments(start: partStart, end: partEnd, log: log)) }
            replay()
        }
        .task(id: "\(range?.lowerBound ?? -1)-\(range?.upperBound ?? -1)") {
            // A new rally: play it from its start. Then keep looping until Pause.
            looping = true
            replay()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let pb = playback, let l = loop, looping, !pb.playing else { continue }
                if pb.position >= l.upperBound - 0.15 || pb.position < l.lowerBound - 0.05 { replay() }
            }
        }
        .onDisappear { playback?.stop() }
    }

    private func replay() {
        guard let pb = playback, let l = loop else { return }
        pb.play(from: l.lowerBound, until: l.upperBound)
    }
}

// MARK: - The tag sheet (QuickTag · XxTag · XxNoModelTag · DoublesTag)

struct RacketTagSheet: View {
    let store: RacketVideoStore
    let ref: RacketPartRef
    let startID: UUID
    /// "Check N unsure rallies" (prompt 248): walk only Snappet's unsure guesses.
    var unsureOnly = false
    /// `true` when the last untagged rally was tagged (→ TtTagDone).
    let onClose: (Bool) -> Void

    @State private var currentID: UUID?
    @State private var winner: RacketRallyWinner?
    @State private var ending: RacketRallyEnding?
    @State private var lastShot: String?
    @State private var rules = false
    /// TnServe / PdWall (prompt 252): the rally's serve and wall answers, saved with the tag.
    @State private var serve: RacketServeOutcome?
    @State private var wall: RacketWallBounce?
    /// The sport's detail board open over the tag sheet (TnServe / PdWall / SqLet).
    @State private var detail: RacketTagDetail?
    /// Unsure guesses in the part when the sheet opened, and how many are checked since.
    @State private var unsureTotal = 0
    @State private var unsureDone = 0

    private var ex: SessionExercise? { store.ex(ref.exerciseID) }
    private var log: RacketRecordingLog? { ex?.racketRecordingLog }
    private var rallies: [RacketRally] {
        RacketRallyMarking.inRange(log?.allRallies ?? [], ref.startSec, ref.endSec).filter(\.isRally)
    }
    private var sport: RacketSport { ex?.racketSport ?? .tableTennis }
    private var doubles: Bool { ex?.isDoubles ?? false }
    private var current: RacketRally? { rallies.first { $0.id == (currentID ?? startID) } }
    /// The part has Snappet's guesses (or this rally is one): the XxTag board; otherwise XxNoModelTag.
    private var modelPath: Bool { rallies.contains(where: \.isFromModel) }

    private var players: [String] {
        var names = ["You"]
        if let p = ex?.partner, !p.isEmpty { names.append(p) }
        return names + RacketOpponentTeam.players(player1: ex?.racketOpponentPlayer1, player2: ex?.racketOpponentPlayer2,
                                                  team: ex?.opponent)
    }

    var body: some View {
        let sides = RacketWatchCopy.sides(opponent: ex?.opponent, doubles: doubles)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let r = current {
                        RacketRallyVideo(log: log, partStart: ref.startSec, partEnd: ref.endSec,
                                         range: r.startSec...r.endSec, sport: sport)
                        topLine(r, sides: sides)
                        Text(sport == .tableTennis && (modelPath || doubles) ? "Who won the point?" : "Who won the rally?")
                            .font(.system(size: 17, weight: .bold))
                        HStack(spacing: 8) {
                            pick(sides.us + (r.guessWinner == .us && r.isGuess ? " · suggested" : ""), winner == .us,
                                 id: "racket.tag.winner.us", wide: true) { winner = .us }
                            pick(sides.them + (r.guessWinner == .them && r.isGuess ? " · suggested" : ""), winner == .them,
                                 id: "racket.tag.winner.them", wide: true) { winner = .them }
                        }
                        Text(modelPath || doubles ? "How did it end?" : "How did it end? Optional")
                            .font(.system(size: 17, weight: .bold))
                        if modelPath {
                            // QuickTag preselects Snappet's ending: no model reads endings yet (Capabilities).
                            Text("Ending suggestions: not available yet. Pick one, or leave it.")
                                .font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                                .accessibilityIdentifier("racket.tag.endingNotYet")
                        }
                        FlowRow {
                            ForEach(RacketRallyEnding.choices(for: sport), id: \.self) { e in
                                pick(e.label, ending == e, id: "racket.tag.end.\(e.rawValue)") { ending = ending == e ? nil : e }
                            }
                        }
                        if doubles {
                            Text("Who made the last shot? Optional").font(.system(size: 17, weight: .bold))
                            FlowRow {
                                ForEach(players, id: \.self) { n in
                                    pick(n, lastShot == n, id: "racket.tag.last.\(n)") { lastShot = lastShot == n ? nil : n }
                                }
                                pick("Skip", lastShot == nil, id: "racket.tag.last.skip") { lastShot = nil }
                            }
                        }
                        HStack(spacing: 10) {
                            Button { save(r, notRally: true) } label: {
                                Text("Not a rally").font(.system(size: 17, weight: .semibold)).foregroundStyle(SnappetColor.ink)
                                    .frame(maxWidth: .infinity, minHeight: 50)
                            }
                            .buttonStyle(.plain).pagerOutline()
                            .accessibilityIdentifier("racket.tag.notRally")
                            Button { save(r, notRally: false) } label: {
                                Text("Next").frame(maxWidth: .infinity, minHeight: 30)
                            }
                            .buttonStyle(SnappetWidePrimaryStyle())
                            .accessibilityIdentifier("racket.tag.next")
                        }
                        if !modelPath && !doubles {
                            Text("Nothing is picked for you. Snappet can’t suggest for \(sport.label.lowercased()) yet.")
                                .font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        // XxTag: "What counts as a rally?" and the sport's own link side by side (TnTag "Serve details",
                        // PdTag "Did it bounce first?", SqTag "Let, stroke or no let").
                        HStack(spacing: 16) {
                            Button("What counts as a rally?") { rules = true }
                                .accessibilityIdentifier("racket.tag.rules")
                            if let d = RacketTagDetail.link(for: sport) {
                                Button(d.linkTitle) { detail = d }
                                    .accessibilityIdentifier("racket.tag.detail.\(d.rawValue)")
                            }
                        }
                        .font(.system(size: 15)).underline()
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 20)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(title).font(.system(size: 17, weight: .semibold)).accessibilityIdentifier("racket.tag.title")
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { onClose(false) }.accessibilityIdentifier("racket.tag.close")
                }
                ToolbarItem(placement: .confirmationAction) {
                    // Skip: the next rally, nothing saved.
                    Button("Skip") { advance(after: current?.id) }.accessibilityIdentifier("racket.tag.skip")
                }
            }
            .sheet(isPresented: $rules) { RacketRulesSheet(sport: sport) }
            .sheet(item: $detail) { d in
                if let r = current { detailSheet(d, rally: r, sides: sides) }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            unsureTotal = rallies.filter(\.isUnsure).count
            load(startID)
        }
    }

    private var title: String {
        guard let r = current, let k = rallies.firstIndex(where: { $0.id == r.id }) else { return "Tag a rally" }
        if unsureOnly { return "Unsure \(min(unsureTotal, unsureDone + 1)) of \(unsureTotal)" }
        return modelPath || doubles ? "Rally \(k + 1) of \(rallies.count)" : "Your rally \(k + 1) of \(rallies.count)"
    }

    /// QuickTag / XxTag: "So far 6–5 · Final 11–9" (TT, badminton, squash, pickleball rally scoring), "Games 4–3 · Point
    /// 40–30" (tennis, padel), "4–2–1 · Mia serving next" (pickleball side-out, prompt 252); DoublesTag: the same score
    /// with the serve line ("Mia serving", "Mia serving, right court", "Mia, server 2"); NoModelTag: "Marked 2:41–2:49 ·
    /// No suggestions".
    @ViewBuilder private func topLine(_ r: RacketRally, sides: (us: String, them: String)) -> some View {
        if modelPath || doubles {
            let line = scoreLine(r, sides: sides)
            HStack(alignment: .firstTextBaseline) {
                if let left = line.left {
                    Text(left).font(.system(size: 14, weight: .semibold))
                        .accessibilityIdentifier("racket.tag.soFar")
                }
                Spacer(minLength: 6)
                if let right = line.right {
                    Text(right).font(.system(size: 14)).foregroundStyle(SnappetColor.textSecondary)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier(line.rightID)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Marked \(RacketVideoTime.clock(r.startSec - ref.startSec))–\(RacketVideoTime.clock(r.endSec - ref.startSec))")
                    .font(.system(size: 22, weight: .light)).monospacedDigit()
                    .accessibilityIdentifier("racket.tag.marked")
                Text("No suggestions").snappetLabel()
            }
        }
    }

    /// "Final 11–9": the game's score, when it has one.
    private var finalLine: String? {
        guard let i = ref.setIndex, let ex, i < ex.sets.count, let s = ex.sets[i].racketScore else { return nil }
        return "Final \(s.label)"
    }

    private func servingLine(_ r: RacketRally, sides: (us: String, them: String)) -> String? {
        RacketTagScore.servingLine(sport: sport, firstServer: ex?.racketFirstServerRaw.flatMap(RacketServe.Side.init(rawValue:)),
                                   unitIndex: ref.setIndex, previous: ex?.racketUnits ?? [], rallyID: r.id,
                                   rallies: rallies, sides: sides, rules: ref.setIndex.flatMap { ex?.racketLiveRules(unitIndex: $0) },
                                   ourFirst: ex?.racketOurFirstServer, partner: ex?.partner, doubles: doubles)
    }

    /// The doubles serve line, or why it isn't known.
    private func doublesServeText(_ r: RacketRally, sides: (us: String, them: String)) -> String {
        servingLine(r, sides: sides) ?? (ex?.racketFirstServerRaw == nil ? "Serving: choose who serves first at warmup"
                                                                         : "Serving: not known until this is a game")
    }

    /// The tag sheet's score line for this sport: left (bold) and right (grey) with the right side's identifier.
    private func scoreLine(_ r: RacketRally, sides: (us: String, them: String)) -> (left: String?, right: String?, rightID: String) {
        let rules = ref.setIndex.flatMap { ex?.racketLiveRules(unitIndex: $0) }
        let before = RacketTagScore.points(before: r.id, in: rallies)
        if sport.usesSets {
            guard let rules else {
                return (nil, doubles ? doublesServeText(r, sides: sides) : nil, "racket.tag.serving")
            }
            let l = RacketTagSportLine.sets(rules: rules, points: before)
            return doubles ? (l.games, doublesServeText(r, sides: sides), "racket.tag.serving") : (l.games, l.point, "racket.tag.point")
        }
        if sport == .pickleball, let rules, rules.isSideOut, let i = ref.setIndex {
            let l = RacketTagSportLine.pickleball(rules: rules, pointsBefore: before, winner: winner.map { $0 == .us ? .us : .them },
                                                  ourFirst: ex?.racketOurFirstServer, unitIndex: i, partner: ex?.partner,
                                                  sides: sides, doubles: doubles)
            return (l.call, l.serve.isEmpty ? nil : l.serve, "racket.tag.serving")
        }
        let soFar = RacketTagScore.soFar(before: r.id, in: rallies)
        let left = "So far \(soFar.us)–\(soFar.them)"
        if doubles { return (left, doublesServeText(r, sides: sides), "racket.tag.serving") }
        return (left, finalLine, "racket.tag.final")
    }

    // MARK: TnServe · PdWall · SqLet (prompt 252)

    @ViewBuilder private func detailSheet(_ d: RacketTagDetail, rally r: RacketRally, sides: (us: String, them: String)) -> some View {
        let number = (rallies.firstIndex { $0.id == r.id } ?? 0) + 1
        let video = RacketRallyVideo(log: log, partStart: ref.startSec, partEnd: ref.endSec, range: r.startSec...r.endSec,
                                     sport: sport, height: d == .serve ? 190 : 200)
        switch d {
        case .serve:
            let rules = ref.setIndex.flatMap { ex?.racketLiveRules(unitIndex: $0) }
            let before = RacketTagScore.points(before: r.id, in: rallies)
            let t = rules.map { RacketLiveScore(rules: $0, points: before).tally }
            let server = rules.flatMap { _ in serverSide(r) }
            RacketServeSheet(number: number, video: video,
                             gameLine: t.map { "Game \($0.gamesFor)–\($0.gamesAgainst)" },
                             servingLine: servingWho(r, sides: sides),
                             sides: sides, serve: serve, winner: winner, server: server,
                             onNextPoint: { o, w in
                                 serve = o
                                 let implied = o.map { RacketServeOutcome.implied($0, server: server) }
                                 winner = w ?? implied?.winner
                                 if let e = implied?.ending { ending = e }
                                 if o == .letReplay { winner = nil }
                                 detail = nil
                                 save(r, notRally: false)
                             },
                             onSkip: { detail = nil; advance(after: r.id) },
                             onClose: { detail = nil })
        case .wall:
            RacketChoiceDetailSheet(title: "Rally \(number)", video: video, question: "Did the ball bounce first?",
                                    options: RacketWallBounce.allCases.map { ($0.rawValue, $0.title, $0.subtitle) },
                                    selected: wall?.rawValue, footnote: nil, idPrefix: "racket.wall",
                                    onNext: { raw in
                                        if let w = raw.flatMap(RacketWallBounce.init(rawValue:)) {
                                            wall = w
                                            ending = RacketWallBounce.ending(w, current: ending)
                                        }
                                        detail = nil
                                    },
                                    onSkip: { detail = nil; advance(after: r.id) },
                                    onClose: { detail = nil })
        case .letCall:
            RacketChoiceDetailSheet(title: "Rally \(number)", video: video, question: "Was there interference?",
                                    options: RacketLetCall.allCases.map { ($0.rawValue, $0.title, $0.subtitle) },
                                    selected: RacketLetCall(ending: ending)?.rawValue, footnote: RacketLetCall.footnote,
                                    idPrefix: "racket.let",
                                    onNext: { raw in
                                        if let c = raw.flatMap(RacketLetCall.init(rawValue:)) {
                                            ending = c.ending
                                            if c == .letReplay { winner = nil }
                                        }
                                        detail = nil
                                    },
                                    onSkip: { detail = nil; advance(after: r.id) },
                                    onClose: { detail = nil })
        }
    }

    /// Who serves this rally, by side (TnServe), from Warmup's "Who serves first?" and your tags before it.
    private func serverSide(_ r: RacketRally) -> RacketServe.Side? {
        guard let i = ref.setIndex, let ex else { return nil }
        return RacketServe.server(sport: sport, firstServer: ex.racketFirstServerRaw.flatMap(RacketServe.Side.init(rawValue:)),
                                  unitIndex: i, previous: Array(ex.racketUnits.prefix(i)),
                                  points: RacketTagScore.points(before: r.id, in: rallies), rules: ex.racketLiveRules(unitIndex: i))
    }

    /// TnServe's "You’re serving" (doubles: "Mia serving"); why not, when it isn't known.
    private func servingWho(_ r: RacketRally, sides: (us: String, them: String)) -> String {
        guard let i = ref.setIndex, let ex else { return "Serving: not known until this is a set" }
        guard let info = RacketDoublesServe.info(sport: sport, rules: ex.racketLiveRules(unitIndex: i),
                                                 firstServer: ex.racketFirstServerRaw.flatMap(RacketServe.Side.init(rawValue:)),
                                                 ourFirst: ex.racketOurFirstServer, unitIndex: i,
                                                 previous: Array(ex.racketUnits.prefix(i)),
                                                 points: RacketTagScore.points(before: r.id, in: rallies), doubles: doubles)
        else { return "Serving: choose who serves first at warmup" }
        return RacketServeCopy.serving(RacketServeCopy.who(info, partner: ex.partner, sides: sides))
    }

    private func load(_ id: UUID) {
        currentID = id
        let r = rallies.first { $0.id == id }
        // A guess with a score tap behind it starts on the suggested winner (QuickTag "You · suggested").
        winner = r?.winner ?? (r?.isGuess == true ? r?.guessWinner : nil)
        ending = r?.ending
        lastShot = r?.lastShotBy
        serve = r?.serve
        wall = r?.wall
    }

    private func save(_ r: RacketRally, notRally: Bool) {
        let all = log?.allRallies ?? []
        let updated = RacketRallyMarking.tag(all, id: r.id, winner: winner, ending: ending, lastShotBy: lastShot, notRally: notRally,
                                             serve: .some(serve), wall: .some(wall))
        store.updateLog(ref.exerciseID) { $0.rallies = updated }
        Haptics.tap()
        if unsureOnly { unsureDone += 1 }
        advance(after: r.id, afterSave: true)
    }

    private func advance(after id: UUID?, afterSave: Bool = false) {
        let nextOne = unsureOnly ? RacketRallyMarking.nextUnsure(rallies, after: id) : RacketRallyMarking.nextUntagged(rallies, after: id)
        if unsureOnly, nextOne == nil, !afterSave { onClose(false); return }
        if let next = nextOne {
            load(next.id)
        } else if afterSave {
            onClose(true)
        } else if let id, let k = rallies.firstIndex(where: { $0.id == id }), k + 1 < rallies.count {
            load(rallies[k + 1].id)
        } else {
            onClose(false)
        }
    }

    private func pick(_ label: String, _ selected: Bool, id: String, wide: Bool = false,
                      action: @escaping () -> Void) -> some View {
        RacketTagChip(label: label, selected: selected, id: id, wide: wide, action: action)
    }
}

/// The boards' tag chip: an outlined rounded rectangle, accent-tinted when picked.
struct RacketTagChip: View {
    let label: String
    let selected: Bool
    let id: String
    var wide = false
    var dashed = false
    let action: () -> Void

    var body: some View {
        Button(action: { action(); Haptics.tap() }) {
            Text(label).font(.system(size: 15, weight: .semibold))
                .foregroundStyle(selected ? SnappetColor.brand : SnappetColor.ink)
                .padding(.horizontal, 13)
                .frame(maxWidth: wide ? .infinity : nil, minHeight: 44)
                .background(selected ? SnappetColor.brand.opacity(0.12) : Color(white: 0.08),
                            in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(selected ? SnappetColor.brand : SnappetColor.hairline,
                                  style: StrokeStyle(lineWidth: 1.5, dash: dashed && !selected ? [4, 3] : [])))
                .fixedSize(horizontal: !wide, vertical: true)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - RallyRules / XxRules ("What counts as a rally")

struct RacketRulesSheet: View {
    let sport: RacketSport
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let sheet = RacketRallyRules.sheet(for: sport)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(sheet.intro).font(.system(size: 15)).foregroundStyle(SnappetColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 10)
                        .accessibilityIdentifier("racket.rules.intro")
                    ForEach(Array(sheet.rows.enumerated()), id: \.offset) { k, row in
                        HStack(alignment: .firstTextBaseline) {
                            Text(row.what).font(.system(size: 15, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            Text(row.result).font(.system(size: 14, weight: .semibold)).foregroundStyle(SnappetColor.textSecondary)
                                .multilineTextAlignment(.trailing)
                        }
                        .padding(.vertical, 9)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("racket.rules.row.\(k)")
                        Divider().overlay(SnappetColor.hairline)
                    }
                    Text(sheet.footer).font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 12)
                        .accessibilityIdentifier("racket.rules.footer")
                }
                .padding(16)
            }
            .navigationTitle("What counts as a rally")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.accessibilityIdentifier("racket.rules.close")
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - FixRally / XxFix (fix a rally, or add a missed one)

struct RacketFixRallySheet: View {
    let rally: RacketRally
    /// The part's rallies (without `rally` when adding).
    let rallies: [RacketRally]
    let lo: Double
    let hi: Double
    var log: RacketRecordingLog? = nil
    var sport: RacketSport = .tableTennis
    /// "+ Add a missed rally": `rally` is new.
    var adding = false
    let onSave: ([RacketRally]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var work: [RacketRally] = []
    @State private var configured = false
    @State private var playback: RacketPlayback?
    @State private var stripWidth: CGFloat = 320

    private var current: RacketRally? { work.first { $0.id == rally.id } }
    private var number: Int {
        (work.filter(\.isRally).sorted { $0.startSec < $1.startSec }.firstIndex { $0.id == rally.id } ?? 0) + 1
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let r = current {
                        if let pb = playback {
                            RacketVideoSurface(playback: pb, sport: sport, height: 190)
                                .overlay(alignment: .bottomTrailing) {
                                    Button(pb.playing ? "Pause" : "Play") {
                                        if pb.playing { pb.pause() } else {
                                            pb.play(from: pb.position >= r.endSec - 0.1 ? r.startSec : pb.position, until: r.endSec)
                                        }
                                    }
                                    .font(.system(size: 13, weight: .semibold))
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(.black.opacity(0.6), in: Capsule())
                                    .padding(8)
                                    .accessibilityIdentifier("racket.fix.play")
                                }
                                .accessibilityIdentifier("racket.fix.video")
                        }
                        Text("Drag to where it starts and ends").font(.system(size: 17, weight: .bold))
                        RacketRangeStrip(start: r.startSec, end: r.endSec, window: window(r), playhead: playback?.position,
                                         onHandleEnded: { isStart in
                                             guard let c = current else { return }
                                             playback?.seek(to: isStart ? c.startSec : c.endSec)
                                         },
                                         onScrub: { t, ended in
                                             if ended { playback?.seek(to: t) } else { playback?.scrub(to: t, tolerance: tolerance(r)) }
                                         }) { s, e in
                            let before = current
                            if let next = RacketRallyMarking.fix(work, id: r.id, start: s, end: e, within: lo, hi) { work = next }
                            // The frame follows the handle being dragged.
                            if let before, let after = current, let pb = playback {
                                if after.startSec != before.startSec { pb.scrub(to: after.startSec, tolerance: tolerance(r)) }
                                else if after.endSec != before.endSec { pb.scrub(to: after.endSec, tolerance: tolerance(r)) }
                            }
                        }
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { stripWidth = $0 }
                        .accessibilityIdentifier("racket.fix.strip")
                        HStack {
                            Text(RacketVideoTime.precise(r.startSec - lo)).accessibilityIdentifier("racket.fix.start")
                            Spacer()
                            Text("Length \(RacketTagSummary.seconds(r.durationSec))").accessibilityIdentifier("racket.fix.length")
                            Spacer()
                            Text(RacketVideoTime.precise(r.endSec - lo))
                        }
                        .font(SnappetType.detail.monospacedDigit()).foregroundStyle(SnappetColor.textSecondary)
                        nudge("Start", r, edge: 0)
                        nudge("End", r, edge: 1)
                        HStack(spacing: 10) {
                            outline("Split in two", id: "racket.fix.split") { work = RacketRallyMarking.splitInTwo(work, id: r.id) }
                            outline("Merge with next", id: "racket.fix.merge") { work = RacketRallyMarking.mergeWithNext(work, id: r.id) }
                        }
                        Button {
                            work = RacketRallyMarking.tag(work, id: r.id, winner: nil, ending: nil, lastShotBy: nil, notRally: true)
                            onSave(work); dismiss()
                        } label: {
                            Text("Not a rally").font(.system(size: 17, weight: .semibold)).foregroundStyle(SnappetColor.perfHard)
                                .frame(maxWidth: .infinity, minHeight: 46)
                                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .strokeBorder(SnappetColor.perfHard.opacity(0.5), lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("racket.fix.notRally")
                        Text("What went wrong? Optional").font(.system(size: 17, weight: .bold))
                        FlowRow {
                            ForEach(RacketFixReason.allCases, id: \.self) { reason in
                                RacketTagChip(label: reason.label(sport), selected: r.fixReasonsRaw?.contains(reason.rawValue) == true,
                                              id: "racket.fix.reason.\(reason.rawValue)") {
                                    work = work.map { q in
                                        guard q.id == r.id else { return q }
                                        var x = q
                                        x.fixReasonsRaw = RacketFixReason.toggled(q.fixReasonsRaw, reason)
                                        return x
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 20)
            }
            .navigationTitle(adding ? "Add a rally" : "Fix rally \(number)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.accessibilityIdentifier("racket.fix.cancel") }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(work); dismiss() }.accessibilityIdentifier("racket.fix.save")
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            guard !configured else { return }
            configured = true
            work = adding ? RacketRallyMarking.insert(rally, into: rallies) : rallies
        }
        .task {
            guard playback == nil else { return }
            let pb = RacketPlayback(partStart: lo, partEnd: hi, startAt: rally.startSec)
            playback = pb
            if let log { await pb.load(RacketVideoMap.segments(start: lo, end: hi, log: log)) }
            pb.seek(to: current?.startSec ?? rally.startSec)
        }
        .onDisappear { playback?.stop() }
    }

    private func window(_ r: RacketRally) -> ClosedRange<Double> {
        max(lo, r.startSec - 10)...max(max(lo, r.startSec - 10) + 1, min(hi, r.endSec + 10))
    }

    private func tolerance(_ r: RacketRally) -> Double {
        let w = window(r)
        return RacketScrub.tolerance(windowSec: w.upperBound - w.lowerBound, widthPoints: Double(stripWidth))
    }

    private func outline(_ label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 15, weight: .semibold)).foregroundStyle(SnappetColor.ink)
                .frame(maxWidth: .infinity, minHeight: 46)
        }
        .buttonStyle(.plain).pagerOutline()
        .accessibilityIdentifier(id)
    }

    private func nudge(_ label: String, _ r: RacketRally, edge: Int) -> some View {
        HStack(spacing: 6) {
            Text(label).font(SnappetType.body)
            Spacer()
            ForEach([-1.0, -0.2, 0.2, 1.0], id: \.self) { d in
                Button(d > 0 ? "+\(d.formatted()) s" : "−\((-d).formatted()) s") {
                    let s = edge == 0 ? r.startSec + d : r.startSec
                    let e = edge == 1 ? r.endSec + d : r.endSec
                    if let next = RacketRallyMarking.fix(work, id: r.id, start: s, end: e, within: lo, hi) {
                        work = next
                        playback?.seek(to: edge == 0 ? s : e)
                    }
                }
                .buttonStyle(.bordered).font(.caption)
                .accessibilityIdentifier("racket.fix.\(edge == 0 ? "start" : "end").\(d)")
            }
        }
    }
}

// MARK: - ShotTags / DoublesShots (every shot, by hand)

struct RacketShotsScreen: View {
    let store: RacketVideoStore
    let ref: RacketPartRef
    let rallyID: UUID
    /// Save → Timeline (Shots → Timeline on the boards).
    let onSaved: () -> Void

    @State private var shots: [RacketShot] = []
    @State private var configured = false

    private var ex: SessionExercise? { store.ex(ref.exerciseID) }
    private var log: RacketRecordingLog? { ex?.racketRecordingLog }
    private var rallies: [RacketRally] { RacketRallyMarking.inRange(log?.allRallies ?? [], ref.startSec, ref.endSec).filter(\.isRally) }
    private var rally: RacketRally? { rallies.first { $0.id == rallyID } }
    private var number: Int { (rallies.firstIndex { $0.id == rallyID } ?? 0) + 1 }
    private var sport: RacketSport { ex?.racketSport ?? .tableTennis }
    private var doubles: Bool { ex?.isDoubles ?? false }

    var body: some View {
        let sides = RacketWatchCopy.sides(opponent: ex?.opponent, doubles: doubles)
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                RacketRallyVideo(log: log, partStart: ref.startSec, partEnd: ref.endSec,
                                 range: rally.map { $0.startSec...$0.endSec }, sport: sport)
                HStack(alignment: .firstTextBaseline) {
                    Text("\(shots.count) \(shots.count == 1 ? "shot" : "shots")").font(.system(size: 17, weight: .bold))
                        .accessibilityIdentifier("racket.shots.count")
                    Spacer(minLength: 6)
                    // "7 shots found · Dashed: Snappet's guess": no model finds shots yet (Capabilities).
                    Text("Shot finding: not available yet").font(.system(size: 13)).foregroundStyle(SnappetColor.textSecondary)
                        .accessibilityIdentifier("racket.shots.notYet")
                }
                if doubles {
                    Text("Sides are filled in. Naming each player is optional.")
                        .font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                }
                if shots.isEmpty {
                    Text("Add each shot as you watch: who hit it, forehand or backhand, and the shot.")
                        .font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(shots.enumerated()), id: \.element.id) { k, s in
                    row(k, s, sides: sides)
                }
                Button { shots = RacketShotTagging.adding(to: shots) } label: {
                    Text("+ Add a shot").font(.system(size: 15, weight: .semibold)).foregroundStyle(SnappetColor.ink)
                        .frame(maxWidth: .infinity, minHeight: 46)
                }
                .buttonStyle(.plain).pagerOutline()
                .accessibilityIdentifier("racket.shots.add")
            }
            .padding(.horizontal, 16).padding(.bottom, 20)
        }
        .navigationTitle("Rally \(number) shots")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }.accessibilityIdentifier("racket.shots.save")
            }
        }
        .onAppear {
            guard !configured else { return }
            configured = true
            shots = rally?.shots ?? []
        }
    }

    @ViewBuilder private func row(_ k: Int, _ s: RacketShot, sides: (us: String, them: String)) -> some View {
        HStack(spacing: 8) {
            Text("\(k + 1)").font(.system(size: 15, weight: .semibold)).foregroundStyle(SnappetColor.textSecondary)
                .frame(width: 20, alignment: .leading)
            Button { shots = RacketShotTagging.swapSide(shots, id: s.id) } label: {
                Text(s.side == .us ? sides.us : sides.them).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(SnappetColor.ink).frame(width: 48, alignment: .leading).lineLimit(1)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("racket.shots.side.\(k)")
            if doubles {
                let names = RacketShotTagging.players(side: s.side, partner: ex?.partner,
                                                      opponents: RacketOpponentTeam.players(player1: ex?.racketOpponentPlayer1,
                                                                                           player2: ex?.racketOpponentPlayer2,
                                                                                           team: ex?.opponent))
                Menu {
                    Button("Not named") { shots = RacketShotTagging.setPlayer(shots, id: s.id, player: nil) }
                    ForEach(names, id: \.self) { n in
                        Button(n) { shots = RacketShotTagging.setPlayer(shots, id: s.id, player: n) }
                    }
                } label: { chipLabel(s.player ?? "Player?", dashed: s.player == nil, minWidth: 64) }
                .accessibilityIdentifier("racket.shots.player.\(k)")
            } else {
                Button { shots = RacketShotTagging.toggleHand(shots, id: s.id) } label: { chipLabel(s.handLabel, dashed: false, minWidth: 40) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("racket.shots.hand.\(k)")
            }
            Menu {
                ForEach(RacketShotType.choices(for: sport), id: \.self) { t in
                    Button(t) { shots = RacketShotTagging.setType(shots, id: s.id, type: t) }
                }
                Divider()
                Button("Remove this shot", role: .destructive) { shots = RacketShotTagging.remove(shots, id: s.id) }
            } label: { chipLabel(s.type ?? "Choose", dashed: s.type == nil, minWidth: 0).frame(maxWidth: .infinity) }
            .accessibilityIdentifier("racket.shots.type.\(k)")
        }
        .accessibilityElement(children: .contain)
    }

    private func chipLabel(_ text: String, dashed: Bool, minWidth: CGFloat) -> some View {
        Text(text).font(.system(size: 15, weight: .semibold)).foregroundStyle(dashed ? SnappetColor.textSecondary : SnappetColor.ink)
            .padding(.horizontal, 10)
            .frame(minWidth: minWidth, maxWidth: minWidth == 0 ? .infinity : nil, minHeight: 44)
            .background(Color(white: 0.08), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(SnappetColor.hairline, style: StrokeStyle(lineWidth: 1.5, dash: dashed ? [4, 3] : [])))
    }

    private func save() {
        let stored = RacketShotTagging.stored(shots)
        store.updateLog(ref.exerciseID) { l in
            l.rallies = l.allRallies.map { r in guard r.id == rallyID else { return r }; var q = r; q.shots = stored; return q }
        }
        Haptics.success()
        onSaved()
    }
}

// MARK: - LiveTag (tag the last rally right after it, from the recording screen)

/// The recording screens' "Tag last rally": no live rally finding, so the last rally is the stretch since the last
/// score tap or tag (`RacketLiveTag`). The camera preview stays at the top (the screen's one preview slot).
struct RacketLiveTagPanel: View {
    let sport: RacketSport
    let sides: (us: String, them: String)
    let number: Int
    let lengthSec: Double
    let onDone: (_ winner: RacketRallyWinner?, _ ending: RacketRallyEnding?, _ notRally: Bool) -> Void
    let onCancel: () -> Void

    @State private var winner: RacketRallyWinner?
    @State private var ending: RacketRallyEnding?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Rally \(number) ended").font(.system(size: 20, weight: .bold)).accessibilityIdentifier("racket.liveTag.title")
                Spacer()
                Button("Cancel", action: onCancel).font(.system(size: 15)).accessibilityIdentifier("racket.liveTag.cancel")
            }
            // "about 5 shots · 6 s": shot count isn't available yet; the length is the stretch tagged.
            Text("Shot count not available yet · last \(Int(lengthSec.rounded())) s")
                .font(.system(size: 14)).foregroundStyle(SnappetColor.textSecondary)
                .accessibilityIdentifier("racket.liveTag.line")
            Text(sport == .tableTennis ? "Who won the point?" : "Who won the rally?").font(.system(size: 17, weight: .bold))
            HStack(spacing: 8) {
                RacketTagChip(label: sides.us, selected: winner == .us, id: "racket.liveTag.winner.us", wide: true) { winner = .us }
                RacketTagChip(label: sides.them, selected: winner == .them, id: "racket.liveTag.winner.them", wide: true) { winner = .them }
            }
            Text("How did it end?").font(.system(size: 17, weight: .bold))
            FlowRow {
                ForEach(RacketRallyEnding.choices(for: sport), id: \.self) { e in
                    RacketTagChip(label: e.label, selected: ending == e, id: "racket.liveTag.end.\(e.rawValue)") {
                        ending = ending == e ? nil : e
                    }
                }
            }
            HStack(spacing: 10) {
                Button { onDone(nil, nil, true) } label: {
                    Text("Not a rally").font(.system(size: 17, weight: .semibold)).foregroundStyle(SnappetColor.ink)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.plain).pagerOutline()
                .accessibilityIdentifier("racket.liveTag.notRally")
                Button { onDone(winner, ending, false) } label: { Text("Done").frame(maxWidth: .infinity, minHeight: 30) }
                    .buttonStyle(SnappetWidePrimaryStyle())
                    .accessibilityIdentifier("racket.liveTag.done")
            }
            Text("Closes when you tap Done. Anything left untagged can wait until after the \(sport.unit.noun).")
                .font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - EditScore / XxEditScore ("Which game", from Your videos, the summary and the split)

enum RacketEditScoreCopy {
    /// "Game 1 · confirmed" / "Game 2 · unconfirmed" / "Game 3 · no score".
    static func chip(_ state: RacketScoreState?, unit: RacketUnit, index: Int) -> String {
        let name = "\(unit.noun.capitalized) \(index + 1)"
        switch state {
        case .confirmed: return "\(name) · confirmed"
        case .fromWatch: return "\(name) · unconfirmed"
        case .unconfirmed, nil: return "\(name) · no score"
        }
    }

    /// "From your Watch" + the Unconfirmed badge; "No score yet"; "Confirmed".
    static func source(_ state: RacketScoreState?) -> (line: String, unconfirmed: Bool) {
        switch state {
        case .confirmed: return ("Confirmed", false)
        case .fromWatch: return ("From your Watch", true)
        case .unconfirmed, nil: return ("No score yet", true)
        }
    }
}

struct RacketEditScoreSheet: View {
    let ex: SessionExercise
    /// The game tapped (the sheet opens on it).
    let unitIndex: Int
    let onSave: (Int, SetLog) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var mine = 0
    @State private var theirs = 0
    @State private var tbMine = 7
    @State private var tbTheirs = 5
    @State private var configured = false

    private var format: RacketFormat { ex.racketFormat }
    private var unit: RacketUnit { format.sport.unit }
    private var isSTB: Bool { format.isSuperTiebreak(index: index) }
    private var needsTB: Bool { !isSTB && format.sport.usesSets && RacketScoring.needsTiebreak(mine, theirs, gamesTo: format.pointsTo) }
    private var maxValue: Int { isSTB ? 40 : format.sport.usesSets ? 13 : (format.cap ?? 60) }
    private var sides: (us: String, them: String) { RacketWatchCopy.sides(opponent: ex.opponent, doubles: ex.isDoubles) }
    private var count: Int { max(ex.sets.count, unitIndex + 1) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Which \(unit.noun)").font(.system(size: 15, weight: .semibold)).foregroundStyle(SnappetColor.textSecondary)
                    FlowRow {
                        ForEach(0..<count, id: \.self) { i in
                            RacketTagChip(label: RacketEditScoreCopy.chip(state(i), unit: unit, index: i), selected: index == i,
                                          id: "racket.editScore.game.\(i)") { load(i) }
                        }
                    }
                    Text("Opens on the \(unit.noun) you tapped.").font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                    let src = RacketEditScoreCopy.source(state(index))
                    HStack(spacing: 8) {
                        Text(src.line).font(.system(size: 15)).foregroundStyle(SnappetColor.textSecondary)
                            .accessibilityIdentifier("racket.editScore.source")
                        if src.unconfirmed {
                            Text("Unconfirmed").font(.system(size: 13, weight: .semibold)).foregroundStyle(SnappetColor.perfModerate)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(SnappetColor.perfModerate))
                        }
                    }
                    HStack(spacing: 14) {
                        column(sides.us, value: $mine, id: "mine")
                        column(sides.them, value: $theirs, id: "theirs")
                    }
                    .padding(12)
                    .background(Color(white: 0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(SnappetColor.hairline))
                    if needsTB {
                        HStack {
                            Text("Tiebreak").font(.subheadline.weight(.semibold))
                            Spacer()
                            Stepper("\(tbMine)", value: $tbMine, in: 0...40).fixedSize()
                            Text("–")
                            Stepper("\(tbTheirs)", value: $tbTheirs, in: 0...40).fixedSize()
                        }
                        .accessibilityIdentifier("racket.editScore.tiebreak")
                    }
                    Button { save() } label: { Text("Save score").frame(maxWidth: .infinity, minHeight: 30) }
                        .buttonStyle(SnappetWidePrimaryStyle())
                        .accessibilityIdentifier("racket.editScore.saveScore")
                    Text("Saving marks it confirmed. Stats update everywhere it’s used.")
                        .font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                        .multilineTextAlignment(.center).frame(maxWidth: .infinity)
                }
                .padding(16)
            }
            .navigationTitle("Edit score")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.accessibilityIdentifier("racket.editScore.cancel") }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.accessibilityIdentifier("racket.editScore.save") }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { if !configured { configured = true; load(unitIndex) } }
    }

    private func state(_ i: Int) -> RacketScoreState? { i < ex.sets.count ? ex.sets[i].racketScoreState : nil }

    private func load(_ i: Int) {
        index = i
        if i < ex.sets.count, let s = ex.sets[i].racketScore {
            mine = s.scoreFor; theirs = s.scoreAgainst
            tbMine = s.tiebreakFor ?? 7; tbTheirs = s.tiebreakAgainst ?? 5
        } else {
            (mine, theirs) = RacketScoring.initialScore(format: format, superTiebreak: format.isSuperTiebreak(index: i))
        }
    }

    private func save() {
        var log = SetLog(durationSec: nil)
        log.scoreFor = mine
        log.scoreAgainst = theirs
        if needsTB { log.tiebreakFor = tbMine; log.tiebreakAgainst = tbTheirs }
        if isSTB { log.superTiebreak = true }
        onSave(index, log)
        Haptics.success()
        dismiss()
    }

    private func column(_ who: String, value: Binding<Int>, id: String) -> some View {
        VStack(spacing: 6) {
            Text(who).font(.system(size: 14, weight: .semibold)).foregroundStyle(SnappetColor.textSecondary).lineLimit(1)
            Text("\(value.wrappedValue)").font(.system(size: 44, weight: .light)).monospacedDigit()
                .contentTransition(.numericText())
                .accessibilityIdentifier("racket.editScore.\(id)")
            HStack(spacing: 8) {
                step("−", id: "\(id).minus") { value.wrappedValue = max(0, value.wrappedValue - 1) }
                step("+", id: "\(id).plus") { value.wrappedValue = min(maxValue, value.wrappedValue + 1) }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func step(_ label: String, id: String, action: @escaping () -> Void) -> some View {
        Button { action(); Haptics.tap() } label: {
            Text(label).font(.system(size: 20, weight: .semibold)).foregroundStyle(SnappetColor.ink)
                .frame(maxWidth: .infinity, minHeight: 44)
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(SnappetColor.hairline, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("racket.editScore.\(id)")
    }
}

// MARK: - TnServe: serve details (prompt 252)

/// TnServe "Tennis serves": Close · Point 12 · Skip, the rally's video, "Game 3–2 · You’re serving", How did the serve
/// go? (First serve in / Second serve in / Double fault / Ace / Let, replay), the footnote, Who won the point?, Next point
/// (saves the serve and the winner with the tag and moves the tag sheet on — the board's arrow back to Tag).
struct RacketServeSheet: View {
    let number: Int
    let video: RacketRallyVideo
    /// "Game 3–2": games in the set before this point; nil when the recording isn't split into sets yet.
    let gameLine: String?
    let servingLine: String
    let sides: (us: String, them: String)
    let serve: RacketServeOutcome?
    let winner: RacketRallyWinner?
    /// Who served this point, when known (an ace / double fault then picks the winner).
    let server: RacketServe.Side?
    let onNextPoint: (RacketServeOutcome?, RacketRallyWinner?) -> Void
    let onSkip: () -> Void
    let onClose: () -> Void

    @State private var picked: RacketServeOutcome?
    @State private var won: RacketRallyWinner?
    @State private var configured = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    video
                    HStack(alignment: .firstTextBaseline) {
                        if let gameLine {
                            Text(gameLine).font(.system(size: 14, weight: .semibold)).accessibilityIdentifier("racket.serve.game")
                        }
                        Spacer(minLength: 6)
                        Text(servingLine).font(.system(size: 14)).foregroundStyle(SnappetColor.textSecondary)
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("racket.serve.serving")
                    }
                    Text("How did the serve go?").font(.system(size: 17, weight: .bold))
                    FlowRow {
                        ForEach(RacketServeOutcome.allCases, id: \.self) { o in
                            RacketTagChip(label: o.label, selected: picked == o, id: "racket.serve.\(o.rawValue)") {
                                picked = picked == o ? nil : o
                                if let o = picked {
                                    let implied = RacketServeOutcome.implied(o, server: server)
                                    if let w = implied.winner { won = w }
                                    if o == .letReplay { won = nil }
                                }
                            }
                        }
                    }
                    Text(RacketServeOutcome.footnote).font(.system(size: 14)).foregroundStyle(SnappetColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Who won the point?").font(.system(size: 17, weight: .bold))
                    HStack(spacing: 8) {
                        RacketTagChip(label: sides.us, selected: won == .us, id: "racket.serve.winner.us", wide: true) {
                            won = won == .us ? nil : .us
                        }
                        RacketTagChip(label: sides.them, selected: won == .them, id: "racket.serve.winner.them", wide: true) {
                            won = won == .them ? nil : .them
                        }
                    }
                    .disabled(picked == .letReplay)
                    RacketWideButton("Next point", id: "racket.serve.next") { onNextPoint(picked, won) }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Point \(number)").font(.system(size: 17, weight: .semibold)).accessibilityIdentifier("racket.serve.title")
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { onClose() }.accessibilityIdentifier("racket.serve.close")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Skip") { onSkip() }.accessibilityIdentifier("racket.serve.skip")
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            guard !configured else { return }
            configured = true
            picked = serve
            won = winner
        }
    }
}

// MARK: - PdWall / SqLet: one question with choice cards (prompt 252)

/// PdWall "Did the ball bounce first?" and SqLet "Was there interference?": Close · Rally 12 · Skip, the rally's video,
/// the question, one choice card per answer (title + what it means), SqLet's footnote, Back / Next. Both buttons return to
/// the tag sheet (the board's "Back or next" arrow); Next keeps the answer.
struct RacketChoiceDetailSheet: View {
    let title: String
    let video: RacketRallyVideo
    let question: String
    /// (id, title, subtitle).
    let options: [(String, String, String)]
    let selected: String?
    let footnote: String?
    let idPrefix: String
    let onNext: (String?) -> Void
    let onSkip: () -> Void
    let onClose: () -> Void

    @State private var picked: String?
    @State private var configured = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    video
                    Text(question).font(.system(size: 20, weight: .bold)).padding(.top, 2)
                        .accessibilityIdentifier("\(idPrefix).question")
                    ForEach(options, id: \.0) { o in
                        Button { picked = o.0; Haptics.tap() } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(o.1).font(.system(size: 16, weight: .semibold)).foregroundStyle(SnappetColor.ink)
                                Text(o.2).font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
                            .padding(.horizontal, 13).padding(.vertical, 6)
                            .background(picked == o.0 ? SnappetColor.brand.opacity(0.14) : Color.white.opacity(0.05),
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(picked == o.0 ? SnappetColor.brand : SnappetColor.hairline, lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("\(idPrefix).\(o.0)")
                        .accessibilityAddTraits(picked == o.0 ? .isSelected : [])
                    }
                    if let footnote {
                        Text(footnote).font(.system(size: 14)).foregroundStyle(SnappetColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("\(idPrefix).footnote")
                    }
                    HStack(spacing: 10) {
                        Button { onClose() } label: {
                            Text("Back").font(.system(size: 17, weight: .semibold)).foregroundStyle(SnappetColor.ink)
                                .frame(maxWidth: .infinity, minHeight: 50)
                        }
                        .buttonStyle(.plain).pagerOutline()
                        .accessibilityIdentifier("\(idPrefix).back")
                        Button { onNext(picked) } label: {
                            Text("Next").frame(maxWidth: .infinity, minHeight: 30)
                        }
                        .buttonStyle(SnappetWidePrimaryStyle())
                        .accessibilityIdentifier("\(idPrefix).next")
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(title).font(.system(size: 17, weight: .semibold)).accessibilityIdentifier("\(idPrefix).title")
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { onClose() }.accessibilityIdentifier("\(idPrefix).close")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Skip") { onSkip() }.accessibilityIdentifier("\(idPrefix).skip")
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            guard !configured else { return }
            configured = true
            picked = selected
        }
    }
}
