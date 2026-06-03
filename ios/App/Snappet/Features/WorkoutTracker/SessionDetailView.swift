import SwiftUI
import SwiftData
import Photos
import Charts
import HighlightEngine

/// Detail for a completed session: summary stats, the **live HR chart + band stats** (B2 —
/// avg/max HR + time-in-zone, only when the session has a persisted `hrSeries`), every exercise
/// with its sets, and the **tagged-media gallery** (B1) — the photos/videos shot during this
/// workout, auto-discovered by capture-time window and/or added by hand.
struct SessionDetailView: View {
    let session: WorkoutSession
    let resolver: ExerciseResolver
    let unit: WeightUnit
    /// The routine's sport, used by B4 highlight generation's activity mapping (`nil` if the
    /// routine was deleted — the bridge then falls back to the dominant exercise category).
    var sport: SportTag? = nil

    /// Dominant exercise category across the session (B4 activity-mapping fallback when there's
    /// no sport). Resolved from the session's exercises via the `resolver`.
    private var dominantCategory: ExerciseCategory? {
        let cats = session.exercises.compactMap { resolver.exercise(id: $0.exerciseId)?.category }
        return WorkoutActivityMapping.dominantCategory(of: cats)
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Date") {
                    Text(session.startedAt, format: .dateTime.weekday().month().day().hour().minute())
                }
                LabeledContent("Duration", value: "\(max(1, Int(session.duration / 60))) min")
                LabeledContent("Sets completed", value: "\(session.completedSetCount)")
                let vol = WorkoutMath.sessionVolumeKg(session)
                if vol > 0 {
                    LabeledContent("Total volume", value: WorkoutMath.formatVolume(kg: vol, unit: unit))
                }
            }

            if let stats = WorkoutHRStats.make(from: session.hrSeries) {
                HeartRateSummarySection(series: session.hrSeries, stats: stats)
            }

            SessionMediaSection(session: session, resolver: resolver, sport: sport, category: dominantCategory)

            ForEach(session.exercises) { ex in
                Section {
                    if ex.skipped {
                        Text("Skipped").foregroundStyle(.secondary).italic()
                    } else {
                        ForEach(Array(ex.sets.enumerated()), id: \.offset) { idx, set in
                            SetLogRow(index: idx + 1, set: set, unit: unit)
                        }
                    }
                } header: {
                    Text(resolver.name(for: ex.exerciseId, override: ex.displayName))
                }
            }
        }
        .navigationTitle("Session")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Heart-rate summary (B2)

/// The "Heart rate" section: a smoothed bpm-over-time line chart + a stats row (avg/max HR)
/// + a time-in-zone bar with a legend. Rendered only when the session has a non-empty
/// `hrSeries` (the parent guards on `WorkoutHRStats.make` being non-nil), so a phone-only /
/// simulator workout shows nothing here. All HR math lives in the pure `WorkoutHRStats`
/// helper and `HighlightEngine.HeartRateSeries`; this view is thin (B2).
private struct HeartRateSummarySection: View {
    let series: [HRPoint]
    let stats: WorkoutHRStats

    var body: some View {
        Section {
            HeartRateChart(series: series)
                .frame(height: 160)
                .padding(.vertical, 4)
                .accessibilityIdentifier("hrChart")

            HStack(spacing: 24) {
                hrStat("Avg", bpm: stats.avgBpm)
                hrStat("Max", bpm: stats.maxBpm)
                hrStat("Min", bpm: stats.minBpm)
            }
            .frame(maxWidth: .infinity)

            if stats.totalSeconds > 0 {
                ZoneBar(stats: stats)
            }
        } header: {
            Text("Heart rate")
        }
    }

