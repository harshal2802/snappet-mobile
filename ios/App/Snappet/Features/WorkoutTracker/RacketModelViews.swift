import SwiftUI

// MARK: - Racket model screens (prompt 248, issue #438 step 5)
//
// Thin renderers over the pure `RacketModelHooks.swift`; scans run in `Services/RacketScanCenter.swift`. Pushed inside
// the Your videos stack (`RacketVideosCover`). Boards: TtCapabilities, TtChooseModel, TtModelCompare, Analyzing,
// Summary (the game summary after a scan), AnalysisSettings.

// MARK: - Shared pieces

private struct MPanel<C: View>: View {
    @ViewBuilder let content: C
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .pagerGlass(cornerRadius: 18)
    }
}

@MainActor private func mNote(_ s: String) -> some View {
    Text(s).font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
}

@MainActor private func mPrimary(_ label: String, id: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
    Button(action: action) { Text(label).frame(maxWidth: .infinity, minHeight: 30).multilineTextAlignment(.center) }
        .buttonStyle(SnappetWidePrimaryStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityIdentifier(id)
}

@MainActor private func mSecondary(_ label: String, id: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Text(label).font(.system(size: 15, weight: .semibold)).foregroundStyle(SnappetColor.ink)
            .frame(maxWidth: .infinity, minHeight: 44).multilineTextAlignment(.center)
    }
    .buttonStyle(.plain)
    .pagerOutline()
    .accessibilityIdentifier(id)
}

@MainActor private func mChip(_ label: String, id: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Text(label).font(.system(size: 14, weight: .semibold)).foregroundStyle(SnappetColor.brand)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .overlay(Capsule().strokeBorder(SnappetColor.hairline))
            .fixedSize(horizontal: false, vertical: true)
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier(id)
}

/// A choice row with a check (ChooseModel, AnalysisSettings).
private struct MOptionRow: View {
    let title: String
    var detail: String? = nil
    let selected: Bool
    let id: String
    let action: () -> Void

