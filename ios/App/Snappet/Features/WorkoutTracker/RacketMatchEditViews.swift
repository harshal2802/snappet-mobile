import SwiftUI
import SwiftData

// MARK: - Edit match (prompt 260)
//
// One sheet over a draft of a logged match (`RacketMatchEditor.swift`): its games (score, order, video, remove, add,
// move to another match) and its details. Cancel drops the draft; Save repairs, validates and writes everything in
// one go (`RacketMatchSave`), and moves every photo / clip attached to a game by index with its game. Opened from the
// match row of the session recap and from Your videos. No wireframe board: it matches the racket sheets (dark, 44 pt
// targets, the split sheet's chips and outlines).

/// Which match the editor opens on.
struct RacketMatchEditTarget: Identifiable {
    let id = UUID()
    let exerciseID: UUID
}

/// Edit match is offered for a finished session only: while a session is live, the match page owns its games.
enum RacketMatchEditAvailability {
    static func allowed(sessionActive: Bool, ex: SessionExercise) -> Bool { !sessionActive && ex.isRacketMatch }

    /// The id for control `base` of the `m`-th match: the first match keeps the plain id (`base.k`), the others are
    /// `base.m<m>.k`, so rows of different matches never share one.
    static func id(_ base: String, match m: Int, _ k: Int? = nil) -> String {
        let head = m == 0 ? base : "\(base).m\(m)"
        return k.map { "\(head).\($0)" } ?? head
    }
}

struct RacketMatchEditSheet: View {
    let session: WorkoutSession
    let exerciseID: UUID
    var onSaved: () -> Void = {}

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var draft: RacketMatchDraft?
    @State private var path: [UUID] = []
    /// A game with video waiting for "what happens to its video".
    @State private var removing: UUID?
    @State private var addPosition: Int?
    @State private var saveProblem: String?