    private func hrStat(_ label: String, bpm: Double) -> some View {
        VStack(spacing: 2) {
            Text("\(Int(bpm.rounded()))")
                .font(.title3.monospacedDigit().weight(.semibold))
                .contentTransition(.numericText())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// A Swift Charts line of bpm over session time. The raw `hrSeries` is resampled + smoothed
/// via `HighlightEngine.HeartRateSeries` (reused, not reimplemented — the engine stays
/// platform-free) so the line is clean rather than jagged. The x-axis is elapsed minutes.
private struct HeartRateChart: View {
    let series: [HRPoint]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Drives the line draw-in: the plotted bpm animates from 0 → actual on first appear.
    @State private var drawn = false

    /// The smoothed (bpm, t-seconds) points the chart draws.
    private var smoothed: [(t: Double, bpm: Double)] {
        let samples = series.map { HRSample(t: $0.t, bpm: $0.bpm) }
        let duration = max(1, series.map(\.t).max() ?? 0)
        // Reuse the engine's resample→smooth (5 s window is gentle for a chart line).
        let hr = HeartRateSeries.make(from: samples, duration: duration, dt: 1.0,
                                      smoothingWindowSec: 5, restBpm: nil, maxBpm: nil)
        return hr.bpm.enumerated().map { (t: Double($0.offset) * hr.dt, bpm: $0.element) }
    }

    var body: some View {
        Chart(smoothed, id: \.t) { point in
            LineMark(
                x: .value("Time", point.t / 60),
                // The line rises from the baseline on appear (issue #30 §5.7); Reduce Motion
                // shows it fully drawn immediately.
                y: .value("BPM", drawn || reduceMotion ? point.bpm : 0)
            )
            // Semantic HR colour — the zone ramp's hot end (kept as the HR scale).
            .foregroundStyle(HeartRateZone.max.color)
            .interpolationMethod(.catmullRom)
        }
        .chartXAxisLabel("min")
        .chartYAxisLabel("bpm")
        .animation(Snappet.snappetAnimation(SnappetMotion.expressive, reduceMotion: reduceMotion), value: drawn)
        .onAppear { drawn = true }
        .onDisappear { drawn = false }
    }
}

/// A horizontal time-in-zone bar (proportional segments per zone, zone-tinted) + a legend
/// listing each used zone with its minutes. Reuses `HeartRateZone` for colors/labels.
private struct ZoneBar: View {
    let stats: WorkoutHRStats

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Drives the segment width grow-in on appear.
    @State private var drawn = false

    private var used: [(zone: HeartRateZone, seconds: Double)] {
        stats.orderedZoneSeconds.filter { $0.seconds > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(used, id: \.zone.rawValue) { item in
                        let fraction = drawn || reduceMotion ? item.seconds / stats.totalSeconds : 0
                        item.zone.color
                            .frame(width: max(1, geo.size.width * fraction))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .animation(Snappet.snappetAnimation(SnappetMotion.standard, reduceMotion: reduceMotion), value: drawn)
            }
            .frame(height: 12)
            .accessibilityIdentifier("hrZoneBar")
            .onAppear { drawn = true }
            .onDisappear { drawn = false }

            ForEach(used, id: \.zone.rawValue) { item in
                HStack(spacing: 6) {
                    Circle().fill(item.zone.color).frame(width: 8, height: 8)
                    Text(item.zone.pillLabel).font(.caption)
                    Spacer()
                    Text(Self.minutesLabel(item.seconds))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    static func minutesLabel(_ seconds: Double) -> String {
        let mins = seconds / 60
        return mins >= 1 ? "\(Int(mins.rounded())) min" : "\(Int(seconds.rounded()))s"
    }
}

// MARK: - Tagged-media gallery (B1 + per-set assignment)

/// The "Media from this workout" section: clips **grouped by the set they were filmed during**
/// (`<exercise> · Set n`) with a **General** bucket for anything not tied to a set, an
/// "Add photos/videos" PHPicker, a "Find media from this workout" auto-discovery action, a
/// per-clip **Move to…** reassignment menu (to fix a wrong auto-guess or pin to General), and
/// remove. Photos access is requested value-first, reusing `SessionMediaService`.
///
/// Placement is inferred from capture time by the pure `SessionMediaAssignment` (reconciled on
/// appear / after discovery) — it only ever (re)places `auto` clips, so a user's manual move or
/// General pin is sticky. `.limited` access can't be scanned by time window, so auto-discovery is
/// hidden and only the PHPicker is offered. The simulator has no Photos, so thumbnails render their
/// placeholder state there (the grouping/reassignment UI still works — it's driven by the model).
private struct SessionMediaSection: View {
    let session: WorkoutSession
    let resolver: ExerciseResolver
    /// Activity inputs for the B4 highlight engine (passed down from the detail view).
    let sport: SportTag?
    let category: ExerciseCategory?

    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Per-session media, ordered by capture offset. `#Predicate` on the `sessionID` FK
    // (the suite's per-parent query convention).
    @Query private var media: [SessionMedia]

    @State private var showingPicker = false
    @State private var isDiscovering = false
    @State private var didAppear = false
    @State private var message: String?
    /// The video clip being edited in the B3 clip-editor sheet (videos only — photos aren't
    /// editable in the clip editor). `item:` sheet so the editor owns its own `NavigationStack`.
    @State private var editingClip: SessionMedia?
    /// Presents the B4 highlight-generation sheet (clip selection → generate → preview).
    @State private var showingHighlight = false

    init(session: WorkoutSession, resolver: ExerciseResolver, sport: SportTag?, category: ExerciseCategory?) {
        self.session = session
        self.resolver = resolver
        self.sport = sport
        self.category = category
        let sid = session.id
        _media = Query(filter: #Predicate<SessionMedia> { $0.sessionID == sid },
                       sort: \SessionMedia.offsetSec, order: .forward)
    }

    /// "Generate highlight" is enabled only when the session has at least one tagged **video**
    /// (the reel stitch is video-first; a photo-only session has nothing to cut).
    private var hasVideo: Bool { media.contains { $0.kind == .video } }

    private let columns = [GridItem(.adaptive(minimum: 88), spacing: 8)]

    var body: some View {
        // A header section with the actions + empty state, then one section per set group, then
        // a General section. A `Group` of `Section`s flattens into the parent `List`.
        Group {
            actionsSection
            ForEach(groups) { group in
                Section {
                    grid(for: group.items)
                } header: {
                    Text(group.title)
                }
            }
        }
        .sheet(isPresented: $showingPicker) {
            MediaPicker { ids in addManual(ids) }
        }
        .sheet(item: $editingClip) { clip in
            ClipEditorView(media: clip)
        }
        .sheet(isPresented: $showingHighlight) {
            // Snapshot the @Models into plain values on the MainActor; the bridge + engine never
            // touch SwiftData. The sheet owns its own NavigationStack (no nesting in the module's).
            SessionHighlightView(
                viewModel: SessionHighlightViewModel(
                    app: app,
                    hrSeries: session.hrSeries,
                    clips: media.map {
                        SessionHighlightInput.Clip(
                            localIdentifier: $0.localIdentifier, isVideo: $0.kind == .video,
                            offsetSec: $0.offsetSec, durationSec: $0.durationSec)
                    },
                    duration: session.duration,
                    sport: sport,
                    category: category))
        }
        .task {
            // On first appear: silently auto-discover (only if full access already granted), then
            // reconcile per-set assignments over whatever media we have (discovered or seeded).
            guard !didAppear else { return }
            didAppear = true
            if app.sessionMedia.canAutoDiscover { await autoDiscover(prompt: false) }
            reconcileAssignments()
        }
    }

    // MARK: Sections

    @ViewBuilder private var actionsSection: some View {
        Section {
            if media.isEmpty {
                ContentUnavailableView {
                    Label("No media yet", systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text("Add photos and videos you took during this workout, or find them automatically.")
                }
                .frame(maxWidth: .infinity)
            }

            if let message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }

            Button {
                Task { await autoDiscover(prompt: true) }
            } label: {
                if isDiscovering {
                    HStack { ProgressView(); Text("Finding media…") }
                } else {
                    Label("Find media from this workout", systemImage: "sparkle.magnifyingglass")
                }
            }
            .disabled(isDiscovering)

            Button {
                Task { await ensureAccessThenPick() }
            } label: {
                Label("Add photos/videos", systemImage: "plus")
            }

            // B4: engine-driven highlight reel from the tagged clips + HR + selection.
            Button {
                showingHighlight = true
            } label: {
                Label("Generate highlight", systemImage: "sparkles.tv")
            }
            .disabled(!hasVideo)
            .accessibilityIdentifier("generateHighlight")
        } header: {
            Text("Media from this workout")
        }
    }

    private func grid(for items: [SessionMedia]) -> some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(items) { item in
                SessionMediaThumb(item: item)
                    .onTapGesture {
                        // A tagged video opens the B3 clip editor; photos aren't editable there.
                        if item.kind == .video { editingClip = item }
                    }
                    .contextMenu { thumbMenu(for: item) }
            }
        }
        .padding(.vertical, 4)
        // Newly discovered / added / reassigned thumbnails settle in gently (Reduce-Motion gated).
        .snappetAnimation(SnappetMotion.standard, value: media.count)
    }

    @ViewBuilder private func thumbMenu(for item: SessionMedia) -> some View {
        if item.kind == .video {
            Button { editingClip = item } label: {
                Label("Edit clip", systemImage: "slider.horizontal.3")
            }
        }
        Menu {
            ForEach(moveTargets) { target in
                Button(target.title) { reassign(item, to: target.exerciseID, set: target.setIndex) }
            }
            Divider()
            Button("General") { reassign(item, to: nil, set: nil) }
        } label: {
            Label("Move to…", systemImage: "arrow.left.arrow.right")
        }
        Button(role: .destructive) { remove(item) } label: {
            Label("Remove", systemImage: "trash")
        }
    }

    // MARK: Grouping

    /// A set/General bucket of clips, in session order (sets first, General last).
    private struct MediaGroup: Identifiable {
        let id: String
        let title: String
        let items: [SessionMedia]
    }

    /// A reassignment destination shown in the Move-to menu.
    private struct MoveTarget: Identifiable {
        let id: String
        let title: String
        let exerciseID: UUID?
        let setIndex: Int?
    }

    private var groups: [MediaGroup] {
        var result: [MediaGroup] = []
        var placed = Set<UUID>()
        for ex in session.exercises {
            let name = resolver.name(for: ex.exerciseId, override: ex.displayName)
            for i in ex.sets.indices {
                let items = media.filter {
                    !$0.isGeneral && $0.assignedExerciseID == ex.id && $0.assignedSetIndex == i
                }
                guard !items.isEmpty else { continue }
                items.forEach { placed.insert($0.id) }
                result.append(MediaGroup(id: "\(ex.id)-\(i)", title: "\(name) · Set \(i + 1)", items: items))
            }
            // Clips tied to the exercise but no specific set.
            let exItems = media.filter {
                !$0.isGeneral && $0.assignedExerciseID == ex.id && $0.assignedSetIndex == nil
            }
            if !exItems.isEmpty {
                exItems.forEach { placed.insert($0.id) }
                result.append(MediaGroup(id: "\(ex.id)-ex", title: name, items: exItems))
            }
        }
        // Everything else (explicitly General, unassigned, or pointing at a missing exercise).
        let general = media.filter { !placed.contains($0.id) }
        if !general.isEmpty {
            result.append(MediaGroup(id: "__general", title: "General", items: general))
        }
        return result
    }

    private var moveTargets: [MoveTarget] {
        var targets: [MoveTarget] = []
        for ex in session.exercises {
            let name = resolver.name(for: ex.exerciseId, override: ex.displayName)
            for i in ex.sets.indices {
                targets.append(MoveTarget(id: "\(ex.id)-\(i)", title: "\(name) · Set \(i + 1)",
                                          exerciseID: ex.id, setIndex: i))
            }
        }
        return targets
    }

    private func reassign(_ item: SessionMedia, to exerciseID: UUID?, set setIndex: Int?) {
        item.assignedExerciseID = exerciseID
        item.assignedSetIndex = setIndex
        // A move to a set is `manual`; a move to General is a sticky `general` pin. Either way the
        // auto-assigner will leave it alone from now on.
        item.assignmentSource = exerciseID == nil ? .general : .manual
        try? context.save()
    }

    /// Re-place every `auto` clip from the set-completion timeline (idempotent — writes only on a
    /// real change, so it can't loop with the `@Query`). Manual / General clips are untouched.
    @MainActor
    private func reconcileAssignments() {
        let completions = SessionMediaAssignment.completions(from: session.exercises, startedAt: session.startedAt)
        guard !completions.isEmpty else { return }
        let autoRows = media.filter { $0.assignmentSource == .auto }
        guard !autoRows.isEmpty else { return }
        let assigned = SessionMediaAssignment.assign(
            clips: autoRows.map { .init(id: $0.id, offsetSec: $0.offsetSec) },
            completions: completions)
        var changed = false
        for row in autoRows {
            let ref = assigned[row.id]
            if row.assignedExerciseID != ref?.exerciseID || row.assignedSetIndex != ref?.setIndex {
                row.assignedExerciseID = ref?.exerciseID
                row.assignedSetIndex = ref?.setIndex
                changed = true
            }
        }
        if changed { try? context.save() }
    }

    private var existingIdentifiers: Set<String> { Set(media.map(\.localIdentifier)) }

    /// Run auto-discovery. `prompt` requests Photos access value-first (on the explicit
    /// "Find media" tap); the silent on-appear pass passes `prompt: false`.
    @MainActor
    private func autoDiscover(prompt: Bool) async {
        message = nil
        if prompt, !app.sessionMedia.canAutoDiscover {
            let status = await app.sessionMedia.requestAccess()
            app.photoAccess = status
            if status == .limited {
                // Limited access can't scan the library by time window — fall back to the picker.
                message = "Limited Photo access — pick the clips by hand."
                showingPicker = true
                return
            }
            guard status == .authorized else {
                message = "Photo access is needed to find media from this workout."
                return
            }
        }
        guard app.sessionMedia.canAutoDiscover else { return }

        isDiscovering = true
        defer { isDiscovering = false }
        do {
            let found = try await app.sessionMedia.discover(
                startedAt: session.startedAt, completedAt: session.completedAt,
                existingIdentifiers: existingIdentifiers)
            insert(found, addedManually: false)
            if prompt { message = found.isEmpty ? "No photos or videos found in this workout's time window." : nil }
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? "Couldn't search your library."
        }
    }

    @MainActor
    private func ensureAccessThenPick() async {
        if app.sessionMedia.currentStatus == .notDetermined {
            app.photoAccess = await app.sessionMedia.requestAccess()
        }
        showingPicker = true
    }

    private func addManual(_ ids: [String]) {
        let cands = app.sessionMedia.candidates(
            forIdentifiers: ids, startedAt: session.startedAt,
            existingIdentifiers: existingIdentifiers)
        insert(cands, addedManually: true)
    }

    private func insert(_ candidates: [SessionMediaService.Candidate], addedManually: Bool) {
        guard !candidates.isEmpty else { return }
        for c in candidates {
            context.insert(SessionMedia(
                sessionID: session.id, localIdentifier: c.localIdentifier,
                kind: c.kind, offsetSec: c.offsetSec, durationSec: c.durationSec,
                addedManually: addedManually))
        }
        try? context.save()
        // Place the newly added clips into their sets from capture time (they're `auto`).
        reconcileAssignments()
    }

    private func remove(_ item: SessionMedia) {
        context.delete(item)
        try? context.save()
    }
}

/// One thumbnail: loads a `PHImageManager` image for the asset, with an offset badge
/// ("+Ns") and a play glyph for videos. Renders a placeholder where the asset is missing
/// (e.g. on the simulator, which has no Photos library).
private struct SessionMediaThumb: View {
    let item: SessionMedia
    @State private var image: UIImage?

    private let side: CGFloat = 88

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Rectangle().fill(.quaternary)
                        .overlay(Image(systemName: item.kind == .video ? "video" : "photo")
                            .foregroundStyle(.secondary))
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: SnappetRadius.sm, style: .continuous))

            if item.kind == .video {
                Image(systemName: "play.circle.fill")
                    .font(.title3).foregroundStyle(.white)
                    .shadow(radius: 2)
                    .frame(width: side, height: side, alignment: .center)
            }

            Text(offsetBadge)
                .font(.caption2.monospacedDigit().weight(.semibold))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(.black.opacity(0.55), in: Capsule())
                .foregroundStyle(.white)
                .padding(4)
        }
        .frame(width: side, height: side)
        .accessibilityElement()
        .accessibilityIdentifier("mediaThumb")
        .accessibilityLabel("\(item.kind == .video ? "Video" : "Photo") at \(offsetBadge)")
        .task(id: item.localIdentifier) { await loadThumbnail() }
    }

    private var offsetBadge: String { "+\(Int(item.offsetSec.rounded()))s" }

    private func loadThumbnail() async {
        guard image == nil else { return }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [item.localIdentifier], options: nil)
        guard let asset = assets.firstObject else { return }
        let target = CGSize(width: side * 3, height: side * 3)
        let options = PHImageRequestOptions()
        // `.highQualityFormat` delivers a single (final) callback, so the continuation
        // resumes exactly once — no degraded-then-final double-resume to guard against.
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = false   // on-device only
        let manager = PHImageManager.default()
        let loaded: UIImage? = await withCheckedContinuation { continuation in
            manager.requestImage(for: asset, targetSize: target,
                                 contentMode: .aspectFill, options: options) { img, _ in
                continuation.resume(returning: img)
            }
        }
        if let loaded { image = loaded }
    }
}

private struct SetLogRow: View {
    let index: Int
    let set: SetLog
    let unit: WeightUnit

    var body: some View {
        HStack {
            Text("Set \(index)").font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            if set.completedAt != nil {
                Text(detailText).font(.subheadline.monospacedDigit())
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
        }
    }

    private var detailText: String {
        let reps = set.actualReps.map { "\($0) reps" } ?? "done"
        if let w = set.actualWeight, w > 0 {
            let kg = WorkoutMath.toKg(w, set.weightUnit)
            return "\(WorkoutMath.formatWeight(kg: kg, unit: unit)) \(unit.display) × \(set.actualReps ?? 0)"
        }
        return reps
    }
}