    var body: some View {
        Button(action: { action(); Haptics.tap() }) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(SnappetColor.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail {
                        Text(detail).font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 6)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? SnappetColor.brand : SnappetColor.textTertiary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? SnappetColor.brand : SnappetColor.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Names a part of the recording the way Your videos does ("Game 1", "Block 2", "Whole recording").
enum RacketPartNames {
    static func title(_ ex: SessionExercise, start: Double, end: Double) -> String {
        if let row = RacketVideoRows.rows(for: ex).first(where: { abs($0.startSec - start) < 0.5 && abs($0.endSec - end) < 0.5 }) {
            return row.title
        }
        return "Part from \(RacketVideoTime.clock(start))"
    }

    static func ref(_ ex: SessionExercise, start: Double, end: Double) -> RacketPartRef {
        let row = RacketVideoRows.rows(for: ex).first { abs($0.startSec - start) < 0.5 && abs($0.endSec - end) < 0.5 }
        let t = row?.title ?? title(ex, start: start, end: end)
        return RacketPartRef(exerciseID: ex.id, title: ex.isRacketDrill ? t : "\(t) video", startSec: start, endSec: end,
                             setIndex: row?.setIndex)
    }
}

// MARK: - TtCapabilities ("What works for this sport")

struct RacketCapabilitiesScreen: View {
    let sport: RacketSport
    /// `nil` from the match form (prompt 249): the preview lives in Your videos, which needs the session.
    let onPreviewNoModel: (() -> Void)?

    var body: some View {
        let caps = RacketCapabilityRegistry.capabilities(for: sport)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("What works for \(sport.label.lowercased())").font(.system(size: 22, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("racket.caps.title")
                mNote("Rally finding runs on Snappet’s placeholder model for now. A feature that isn’t built yet says Not available yet, and its screen uses the by-hand version.")
                ForEach(RacketFeature.allCases, id: \.self) { f in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.title).font(.system(size: 16, weight: .semibold))
                            Text(f.withoutIt).font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if caps.state(f) == .placeholder, let limit = f.placeholderLimit {
                                Text(limit).font(SnappetType.detail).foregroundStyle(SnappetColor.perfModerate)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 8)
                        let state = caps.state(f)
                        Text(RacketCapabilityRegistry.statusLabel(caps, f))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(state == .available ? SnappetColor.perfFresh
                                             : state == .placeholder ? SnappetColor.perfModerate : SnappetColor.textSecondary)
                            .fixedSize()
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .pagerGlass(cornerRadius: 14)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("racket.caps.\(f.rawValue)")
                }
                if let m = caps.model {
                    mNote("\(m.label): \(m.note.lowercased()). Video only, on this phone.")
                        .accessibilityIdentifier("racket.caps.model")
                }
                if let onPreviewNoModel {
                    mSecondary("Preview a sport with no model", id: "racket.caps.preview", action: onPreviewNoModel)
                }
            }
            .padding(20)
        }
        .navigationTitle("What works")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Analyzing ("Finding your rallies")

struct RacketAnalyzingScreen: View {
    let store: RacketVideoStore
    let onReview: (RacketPartRef) -> Void
    let onCompare: (RacketPartRef, UUID) -> Void
    let onLater: () -> Void

    private var center: RacketScanCenter { RacketScanCenter.shared }

    private struct Row: Identifiable {
        var ex: SessionExercise
        var rec: RacketScanRecord
        var id: UUID { rec.id }
        var title: String
        var scoreLine: String?
    }

    /// The newest scan of each part, in recording order, for every recording in the session.
    private var rows: [Row] {
        store.session.exercises.filter { $0.discipline == .racket }.flatMap { ex -> [Row] in
            guard let log = ex.racketRecordingLog else { return [] }
            let parts = Dictionary(grouping: log.allScans) { "\(Int($0.partStart))-\(Int($0.partEnd))" }
            let videoRows = RacketVideoRows.rows(for: ex)
            return parts.values.compactMap { $0.max { $0.startedAt < $1.startedAt } }
                .sorted { $0.partStart < $1.partStart }
                .map { rec in
                    let row = videoRows.first { abs($0.startSec - rec.partStart) < 0.5 && abs($0.endSec - rec.partEnd) < 0.5 }
                    let line = row?.line.components(separatedBy: " · ").first
                    let score = (row?.setIndex != nil && line?.contains("–") == true) ? line : nil
                    return Row(ex: ex, rec: rec, title: row?.title ?? RacketPartNames.title(ex, start: rec.partStart, end: rec.partEnd),
                               scoreLine: score)
                }
        }
    }

    var body: some View {
        let rs = rows
        let running = rs.first { $0.rec.id == center.runningID }
        let ready = rs.first { $0.rec.status == .done }
        let anyMatch = rs.contains { $0.ex.isRacketMatch }
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Finding your rallies").font(.system(size: 22, weight: .semibold))
                Text(headline(rs, running: running)).font(SnappetType.body.monospacedDigit())
                    .foregroundStyle(SnappetColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("racket.analyzing.headline")
                mNote("Keep Snappet open if you can. It runs fastest on a charger and picks up where it stopped.")
                ForEach(rs) { r in row(r) }
                if anyMatch {
                    mNote("Your scores are saved. Confirm any unconfirmed ones when you have a moment.")
                }
                if let ready, ready.rec.applied == true {
                    mPrimary("Review \(ready.title)", id: "racket.analyzing.review") {
                        onReview(RacketPartNames.ref(ready.ex, start: ready.rec.partStart, end: ready.rec.partEnd))
                    }
                }
                mSecondary("Do it later", id: "racket.analyzing.later", action: onLater)
                if rs.contains(where: { $0.rec.isActive }) {
                    Button("Stop scanning") { center.stopAll(in: store.session) }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(SnappetColor.perfHard)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .accessibilityIdentifier("racket.analyzing.stopAll")
                }
            }
            .padding(20)
        }
        .navigationTitle("Finding rallies")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func headline(_ rs: [Row], running: Row?) -> String {
        if let running {
            return RacketScanETA.headline(title: running.title, fraction: center.live[running.rec.id] ?? running.rec.fraction,
                                          eta: center.eta)
        }
        if rs.isEmpty { return "Nothing to scan yet" }
        if rs.contains(where: { $0.rec.isActive }) { return "Waiting to start" }
        if rs.allSatisfy({ $0.rec.status == .done }) { return "Done · \(rs.count) \(rs.count == 1 ? "part" : "parts") scanned" }
        return "Paused"
    }

    private func status(_ r: Row) -> (String, Color) {
        switch r.rec.status {
        case .running:
            return ("\(Int(((center.live[r.rec.id] ?? r.rec.fraction) * 100).rounded()))%", SnappetColor.brand)
        case .queued:
            return (r.rec.waitForCharger == true ? "Waiting for a charger" : "Waiting", SnappetColor.textSecondary)
        case .paused:
            return ("Paused at \(Int((r.rec.fraction * 100).rounded()))%", SnappetColor.perfModerate)
        case .failed:
            return ("Not scanned", SnappetColor.perfModerate)
        case .done:
            if r.rec.isPendingCompare { return ("Ready to compare", SnappetColor.brand) }
            let n = r.rec.guesses?.count ?? 0
            return ("Ready · \(n) \(n == 1 ? "rally" : "rallies")", SnappetColor.perfFresh)
        }
    }

    @ViewBuilder private func row(_ r: Row) -> some View {
        let (label, color) = status(r)
        let k = rows.firstIndex { $0.id == r.id } ?? 0
        MPanel {
            HStack(alignment: .firstTextBaseline) {
                Text(r.title).font(.system(size: 16, weight: .semibold))
                if let s = r.scoreLine {
                    Text(s).font(SnappetType.body.monospacedDigit()).foregroundStyle(SnappetColor.textSecondary)
                }
                Spacer(minLength: 6)
                Text(label).font(.caption.weight(.semibold)).foregroundStyle(color).fixedSize()
                    .accessibilityIdentifier("racket.analyzing.status.\(k)")
            }
            if r.rec.status == .running {
                ProgressView(value: center.live[r.rec.id] ?? r.rec.fraction).tint(SnappetColor.brand)
            }
            if let note = r.rec.note, r.rec.status == .paused || r.rec.status == .failed {
                mNote(note)
            }
            FlowRow {
                if r.rec.isActive {
                    mChip("Stop", id: "racket.analyzing.stop.\(k)") { center.stop(r.rec.id) }
                }
                if r.rec.status == .paused || r.rec.status == .failed {
                    mChip(r.rec.status == .failed ? "Try again" : "Resume", id: "racket.analyzing.resume.\(k)") {
                        center.resume(r.rec.id, exerciseID: r.ex.id, store: store)
                    }
                }
                if r.rec.isPendingCompare {
                    mChip("Compare", id: "racket.analyzing.compare.\(k)") {
                        onCompare(RacketPartNames.ref(r.ex, start: r.rec.partStart, end: r.rec.partEnd), r.rec.id)
                    }
                } else if r.rec.status == .done {
                    mChip("Review", id: "racket.analyzing.reviewRow.\(k)") {
                        onReview(RacketPartNames.ref(r.ex, start: r.rec.partStart, end: r.rec.partEnd))
                    }
                }
            }
        }
    }
}

// MARK: - Summary (the game summary after a scan)

struct RacketAnalysisSummaryScreen: View {
    let store: RacketVideoStore
    let ref: RacketPartRef
    let onDoneForNow: () -> Void
    let onTimeline: () -> Void
    /// Tag one rally at a time (`unsureOnly` = only the unsure ones); `true` when finished.
    let onTag: (_ unsureOnly: Bool) -> Void
    let onEditScore: (Int) -> Void

    private var ex: SessionExercise? { store.ex(ref.exerciseID) }

    var body: some View {
        let log = ex?.racketRecordingLog
        let rallies = RacketRallyMarking.inRange(log?.allRallies ?? [], ref.startSec, ref.endSec)
        let g = RacketGuessSummary.make(rallies)
        let tags = RacketTagSummary.make(rallies, sport: ex?.racketSport ?? .tableTennis)
        let scan = log?.appliedScan(partStart: ref.startSec, partEnd: ref.endSec)
        let state = ref.setIndex.flatMap { i in ex.flatMap { i < $0.sets.count ? $0.sets[i].racketScoreState : nil } }
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let st = state, let i = ref.setIndex {
                    HStack(alignment: .firstTextBaseline) {
                        Text(headline(st)).font(.system(size: 28, weight: .light)).monospacedDigit()
                            .accessibilityIdentifier("racket.analysis.score")
                        Spacer()
                        mChip("Edit score", id: "racket.analysis.editScore") { onEditScore(i) }
                    }
                    if case .fromWatch = st {
                        Text("Score unconfirmed · from your Watch").font(SnappetType.detail).foregroundStyle(SnappetColor.perfModerate)
                    } else if case .unconfirmed = st {
                        Text(RacketScoreState.unconfirmedLabel).font(SnappetType.detail).foregroundStyle(SnappetColor.perfModerate)
                    }
                }
                if let scan {
                    Text("\(scan.modelLabel) · \((scan.finishedAt ?? scan.startedAt).formatted(.dateTime.month(.abbreviated).day().hour().minute()))")
                        .snappetLabel()
                        .accessibilityIdentifier("racket.analysis.model")
                }
                HStack(spacing: 10) {
                    stat("\(g.found)", "rallies found", id: "racket.analysis.found")
                    stat(g.longestSec.map(RacketTagSummary.seconds) ?? "—", "longest rally", id: "racket.analysis.longest")
                    stat(g.averageSec.map(RacketTagSummary.seconds) ?? "—", "average rally", id: "racket.analysis.average")
                }
                mNote(g.guesses > 0 ? "Estimated from video until you confirm. Your tags replace Snappet’s guesses everywhere."
                                    : "Every rally here is checked or tagged by you.")
                Text("How much time do you have?").font(.system(size: 17, weight: .semibold))
                option("Done for now", "0 min", "Keep the estimates. You can tag later.", id: "racket.analysis.doneForNow",
                       action: onDoneForNow)
                if g.unsureLeft > 0 {
                    option("Check \(g.unsureLeft) unsure \(g.unsureLeft == 1 ? "rally" : "rallies")",
                           minutes(Double(g.unsureLeft) * 15), "Only the ones Snappet isn’t sure about.",
                           id: "racket.analysis.checkUnsure") { onTag(true) }
                }
                if tags.untagged > 0 {
                    option("Tag winners and endings", minutes(Double(tags.untagged) * 12), "One rally at a time.",
                           id: "racket.analysis.tagAll") { onTag(false) }
                }
                mSecondary("Open timeline", id: "racket.analysis.timeline", action: onTimeline)
                mNote("Shot counts and shot types aren’t in the placeholder model yet, so they’re tagged by hand or skipped.")
            }
            .padding(20)
        }
        .navigationTitle("\(ref.shortTitle) summary")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func headline(_ st: RacketScoreState) -> String {
        switch st {
        case .confirmed(let s), .fromWatch(let s): return "\(s.scoreFor > s.scoreAgainst ? "Won" : "Lost") \(s.label)"
        case .unconfirmed: return "No score yet"
        }
    }

    private func minutes(_ sec: Double) -> String { sec < 60 ? "under a minute" : "about \(Int((sec / 60).rounded())) min" }

    private func stat(_ v: String, _ k: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(v).font(.system(size: 26, weight: .light)).monospacedDigit().accessibilityIdentifier(id)
            Text(k).font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12).pagerGlass(cornerRadius: 14)
    }

    private func option(_ title: String, _ time: String, _ detail: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(SnappetColor.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail).font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                Text(time).font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary).fixedSize()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .pagerGlass(cornerRadius: 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}

// MARK: - TtChooseModel ("Re-scan…")

struct RacketChooseModelScreen: View {
    let store: RacketVideoStore
    let ref: RacketPartRef
    /// Re-scan started → Analyzing.
    let onScan: () -> Void
    let onCancel: () -> Void

    @State private var chosen: RallyModelInfo?
    @State private var compare = true

    private var ex: SessionExercise? { store.ex(ref.exerciseID) }

    var body: some View {
        let sport = ex?.racketSport ?? .tableTennis
        let caps = RacketCapabilityRegistry.capabilities(for: sport)
        let log = ex?.racketRecordingLog
        let applied = log?.appliedScan(partStart: ref.startSec, partEnd: ref.endSec)
        let imports = (log?.allAIImports ?? []).filter { $0.partStart < ref.endSec - 0.01 && $0.partEnd > ref.startSec + 0.01 }
        let pick = chosen ?? caps.model
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Choose a model").font(.system(size: 22, weight: .semibold))
                if let applied {
                    mNote("Scanned with \(applied.modelLabel) \((applied.finishedAt ?? applied.startedAt).formatted(.relative(presentation: .named))).")
                        .accessibilityIdentifier("racket.choose.scanned")
                }
                ForEach(Array(caps.models.enumerated()), id: \.element.id) { k, m in
                    MOptionRow(title: k == 0 && caps.models.count > 1 ? "\(m.label) · newest" : m.label,
                               detail: detail(m, index: k, applied: applied),
                               selected: pick == m, id: "racket.choose.model.\(k)") { chosen = m }
                }
                if applied != nil {
                    Toggle(isOn: $compare) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Compare before replacing").font(.system(size: 16, weight: .semibold))
                            Text("See where the new scan differs").font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                        }
                    }
                    .accessibilityIdentifier("racket.choose.compare")
                }
                mNote("Your tags are always kept. Older results stay available to watch.")
                if !imports.isEmpty {
                    Text("Other AI results").snappetLabel().padding(.top, 4)
                    ForEach(Array(imports.enumerated()), id: \.element.id) { k, imp in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(imp.appName) · \(imp.importedAt.formatted(.dateTime.month(.abbreviated).day()))")
                                    .font(SnappetType.body)
                                Text("\(imp.rallies.count) \(imp.rallies.count == 1 ? "rally" : "rallies") · \(imp.model ?? "model not given")")
                                    .font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                            }
                            Spacer()
                            Button("Remove", role: .destructive) {
                                store.updateLog(ref.exerciseID) { l in l.aiImports = l.allAIImports.filter { $0.id != imp.id } }
                            }
                            .font(SnappetType.detail.weight(.semibold))
                            .accessibilityIdentifier("racket.choose.removeAI.\(k)")
                        }
                        .padding(.vertical, 4)
                    }
                    mNote("Removing a reply keeps anything you already accepted from it.")
                }
                if let pick {
                    mPrimary("Re-scan with \(pick.label)", id: "racket.choose.rescan") {
                        RacketScanCenter.shared.enqueue([ref], model: pick, compare: applied != nil && compare, store: store)
                        onScan()
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Re-scan \(ref.shortTitle)")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onCancel).accessibilityIdentifier("racket.choose.cancel")
            }
        }
    }

    private func detail(_ m: RallyModelInfo, index k: Int, applied: RacketScanRecord?) -> String {
        var parts: [String] = []
        if k == 0 { parts.append("Recommended for this sport") }
        if let a = applied, a.modelID == m.id, a.modelVersion == m.version { parts.append("Used for this video now") }
        else if k > 0 { parts.append("Older, kept for comparison") }
        if m.isPlaceholder { parts.append(m.note) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - TtModelCompare

struct RacketModelCompareScreen: View {
    let store: RacketVideoStore
    let ref: RacketPartRef
    let recordID: UUID
    /// "Use v3" → the game summary.
    let onUse: () -> Void
    /// "Keep v2" / Done → Your videos.
    let onKeep: () -> Void

    private var ex: SessionExercise? { store.ex(ref.exerciseID) }

    var body: some View {
        let log = ex?.racketRecordingLog
        let newer = log?.allScans.first { $0.id == recordID }
        let older = log?.appliedScan(partStart: ref.startSec, partEnd: ref.endSec)
        let names = newer.flatMap { n in older.map { RacketModelCompare.names(newer: n, older: $0) } } ?? ("New scan", "Earlier scan")
        let sides = RacketWatchCopy.sides(opponent: ex?.opponent, doubles: ex?.isDoubles ?? false)
        let r = RacketModelCompare.build(newer: newer?.guesses ?? [], older: older?.guesses ?? [],
                                         newerName: names.0, olderName: names.1, sides: sides,
                                         within: ref.startSec...max(ref.startSec, ref.endSec))
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("\(newer?.modelLabel ?? "New scan") vs \(older?.modelLabel ?? "earlier scan") · \(ref.shortTitle)")
                    .snappetLabel()
                    .accessibilityIdentifier("racket.modelCompare.header")
                Text(r.differencesLine).font(.system(size: 28, weight: .light))
                    .accessibilityIdentifier("racket.modelCompare.count")
                mNote(r.countsLine).accessibilityIdentifier("racket.modelCompare.counts")
                ForEach(Array(r.items.enumerated()), id: \.element.id) { k, item in
                    MPanel {
                        Text(item.title).font(.system(size: 16, weight: .semibold))
                        HStack {
                            Text(item.newer).font(SnappetType.body)
                            Spacer()
                            Text(item.older).font(SnappetType.body).foregroundStyle(SnappetColor.textSecondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("racket.modelCompare.item.\(k)")
                }
                mNote("Rallies you’ve tagged yourself aren’t affected.")
                mPrimary("Use \(names.0)", id: "racket.modelCompare.use") {
                    store.updateLog(ref.exerciseID) { RacketScanCenter.applyResults(&$0, recordID: recordID) }
                    onUse()
                }
                mSecondary("Keep \(names.1)", id: "racket.modelCompare.keep") {
                    store.updateLog(ref.exerciseID) { RacketScanCenter.keepEarlier(&$0, recordID: recordID) }
                    onKeep()
                }
            }
            .padding(20)
        }
        .navigationTitle("Compare models")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: onKeep).accessibilityIdentifier("racket.modelCompare.done")
            }
        }
    }
}

