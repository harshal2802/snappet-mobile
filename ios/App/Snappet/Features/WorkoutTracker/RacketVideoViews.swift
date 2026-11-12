import SwiftUI
import SwiftData

// MARK: - Racket videos, split and tagging screens (prompt 246, issue #438 step 3)
//
// One full-screen stack, opened from the match / drill page ("Your videos"), the session recap, and the end of a
// whole-match recording (the split prompt). Thin renderers over the pure `RacketVideoSplit.swift` /
// `RacketRallyTags.swift`; Photos + AVFoundation go through `Services/RacketVideoLibrary.swift`. The screens edit the
// session directly (`RacketVideoStore`) so they work the same live and from a finished session's detail.
//
// Boards: TtSplitPrompt → TtSplitReview → TtSplitEdit / TtSplitAssign → TtSplitDone → TtDeleteOriginal; TtKeepRallies;
// TtOriginalMissing; FindRallies / TtNoModelVideos (Your videos); TtDrillVideos; TtPlayerOriginal / TtPlayerAnalyzed /
// TtPlayerExport; TtNoModelTimeline / Timeline / FixRally; TtNoModelTag / DoublesTag; TtTagDone; TtManualSummary.
// Step 4 (prompt 247): each part / block also offers "Another AI app" and "Bring results back" (`RacketAIViews.swift`).
// Step 5 (prompt 248): Your videos is the FindRallies board when the sport has a model (every sport, on the placeholder):
// Find rallies / Re-scan…, Analyzing, ChooseModel, ModelCompare, the game summary and AnalysisSettings
// (`RacketModelViews.swift`); "Preview a sport with no model" shows the TtNoModelVideos state, labelled as a preview.

/// Where the stack opens.
enum RacketVideosStart: Hashable, Sendable {
    /// Your videos for the session.
    case videos
    /// The split prompt for one whole-match recording (after Stop and split).
    case splitPrompt(UUID)
    /// Your videos with "Keep rallies only" open (TtSessionRecap → TtKeepRallies).
    case keepRallies
    /// "What works for <sport>" (the match page, prompt 248).
    case capabilities(RacketSport)
    /// One drill's videos (PracticeReview "Drill videos", prompt 250).
    case drillVideos(UUID)
}

struct RacketVideosTarget: Identifiable {
    let id = UUID()
    let start: RacketVideosStart
}

/// A part to play / mark: one row of Your videos.
struct RacketPartRef: Hashable, Sendable {
    var exerciseID: UUID
    var title: String
    var startSec: Double
    var endSec: Double
    var setIndex: Int?
}

enum RacketVideoRoute: Hashable {
    case review(UUID)
    case assign(UUID)
    case done(UUID)
    case drill(UUID)
    case player(RacketPartRef, ralliesOnly: Bool)
    case timeline(RacketPartRef)
    case tagDone(RacketPartRef)
    case summary(RacketPartRef)
    case missing(RacketPartRef)
    case videos
    // Round trip with another AI app (prompt 247).
    case aiSend(RacketPartRef)
    case aiPrompt(RacketAIPromptContext)
    case aiImport(RacketPartRef)
    case aiCompare(RacketPartRef, UUID)
    /// The player opened on Analyzed (after Add as suggestions / Compare → Done).
    case analyzed(RacketPartRef)
    // Model hooks (prompt 248).
    case capabilities(RacketSport)
    /// Your videos as a sport with no model would show it (TtNoModelVideos), labelled as a preview.
    case noModelPreview(RacketSport)
    case analyzing
    case chooseModel(RacketPartRef)
    case modelCompare(RacketPartRef, UUID)
    /// The game summary after a scan (Summary board).
    case analysis(RacketPartRef)
    case analysisSettings(RacketSport)
}

/// The tag sheet opened from the game summary ("Check N unsure" / "Tag winners and endings").
struct RacketTagTarget: Identifiable {
    let id = UUID()
    let ref: RacketPartRef
    let unsureOnly: Bool
}

/// Reads and writes the session's racket entities (a SwiftData model): mutate, then save.
@MainActor
struct RacketVideoStore {
    let session: WorkoutSession
    let context: ModelContext

    func ex(_ id: UUID) -> SessionExercise? { session.exercises.first { $0.id == id } }

    func update(_ id: UUID, _ body: (inout SessionExercise) -> Void) {
        guard let i = session.exercises.firstIndex(where: { $0.id == id }) else { return }
        var e = session.exercises[i]
        body(&e)
        session.exercises[i] = e
        try? context.save()
    }

    func updateLog(_ id: UUID, _ body: (inout RacketRecordingLog) -> Void) {
        update(id) { e in
            guard var l = e.racketRecordingLog else { return }
            body(&l)
            e.racketRecordingLog = l
        }
    }

    /// Link the proposed games to the logged ones and log the missing ones "Score unconfirmed" (without applying the
    /// split): Later / Keep as one video still leave the match with its games, as step 1 did.
    func logGames(_ id: UUID, parts: [RacketVideoPart]) {
        update(id) { e in
            guard let l = e.racketRecordingLog else { return }
            let out = RacketSplitAssign.apply(parts: parts, sets: e.sets, base: l.baseIndex, startedAt: l.startedAt)
            e.sets = out.sets
        }
    }

    func saveScore(_ id: UUID, unit: Int, _ log: SetLog) {
        update(id) { e in
            if unit < e.sets.count { RacketScoreEdit.apply(log, to: &e.sets[unit]) } else { e.sets.append(log) }
        }
    }
}

// MARK: - The stack

struct RacketVideosCover: View {
    let session: WorkoutSession
    let start: RacketVideosStart
    let onClose: () -> Void

    @Environment(\.modelContext) private var context
    @State private var path: [RacketVideoRoute] = []
    /// The split being reviewed (TtSplitReview / TtSplitEdit), before Apply.
    @State private var draft: [RacketVideoPart] = []
    @State private var draftFor: UUID?
    @State private var editing: RacketVideoPart?
    @State private var scoring: RacketScoreTarget?
    @State private var deleting: UUID?
    @State private var keeping = false
    @State private var openedKeep = false
    @State private var found: Set<String> = []
    @State private var tagTarget: RacketTagTarget?
    @State private var autoAsk: [RacketPartRef] = []
    /// The split review's player on the whole original (device feedback round 1), shared with "Fix one part".
    @State private var reviewPlayback: RacketPlayback?
    @State private var reviewFor: UUID?

    private var store: RacketVideoStore { RacketVideoStore(session: session, context: context) }

    var body: some View {
        NavigationStack(path: $path) {
            root
                .navigationDestination(for: RacketVideoRoute.self) { destination($0) }
        }
        .preferredColorScheme(.dark)
        .tint(SnappetColor.brand)
        .onAppear(perform: refreshFound)
        .onDisappear { reviewPlayback?.stop() }
        .sheet(item: $editing) { p in
            RacketSplitEditSheet(part: p, parts: draft, duration: draftDuration, unit: unit(draftFor),
                                 playback: reviewPlayback, sources: reviewSources,
                                 sport: draftFor.flatMap { store.ex($0)?.racketSport } ?? .tableTennis) { draft = $0 }
        }
        .sheet(item: $scoring) { t in
            if let ex = store.ex(t.exerciseID) {
                RacketScoreSheet(ex: ex, unitIndex: t.unitIndex, durationSec: nil) { log in
                    store.saveScore(t.exerciseID, unit: t.unitIndex, log)
                }
            }
        }
        .sheet(item: Binding(get: { deleting.map(IDBox.init) }, set: { deleting = $0?.id })) { box in
            RacketDeleteOriginalSheet(store: store, exerciseID: box.id) {
                refreshFound()
                path = [.videos]
            }
        }
        .sheet(isPresented: $keeping) {
            RacketKeepRalliesSheet(store: store) { refreshFound() }
        }
        .sheet(item: $tagTarget) { t in
            RacketTagSheet(store: store, ref: t.ref, startID: startID(t), unsureOnly: t.unsureOnly) { finished in
                tagTarget = nil
                if finished { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { path.append(.tagDone(t.ref)) } }
            }
        }
    }

    private func startID(_ t: RacketTagTarget) -> UUID {
        let rs = RacketRallyMarking.inRange(store.ex(t.ref.exerciseID)?.racketRecordingLog?.allRallies ?? [], t.ref.startSec, t.ref.endSec)
        let next = t.unsureOnly ? RacketRallyMarking.nextUnsure(rs, after: nil) : RacketRallyMarking.nextUntagged(rs, after: nil)
        return (next ?? rs.first(where: \.isRally))?.id ?? UUID()
    }

    private var scanCenter: RacketScanCenter { RacketScanCenter.shared }

    private struct IDBox: Identifiable { let id: UUID }

    private var draftDuration: Double { draftFor.flatMap { store.ex($0)?.racketRecordingLog?.timelineSec } ?? 0 }
    private func unit(_ id: UUID?) -> RacketUnit { id.flatMap { store.ex($0)?.racketFormat.sport.unit } ?? .game }

    private func refreshFound() {
        let ids = session.exercises.flatMap { $0.racketRecordingLog.map(RacketVideoMap.neededIdentifiers) ?? [] }
        found = RacketVideoLibrary.shared.found(ids)
    }

