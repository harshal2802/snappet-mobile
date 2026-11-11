import SwiftUI
import AVFoundation

// MARK: - Racket player, timeline and tagging (prompt 246, issue #438 step 3)
//
// TtPlayerOriginal / TtPlayerAnalyzed / TtPlayerExport, TtNoModelTimeline (+ Timeline rows, FixRally), TtNoModelTag /
// DoublesTag. A part plays from the original Photos video at its time range (`RacketPlayback`); marks and tags are
// pure (`RacketRallyTags.swift`) and saved on the recording log through `RacketVideoStore`.

// MARK: - Video surface

struct RacketVideoSurface: View {
    let playback: RacketPlayback
    var overlay: String? = nil
    var sport: RacketSport = .tableTennis
    var height: CGFloat = 220

    var body: some View {
        ZStack(alignment: .top) {
            if let player = playback.player {
                RacketPlayerLayerView(player: player)
                if let line = playback.loadState.line {
                    // Some stretches of the original are missing: say so over the video.
                    VStack {
                        Spacer()
                        Text(line).font(SnappetType.detail).foregroundStyle(SnappetColor.ink)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.black.opacity(0.6), in: Capsule())
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(8)
                            .accessibilityIdentifier("racket.player.partial")
                    }
                }
            } else {
                // No saved video (the simulator's stand-in camera), still loading, downloading from iCloud, or missing.
                ZStack {
                    Color(white: 0.11)
                    VStack(spacing: 8) {
                        Image(systemName: playback.loadState.isCloud ? "icloud.and.arrow.down" : sport.symbol)
                            .font(.system(size: 30)).foregroundStyle(SnappetColor.textTertiary)
                        Text(playback.loadState.line ?? (playback.loaded ? "No video saved for this recording" : "Loading video…"))
                            .font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("racket.player.standIn")
                        if case .downloading(let f) = playback.loadState {
                            ProgressView(value: f).tint(SnappetColor.brand).frame(width: 160)
                        }
                        if playback.loadState.canRetry {
                            Button("Try again") { Task { await playback.retry() } }
                                .font(.system(size: 15, weight: .semibold))
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("racket.player.retry")
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            if let overlay {
                Text(overlay)
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(10)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("racket.player.overlay")
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct RacketPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    final class V: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> V {
        let v = V()
        v.backgroundColor = .black
        v.playerLayer.videoGravity = .resizeAspect
        v.playerLayer.player = player
        return v
    }

    func updateUIView(_ v: V, context: Context) { v.playerLayer.player = player }
}

// MARK: - Timeline bar (rally segments on the part)

struct RacketTimelineBar: View {
    let start: Double
    let end: Double
    let position: Double
    let rallies: [RacketRally]
    var pendingStart: Double? = nil
    /// Another AI app's rallies not compared yet: drawn dashed (AIImport "Shown dashed and labelled", prompt 247).
    var suggestions: [RacketRally] = []
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let span = max(0.001, end - start)
            let x: (Double) -> Double = { t in (t - start) / span * w }
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).fill(SnappetColor.hairline.opacity(0.6)).frame(height: 28)
                ForEach(suggestions) { r in
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(SnappetColor.brand, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                        .frame(width: max(3, x(r.endSec) - x(r.startSec)), height: 26)
                        .offset(x: x(r.startSec))
                }
                ForEach(rallies.filter { $0.isRally && !$0.isUnsure }) { r in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(r.isTagged ? SnappetColor.brand : SnappetColor.brand.opacity(r.isGuess ? 0.3 : 0.45))
                        .frame(width: max(2, x(r.endSec) - x(r.startSec)), height: 22)
                        .offset(x: x(r.startSec))
                }
                // Snappet's unsure guesses (prompt 248, Timeline board "Dashed: unsure").
                ForEach(rallies.filter(\.isUnsure)) { r in
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(SnappetColor.perfModerate, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                        .frame(width: max(3, x(r.endSec) - x(r.startSec)), height: 22)
                        .offset(x: x(r.startSec))
                }
                if let p = pendingStart {
                    Rectangle().fill(SnappetColor.perfModerate).frame(width: 2, height: 32).offset(x: x(p))
                }
                Rectangle().fill(SnappetColor.ink).frame(width: 2, height: 36).offset(x: x(position) - 1)
            }
            .frame(height: 36)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                onSeek(start + min(max(0, v.location.x), w) / w * span)
            })
        }
        .frame(height: 36)
        .accessibilityElement()
        .accessibilityLabel("Timeline, \(rallies.filter(\.isRally).count) rallies"
                            + (rallies.contains(where: \.isUnsure) ? ", \(rallies.filter(\.isUnsure).count) unsure" : "")
                            + (suggestions.isEmpty ? "" : ", \(suggestions.count) suggested"))
        .accessibilityIdentifier("racket.timeline.bar")
    }
}

// MARK: - TtPlayerOriginal / TtPlayerAnalyzed

struct RacketPlayerScreen: View {
    let store: RacketVideoStore
    let ref: RacketPartRef
    let ralliesOnly: Bool
    /// Open on Analyzed (after Add as suggestions / Compare → Done, prompt 247).
    var startAnalyzed = false
    /// Compare a waiting reply from another AI app.
    var onCompare: ((UUID) -> Void)? = nil

    @State private var playback: RacketPlayback?
    @State private var analyzed = false
    @State private var onlyRallies = false
    @State private var showNumber = true
    @State private var showScore = true
    @State private var exporting = false
    @State private var configured = false

    private var ex: SessionExercise? { store.ex(ref.exerciseID) }
    private var rallies: [RacketRally] {
        RacketRallyMarking.inRange(ex?.racketRecordingLog?.allRallies ?? [], ref.startSec, ref.endSec)
    }
    private var sides: (us: String, them: String) {
        RacketWatchCopy.sides(opponent: ex?.opponent, doubles: ex?.isDoubles ?? false)
    }
    private var pendingImports: [RacketAIImport] {
        ex?.racketRecordingLog?.pendingAIImports(partStart: ref.startSec, partEnd: ref.endSec) ?? []
    }
    private var suggestions: [RacketRally] {
        ex?.racketRecordingLog?.aiSuggestions(partStart: ref.startSec, partEnd: ref.endSec) ?? []
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let pb = playback {
                    RacketVideoSurface(playback: pb, overlay: analyzed ? overlayLine(pb.position) : nil,
                                       sport: ex?.racketSport ?? .tableTennis)
                    Picker("View", selection: $analyzed) {
                        Text("Original").tag(false)
                        Text("Analyzed").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("racket.player.mode")
                    RacketTimelineBar(start: ref.startSec, end: ref.endSec, position: pb.position, rallies: rallies,
                                      suggestions: analyzed ? suggestions : []) { pb.seek(to: $0) }
                    HStack {
                        Text(RacketVideoTime.clock(pb.position - ref.startSec)).monospacedDigit()
                            .accessibilityIdentifier("racket.player.clock")
                        Spacer()
                        if let r = RacketPlaybackPolicy.rally(at: pb.position, in: rallies) {
                            Text("Rally \(r.number)").font(SnappetType.detail.weight(.semibold))
                        }
                        Spacer()
                        Text(RacketVideoTime.clock(ref.endSec - ref.startSec)).monospacedDigit()
                            .foregroundStyle(SnappetColor.textSecondary)
                    }
                    .font(SnappetType.detail)
                    transport(pb)
                    HStack(spacing: 10) {
                        Toggle("Rallies only", isOn: $onlyRallies)
                            .disabled(rallies.isEmpty)
                            .accessibilityIdentifier("racket.player.ralliesOnly")
                        Picker("Speed", selection: Binding(get: { pb.rate }, set: { pb.rate = $0 })) {
                            Text("1×").tag(Float(1))
                            Text("0.5×").tag(Float(0.5))
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 110)
                    }
                    if analyzed { analysisPanel } else {
                        Text("Exactly as recorded. Rally marks sit on the timeline only.")
                            .font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle(ref.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Share") { playback?.pause(); exporting = true }.accessibilityIdentifier("racket.player.share")
            }
        }
        .sheet(isPresented: $exporting) {
            if let pb = playback { RacketExportSheet(store: store, ref: ref, position: pb.position, rallies: rallies, sides: sides) }
        }
        .onChange(of: onlyRallies) { _, on in playback?.ralliesOnly = on ? rallies : nil }
        .task {
            guard !configured else { return }
            configured = true
            analyzed = startAnalyzed
            let pb = RacketPlayback(partStart: ref.startSec, partEnd: ref.endSec)
            playback = pb
            onlyRallies = ralliesOnly && !rallies.isEmpty
            pb.ralliesOnly = onlyRallies ? rallies : nil
            if onlyRallies, let first = rallies.first(where: \.isRally) { pb.seek(to: first.startSec) }
            if let log = ex?.racketRecordingLog {
                await pb.load(RacketVideoMap.segments(start: ref.startSec, end: ref.endSec, log: log))
                if onlyRallies, let first = rallies.first(where: \.isRally) { pb.seek(to: first.startSec) }
            }
        }
        .onDisappear { playback?.stop() }
    }

    private func transport(_ pb: RacketPlayback) -> some View {
        HStack(spacing: 10) {
            control("−10 s", id: "racket.player.back10") { pb.step(-10) }
            control(pb.playing ? "Pause" : "Play", id: "racket.player.play") { pb.toggle() }
            control("+10 s", id: "racket.player.fwd10") { pb.step(10) }
        }
    }

    private func control(_ label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.plain).pagerOutline()
        .accessibilityIdentifier(id)
    }

    private func overlayLine(_ t: Double) -> String? {
        guard let r = RacketPlaybackPolicy.rally(at: t, in: rallies) else {
            // Another app's suggestion, labelled with its name (your rallies always show first).
            guard let s = suggestions.first(where: { t >= $0.startSec && t < $0.endSec }) else { return nil }
            var parts = ["\(s.aiName ?? "Other app") suggests a rally"]
            if let w = s.winner { parts.append(w == .us ? "\(sides.us) won" : "\(sides.them) won") }
            if let e = s.ending { parts.append(e.label) }
            return parts.joined(separator: " · ")
        }
        var parts: [String] = []
        if showNumber { parts.append(RacketPlaybackPolicy.overlayLine(number: r.number, rally: r.rally, sides: sides)) }
        if r.rally.isGuess { parts.append(r.rally.isUnsure ? "Snappet guess, unsure" : "Snappet guess") }
        if showScore {
            let s = RacketPlaybackPolicy.runningScore(through: r.number, in: rallies)
            parts.append("\(s.us)–\(s.them)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var analysisPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Analysis shown").snappetLabel()
            HStack {
                Text("Your tags always show").font(SnappetType.body)
                Spacer()
                Image(systemName: "checkmark").foregroundStyle(SnappetColor.brand)
            }
            if let scan = ex?.racketRecordingLog?.appliedScan(partStart: ref.startSec, partEnd: ref.endSec) {
                let g = rallies.filter(\.isGuess).count
                HStack {
                    Text("\(scan.modelLabel) · used now").font(SnappetType.body)
                    Spacer()
                    Image(systemName: "checkmark").foregroundStyle(SnappetColor.brand)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("racket.player.model")
                Text("\(g) of the rallies here are Snappet’s guesses. Your tags always win.")
                    .font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Not scanned yet, so there are no Snappet guesses here. Find rallies on Your videos.")
                    .font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(pendingImports) { imp in
                let n = RacketRallyMarking.inRange(imp.rallies, ref.startSec, ref.endSec).count
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(imp.appName) suggestions").font(SnappetType.body)
                        Text("\(n) \(n == 1 ? "rally" : "rallies"), dashed on the timeline. They don’t count until you compare.")
                            .font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("racket.player.aiSuggestions")
                    Spacer(minLength: 6)
                    if let onCompare {
                        Button("Compare") { onCompare(imp.id) }
                            .font(SnappetType.detail.weight(.semibold))
                            .accessibilityIdentifier("racket.player.aiCompare")
                    }
                }
            }
            Text("Show on video").snappetLabel().padding(.top, 4)
            Toggle("Rally number", isOn: $showNumber).accessibilityIdentifier("racket.player.showNumber")
            Toggle("Score", isOn: $showScore).accessibilityIdentifier("racket.player.showScore")
            ForEach(["Ball path", "Shot names", "Bounces"], id: \.self) { name in
                HStack {
                    Text(name)
                    Spacer()
                    Text("Not in the placeholder yet").font(SnappetType.detail).foregroundStyle(SnappetColor.textTertiary)
                }
            }
        }
        .padding(14).pagerGlass(cornerRadius: 18)
    }
}

// MARK: - TtPlayerExport ("Save or share")

struct RacketExportSheet: View {
    let store: RacketVideoStore
    let ref: RacketPartRef
    let position: Double
    let rallies: [RacketRally]
    let sides: (us: String, them: String)

    enum Which: String, CaseIterable { case rally, ralliesOnly, whole }

    @Environment(\.dismiss) private var dismiss
    @State private var analyzed = false
    @State private var which: Which = .whole
    @State private var smaller = false
    @State private var working = false
    @State private var message: String?
    @State private var shareURL: URL?
    @State private var configured = false

    private var current: (number: Int, rally: RacketRally)? { RacketPlaybackPolicy.rally(at: position, in: rallies) }

    var body: some View {
        NavigationStack {
            Form {
                Section("What to include") {
                    Picker("What to include", selection: $analyzed) {
                        Text("Original").tag(false)
                        Text("Analyzed").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("racket.export.include")
                }
                Section("Which part") {
                    if let c = current {
                        option(.rally, "This rally", "Rally \(c.number) · \(Int(c.rally.durationSec.rounded())) s")
                    }
                    if rallies.contains(where: \.isRally) {
                        option(.ralliesOnly, "Rallies only", "Dead time removed")
                    }
                    option(.whole, ref.title.replacingOccurrences(of: " video", with: ""), RacketVideoTime.clock(ref.endSec - ref.startSec))
                }
                Section("Quality") {
                    Picker("Quality", selection: $smaller) {
                        Text("Full").tag(false)
                        Text("Smaller").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    Text("Other people may be in this video. Check they’re OK with you sharing it.")
                        .font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                    if let message {
                        Text(message).font(SnappetType.detail).accessibilityIdentifier("racket.export.message")
                    }
                    Button("Save to Photos") { run(share: false) }
                        .disabled(working).accessibilityIdentifier("racket.export.save")
                    Button("Share") { run(share: true) }
                        .disabled(working).accessibilityIdentifier("racket.export.share")
                    if working { ProgressView("Making the video…") }
                }
            }
            .navigationTitle("Save or share")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .sheet(item: Binding(get: { shareURL.map(URLBox.init) }, set: { shareURL = $0?.url })) { box in
                ShareSheet(items: [box.url])
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            guard !configured else { return }
            configured = true
            which = current != nil ? .rally : .whole
        }
    }

    private struct URLBox: Identifiable { let url: URL; var id: String { url.absoluteString } }

    private func option(_ w: Which, _ title: String, _ detail: String) -> some View {
        Button { which = w } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(title).foregroundStyle(SnappetColor.ink)
                    Text(detail).font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                }
                Spacer()
                if which == w { Image(systemName: "checkmark").foregroundStyle(SnappetColor.brand) }
            }
        }
        .accessibilityIdentifier("racket.export.which.\(w.rawValue)")
        .accessibilityAddTraits(which == w ? .isSelected : [])
    }

    /// The recording ranges to export, in order.
    private var ranges: [ClosedRange<Double>] {
        switch which {
        case .rally:
            guard let c = current else { return [ref.startSec...ref.endSec] }
            return [c.rally.startSec...c.rally.endSec]
        case .ralliesOnly:
            return RacketKeepRallies.ranges(rallies, duration: ref.endSec)
                .map { max(ref.startSec, $0.lowerBound)...min(ref.endSec, $0.upperBound) }
        case .whole:
            return [ref.startSec...ref.endSec]
        }
    }

    private func run(share: Bool) {
        guard let log = store.ex(ref.exerciseID)?.racketRecordingLog else { return }
        let rs = ranges
        let pieces = rs.map { (RacketVideoMap.segments(start: $0.lowerBound, end: $0.upperBound, log: log), $0.lowerBound, $0.upperBound) }
        // Analyzed: your tags burned in over each rally (device only — the simulator can't re-encode).
        var captions: [(start: Double, end: Double, text: String)] = []
        if analyzed {
            var cursor = 0.0
            let all = rallies.filter(\.isRally)
            for r in rs {
                for (k, rally) in all.enumerated() where rally.startSec < r.upperBound && rally.endSec > r.lowerBound {
                    let a = cursor + max(0, rally.startSec - r.lowerBound)
                    let b = cursor + min(r.upperBound, rally.endSec) - r.lowerBound
                    captions.append((a, b, RacketPlaybackPolicy.overlayLine(number: k + 1, rally: rally, sides: sides)))
                }
                cursor += r.upperBound - r.lowerBound
            }
        }
        working = true
        message = nil
        Task {
            defer { working = false }
            do {
                if share {
                    shareURL = try await RacketVideoLibrary.shared.export(pieces, smaller: smaller, captions: captions)
                } else {
                    _ = try await RacketVideoLibrary.shared.saveToPhotos(pieces, smaller: smaller, captions: captions)
                    message = "Saved to Photos"
                    Haptics.success()
                }
            } catch {
                message = error.localizedDescription
            }
        }
    }
}

// MARK: - TtNoModelTimeline (+ Timeline rows, FixRally)

struct RacketTimelineScreen: View {
    let store: RacketVideoStore
    let ref: RacketPartRef
    /// The last rally was tagged (TtTagDone).
    let onTagDone: () -> Void
    /// "Done, see your tags" (TtManualSummary).
    let onSummary: () -> Void

    @State private var playback: RacketPlayback?
    @State private var pendingStart: Double?
    @State private var problem: String?
    @State private var tagging: RacketRally?
    @State private var fixing: RacketRally?
    @State private var configured = false
    /// Timeline board: All / Unsure / Untagged (prompt 248).
    @State private var filter = 0

    private var ex: SessionExercise? { store.ex(ref.exerciseID) }
    private var allRallies: [RacketRally] { ex?.racketRecordingLog?.allRallies ?? [] }
    private var rallies: [RacketRally] { RacketRallyMarking.inRange(allRallies, ref.startSec, ref.endSec) }
    private var sport: RacketSport { ex?.racketSport ?? .tableTennis }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let pb = playback {
                    RacketVideoSurface(playback: pb, sport: sport)
                    RacketTimelineBar(start: ref.startSec, end: ref.endSec, position: pb.position, rallies: rallies,
                                      pendingStart: pendingStart) { pb.seek(to: $0) }
                    let s = RacketTagSummary.make(rallies, sport: sport)
                    let g = RacketGuessSummary.make(rallies)
                    HStack {
                        Text(rallies.contains(where: \.isFromModel)
                             ? "\(g.found) \(g.found == 1 ? "rally" : "rallies") · \(g.unsureLeft) unsure · \(s.tagged) tagged"
                             : "\(s.marked) \(s.marked == 1 ? "rally" : "rallies") marked · \(s.tagged) tagged")
                            .font(SnappetType.detail.weight(.semibold))
                            .accessibilityIdentifier("racket.tl.count")
                        Spacer()
                        Text(RacketVideoTime.precise(pb.position - ref.startSec)).font(SnappetType.detail.monospacedDigit())
                            .accessibilityIdentifier("racket.tl.clock")
                    }
                    HStack(spacing: 10) {
                        control("−5 s", id: "racket.tl.back5") { pb.step(-5) }
                        control(pb.playing ? "Pause" : "Play", id: "racket.tl.play") { pb.toggle() }
                        control("+5 s", id: "racket.tl.fwd5") { pb.step(5) }
                    }
                    HStack(spacing: 10) {
                        control(pendingStart == nil ? "Mark start" : "Start marked", id: "racket.tl.markStart") {
                            pendingStart = pb.position
                            problem = nil
                            Haptics.tap()
                        }
                        control("Mark end", id: "racket.tl.markEnd") { markEnd(pb) }
                    }
                    if let problem {
                        Text(problem).font(SnappetType.detail).foregroundStyle(SnappetColor.perfModerate)
                            .accessibilityIdentifier("racket.tl.problem")
                    }
                    Button {
                        tagging = RacketPlaybackPolicy.rally(at: pb.position, in: rallies)?.rally
                            ?? RacketRallyMarking.nextUntagged(rallies, after: nil) ?? rallies.last
                    } label: { Text("Tag this rally").frame(maxWidth: .infinity, minHeight: 30) }
                    .buttonStyle(SnappetWidePrimaryStyle())
                    .disabled(rallies.isEmpty)
                    .accessibilityIdentifier("racket.tl.tag")
                    rallyRows
                    Button { onSummary() } label: {
                        Text("Done, see your tags").font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.plain).pagerOutline()
                    .accessibilityIdentifier("racket.tl.done")
                    Text("Your marks and tags work like any others: stats, reels and the timeline all use them.")
                        .font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                }
            }
            .padding(16)
        }
        .navigationTitle(ref.title.replacingOccurrences(of: " video", with: "") + " timeline")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $tagging) { r in
            RacketTagSheet(store: store, ref: ref, startID: r.id) { finished in
                tagging = nil
                if finished { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { onTagDone() } }
            }
        }
        .sheet(item: $fixing) { r in
            RacketFixRallySheet(rally: r, rallies: rallies, lo: ref.startSec, hi: ref.endSec) { updated in
                save(updated)
            }
        }
        .task {
            guard !configured else { return }
            configured = true
            let pb = RacketPlayback(partStart: ref.startSec, partEnd: ref.endSec)
            playback = pb
            if let log = ex?.racketRecordingLog {
                await pb.load(RacketVideoMap.segments(start: ref.startSec, end: ref.endSec, log: log))
            }
        }
        .onDisappear { playback?.stop() }
    }