// MARK: - AnalysisSettings ("Video analysis")

struct RacketAnalysisSettingsScreen: View {
    let sport: RacketSport
    let onCapabilities: () -> Void

    @AppStorage(RacketAutoScan.storageKey) private var afterRaw = RacketAutoScan.default.rawValue

    var body: some View {
        let after = RacketAutoScan(rawValue: afterRaw) ?? .default
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("After a session").snappetLabel()
                ForEach(RacketAutoScan.allCases, id: \.self) { o in
                    MOptionRow(title: o.title, detail: o.detail, selected: after == o, id: "racket.analysisSettings.\(o.rawValue)") {
                        afterRaw = o.rawValue
                    }
                }
                Text("During play").snappetLabel().padding(.top, 6)
                MPanel {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Live tracking").font(.system(size: 16, weight: .semibold))
                            Text("Off by default. May warm the phone more. Comes after a heat test on a phone; until then play uses the tracking-off screens.")
                                .font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 6)
                        Text("Off").font(SnappetType.detail.weight(.semibold)).foregroundStyle(SnappetColor.textSecondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("racket.analysisSettings.live")
                }
                NavigationLink {
                    RacketRecordingSettingsView().navigationTitle("Recording defaults")
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Still playing check and recording defaults").font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(SnappetColor.ink).fixedSize(horizontal: false, vertical: true)
                            Text("How long without taps before Snappet asks, and how matches and drills record")
                                .font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(SnappetColor.textTertiary)
                    }
                    .padding(12).pagerGlass(cornerRadius: 14)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("racket.analysisSettings.recording")
                mSecondary("What works for \(sport.label.lowercased())", id: "racket.analysisSettings.caps", action: onCapabilities)
                mNote("Applies to all racket sports. Scans run on this phone; nothing is uploaded.")
            }
            .padding(20)
        }
        .navigationTitle("Video analysis")
        .navigationBarTitleDisplayMode(.inline)
    }
}