    @ViewBuilder private var root: some View {
        switch start {
        case .videos: videosList
        case .keepRallies: videosList.onAppear { if !openedKeep { openedKeep = true; keeping = true } }
        case .splitPrompt(let id): splitPrompt(id)
        case .capabilities(let sport):
            RacketCapabilitiesScreen(sport: sport) { path.append(.noModelPreview(sport)) }
                .toolbar { closeButton() }
        case .drillVideos(let id):
            drillVideos(id).toolbar { closeButton() }
        }
    }

    @ViewBuilder private func destination(_ r: RacketVideoRoute) -> some View {
        switch r {
        case .review(let id): splitReview(id)
        case .assign(let id): splitAssign(id)
        case .done(let id): splitDone(id)
        case .drill(let id): drillVideos(id)
        case .player(let ref, let only):
            RacketPlayerScreen(store: store, ref: ref, ralliesOnly: only) { path.append(.aiCompare(ref, $0)) }
        case .analyzed(let ref):
            RacketPlayerScreen(store: store, ref: ref, ralliesOnly: false, startAnalyzed: true) { path.append(.aiCompare(ref, $0)) }
        case .aiSend(let ref):
            RacketAISendScreen(store: store, ref: ref, onPrompt: { path.append(.aiPrompt($0)) },
                               onSent: { replaceTop(with: .aiImport(ref)) }, onCancel: { path.removeLast() })
        case .aiPrompt(let ctx): RacketAIPromptScreen(context: ctx)
        case .aiImport(let ref):
            RacketAIImportScreen(store: store, ref: ref, onCompare: { replaceTop(with: .aiCompare(ref, $0)) },
                                 onSuggestions: { replaceTop(with: .analyzed(ref)) }, onCancel: { path.removeLast() })
        case .aiCompare(let ref, let id):
            RacketAICompareScreen(store: store, ref: ref, importID: id) { replaceTop(with: .analyzed(ref)) }
        case .timeline(let ref): RacketTimelineScreen(store: store, ref: ref) { path.append(.tagDone(ref)) }
            onSummary: { path.append(.summary(ref)) }
        case .tagDone(let ref): tagDone(ref)
        case .summary(let ref): manualSummary(ref)
        case .missing(let ref): originalMissing(ref)
        case .videos: videosList
        case .capabilities(let sport):
            RacketCapabilitiesScreen(sport: sport) { path.append(.noModelPreview(sport)) }
        case .noModelPreview(let sport): videosContent(noModel: true, previewSport: sport)
        case .analyzing:
            RacketAnalyzingScreen(store: store, onReview: { replaceTop(with: .analysis($0)) },
                                  onCompare: { path.append(.modelCompare($0, $1)) },
                                  onLater: { backToVideos() })
        case .chooseModel(let ref):
            RacketChooseModelScreen(store: store, ref: ref, onScan: { replaceTop(with: .analyzing) },
                                    onCancel: { path.removeLast() })
        case .modelCompare(let ref, let id):
            RacketModelCompareScreen(store: store, ref: ref, recordID: id, onUse: { replaceTop(with: .analysis(ref)) },
                                     onKeep: { backToVideos() })
        case .analysis(let ref):
            RacketAnalysisSummaryScreen(store: store, ref: ref, onDoneForNow: { backToVideos() },
                                        onTimeline: { path.append(.timeline(ref)) },
                                        onTag: { tagTarget = RacketTagTarget(ref: ref, unsureOnly: $0) },
                                        onEditScore: { scoring = RacketScoreTarget(exerciseID: ref.exerciseID, unitIndex: $0, durationSec: nil) })
        case .analysisSettings(let sport):
            RacketAnalysisSettingsScreen(sport: sport) { path.append(.capabilities(sport)) }
        }
    }

    /// Back to Your videos (the root, or the pushed list after a split).
    private func backToVideos() {
        if case .videos = start { path = [] } else { path = [.videos] }
    }

    /// Find rallies on these parts with the sport's model, then show Analyzing.
    private func findRallies(_ refs: [RacketPartRef], sport: RacketSport, waitForCharger: Bool = false, show: Bool = true) {
        guard let model = RacketCapabilityRegistry.capabilities(for: sport).model, !refs.isEmpty else { return }
        scanCenter.enqueue(refs, model: model, waitForCharger: waitForCharger, store: store)
        for id in Set(refs.map(\.exerciseID)) { store.updateLog(id) { $0.scanOffered = true } }
        if show { path.append(.analyzing) }
    }

    /// Every part of the session's recordings that no scan has covered (FindRallies "Scan all", AnalysisSettings).
    private var unscannedParts: [RacketPartRef] {
        racketEntities.flatMap { ex -> [RacketPartRef] in
            guard let log = ex.racketRecordingLog else { return [] }
            return RacketVideoRows.rows(for: ex).filter { row in
                RacketScanState.of(log, partStart: row.startSec, partEnd: row.endSec, current: nil) == .notScanned
            }.map { ref(ex, $0) }
        }
    }

    /// "After a session" (AnalysisSettings), once per recording, the first time Your videos opens on it.
    private func offerAutoScan() {
        let sport = racketEntities.first?.racketSport ?? .tableTennis
        guard RacketCapabilityRegistry.capabilities(for: sport).has(.findRallies) else { return }
        let parts = unscannedParts.filter { store.ex($0.exerciseID)?.racketRecordingLog?.scanOffered != true }
        switch RacketAutoScan.decision(RacketAutoScan.load(), unscanned: parts.count, alreadyHandled: false) {
        case .start: findRallies(parts, sport: sport, show: false)
        case .startOnCharger: findRallies(parts, sport: sport, waitForCharger: true, show: false)
        case .ask: autoAsk = parts
        case .nothing: break
        }
    }

    /// AISend → AIImport → AICompare → Analyzed each replace the screen before (Back returns to Your videos).
    private func replaceTop(with r: RacketVideoRoute) {
        if !path.isEmpty { path.removeLast() }
        path.append(r)
    }

    /// "21 suggested by ChatGPT, not compared yet" + Compare, for a part with a reply waiting (prompt 247).
    @ViewBuilder private func aiPending(_ ex: SessionExercise, _ r: RacketPartRef, id: String) -> some View {
        if let log = ex.racketRecordingLog, let imp = log.pendingAIImports(partStart: r.startSec, partEnd: r.endSec).last {
            let n = RacketRallyMarking.inRange(imp.rallies, r.startSec, r.endSec).count
            HStack(alignment: .firstTextBaseline) {
                Text("\(n) suggested by \(imp.appName), not compared yet")
                    .font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("racket.\(id).aiPending")
                Spacer(minLength: 6)
                chipButton("Compare", id: "racket.\(id).aiCompare") { path.append(.aiCompare(r, imp.id)) }
            }
        }
    }

    // MARK: Small pieces