    /// Replace this part's rallies (rallies elsewhere on the recording are kept).
    private func save(_ partRallies: [RacketRally]) {
        let outside = allRallies.filter { !($0.startSec >= ref.startSec - 0.01 && $0.startSec < ref.endSec) }
        store.updateLog(ref.exerciseID) { $0.rallies = (outside + partRallies).sorted { $0.startSec < $1.startSec } }
    }

    private func markEnd(_ pb: RacketPlayback) {
        switch RacketRallyMarking.rally(start: pendingStart, end: pb.position, within: ref.startSec, ref.endSec, existing: rallies) {
        case .success(let r):
            save(RacketRallyMarking.insert(r, into: rallies))
            pendingStart = nil
            problem = nil
            Haptics.success()
        case .failure(let p):
            switch p {
            case .noStart: problem = "Mark the start first."
            case .tooShort: problem = "Too short for a rally. Move on a little, then mark the end."
            case .overlaps: problem = "That overlaps a rally you already marked. Fix that one instead."
            }
            Haptics.warning()
        }
    }

    private func control(_ label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.plain).pagerOutline()
        .accessibilityIdentifier(id)
    }

    /// Timeline board rows: "Rally 3 · 2:41 · 8 s · You won", tap to tag, Fix.
    @ViewBuilder private var rallyRows: some View {
        let sides = RacketWatchCopy.sides(opponent: ex?.opponent, doubles: ex?.isDoubles ?? false)
        let all = rallies.filter(\.isRally)
        let hasGuesses = all.contains(where: \.isFromModel)
        let rs = filter == 1 ? all.filter(\.isUnsure) : filter == 2 ? all.filter { !$0.isTagged } : all
        if !all.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if hasGuesses {
                    Text("Solid: rally · Dashed: unsure").font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                    Picker("Show", selection: $filter) {
                        Text("All \(all.count)").tag(0)
                        Text("Unsure \(all.filter(\.isUnsure).count)").tag(1)
                        Text("Untagged \(all.filter { !$0.isTagged }.count)").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("racket.tl.filter")
                }
                Text(hasGuesses ? "A winner on a row means you tagged it. Your tags replace Snappet’s guesses everywhere."
                                : "A winner on a row means you tagged it.").snappetLabel()
                ForEach(Array(rs.enumerated()), id: \.element.id) { k, r in
                    HStack(spacing: 8) {
                        Button { playback?.seek(to: r.startSec); tagging = r } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Rally \(k + 1)").font(.system(size: 15, weight: .semibold)).foregroundStyle(SnappetColor.ink)
                                Text("\(RacketVideoTime.clock(r.startSec - ref.startSec)) · \(RacketTagSummary.seconds(r.durationSec))"
                                     + (r.aiName.map { " · from \($0)" } ?? "")
                                     + (r.isGuess ? " · Snappet guess" : ""))
                                    .font(SnappetType.detail.monospacedDigit()).foregroundStyle(SnappetColor.textSecondary)
                            }
                            Spacer()
                            Text(r.winner.map { $0 == .us ? "\(sides.us) won" : "\(sides.them) won" }
                                 ?? (r.isTagged ? "Replayed" : r.isUnsure ? "Unsure" : "Untagged"))
                                .font(SnappetType.detail.weight(.semibold))
                                .foregroundStyle(r.isTagged ? SnappetColor.ink : r.isUnsure ? SnappetColor.perfModerate : SnappetColor.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("racket.tl.rally.\(k)")
                        Button("Fix") { fixing = r }
                            .font(SnappetType.detail.weight(.semibold))
                            .accessibilityIdentifier("racket.tl.fix.\(k)")
                    }
                    .padding(10).pagerGlass(cornerRadius: 12)
                }
            }
        }
    }
}