    private var ex: SessionExercise? { session.exercises.first { $0.id == exerciseID } }
    private var unit: RacketUnit { draft?.details.sport.unit ?? ex?.racketFormat.sport.unit ?? .game }
    private var otherMatches: [SessionExercise] { session.exercises.filter { $0.isRacketMatch && $0.id != exerciseID } }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let d = draft { list(d) } else { Color.clear }
            }
            .navigationDestination(for: UUID.self) { id in
                if let d = draft, d.index(of: id) != nil { gameScreen(id, d) }
            }
            .navigationTitle("Edit match")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("racket.editMatch.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.fontWeight(.semibold).accessibilityIdentifier("racket.editMatch.save")
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(SnappetColor.brand)
        .onAppear {
            if draft == nil, let ex { draft = RacketMatchEditor.draft(from: ex) }
        }
        .confirmationDialog("Remove this \(unit.noun)?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { id in
            ForEach(RacketRemovedVideo.allCases, id: \.self) { choice in
                Button(choice.label, role: choice == .notPlay ? .destructive : nil) {
                    remove(id, video: choice)
                }
                .accessibilityIdentifier("racket.editMatch.removeChoice.\(choice.rawValue)")
            }
            Button("Cancel", role: .cancel) { removing = nil }
                .accessibilityIdentifier("racket.editMatch.removeChoice.cancel")
        } message: { id in
            Text("It has video. " + (draft.map { RacketMatchEditor.ralliesLine($0, game: id) } ?? ""))
        }
    }

    // MARK: The match

    private func format(_ d: RacketMatchDraft) -> RacketFormat {
        RacketFormat(sport: d.details.sport, bestOf: d.details.bestOf, pointsTo: d.details.pointsTo,
                     superTiebreak: d.details.superTiebreak, goldenPoint: d.details.goldenPoint, sideOut: d.details.sideOut)
    }

    private func resultLine(_ d: RacketMatchDraft) -> String {
        let state = RacketScoring.state(units: d.games.compactMap(\.set.racketScore), format: format(d), end: ex?.racketEnd)
        let n = d.games.count
        return "\(state.shortResult) · \(n) \(n == 1 ? unit.noun : "\(unit.noun)s")"
    }

    private func gameTitle(_ k: Int) -> String { "\(unit.noun.capitalized) \(k + 1)" }

    private func scoreLine(_ s: SetLog) -> String {
        switch s.racketScoreState {
        case .confirmed(let sc): return sc.label
        case .fromWatch(let sc): return "\(sc.label) from Watch"
        case .unconfirmed, nil:
            return s.suggestedScore.map { "\($0.label)? · Score unconfirmed" } ?? RacketScoreState.unconfirmedLabel
        }
    }

    private func videoLine(_ d: RacketMatchDraft, _ id: UUID) -> String {
        if let r = d.videoRange(of: id) {
            return "Video \(RacketVideoTime.range(r.lo, r.hi))\(r.skips.isEmpty ? "" : " · \(r.skips.count == 1 ? "1 timeout" : "\(r.skips.count) timeouts")")"
        }
        return d.hasVideo(id) ? "Video" : "No video"
    }

    @ViewBuilder private func list(_ d: RacketMatchDraft) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(resultLine(d)).font(.system(size: 28, weight: .light).monospacedDigit())
                    .accessibilityIdentifier("racket.editMatch.result")
                note("Nothing changes until you tap Save. Cancel leaves the match as it was.")
                Text("\(unit.noun.capitalized)s").snappetLabel()
                ForEach(Array(d.games.enumerated()), id: \.element.id) { k, g in
                    Button { path.append(g.id) } label: {
                        HStack(alignment: .center, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(gameTitle(k)).font(.system(size: 16, weight: .semibold)).foregroundStyle(SnappetColor.ink)
                                Text("\(scoreLine(g.set)) · \(videoLine(d, g.id))")
                                    .font(SnappetType.detail.monospacedDigit()).foregroundStyle(SnappetColor.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 6)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                                .foregroundStyle(SnappetColor.textTertiary)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(12)
                    .pagerGlass(cornerRadius: 14)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("racket.editMatch.game.\(k)")
                    .accessibilityHint("Opens this \(unit.noun) to change it")
                }
                addPanel(d)
                detailsPanel(d)
                if let saveProblem {
                    Text(saveProblem).font(SnappetType.detail).foregroundStyle(SnappetColor.perfHard)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("racket.editMatch.problem")
                }
            }
            .padding(20)
        }
    }

    @ViewBuilder private func addPanel(_ d: RacketMatchDraft) -> some View {
        if let p = addPosition {
            panel {
                Text("Add a \(unit.noun)").font(.system(size: 15, weight: .semibold))
                note("Where it goes. A \(unit.noun) you add has no video and never takes another \(unit.noun)’s video.")
                FlowRow {
                    ForEach(0...d.games.count, id: \.self) { q in
                        chip(q == 0 ? "First" : "After \(gameTitle(q - 1))", selected: q == p, id: "racket.editMatch.addAt.\(q)") {
                            addPosition = q
                        }
                    }
                }
                HStack(spacing: 10) {
                    outline("Cancel", id: "racket.editMatch.addCancel") { addPosition = nil }
                    outline("Add", id: "racket.editMatch.addConfirm") {
                        var nd = RacketMatchEditor.add(d, at: p, fallback: session.startedAt)
                        nd = RacketMatchEditor.normalized(nd)
                        let newID = nd.games[min(p, nd.games.count - 1)].id
                        draft = nd
                        addPosition = nil
                        path.append(newID)
                    }
                }
            }
        } else {
            outline("Add a \(unit.noun)", id: "racket.editMatch.add") { addPosition = d.games.count }
        }
    }

    @ViewBuilder private func detailsPanel(_ d: RacketMatchDraft) -> some View {
        let binding = Binding<RacketMatchParams>(get: { draft?.details ?? d.details }, set: { draft?.details = $0 })
        panel {
            Text("Match details").font(.system(size: 15, weight: .semibold))
            if d.details.doubles {
                field("Partner", text: binding.partner, id: "racket.editMatch.partner")
                field("Opponent 1", text: Binding(get: { binding.wrappedValue.opponents.player1 },
                                                   set: { var o = binding.wrappedValue.opponents; o.setPlayer1($0); binding.wrappedValue.opponents = o }),
                      id: "racket.editMatch.opponent1")
                field("Opponent 2", text: Binding(get: { binding.wrappedValue.opponents.player2 },
                                                   set: { var o = binding.wrappedValue.opponents; o.setPlayer2($0); binding.wrappedValue.opponents = o }),
                      id: "racket.editMatch.opponent2")
                field("Team name", text: Binding(get: { binding.wrappedValue.opponents.teamName },
                                                  set: { var o = binding.wrappedValue.opponents; o.setTeamName($0); binding.wrappedValue.opponents = o }),
                      id: "racket.editMatch.team")
            } else {
                field("Opponent", text: binding.opponent, id: "racket.editMatch.opponent")
            }
            field("Event", text: binding.event, id: "racket.editMatch.event")
            field("Round", text: binding.round, id: "racket.editMatch.round")
            Text("Best of").snappetLabel()
            FlowRow {
                ForEach([1, 3, 5, 7], id: \.self) { n in
                    chip("\(n)", selected: d.details.bestOf == n, id: "racket.editMatch.bestOf.\(n)") { draft?.details.bestOf = n }
                }
                chip("Open play", selected: d.details.bestOf == nil, id: "racket.editMatch.bestOf.open") { draft?.details.bestOf = nil }
            }
            HStack {
                Text("\(d.details.sport.usesSets ? "Games per set" : "Points per \(unit.noun)") \(d.details.pointsTo)")
                    .font(SnappetType.body.monospacedDigit())
                    .accessibilityIdentifier("racket.editMatch.pointsTo")
                Spacer()
                stepButton("minus", id: "racket.editMatch.pointsTo.minus", label: "Fewer") {
                    draft?.details.pointsTo = max(1, d.details.pointsTo - 1)
                }
                stepButton("plus", id: "racket.editMatch.pointsTo.plus", label: "More") {
                    draft?.details.pointsTo = d.details.pointsTo + 1
                }
            }
            if let n = RacketMatchEditor.fitNote(d) {
                note(n).accessibilityIdentifier("racket.editMatch.fitNote")
            }
        }
    }

    // MARK: One game

    @ViewBuilder private func gameScreen(_ id: UUID, _ d: RacketMatchDraft) -> some View {
        let k = d.index(of: id) ?? 0
        let s = d.games[k].set
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(scoreLine(s)).font(.system(size: 15)).foregroundStyle(SnappetColor.textSecondary)
                    .accessibilityIdentifier("racket.editMatch.g.state")
                scoreEditor(id, s)
                FlowRow {
                    let confirmOff = RacketMatchEditor.confirmBlock(d, game: id)
                    chip("Confirm score", selected: false, id: "racket.editMatch.g.confirm") {
                        draft = RacketMatchEditor.confirm(d, game: id)
                    }
                    .disabled(confirmOff != nil).opacity(confirmOff != nil ? 0.45 : 1)
                    chip("Score unknown", selected: false, id: "racket.editMatch.g.unknown") {
                        draft = RacketMatchEditor.markUnknown(d, game: id)
                    }
                }
                Text("Video").snappetLabel()
                note(videoLine(d, id)).accessibilityIdentifier("racket.editMatch.g.video")
                videoControls(id, d)
                Text("Order").snappetLabel()
                let earlier = RacketMatchEditor.moveBlock(d, game: id, by: -1)
                let later = RacketMatchEditor.moveBlock(d, game: id, by: 1)
                HStack(spacing: 10) {
                    outline("Move earlier", id: "racket.editMatch.g.earlier") { draft = RacketMatchEditor.move(d, game: id, by: -1) }
                        .disabled(earlier != nil).opacity(earlier != nil ? 0.45 : 1)
                    outline("Move later", id: "racket.editMatch.g.later") { draft = RacketMatchEditor.move(d, game: id, by: 1) }
                        .disabled(later != nil).opacity(later != nil ? 0.45 : 1)
                }
                if let r = [earlier, later].compactMap({ $0 }).first(where: { $0 == RacketMatchEditor.videoOrderReason }) ?? earlier ?? later {
                    note(r).accessibilityIdentifier("racket.editMatch.g.moveReason")
                }
                if !otherMatches.isEmpty {
                    Text("Another match").snappetLabel()
                    let off = RacketMatchEditor.moveToMatchBlock(d, game: id, otherMatches: otherMatches.count)
                    ForEach(Array(otherMatches.enumerated()), id: \.element.id) { m, other in
                        outline("Move to \(RacketStats.matchRowTitle(other))", id: "racket.editMatch.g.moveTo.\(m)") {
                            draft = RacketMatchEditor.moveToMatch(d, game: id, to: other.id, otherMatches: otherMatches.count)
                            path.removeAll()
                        }
                        .disabled(off != nil).opacity(off != nil ? 0.45 : 1)
                    }
                    if let off { note(off).accessibilityIdentifier("racket.editMatch.g.moveToReason") }
                }
                Text("Remove").snappetLabel()
                let removeOff = RacketMatchEditor.removeBlock(d, game: id)
                Button {
                    if RacketMatchEditor.removeNeedsChoice(d, game: id) { removing = id } else { remove(id, video: nil) }
                } label: {
                    Text("Remove \(unit.noun)").font(.system(size: 15, weight: .semibold)).foregroundStyle(SnappetColor.perfHard)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain).pagerOutline()
                .disabled(removeOff != nil).opacity(removeOff != nil ? 0.45 : 1)
                .accessibilityIdentifier("racket.editMatch.g.remove")
                if let removeOff {
                    note(removeOff).accessibilityIdentifier("racket.editMatch.g.removeReason")
                } else if RacketMatchEditor.removeNeedsChoice(d, game: id) {
                    note("It has video, so you choose what happens to it. Video is never deleted.")
                }
            }
            .padding(20)
        }
        .navigationTitle(gameTitle(k))
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private func scoreEditor(_ id: UUID, _ s: SetLog) -> some View {
        let shown = s.racketScore ?? s.suggestedScore ?? RacketUnitScore(scoreFor: 0, scoreAgainst: 0)
        HStack(spacing: 12) {
            scoreStepper("You", value: shown.scoreFor, id: "racket.editMatch.g.for") { v in
                var sc = shown; sc.scoreFor = v
                draft = draft.map { RacketMatchEditor.setScore($0, game: id, sc) }
            }
            scoreStepper("Them", value: shown.scoreAgainst, id: "racket.editMatch.g.against") { v in
                var sc = shown; sc.scoreAgainst = v
                draft = draft.map { RacketMatchEditor.setScore($0, game: id, sc) }
            }
        }
    }

    private func scoreStepper(_ who: String, value: Int, id: String, set: @escaping (Int) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(who).font(SnappetType.label).foregroundStyle(SnappetColor.textSecondary)
            HStack(spacing: 8) {
                Text("\(value)").font(.system(size: 30, weight: .light)).monospacedDigit()
                    .frame(minWidth: 40, alignment: .leading)
                    .accessibilityIdentifier(id)
                stepButton("minus", id: "\(id).minus", label: "\(who) minus one") { set(max(0, value - 1)) }
                stepButton("plus", id: "\(id).plus", label: "\(who) plus one") { set(value + 1) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pagerGlass(cornerRadius: 14)
    }

    @ViewBuilder private func videoControls(_ id: UUID, _ d: RacketMatchDraft) -> some View {
        if d.hasVideo(id) {
            outline("Unlink video", id: "racket.editMatch.g.unlink") { draft = RacketMatchEditor.unlink(d, game: id) }
                .disabled(RacketMatchEditor.unlinkBlock(d, game: id) != nil)
            note("Its video then counts for no \(unit.noun). It stays in the recording and can be linked again.")
        } else {
            let candidates = RacketMatchEditor.linkCandidates(d)
            if candidates.isEmpty {
                note(d.hasRecording ? "Every part of the recording with play is already a \(unit.noun)."
                                    : "This match has no recording.")
                    .accessibilityIdentifier("racket.editMatch.g.noCandidates")
            }
            ForEach(Array(candidates.enumerated()), id: \.element) { c, pid in
                if let p = d.parts.first(where: { $0.id == pid }) {
                    let off = RacketMatchEditor.linkBlock(d, game: id, part: pid)
                    outline("Link \(RacketVideoTime.range(p.startSec, p.endSec)) (\(p.kind.label(unit: unit)))",
                            id: "racket.editMatch.g.link.\(c)") {
                        draft = RacketMatchEditor.link(d, game: id, part: pid)
                    }
                    .disabled(off != nil).opacity(off != nil ? 0.45 : 1)
                    if let off { note(off).accessibilityIdentifier("racket.editMatch.g.linkReason.\(c)") }
                }
            }
        }
    }

    // MARK: Actions

    private func remove(_ id: UUID, video: RacketRemovedVideo?) {
        guard let d = draft else { return }
        draft = RacketMatchEditor.remove(d, game: id, video: video)
        removing = nil
        path.removeAll()
        Haptics.tap()
    }

    /// Repair, validate, then write the match, any match that received a game, and the media, in one save.
    private func save() {
        guard let d = draft else { dismiss(); return }
        guard let out = RacketMatchSave.apply(d, to: session.exercises, match: exerciseID) else {
            saveProblem = "This match can’t be saved as it is. Nothing was changed. Check the \(unit.noun)s with video and try again."
            return
        }
        session.exercises = out.exercises
        let sid = session.id
        let media = (try? context.fetch(FetchDescriptor<SessionMedia>(predicate: #Predicate { $0.sessionID == sid }))) ?? []
        for m in media {
            guard let exID = m.assignedExerciseID, let move = out.media[exID], let old = m.assignedSetIndex else { continue }
            let to = move(old)
            m.assignedExerciseID = to.exerciseID
            m.assignedSetIndex = to.setIndex
        }
        try? context.save()
        Haptics.success()
        onSaved()
        dismiss()
    }

    // MARK: Pieces

    private func panel<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) { c() }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .pagerGlass(cornerRadius: 18)
    }

    private func note(_ s: String) -> some View {
        Text(s).font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func field(_ label: String, text: Binding<String>, id: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(SnappetType.label).foregroundStyle(SnappetColor.textSecondary)
            TextField(label, text: text)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(SnappetColor.hairline))
                .accessibilityIdentifier(id)
                .accessibilityLabel(label)
        }
    }

    private func chip(_ label: String, selected: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: { action(); Haptics.tap() }) {
            Text(label).font(.system(size: 14, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.black : SnappetColor.ink)
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background(selected ? SnappetColor.brand : Color.clear, in: Capsule())
                .overlay(Capsule().strokeBorder(SnappetColor.hairline))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func outline(_ label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 44)
                .multilineTextAlignment(.center)
        }
        .buttonStyle(.plain).pagerOutline()
        .accessibilityIdentifier(id)
    }

    private func stepButton(_ symbol: String, id: String, label: String, action: @escaping () -> Void) -> some View {
        Button { action(); Haptics.tap() } label: {
            Image(systemName: symbol).font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(.white.opacity(0.09), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityLabel(label)
    }
}