    private func closeButton(_ label: String = "Close") -> some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(label) { onClose() }.accessibilityIdentifier("racket.videos.close")
        }
    }

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

    private func primary(_ label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(label).frame(maxWidth: .infinity, minHeight: 30) }
            .buttonStyle(SnappetWidePrimaryStyle())
            .accessibilityIdentifier(id)
    }

    private func secondary(_ label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 15, weight: .semibold)).foregroundStyle(SnappetColor.ink)
                .frame(maxWidth: .infinity, minHeight: 44).multilineTextAlignment(.center)
        }
        .buttonStyle(.plain)
        .pagerOutline()
        .accessibilityIdentifier(id)
    }

    private func chipButton(_ label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 14, weight: .semibold)).foregroundStyle(SnappetColor.brand)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .overlay(Capsule().strokeBorder(SnappetColor.hairline))
                .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    /// The recording as a strip of parts (TtSplitPrompt / TtSplitReview).
    private func partStrip(_ parts: [RacketVideoPart], total: Double) -> some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(parts) { p in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(stripColor(p))
                        .frame(width: max(2, geo.size.width * p.durationSec / max(1, total) - 2))
                }
            }
        }
        .frame(height: 30)
        .accessibilityElement()
        .accessibilityLabel("Recording split into \(parts.count) parts")
    }

    private func stripColor(_ p: RacketVideoPart) -> Color {
        switch RacketSplitReview.status(p) {
        case .matched: return SnappetColor.brand
        case .unsure: return SnappetColor.perfModerate
        case .notCounted: return SnappetColor.textSecondary.opacity(0.35)
        }
    }

    private func ensureDraft(_ id: UUID) {
        guard draftFor != id, let ex = store.ex(id), let log = ex.racketRecordingLog else { return }
        draftFor = id
        if let s = log.split, !s.parts.isEmpty {
            draft = s.parts
        } else {
            draft = RacketSplitProposal.propose(log: log, format: ex.racketFormat)
        }
        // Show the scores already logged (the Watch's) on the proposed games.
        let out = RacketSplitAssign.apply(parts: draft, sets: ex.sets, base: log.baseIndex, startedAt: log.startedAt)
        let known = ex.sets.count
        draft = out.parts.map { p in var q = p; if let i = q.setIndex, i >= known { q.setIndex = nil }; return q }
    }

    // MARK: TtSplitPrompt

    @ViewBuilder private func splitPrompt(_ id: UUID) -> some View {
        let ex = store.ex(id)
        let log = ex?.racketRecordingLog
        let u = ex?.racketFormat.sport.unit ?? .game
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("\(RacketVideoTime.clock(log?.timelineSec ?? 0)) recorded")
                    .font(.system(size: 28, weight: .light)).monospacedDigit()
                    .accessibilityIdentifier("racket.split.recorded")
                note(RacketSplitProposal.promptLine(draft, unit: u)).accessibilityIdentifier("racket.split.line")
                partStrip(draft, total: log?.timelineSec ?? 1)
                HStack(spacing: 14) {
                    legend(SnappetColor.textSecondary.opacity(0.35), "Warmup and breaks")
                    legend(SnappetColor.brand, "\(u.noun.capitalized)s")
                    legend(SnappetColor.perfModerate, "Unsure")
                }
                primary("Review the split", id: "racket.split.review") { path.append(.review(id)) }
                secondary("Keep as one video", id: "racket.split.keepOne") {
                    store.logGames(id, parts: draft)
                    store.updateLog(id) { $0.keptAsOne = true }
                    path.append(.videos)
                }
                note("You can split it any time from Your videos. The original is never changed.")
            }
            .padding(20)
        }
        .navigationTitle("Recording saved")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Later") { store.logGames(id, parts: draft); path.append(.videos) }
                    .accessibilityIdentifier("racket.split.later")
            }
        }
        .navigationBarBackButtonHidden()
        .onAppear { ensureDraft(id) }
    }

    private func legend(_ c: Color, _ s: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 12, height: 12)
            Text(s).font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary).fixedSize()
        }
    }

    // MARK: TtSplitReview

    /// Device feedback round 1: the original plays at the top, the bar under it is the split as a segmented timeline
    /// with a playhead, and tapping a part (in the bar or the list) plays it. "Fix" opens TtSplitEdit.
    @ViewBuilder private func splitReview(_ id: UUID) -> some View {
        let ex = store.ex(id)
        let u = ex?.racketFormat.sport.unit ?? .game
        let ords = RacketSplitReview.ordinals(draft)
        let playing = reviewPlayback.flatMap { RacketSplitTimeline.partIndex(at: $0.position, in: draft) }
        VStack(spacing: 0) {
            if let pb = reviewPlayback {
                VStack(alignment: .leading, spacing: 8) {
                    RacketVideoSurface(playback: pb, sport: ex?.racketSport ?? .tableTennis, height: 200)
                    RacketSplitTimelineBar(parts: draft, total: draftDuration, playback: pb) { k in playPart(k) }
                    HStack(spacing: 10) {
                        Text(RacketVideoTime.clock(pb.position)).monospacedDigit()
                            .accessibilityIdentifier("racket.split.clock")
                        if let k = playing, k < draft.count {
                            Text(RacketSplitReview.name(draft[k], ordinal: ords[draft[k].id], unit: u))
                                .font(SnappetType.detail.weight(.semibold))
                                .accessibilityIdentifier("racket.split.playingPart")
                        }
                        Spacer()
                        Button(pb.playing ? "Pause" : "Play") { pb.toggle() }
                            .font(.system(size: 15, weight: .semibold))
                            .accessibilityIdentifier("racket.split.play")
                        Text(RacketVideoTime.clock(draftDuration)).monospacedDigit().foregroundStyle(SnappetColor.textSecondary)
                    }
                    .font(SnappetType.detail)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    note("Found from your Watch taps and new-\(u.noun) marks, and breaks you marked. Rally activity needs a model. Tap a part to watch it, Fix to change it.")
                    ForEach(Array(draft.enumerated()), id: \.element.id) { k, p in
                        HStack(alignment: .center, spacing: 8) {
                            Button { playPart(k) } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(RacketSplitReview.name(p, ordinal: ords[p.id], unit: u))
                                            .font(.system(size: 16, weight: .semibold)).foregroundStyle(SnappetColor.ink)
                                        Text(RacketSplitReview.detail(p, sets: ex?.sets ?? [], unit: u, isLast: k == draft.count - 1))
                                            .font(SnappetType.detail.monospacedDigit()).foregroundStyle(SnappetColor.textSecondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .multilineTextAlignment(.leading)
                                    }
                                    Spacer(minLength: 6)
                                    let st = RacketSplitReview.status(p)
                                    Text(st.rawValue).font(.caption.weight(.semibold))
                                        .foregroundStyle(st == .matched ? SnappetColor.brand : st == .unsure ? SnappetColor.perfModerate : SnappetColor.textSecondary)
                                        .fixedSize()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("racket.split.part.\(k)")
                            .accessibilityHint("Plays this part")
                            Button { reviewPlayback?.pause(); editing = p } label: {
                                Text("Fix").font(.system(size: 14, weight: .semibold)).foregroundStyle(SnappetColor.brand)
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    .overlay(Capsule().strokeBorder(SnappetColor.hairline))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("racket.split.fix.\(k)")
                            .accessibilityLabel("Fix \(RacketSplitReview.name(p, ordinal: ords[p.id], unit: u))")
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .pagerGlass(cornerRadius: 14)
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(SnappetColor.brand, lineWidth: playing == k ? 1.5 : 0))
                    }
                    primary("Looks right, apply", id: "racket.split.apply") { apply(id) }
                }
                .padding(20)
            }
        }
        .navigationTitle("Split recording")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Apply") { apply(id) }.accessibilityIdentifier("racket.split.applyTop")
            }
        }
        .onAppear { ensureDraft(id); ensureReviewPlayback(id) }
        .onDisappear { reviewPlayback?.pause() }
    }

    /// Where the recording's video lives (the 10-minute originals, or the derived videos).
    private var reviewSources: [RacketVideoMap.Source] {
        draftFor.flatMap { store.ex($0)?.racketRecordingLog }.map(RacketVideoMap.sources) ?? []
    }

    /// One player on the whole recording (step 3's composition across the Photos parts), made once per recording.
    private func ensureReviewPlayback(_ id: UUID) {
        guard reviewFor != id, let log = store.ex(id)?.racketRecordingLog else { return }
        reviewPlayback?.stop()
        reviewFor = id
        let total = log.timelineSec
        let pb = RacketPlayback(partStart: 0, partEnd: max(1, total))
        reviewPlayback = pb
        Task { await pb.load(RacketVideoMap.segments(start: 0, end: total, log: log)) }
    }

    /// A part tapped in the bar or the list: seek to it and play it (to its end).
    private func playPart(_ k: Int) {
        guard let pb = reviewPlayback, draft.indices.contains(k) else { return }
        let p = draft[k]
        pb.play(from: RacketScrub.seekTarget(p, sources: reviewSources), until: p.endSec)
        Haptics.tap()
    }

    private func apply(_ id: UUID) {
        store.update(id) { e in
            guard var l = e.racketRecordingLog else { return }
            let parts = RacketSplitEditor.normalized(draft, duration: l.timelineSec)
            let out = RacketSplitAssign.apply(parts: parts, sets: e.sets, base: l.baseIndex, startedAt: l.startedAt)
            e.sets = out.sets
            l.split = RacketSplit(parts: out.parts, appliedAt: .now)
            l.keptAsOne = nil
            e.racketRecordingLog = l
        }
        draft = store.ex(id)?.racketRecordingLog?.split?.parts ?? draft
        Haptics.success()
        path.append(.assign(id))
    }

    // MARK: TtSplitAssign

    @ViewBuilder private func splitAssign(_ id: UUID) -> some View {
        let ex = store.ex(id)
        let u = ex?.racketFormat.sport.unit ?? .game
        let parts = ex?.racketRecordingLog?.split?.parts.filter { $0.kind == .game } ?? []
        let sets = ex?.sets ?? []
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Match video to your \(u.noun)s").font(.system(size: 22, weight: .semibold))
                note("Each part links to that \(u.noun). It stays inside the original video.")
                ForEach(Array(parts.enumerated()), id: \.element.id) { k, p in
                    HStack(spacing: 8) {
                        Text(RacketSplitAssign.title(p, ordinal: k + 1, sets: sets, unit: u))
                            .font(.system(size: 15, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Text("→").foregroundStyle(SnappetColor.textSecondary)
                        Text(RacketVideoTime.range(p.startSec, p.endSec))
                            .font(SnappetType.detail.monospacedDigit()).foregroundStyle(SnappetColor.textSecondary)
                    }
                    .padding(12).pagerGlass(cornerRadius: 14)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("racket.assign.row.\(k)")
                }
                if let missing = RacketSplitAssign.missingScore(parts: parts, sets: sets, unit: u) {
                    panel {
                        Text(missing.line).font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(SnappetColor.perfModerate)
                            .accessibilityIdentifier("racket.assign.missing")
                        note("It shows as “Score unconfirmed” and counts for neither side until you enter it.")
                        chipButton("Enter the score", id: "racket.assign.enterScore") {
                            if let i = missing.part.setIndex {
                                scoring = RacketScoreTarget(exerciseID: id, unitIndex: i, durationSec: nil)
                            }
                        }
                    }
                }
                primary("Save", id: "racket.assign.save") { path.append(.done(id)) }
            }
            .padding(20)
        }
        .navigationTitle(ex.map { "Match \($0.racketMatchTitle)" } ?? "Match")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { path.append(.done(id)) }.accessibilityIdentifier("racket.assign.done")
            }
        }
    }

    // MARK: TtSplitDone

    @ViewBuilder private func splitDone(_ id: UUID) -> some View {
        let ex = store.ex(id)
        let u = ex?.racketFormat.sport.unit ?? .game
        let parts = ex?.racketRecordingLog?.split?.countedParts ?? []
        let ords = RacketSplitReview.ordinals(parts)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(parts.count) \(parts.count == 1 ? "part" : "parts") saved")
                    .font(.system(size: 28, weight: .light))
                    .accessibilityIdentifier("racket.splitDone.count")
                note("Each \(u.noun) is now its own part of the original video, ready for rallies. No extra space used.")
                ForEach(parts) { p in
                    HStack {
                        Text(RacketSplitReview.name(p, ordinal: ords[p.id], unit: u)).font(SnappetType.body)
                        Spacer()
                        Text(RacketVideoTime.clock(p.durationSec)).font(SnappetType.body.monospacedDigit())
                            .foregroundStyle(SnappetColor.textSecondary)
                    }
                    .padding(.vertical, 4)
                }
                if ex?.racketRecordingLog?.originalDeleted != true {
                    secondary("Delete the long original…", id: "racket.splitDone.delete") { deleting = id }
                }
                let sport = ex?.racketFormat.sport ?? .tableTennis
                if RacketCapabilityRegistry.capabilities(for: sport).has(.findRallies), let ex {
                    // Prompt 248: "Find rallies in all" (SplitDone → Analyzing).
                    secondary("Find rallies in all", id: "racket.splitDone.findAll") {
                        let refs = RacketVideoRows.rows(for: ex).map { self.ref(ex, $0) }
                        path.append(.videos)
                        findRallies(refs, sport: sport)
                    }
                } else {
                    note(RacketRallyFinding.notYetLine(sport) + " Mark and tag rallies from Your videos.")
                }
                primary("Done", id: "racket.splitDone.done") { path.append(.videos) }
            }
            .padding(20)
        }
        .navigationTitle("Split saved")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
    }

    // MARK: Your videos (FindRallies / TtNoModelVideos)

    private var racketEntities: [SessionExercise] {
        session.exercises.filter { $0.discipline == .racket && $0.racketRecordingLog != nil }
    }

    @ViewBuilder private var videosList: some View { videosContent(noModel: false, previewSport: nil) }

    /// FindRallies (a model) or TtNoModelVideos (none, or "Preview a sport with no model").
    @ViewBuilder private func videosContent(noModel: Bool, previewSport: RacketSport?) -> some View {
        let sport = previewSport ?? racketEntities.first?.racketSport
            ?? session.exercises.first { $0.discipline == .racket }?.racketSport ?? .tableTennis
        let canFind = RacketRallyFinding.availability(for: sport, noModel: noModel) != .notYet
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if previewSport != nil {
                    Text("Preview: a sport with no model").font(.caption.weight(.semibold))
                        .foregroundStyle(SnappetColor.perfModerate)
                        .accessibilityIdentifier("racket.videos.previewLabel")
                }
                if !canFind {
                    panel {
                        Text(RacketRallyFinding.notYetLine(sport)).font(.system(size: 15, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("racket.videos.notYet")
                        note("You can still watch, mark rallies and tag them yourself, or ask another AI app.")
                    }
                } else {
                    note("Scanned after each session, or whenever you choose.")
                        .accessibilityIdentifier("racket.videos.header")
                    if !autoAsk.isEmpty, previewSport == nil {
                        panel {
                            Text("Find rallies in \(autoAsk.count) \(autoAsk.count == 1 ? "video" : "videos")?")
                                .font(.system(size: 15, weight: .semibold))
                                .accessibilityIdentifier("racket.videos.autoAsk")
                            note("Snappet scans on this phone. It runs fastest on a charger. Change this in Settings.")
                            HStack(spacing: 8) {
                                chipButton("Find rallies", id: "racket.videos.autoAsk.yes") {
                                    let parts = autoAsk
                                    autoAsk = []
                                    findRallies(parts, sport: sport)
                                }
                                chipButton("Not now", id: "racket.videos.autoAsk.no") {
                                    for id in Set(autoAsk.map(\.exerciseID)) { store.updateLog(id) { $0.scanOffered = true } }
                                    autoAsk = []
                                }
                            }
                        }
                    }
                    if previewSport == nil, scanCenter.runningID != nil || !scanCenter.queuedIDs.isEmpty {
                        chipButton("Finding rallies… See progress", id: "racket.videos.progress") { path.append(.analyzing) }
                    }
                }
                if racketEntities.isEmpty {
                    note("No recordings yet. Choose “Everything” when you set up a match or a drill.")
                        .accessibilityIdentifier("racket.videos.empty")
                }
                ForEach(racketEntities) { ex in entitySection(ex, canFind: canFind) }
                let keep = RacketKeepRallies.plan(session.exercises)
                if keep.canKeep, previewSport == nil {
                    secondary("Keep rallies only…", id: "racket.videos.keepRallies") { keeping = true }
                }
                if canFind {
                    if !unscannedParts.isEmpty {
                        secondary("Scan all on charger", id: "racket.videos.scanAll") {
                            findRallies(unscannedParts, sport: sport, waitForCharger: true)
                        }
                    }
                } else {
                    note("When a model passes its test for \(sport.label.lowercased()), Find rallies appears here.")
                }
                chipButton("What works for \(sport.label.lowercased())", id: "racket.videos.capabilities") {
                    path.append(.capabilities(sport))
                }
            }
            .padding(20)
        }
        .navigationTitle("Your videos")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(previewSport == nil)
        .toolbar {
            if previewSport == nil {
                closeButton()
                ToolbarItem(placement: .confirmationAction) {
                    Button("Settings") { path.append(.analysisSettings(sport)) }
                        .accessibilityIdentifier("racket.videos.settings")
                }
            }
        }
        .onAppear {
            refreshFound()
            guard previewSport == nil else { return }
            scanCenter.settle(store)
            if canFind { offerAutoScan() }
        }
    }

    /// The row's scan state (FindRallies: "Snappet placeholder v1" / "Not scanned" / "Scanning · 62%").
    @ViewBuilder private func scanLine(_ scan: RacketScanState, id: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(scan.chip).font(.caption.weight(.semibold))
                .foregroundStyle(scan.isScanned ? SnappetColor.brand : SnappetColor.textSecondary)
                .accessibilityIdentifier(id)
            if case .scanned(_, true) = scan {
                Text("A newer Snappet model is available.").font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
            }
            if case .paused(_, let n?) = scan {
                Text(n).font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
            }
            if case .failed(let n) = scan {
                Text(n).font(SnappetType.detail).foregroundStyle(SnappetColor.perfModerate)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Find rallies (not scanned) or Re-scan… (scanned), Resume (paused), progress (scanning), Compare / Review.
    @ViewBuilder private func scanButtons(_ ex: SessionExercise, _ r: RacketPartRef, _ scan: RacketScanState, id: String) -> some View {
        switch scan {
        case .notScanned, .failed:
            chipButton("Find rallies", id: "racket.\(id).find") { findRallies([r], sport: ex.racketFormat.sport) }
        case .scanning, .queued, .waiting:
            chipButton("See progress", id: "racket.\(id).progress") { path.append(.analyzing) }
        case .paused:
            chipButton("Resume", id: "racket.\(id).resume") {
                if let rec = ex.racketRecordingLog?.latestScan(partStart: r.startSec, partEnd: r.endSec) {
                    scanCenter.resume(rec.id, exerciseID: ex.id, store: store)
                    path.append(.analyzing)
                }
            }
        case .readyToCompare:
            chipButton("Compare scans", id: "racket.\(id).compare") {
                if let rec = ex.racketRecordingLog?.latestScan(partStart: r.startSec, partEnd: r.endSec) {
                    path.append(.modelCompare(r, rec.id))
                }
            }
        case .scanned:
            chipButton("Results", id: "racket.\(id).results") { path.append(.analysis(r)) }
            chipButton("Re-scan…", id: "racket.\(id).rescan") { path.append(.chooseModel(r)) }
        }
    }

    @ViewBuilder private func entitySection(_ ex: SessionExercise, canFind: Bool) -> some View {
        let log = ex.racketRecordingLog
        let state = log.map { RacketOriginalCheck.state(needed: RacketVideoMap.neededIdentifiers($0), found: found) } ?? .noVideo
        VStack(alignment: .leading, spacing: 10) {
            Text(ex.isRacketDrill ? (ex.displayName ?? "Drill") : "Match \(ex.racketMatchTitle)").snappetLabel()
            if case .missing = state {
                Text("Original video not found").font(SnappetType.detail).foregroundStyle(SnappetColor.perfModerate)
                    .accessibilityIdentifier("racket.videos.missing")
            }
            if ex.isRacketDrill {
                panel {
                    Text(RacketVideoRows.drillHeader(ex)).font(SnappetType.body)
                        .accessibilityIdentifier("racket.videos.drillHeader")
                    chipButton("Drill videos", id: "racket.videos.drill") { path.append(.drill(ex.id)) }
                }
            } else {
                ForEach(Array(RacketVideoRows.rows(for: ex).enumerated()), id: \.element.id) { k, row in
                    videoRow(ex, row, index: k, state: state, canFind: canFind)
                }
            }
        }
    }

    private func ref(_ ex: SessionExercise, _ row: RacketVideoRow) -> RacketPartRef {
        RacketPartRef(exerciseID: ex.id, title: ex.isRacketDrill ? row.title : "\(row.title) video",
                      startSec: row.startSec, endSec: row.endSec, setIndex: row.setIndex)
    }

    @ViewBuilder private func videoRow(_ ex: SessionExercise, _ row: RacketVideoRow, index k: Int,
                                       state: RacketOriginalCheck.State, canFind: Bool) -> some View {
        let r = ref(ex, row)
        let scan = ex.racketRecordingLog.map {
            RacketScanState.of($0, partStart: row.startSec, partEnd: row.endSec,
                               current: RacketCapabilityRegistry.capabilities(for: ex.racketFormat.sport).model)
        } ?? .notScanned
        panel {
            HStack(alignment: .firstTextBaseline) {
                Text(row.title).font(.system(size: 17, weight: .semibold))
                Spacer()
                if let chip = row.scoreChip {
                    Text(chip).font(.caption.weight(.semibold)).foregroundStyle(SnappetColor.perfModerate)
                        .accessibilityIdentifier("racket.videos.chip.\(k)")
                }
            }
            if canFind {
                scanLine(scan, id: "racket.videos.scan.\(k)")
            }
            Text(row.line).font(SnappetType.detail.monospacedDigit()).foregroundStyle(SnappetColor.textSecondary)
                .accessibilityIdentifier("racket.videos.line.\(k)")
            Text(row.tagLine).font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                .accessibilityIdentifier("racket.videos.tags.\(k)")
            FlowRow {
                chipButton("Play", id: "racket.videos.play.\(k)") {
                    if case .missing = state { path.append(.missing(r)) } else { path.append(.player(r, ralliesOnly: false)) }
                }
                chipButton(canFind ? "Open timeline" : "Mark rallies", id: "racket.videos.mark.\(k)") { path.append(.timeline(r)) }
                if canFind { scanButtons(ex, r, scan, id: "videos.\(k)") }
                if row.rallies > 0 {
                    chipButton("See your tags", id: "racket.videos.seeTags.\(k)") { path.append(.summary(r)) }
                }
                if let i = row.setIndex, ex.isRacketMatch {
                    chipButton("Edit score", id: "racket.videos.score.\(k)") {
                        scoring = RacketScoreTarget(exerciseID: ex.id, unitIndex: i, durationSec: nil)
                    }
                }
                if row.kind == .whole {
                    chipButton("Split recording", id: "racket.videos.split") { path.append(.review(ex.id)) }
                }
                // Step 4 (prompt 247): the round trip with another AI app.
                chipButton("Another AI app", id: "racket.videos.ai.\(k)") { path.append(.aiSend(r)) }
                chipButton("Bring results back", id: "racket.videos.aiImport.\(k)") { path.append(.aiImport(r)) }
            }
            aiPending(ex, r, id: "videos.\(k)")
        }
    }

    // MARK: TtDrillVideos

    @ViewBuilder private func drillVideos(_ id: UUID) -> some View {
        let ex = store.ex(id)
        let rows = ex.map(RacketVideoRows.rows(for:)) ?? []
        let rallies = ex?.racketRecordingLog?.allRallies ?? []
        let longest = rallies.filter(\.isRally).max { $0.durationSec < $1.durationSec }
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Your drill videos").font(.system(size: 22, weight: .semibold))
                note(ex.map(RacketVideoRows.drillHeader) ?? "")
                ForEach(Array(rows.enumerated()), id: \.element.id) { k, row in
                    let r = RacketPartRef(exerciseID: id, title: row.title, startSec: row.startSec, endSec: row.endSec,
                                          setIndex: row.setIndex)
                    let s = RacketTagSummary.make(RacketRallyMarking.inRange(rallies, row.startSec, row.endSec),
                                                  sport: ex?.racketSport ?? .tableTennis)
                    panel {
                        Text(row.title).font(.system(size: 17, weight: .semibold))
                        Text(s.marked > 0 ? "\(s.marked) rallies · \(RacketVideoTime.clock(row.endSec - row.startSec))"
                                          : "\(RacketVideoTime.clock(row.endSec - row.startSec)) · not marked")
                            .font(SnappetType.detail.monospacedDigit()).foregroundStyle(SnappetColor.textSecondary)
                            .accessibilityIdentifier("racket.drill.line.\(k)")
                        if let l = s.longestSec { note("Longest \(RacketTagSummary.seconds(l))") }
                        if let ex, let log = ex.racketRecordingLog,
                           RacketCapabilityRegistry.capabilities(for: ex.racketFormat.sport).has(.findRallies) {
                            scanLine(RacketScanState.of(log, partStart: row.startSec, partEnd: row.endSec,
                                                        current: RacketCapabilityRegistry.capabilities(for: ex.racketFormat.sport).model),
                                     id: "racket.drill.scan.\(k)")
                        }
                        FlowRow {
                            if s.marked > 0 {
                                chipButton("Play rallies only", id: "racket.drill.rallies.\(k)") { path.append(.player(r, ralliesOnly: true)) }
                            }
                            chipButton(s.marked > 0 ? "Full block" : "Play block", id: "racket.drill.play.\(k)") {
                                path.append(.player(r, ralliesOnly: false))
                            }
                            let canFind = RacketCapabilityRegistry.capabilities(for: ex?.racketSport ?? .tableTennis).has(.findRallies)
                            chipButton(canFind ? "Open timeline" : "Mark rallies", id: "racket.drill.mark.\(k)") { path.append(.timeline(r)) }
                            if canFind, let ex, let log = ex.racketRecordingLog {
                                scanButtons(ex, r, RacketScanState.of(log, partStart: row.startSec, partEnd: row.endSec,
                                                                      current: RacketCapabilityRegistry.capabilities(for: ex.racketFormat.sport).model),
                                            id: "drill.\(k)")
                            }
                            chipButton("Another AI app", id: "racket.drill.ai.\(k)") { path.append(.aiSend(r)) }
                            chipButton("Bring results back", id: "racket.drill.aiImport.\(k)") { path.append(.aiImport(r)) }
                        }
                        if let ex { aiPending(ex, r, id: "drill.\(k)") }
                    }
                }
                if let longest, let row = rows.first(where: { longest.startSec >= $0.startSec && longest.startSec < $0.endSec }) {
                    // DrillVideos → PlayerAnalyzed (V2.1): the longest rally opens on Analyzed.
                    secondary("Watch the longest rally", id: "racket.drill.longest") {
                        path.append(.analyzed(RacketPartRef(exerciseID: id, title: row.title, startSec: longest.startSec,
                                                            endSec: longest.endSec, setIndex: row.setIndex)))
                    }
                }
                note("Blocks and rests come from your timers. A drill keeps its one recording; it never offers to delete the original.")
            }
            .padding(20)
        }
        .navigationTitle(ex?.displayName ?? "Drill videos")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: TtTagDone

    @ViewBuilder private func tagDone(_ ref: RacketPartRef) -> some View {
        let ex = store.ex(ref.exerciseID)
        let rallies = RacketRallyMarking.inRange(ex?.racketRecordingLog?.allRallies ?? [], ref.startSec, ref.endSec)
        let s = RacketTagSummary.make(rallies, sport: ex?.racketSport ?? .tableTennis)
        let g = RacketGuessSummary.make(rallies)
        let modelPath = rallies.contains(where: \.isFromModel)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(modelPath && g.unsureTotal > 0 ? g.checkedLine : s.checkedLine)
                    .font(.system(size: 28, weight: .light)).accessibilityIdentifier("racket.tagDone.checked")
                note(modelPath ? "Your tags replace Snappet’s guesses everywhere: stats, timeline, player and reels."
                               : "Your tags are what Snappet uses everywhere: stats, timeline, player and reels.")
                panel {
                    statLine("Tagged by you", "\(s.tagged) \(s.tagged == 1 ? "rally" : "rallies")")
                    if modelPath {
                        statLine("Snappet’s guesses", "\(g.guesses) \(g.guesses == 1 ? "rally" : "rallies")")
                            .accessibilityElement(children: .combine).accessibilityIdentifier("racket.tagDone.guesses")
                        statLine("Unsure left", "\(g.unsureLeft)")
                            .accessibilityElement(children: .combine).accessibilityIdentifier("racket.tagDone.unsureLeft")
                    } else {
                        statLine("Snappet’s guesses", "None, no model yet")
                        statLine("Left to tag", "\(s.untagged)")
                    }
                    if s.fromAI > 0 {
                        statLine("From other apps", "\(s.fromAI) accepted")
                    }
                }
                if s.untagged > 0 {
                    // Review5: this button was unwired on the board.
                    primary("Tag winners for the rest", id: "racket.tagDone.rest") {
                        path.removeLast()
                        path.append(.timeline(ref))
                    }
                }
                secondary("Open timeline", id: "racket.tagDone.timeline") { path.removeLast() }
                secondary("See your tags", id: "racket.tagDone.summary") { path.append(.summary(ref)) }
            }
            .padding(20)
        }
        .navigationTitle(ref.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { path = [.videos] }.accessibilityIdentifier("racket.tagDone.done")
            }
        }
    }

    private func statLine(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(SnappetType.body)
            Spacer()
            Text(v).font(SnappetType.body.monospacedDigit()).foregroundStyle(SnappetColor.textSecondary)
        }
    }

    // MARK: TtManualSummary ("From your tags")

    @ViewBuilder private func manualSummary(_ ref: RacketPartRef) -> some View {
        let ex = store.ex(ref.exerciseID)
        let sport = ex?.racketSport ?? .tableTennis
        let rallies = RacketRallyMarking.inRange(ex?.racketRecordingLog?.allRallies ?? [], ref.startSec, ref.endSec)
        let s = RacketTagSummary.make(rallies, sport: sport)
        let sides = RacketWatchCopy.sides(opponent: ex?.opponent, doubles: ex?.isDoubles ?? false)
        let scoreState = ref.setIndex.flatMap { i in ex.flatMap { i < $0.sets.count ? $0.sets[i].racketScoreState : nil } }
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let st = scoreState {
                    HStack {
                        Text(scoreHeadline(st)).font(.system(size: 28, weight: .light)).monospacedDigit()
                            .accessibilityIdentifier("racket.summary.score")
                        Spacer()
                        if let i = ref.setIndex {
                            chipButton("Edit score", id: "racket.summary.editScore") {
                                scoring = RacketScoreTarget(exerciseID: ref.exerciseID, unitIndex: i, durationSec: nil)
                            }
                        }
                    }
                }
                Text("Source: your tags\(s.fromAI > 0 ? " and \(s.aiNames.joined(separator: ", "))" : "")"
                     + (rallies.contains(where: \.isGuess) ? " · Snappet’s guesses count once you confirm them"
                        : RacketCapabilityRegistry.capabilities(for: sport).hasModel ? "" : " · No model for \(sport.label.lowercased())"))
                    .snappetLabel()
                HStack(spacing: 10) {
                    bigStat("\(s.marked)", "rallies marked", id: "racket.summary.marked")
                    bigStat("\(s.tagged)", "tagged", id: "racket.summary.tagged")
                    bigStat(s.longestSec.map(RacketTagSummary.seconds) ?? "—", "longest rally", id: "racket.summary.longest")
                }
                panel {
                    Text("Who won your tagged rallies").snappetLabel()
                    bar(sides.us, s.wonUs, of: max(1, s.wonUs + s.wonThem), id: "racket.summary.won.us")
                    bar(sides.them, s.wonThem, of: max(1, s.wonUs + s.wonThem), id: "racket.summary.won.them")
                }
                if !s.endings.isEmpty {
                    panel {
                        Text("How rallies ended").snappetLabel()
                        ForEach(s.endings, id: \.ending) { e in
                            bar(e.ending.label, e.count, of: max(1, s.endings.first?.count ?? 1), id: "racket.summary.ending.\(e.ending.rawValue)")
                        }
                    }
                }
                Text(s.sourceLine).font(.system(size: 15, weight: .semibold)).accessibilityIdentifier("racket.summary.source")
                note("Rally times come from your marks. Shot counts and ball path need a model, so they aren’t shown. These count in your history and trends like any other numbers.")
                if s.marked > 0 {
                    primary("Play your rallies", id: "racket.summary.play") { path.append(.player(ref, ralliesOnly: true)) }
                }
                secondary("Keep marking", id: "racket.summary.keepMarking") {
                    if path.count >= 2, case .timeline = path[path.count - 2] { path.removeLast() } else { path.append(.timeline(ref)) }
                }
            }
            .padding(20)
        }
        .navigationTitle(ref.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { path = [.videos] }.accessibilityIdentifier("racket.summary.done")
            }
        }
    }

    private func scoreHeadline(_ st: RacketScoreState) -> String {
        switch st {
        case .confirmed(let s): return "\(s.scoreFor > s.scoreAgainst ? "Won" : "Lost") \(s.label)"
        case .fromWatch(let s): return "\(s.scoreFor > s.scoreAgainst ? "Won" : "Lost") \(s.label) · from Watch"
        case .unconfirmed: return RacketScoreState.unconfirmedLabel
        }
    }

    private func bigStat(_ v: String, _ k: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(v).font(.system(size: 26, weight: .light)).monospacedDigit().accessibilityIdentifier(id)
            Text(k).font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12).pagerGlass(cornerRadius: 14)
    }

    private func bar(_ label: String, _ n: Int, of total: Int, id: String) -> some View {
        HStack(spacing: 8) {
            Text(label).font(SnappetType.body).frame(width: 110, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            GeometryReader { g in
                Capsule().fill(SnappetColor.brand).frame(width: max(4, g.size.width * Double(n) / Double(total)))
            }
            .frame(height: 8)
            Text("\(n)").font(SnappetType.body.monospacedDigit()).frame(width: 30, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }

    // MARK: TtOriginalMissing

    @ViewBuilder private func originalMissing(_ ref: RacketPartRef) -> some View {
        let ids = store.ex(ref.exerciseID)?.racketRecordingLog.map(RacketVideoMap.neededIdentifiers) ?? []
        VStack(alignment: .leading, spacing: 14) {
            Text("This video isn’t on your phone").font(.system(size: 22, weight: .semibold))
                .accessibilityIdentifier("racket.missing.title")
            Text("Deleted, edited or stored only in iCloud").snappetLabel()
            note("The parts and timeline point into Photos videos, and Snappet can’t find them right now.")
            primary("Download from iCloud", id: "racket.missing.download") {
                Task {
                    _ = await RacketVideoLibrary.shared.download(ids)
                    refreshFound()
                    if case .available = RacketOriginalCheck.state(needed: ids, found: found) {
                        path.removeLast()
                        path.append(.player(ref, ralliesOnly: false))
                    }
                }
            }
            secondary("Find it in Photos", id: "racket.missing.photos") { RacketVideoLibrary.shared.openPhotos() }
            secondary("Keep tags and stats only", id: "racket.missing.keep") { path.removeLast() }
            note("Your scores, tags and stats are safe either way. Only playback needs the video.")
            Spacer()
        }
        .padding(20)
        .navigationTitle(ref.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - TtSplitEdit ("Fix one part")

struct RacketSplitEditSheet: View {
    let part: RacketVideoPart
    let parts: [RacketVideoPart]
    let duration: Double
    let unit: RacketUnit
    /// The review's player on the whole original (shared, so nothing reloads); nil shows no video area.
    var playback: RacketPlayback? = nil
    var sources: [RacketVideoMap.Source] = []
    var sport: RacketSport = .tableTennis
    let onSave: ([RacketVideoPart]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var work: [RacketVideoPart] = []
    @State private var configured = false
    @State private var thumbnails: [UIImage?] = []
    @State private var stripWidth: CGFloat = 320

    private var current: RacketVideoPart? { work.first { $0.id == part.id } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let p = current {
                        if let pb = playback {
                            RacketVideoSurface(playback: pb, sport: sport, height: 200)
                            HStack(spacing: 10) {
                                Text("Playhead \(RacketVideoTime.clock(pb.position))")
                                    .font(SnappetType.detail.monospacedDigit()).foregroundStyle(SnappetColor.textSecondary)
                                    .accessibilityIdentifier("racket.split.edit.playhead")
                                Spacer()
                                Button(pb.playing ? "Pause" : "Play") { pb.playing ? pb.pause() : pb.play(from: pb.position, until: p.endSec) }
                                    .font(.system(size: 15, weight: .semibold))
                                    .buttonStyle(.bordered)
                                    .accessibilityIdentifier("racket.split.edit.play")
                            }
                        }
                        Text("Drag to where it starts and ends").snappetLabel()
                        RacketRangeStrip(start: p.startSec, end: p.endSec, window: windowRange(p),
                                         thumbnails: thumbnails, playhead: playback?.position,
                                         onHandleEnded: { isStart in
                                             guard let c = current else { return }
                                             playback?.seek(to: isStart ? c.startSec : c.endSec)
                                         },
                                         onScrub: playback == nil ? nil : { t, ended in
                                             if ended { playback?.seek(to: t) } else { playback?.scrub(to: t, tolerance: tolerance(p)) }
                                         }) { s, e in
                            let before = current
                            work = RacketSplitEditor.setBounds(work, id: p.id, start: s, end: e, duration: duration)
                            // The video follows the handle being dragged.
                            if let before, let after = current, let pb = playback {
                                if after.startSec != before.startSec { pb.scrub(to: after.startSec, tolerance: tolerance(p)) }
                                else if after.endSec != before.endSec { pb.scrub(to: after.endSec, tolerance: tolerance(p)) }
                            }
                        }
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { stripWidth = $0 }
                        edgeRow("Starts", value: p.startSec, id: "start") { d in
                            work = RacketSplitEditor.setBounds(work, id: p.id, start: p.startSec + d, end: p.endSec, duration: duration)
                            if let c = current { playback?.seek(to: c.startSec) }
                        }
                        edgeRow("Ends", value: p.endSec, id: "end") { d in
                            work = RacketSplitEditor.setBounds(work, id: p.id, start: p.startSec, end: p.endSec + d, duration: duration)
                            if let c = current { playback?.seek(to: c.endSec) }
                        }
                        Text("What is this part?").snappetLabel()
                        FlowRow {
                            ForEach(RacketPartKind.editChoices, id: \.self) { k in
                                choice(k.label(unit: unit), selected: p.kind == k, id: "racket.split.edit.kind.\(k.rawValue)") {
                                    work = RacketSplitEditor.setKind(work, id: p.id, kind: k)
                                }
                            }
                        }
                        if p.kind == .unsure || p.kind == .game {
                            Text("Belongs to").snappetLabel()
                            FlowRow {
                                ForEach(RacketPartBelongs.allCases, id: \.self) { b in
                                    choice(b.label(unit: unit), selected: p.belongs == b, id: "racket.split.edit.belongs.\(b.rawValue)") {
                                        work = RacketSplitEditor.setBelongs(work, id: p.id, belongs: b)
                                    }
                                }
                            }
                        }
                        let cut = splitPoint(p)
                        HStack(spacing: 10) {
                            outline("Split here", id: "racket.split.edit.splitHere") {
                                if let cut { work = RacketSplitEditor.split(work, id: p.id, at: cut); Haptics.tap() }
                            }
                            .disabled(cut == nil)
                            .opacity(cut == nil ? 0.45 : 1)
                            outline("Merge with next", id: "racket.split.edit.merge") {
                                work = RacketSplitEditor.mergeWithNext(work, id: p.id)
                            }
                        }
                        Text(splitNote(p, cut: cut))
                            .font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("racket.split.edit.splitNote")
                    }
                }
                .padding(20)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // TtSplitEdit: Cancel · the part's range · Save.
                ToolbarItem(placement: .principal) {
                    Text(current.map { RacketVideoTime.range($0.startSec, $0.endSec) } ?? "Fix one part")
                        .font(.system(size: 17, weight: .semibold)).monospacedDigit()
                        .accessibilityIdentifier("racket.split.edit.range")
                }
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(work); dismiss() }.accessibilityIdentifier("racket.split.edit.save")
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            guard !configured else { return }
            configured = true
            work = parts
            playback?.pause()
            playback?.seek(to: RacketScrub.seekTarget(part, sources: sources))
        }
        .onDisappear { playback?.pause() }
        .task(id: filmKey) { await loadFilmStrip() }
    }

    /// The film strip is redrawn when the window (the neighbours' outer edges) or the strip's size changes, or once
    /// the video has loaded.
    private var filmKey: String {
        guard let p = current else { return "" }
        let w = windowRange(p)
        return "\(w.lowerBound)-\(w.upperBound)-\(Int(stripWidth))-\(playback?.player != nil)"
    }

    private func loadFilmStrip() async {
        guard let pb = playback, let player = pb.player, let p = current else { thumbnails = []; return }
        let w = windowRange(p)
        let count = RacketScrub.thumbnailCount(width: Double(stripWidth), height: 56)
        let times = RacketScrub.thumbnailTimes(start: w.lowerBound, end: w.upperBound, count: count).map { $0 - pb.partStart }
        let images = await RacketVideoLibrary.shared.thumbnails(player, times: times)
        if !Task.isCancelled { thumbnails = images }
    }

    private func tolerance(_ p: RacketVideoPart) -> Double {
        let w = windowRange(p)
        return RacketScrub.tolerance(windowSec: w.upperBound - w.lowerBound, widthPoints: Double(stripWidth))
    }

    private func splitPoint(_ p: RacketVideoPart) -> Double? {
        guard let pb = playback else { return nil }
        return RacketScrub.splitPoint(playhead: pb.position, part: p)
    }

    private func splitNote(_ p: RacketVideoPart, cut: Double?) -> String {
        if let cut { return "Split here cuts this part at the playhead, \(RacketVideoTime.clock(cut)). Adjust each half after." }
        return "Split here cuts this part at the playhead. Play or drag on the strip to put it inside this part, at least \(Int(RacketSplitEditor.minPartSec)) s from each end."
    }

    private func windowRange(_ p: RacketVideoPart) -> ClosedRange<Double> {
        let i = work.firstIndex { $0.id == p.id } ?? 0
        let lo = i > 0 ? work[i - 1].startSec : 0
        let hi = i < work.count - 1 ? work[i + 1].endSec : duration
        return lo...max(lo + 1, hi)
    }

    private func edgeRow(_ label: String, value: Double, id: String, nudge: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(label).font(SnappetType.body)
            Text(RacketVideoTime.clock(value)).font(SnappetType.body.monospacedDigit()).foregroundStyle(SnappetColor.textSecondary)
            Spacer()
            ForEach([(-10.0, "−10 s"), (-1.0, "−1 s"), (1.0, "+1 s"), (10.0, "+10 s")], id: \.0) { d, t in
                Button(t) { nudge(d) }
                    .font(.system(size: 13, weight: .semibold))
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("racket.split.edit.\(id).\(Int(d))")
            }
        }
    }

    private func choice(_ label: String, selected: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: { action(); Haptics.tap() }) {
            Text(label).font(.system(size: 14, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.black : SnappetColor.ink)
                .padding(.horizontal, 12).padding(.vertical, 8)
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
        }
        .buttonStyle(.plain).pagerOutline()
        .accessibilityIdentifier(id)
    }
}

/// TtSplitReview's bar as a segmented timeline: one segment per part (game accent, break / warmup / not play grey,
/// unsure amber) and the playhead. A tap plays the part under the finger; a drag scrubs the video.
struct RacketSplitTimelineBar: View {
    let parts: [RacketVideoPart]
    let total: Double
    let playback: RacketPlayback
    let onTapPart: (Int) -> Void

    @State private var dragging = false

    var body: some View {
        GeometryReader { g in
            let w = Double(g.size.width)
            ZStack(alignment: .leading) {
                ForEach(RacketSplitTimeline.layout(parts, total: total, width: w), id: \.id) { seg in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color(seg.tone))
                        .frame(width: seg.width, height: 26)
                        .offset(x: seg.x)
                }
                Rectangle().fill(SnappetColor.ink).frame(width: 2, height: 34)
                    .offset(x: RacketSplitTimeline.x(at: playback.position, total: total, width: w) - 1)
            }
            .frame(height: 34)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    guard dragging || abs(v.translation.width) > 6 else { return }
                    dragging = true
                    let t = RacketSplitTimeline.time(atX: v.location.x, total: total, width: w)
                    playback.scrub(to: t, tolerance: RacketScrub.tolerance(windowSec: total, widthPoints: w))
                }
                .onEnded { v in
                    let t = RacketSplitTimeline.time(atX: v.location.x, total: total, width: w)
                    if dragging {
                        playback.seek(to: t)
                    } else if let k = RacketSplitTimeline.partIndex(at: t, in: parts) {
                        onTapPart(k)
                    }
                    dragging = false
                })
        }
        .frame(height: 34)
        .accessibilityElement()
        .accessibilityLabel("Recording split into \(parts.count) parts, playhead at \(RacketVideoTime.clock(playback.position))")
        .accessibilityIdentifier("racket.split.timeline")
    }

    private func color(_ tone: RacketSplitTimeline.Tone) -> Color {
        switch tone {
        case .game: return SnappetColor.brand
        case .unsure: return SnappetColor.perfModerate
        case .grey: return SnappetColor.textSecondary.opacity(0.35)
        }
    }
}