// MARK: - FixRally

struct RacketFixRallySheet: View {
    let rally: RacketRally
    let rallies: [RacketRally]
    let lo: Double
    let hi: Double
    let onSave: ([RacketRally]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var work: [RacketRally] = []
    @State private var configured = false

    private var current: RacketRally? { work.first { $0.id == rally.id } }

    var body: some View {
        NavigationStack {
            Form {
                if let r = current {
                    Section("Drag to where it starts and ends") {
                        RacketRangeStrip(start: r.startSec, end: r.endSec,
                                         window: max(lo, r.startSec - 10)...min(hi, r.endSec + 10)) { s, e in
                            if let next = RacketRallyMarking.fix(work, id: r.id, start: s, end: e, within: lo, hi) { work = next }
                        }
                        HStack {
                            Text(RacketVideoTime.precise(r.startSec - lo))
                            Spacer()
                            Text("Length \(RacketTagSummary.seconds(r.durationSec))")
                            Spacer()
                            Text(RacketVideoTime.precise(r.endSec - lo))
                        }
                        .font(SnappetType.detail.monospacedDigit())
                        nudge("Start", r, edge: 0)
                        nudge("End", r, edge: 1)
                    }
                    Section {
                        Button("Split in two") { work = RacketRallyMarking.splitInTwo(work, id: r.id) }
                        Button("Merge with next") { work = RacketRallyMarking.mergeWithNext(work, id: r.id) }
                        Button("Not a rally", role: .destructive) {
                            work = RacketRallyMarking.tag(work, id: r.id, winner: nil, ending: nil, lastShotBy: nil, notRally: true)
                            onSave(work); dismiss()
                        }
                        .accessibilityIdentifier("racket.fix.notRally")
                    }
                }
            }
            .navigationTitle("Fix rally")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(work); dismiss() }.accessibilityIdentifier("racket.fix.save")
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { if !configured { configured = true; work = rallies } }
    }

    private func nudge(_ label: String, _ r: RacketRally, edge: Int) -> some View {
        HStack {
            Text(label)
            Spacer()
            ForEach([-1.0, -0.2, 0.2, 1.0], id: \.self) { d in
                Button(d > 0 ? "+\(d.formatted()) s" : "−\((-d).formatted()) s") {
                    let s = edge == 0 ? r.startSec + d : r.startSec
                    let e = edge == 1 ? r.endSec + d : r.endSec
                    if let next = RacketRallyMarking.fix(work, id: r.id, start: s, end: e, within: lo, hi) { work = next }
                }
                .buttonStyle(.bordered).font(.caption)
            }
        }
    }
}

// MARK: - TtNoModelTag / DoublesTag

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