/// A strip with draggable start / end handles over `window` (FixRally / SplitEdit "film strip"). In SplitEdit it also
/// shows frames of the video behind the range, the playhead, and lets a drag on the strip move the playhead.
struct RacketRangeStrip: View {
    let start: Double
    let end: Double
    let window: ClosedRange<Double>
    var thumbnails: [UIImage?] = []
    var playhead: Double? = nil
    /// A handle was released (`true` = the start handle).
    var onHandleEnded: ((Bool) -> Void)? = nil
    /// A drag on the strip outside the handles: the time under the finger, and whether the drag ended.
    var onScrub: ((Double, Bool) -> Void)? = nil
    let onChange: (Double, Double) -> Void

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let span = max(0.001, window.upperBound - window.lowerBound)
            let x0 = (start - window.lowerBound) / span * w
            let x1 = (end - window.lowerBound) / span * w
            let time: (CGFloat) -> Double = { window.lowerBound + min(max(0, $0), w) / max(1, w) * span }
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6).fill(SnappetColor.hairline.opacity(0.6))
                if !thumbnails.isEmpty {
                    HStack(spacing: 0) {
                        ForEach(Array(thumbnails.enumerated()), id: \.offset) { _, img in
                            Group {
                                if let img { Image(uiImage: img).resizable().scaledToFill() } else { Color(white: 0.12) }
                            }
                            .frame(width: w / CGFloat(thumbnails.count), height: 48)
                            .clipped()
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    // Outside the range is shaded, so the kept stretch reads at a glance.
                    Rectangle().fill(.black.opacity(0.55)).frame(width: max(0, x0))
                    Rectangle().fill(.black.opacity(0.55)).frame(width: max(0, w - x1)).offset(x: x1)
                }
                RoundedRectangle(cornerRadius: 6)
                    .fill(SnappetColor.brand.opacity(thumbnails.isEmpty ? 0.35 : 0.12))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(SnappetColor.brand, lineWidth: thumbnails.isEmpty ? 0 : 2))
                    .frame(width: max(2, x1 - x0)).offset(x: x0)
                    .allowsHitTesting(false)
                if let playhead, window.contains(playhead) {
                    Rectangle().fill(SnappetColor.ink).frame(width: 2, height: 56)
                        .offset(x: (playhead - window.lowerBound) / span * w - 1)
                        .allowsHitTesting(false)
                }
                handle.offset(x: x0 - 8)
                    .gesture(DragGesture()
                        .onChanged { v in onChange(time(v.location.x), end) }
                        .onEnded { _ in onHandleEnded?(true) })
                handle.offset(x: x1 - 8)
                    .gesture(DragGesture()
                        .onChanged { v in onChange(start, time(v.location.x)) }
                        .onEnded { _ in onHandleEnded?(false) })
            }
            .contentShape(Rectangle())
            .simultaneousGesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    // Leave drags that began on a handle to the handle.
                    guard abs(v.startLocation.x - x0) > 14, abs(v.startLocation.x - x1) > 14 else { return }
                    onScrub?(time(v.location.x), false)
                }
                .onEnded { v in
                    guard abs(v.startLocation.x - x0) > 14, abs(v.startLocation.x - x1) > 14 else { return }
                    onScrub?(time(v.location.x), true)
                }, including: onScrub == nil ? .subviews : .all)
        }
        .frame(height: 56)
        .accessibilityElement()
        .accessibilityLabel("From \(RacketVideoTime.clock(start)) to \(RacketVideoTime.clock(end))")
    }

    private var handle: some View {
        RoundedRectangle(cornerRadius: 4).fill(SnappetColor.brand).frame(width: 16, height: 56)
    }
}

// MARK: - TtDeleteOriginal

struct RacketDeleteOriginalSheet: View {
    let store: RacketVideoStore
    let exerciseID: UUID
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var confirming = false
    @State private var working: String?
    @State private var failure: String?

    var body: some View {
        let log = store.ex(exerciseID)?.racketRecordingLog
        let plan = log.map(RacketVideoSpace.deletePlan) ?? RacketVideoSpace.DeletePlan(parts: [], keepSec: 0, neededBytes: 0, originals: 0)
        let free = RacketRecorder.storage()?.free
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Save parts, then delete").font(.system(size: 22, weight: .semibold))
                    Text("Snappet first saves each part as its own video in Photos. Only then is the original deleted.")
                        .font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary).fixedSize(horizontal: false, vertical: true)
                    VStack(spacing: 10) {
                        row("Parts to save", RacketVideoSpace.partsLine(plan), id: "racket.delete.parts")
                        row("Space needed", RacketVideoSpace.size(plan.neededBytes), id: "racket.delete.needed")
                        if let free { row("Space free", RacketStorageCheck.gigabytes(free), id: "racket.delete.free") }
                        row("Not kept", "Warmup, breaks and parts you marked “not play”", id: "racket.delete.notKept")
                    }
                    .padding(14).pagerGlass(cornerRadius: 18)
                    if let working {
                        ProgressView(working).accessibilityIdentifier("racket.delete.progress")
                    }
                    if let failure {
                        Text(failure).font(SnappetType.detail).foregroundStyle(SnappetColor.perfHard)
                            .accessibilityIdentifier("racket.delete.failure")
                    }
                    Button { confirming = true } label: {
                        Text("Save parts, then delete").font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(SnappetColor.perfHard)
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .overlay(Capsule().strokeBorder(SnappetColor.perfHard, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .disabled(!plan.canDelete || !plan.fits(freeBytes: free) || working != nil)
                    .accessibilityIdentifier("racket.delete.start")
                    Text(plan.fits(freeBytes: free) ? "iOS asks you to confirm the deletion. Your tags and stats stay."
                                                    : "Not enough space to save the parts first. Free some space, then try again.")
                        .font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
            }
            .navigationTitle("Delete original")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .confirmationDialog("Delete the long original?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Save \(plan.parts.count) parts, then delete", role: .destructive) { run(plan) }
                    .accessibilityIdentifier("racket.delete.confirm")
            } message: {
                Text("Each part is saved to Photos first. Then iOS asks you to confirm deleting the original.")
            }
        }
        .preferredColorScheme(.dark)
    }

    private func row(_ k: String, _ v: String, id: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).font(SnappetType.body)
            Spacer(minLength: 10)
            Text(v).font(SnappetType.body.monospacedDigit()).foregroundStyle(SnappetColor.textSecondary)
                .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }

    /// Save every kept part as a new Photos video; only when all are saved, delete the originals (iOS confirms).
    private func run(_ plan: RacketVideoSpace.DeletePlan) {
        guard let log = store.ex(exerciseID)?.racketRecordingLog else { return }
        Task {
            var made: [RacketDerivedVideo] = []
            do {
                for (k, p) in plan.parts.enumerated() {
                    working = "Saving part \(k + 1) of \(plan.parts.count)…"
                    let segs = RacketVideoMap.segments(start: p.startSec, end: p.endSec, log: log)
                    let id = try await RacketVideoLibrary.shared.saveToPhotos([(segs, p.startSec, p.endSec)])
                    made.append(RacketDerivedVideo(localIdentifier: id, startSec: p.startSec, endSec: p.endSec))
                }
                store.updateLog(exerciseID) { $0.derived = ($0.derived ?? []) + made }
                working = "Deleting the original…"
                try await RacketVideoLibrary.shared.delete(log.assets.map(\.localIdentifier))
                store.updateLog(exerciseID) { $0.originalDeleted = true }
                working = nil
                Haptics.success()
                dismiss()
                onDone()
            } catch {
                // The parts already saved stay in Photos and on the log; the original is kept.
                if !made.isEmpty { store.updateLog(exerciseID) { $0.derived = ($0.derived ?? []) + made } }
                working = nil
                failure = error.localizedDescription
            }
        }
    }
}