    private var ex: SessionExercise? { store.ex(ref.exerciseID) }
    private var rallies: [RacketRally] {
        RacketRallyMarking.inRange(ex?.racketRecordingLog?.allRallies ?? [], ref.startSec, ref.endSec).filter(\.isRally)
    }
    private var sport: RacketSport { ex?.racketSport ?? .tableTennis }
    private var doubles: Bool { ex?.isDoubles ?? false }
    private var current: RacketRally? { rallies.first { $0.id == (currentID ?? startID) } }
    /// Unsure guesses in the part when the sheet opened, and how many are checked since.
    @State private var unsureTotal = 0
    @State private var unsureDone = 0

    private var players: [String] {
        var names = ["You"]
        if let p = ex?.partner, !p.isEmpty { names.append(p) }
        let opp = (ex?.opponent ?? "").split(separator: "&").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return names + opp
    }

    var body: some View {
        let sides = RacketWatchCopy.sides(opponent: ex?.opponent, doubles: doubles)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let r = current, let k = rallies.firstIndex(where: { $0.id == r.id }) {
                        Text("Marked \(RacketVideoTime.clock(r.startSec - ref.startSec))–\(RacketVideoTime.clock(r.endSec - ref.startSec))")
                            .font(.system(size: 22, weight: .light)).monospacedDigit()
                            .accessibilityIdentifier("racket.tag.marked")
                        if unsureOnly {
                            Text("Unsure \(unsureDone + 1) of \(unsureTotal)").snappetLabel()
                                .accessibilityIdentifier("racket.tag.unsureCount")
                        } else if r.isGuess {
                            Text(r.isUnsure ? "Snappet guess · unsure" : "Snappet guess").snappetLabel()
                        } else {
                            Text("No suggestions").snappetLabel()
                        }
                        Text("Who won the rally?").font(.system(size: 17, weight: .semibold))
                        HStack(spacing: 10) {
                            pick(sides.us + (r.guessWinner == .us && r.isGuess ? " · suggested" : ""), winner == .us,
                                 id: "racket.tag.winner.us") { winner = .us }
                            pick(sides.them + (r.guessWinner == .them && r.isGuess ? " · suggested" : ""), winner == .them,
                                 id: "racket.tag.winner.them") { winner = .them }
                        }
                        Text("How did it end? Optional").font(.system(size: 17, weight: .semibold))
                        FlowRow {
                            ForEach(RacketRallyEnding.choices(for: sport), id: \.self) { e in
                                pick(e.label, ending == e, id: "racket.tag.end.\(e.rawValue)") { ending = ending == e ? nil : e }
                            }
                        }
                        if doubles {
                            Text("Who made the last shot? Optional").font(.system(size: 17, weight: .semibold))
                            FlowRow {
                                ForEach(players, id: \.self) { n in
                                    pick(n, lastShot == n, id: "racket.tag.last.\(n)") { lastShot = lastShot == n ? nil : n }
                                }
                            }
                        }
                        Button(role: .destructive) { save(r, notRally: true) } label: {
                            Text("Not a rally").frame(maxWidth: .infinity, minHeight: 40)
                        }
                        .accessibilityIdentifier("racket.tag.notRally")
                        Button { save(r, notRally: false) } label: { Text("Next").frame(maxWidth: .infinity, minHeight: 30) }
                            .buttonStyle(SnappetWidePrimaryStyle())
                            .accessibilityIdentifier("racket.tag.next")
                        Text(r.isFromModel ? "A suggestion is only a suggestion: nothing counts until you pick it and tap Next."
                             : "Nothing is picked for you. Snappet can’t suggest for \(sport.label.lowercased()) yet.")
                            .font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Color.clear.frame(height: 0).navigationTitle(unsureOnly ? "Check unsure rallies" : "Your rally \(k + 1) of \(rallies.count)")
                    }
                }
                .padding(20)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { onClose(false) }.accessibilityIdentifier("racket.tag.close")
                }
                ToolbarItem(placement: .confirmationAction) {
                    // Skip: the next rally, nothing saved (review5: Skip / Close / Not a rally are wired).
                    Button("Skip") { advance(after: current?.id) }.accessibilityIdentifier("racket.tag.skip")
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            unsureTotal = rallies.filter(\.isUnsure).count
            load(startID)
        }
    }

    private func load(_ id: UUID) {
        currentID = id
        let r = rallies.first { $0.id == id }
        // A guess with a score tap behind it starts on the suggested winner (QuickTag "You · suggested"); Next confirms
        // it as your tag (prompt 248).
        winner = r?.winner ?? (r?.isGuess == true ? r?.guessWinner : nil)
        ending = r?.ending
        lastShot = r?.lastShotBy
    }

    private func save(_ r: RacketRally, notRally: Bool) {
        let all = ex?.racketRecordingLog?.allRallies ?? []
        let updated = RacketRallyMarking.tag(all, id: r.id, winner: winner, ending: ending, lastShotBy: lastShot, notRally: notRally)
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

    private func pick(_ label: String, _ selected: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: { action(); Haptics.tap() }) {
            Text(label).font(.system(size: 15, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.black : SnappetColor.ink)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .frame(minWidth: 60)
                .background(selected ? SnappetColor.brand : Color.clear, in: Capsule())
                .overlay(Capsule().strokeBorder(SnappetColor.hairline))
                .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