// MARK: - TtKeepRallies

struct RacketKeepRalliesSheet: View {
    let store: RacketVideoStore
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var confirming = false
    @State private var working: String?
    @State private var failure: String?

    var body: some View {
        let plan = RacketKeepRallies.plan(store.session.exercises)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Keep the rallies, free up space").font(.system(size: 22, weight: .semibold))
                    Text("Snappet saves each rally as its own video in Photos. Only then does it offer to delete today’s full videos.")
                        .font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary).fixedSize(horizontal: false, vertical: true)
                    VStack(spacing: 10) {
                        line("Full videos today", "\(plan.fullVideos)", id: "racket.keep.full")
                        line("Rallies to keep", RacketKeepRallies.ralliesLine(plan), id: "racket.keep.count")
                        if let src = RacketKeepRallies.sourceLine(plan) { line("From", src, id: "racket.keep.source") }
                        line("Space freed", RacketVideoSpace.size(plan.freedBytes), id: "racket.keep.freed")
                        line("Not kept", "Time between rallies, warmup and breaks", id: "racket.keep.notKept")
                    }
                    .padding(14).pagerGlass(cornerRadius: 18)
                    if let working { ProgressView(working) }
                    if let failure {
                        Text(failure).font(SnappetType.detail).foregroundStyle(SnappetColor.perfHard)
                    }
                    Button { confirming = true } label: {
                        Text("Save rallies, then delete").font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(SnappetColor.perfHard)
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .overlay(Capsule().strokeBorder(SnappetColor.perfHard, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .disabled(!plan.canKeep || working != nil)
                    .accessibilityIdentifier("racket.keep.save")
                    Text("iOS asks you to confirm the deletion. Your scores, tags and stats stay.")
                        .font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                }
                .padding(20)
            }
            .navigationTitle("Keep rallies only")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .confirmationDialog("Keep rallies only?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Save \(plan.rallies) rallies, then delete", role: .destructive) { run() }
                    .accessibilityIdentifier("racket.keep.confirm")
            } message: {
                Text("Rallies are saved to Photos first. Then iOS asks you to confirm deleting today’s full videos.")
            }
        }
        .preferredColorScheme(.dark)
    }

    private func line(_ k: String, _ v: String, id: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).font(SnappetType.body)
            Spacer(minLength: 10)
            Text(v).font(SnappetType.body.monospacedDigit()).foregroundStyle(SnappetColor.textSecondary)
                .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }

    private func run() {
        Task {
            do {
                for ex in store.session.exercises where ex.discipline == .racket {
                    guard let log = ex.racketRecordingLog, log.originalDeleted != true, !log.assets.isEmpty else { continue }
                    let ranges = RacketKeepRallies.ranges(log.allRallies, duration: log.timelineSec)
                    guard !ranges.isEmpty else { continue }
                    var made: [RacketDerivedVideo] = []
                    for (k, r) in ranges.enumerated() {
                        working = "Saving rally video \(k + 1) of \(ranges.count)…"
                        let segs = RacketVideoMap.segments(start: r.lowerBound, end: r.upperBound, log: log)
                        let id = try await RacketVideoLibrary.shared.saveToPhotos([(segs, r.lowerBound, r.upperBound)])
                        made.append(RacketDerivedVideo(localIdentifier: id, startSec: r.lowerBound, endSec: r.upperBound))
                    }
                    store.updateLog(ex.id) { $0.derived = made }
                    working = "Deleting the full videos…"
                    try await RacketVideoLibrary.shared.delete(log.assets.map(\.localIdentifier))
                    store.updateLog(ex.id) { $0.originalDeleted = true }
                }
                working = nil
                Haptics.success()
                dismiss()
                onDone()
            } catch {
                working = nil
                failure = error.localizedDescription
            }
        }
    }
}

// MARK: - Layout helper

/// Wraps its children onto as many lines as they need (chips never truncate).
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.init(width: maxW, height: nil))
            if x > 0, x + size.width > maxW { y += rowH + spacing; x = 0; rowH = 0 }
            x += size.width + spacing
            rowH = max(rowH, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.init(width: bounds.width, height: nil))
            if x > bounds.minX, x + size.width > bounds.maxX { y += rowH + spacing; x = bounds.minX; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: .init(size))
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
    }
}
