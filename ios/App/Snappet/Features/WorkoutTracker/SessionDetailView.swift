import SwiftUI
import SwiftData
import Photos
import Charts
import HighlightEngine

/// Detail for a completed session: summary stats, the **live HR chart + band stats** (B2 —
/// avg/max HR + time-in-zone, only when the session has a persisted `hrSeries`), and a unified
/// **per-set** breakdown — each set is one tile showing its reps/weight, the heart rate at that set,
/// and the photos/videos tagged to it (multiple media → multiple rows under the tile). Media is
/// auto-discovered by capture-time window and/or added by hand; a **General** bucket holds anything
/// not tied to a set.
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

    /// The clip being edited. Hosted HERE (on the `List`, which has no `@Query` so it never
    /// re-renders from media/app changes) rather than inside `SessionMediaSection` — a `.sheet`
    /// attached to the section's `Group` (which flattens into the `List`) gets torn down when the
    /// section re-renders, so it collapsed on the first open and only worked on the second
    /// (decisions.md: present from a stable host, not a flattened Group).
    @State private var editingClip: SessionMedia?
    /// A clip the user asked to remove — drives the destructive confirmation (hosted on the List).
    @State private var pendingRemoval: SessionMedia?
    @Environment(\.modelContext) private var context
    private let mediaLibrary = MediaLibraryService()

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

            // Unified media + per-set breakdown (the actions header, one section per exercise with
            // per-set tiles + their media, and a General bucket).
            SessionMediaSection(session: session, resolver: resolver, unit: unit,
                                sport: sport, category: dominantCategory,
                                onEditClip: { editingClip = $0 },
                                onRemove: { pendingRemoval = $0 })
        }
        .navigationTitle("Session")
        .navigationBarTitleDisplayMode(.inline)
        // Presented from the List (a stable host), so opening the editor never tears itself down.
        .sheet(item: $editingClip) { clip in ClipEditorView(media: clip) }
        // Destructive remove, confirmed (also hosted on the List). "Delete from Photos" removes the
        // underlying asset from the library; "Remove from session" only drops the tag.
        .confirmationDialog(
            "Remove this \(pendingRemoval?.kind == .video ? "video" : "photo")?",
            isPresented: Binding(get: { pendingRemoval != nil },
                                 set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible, presenting: pendingRemoval
        ) { item in
            Button("Remove from session only") { removeTag(item) }
            Button("Delete from Photos too", role: .destructive) { deleteFromPhotos(item) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("“Remove from session” keeps the video in your Photos library. “Delete from Photos” permanently removes it (iOS will ask once more).")
        }
    }

    private func removeTag(_ item: SessionMedia) {
        context.delete(item)
        try? context.save()
    }

    private func deleteFromPhotos(_ item: SessionMedia) {
        // Delete the Photos asset FIRST (iOS shows its own confirmation); only drop the session tag
        // if that succeeds, so a denied/cancelled delete doesn't orphan the tag from a still-present asset.
        let id = item.localIdentifier
        Task {
            do {
                try await mediaLibrary.deleteAssets(localIdentifiers: [id])
                context.delete(item)
                try? context.save()
            } catch {
                // Asset not deleted (denied/cancelled) — keep the tag so the clip still shows.
            }
        }
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

// MARK: - Per-set media + breakdown (B1 + per-set assignment, unified)

/// The "Media from this workout" section: an actions header (find / add / generate / studio), then
/// **one tile per set** — each set's reps/weight + the heart rate at that set, with the photos/videos
/// tagged to it shown as rows beneath (multiple media → multiple rows). A **General** bucket holds
/// anything not tied to a set. Media can be reassigned (Move to…) or **removed** (swipe or the menu).
///
/// Placement is inferred from capture time by the pure `SessionMediaAssignment` (reconciled on appear
/// / after discovery) — it only ever (re)places `auto` clips, so a manual move or General pin is
/// sticky. `.limited` access can't be scanned by time window, so auto-discovery falls back to the
/// PHPicker. The simulator has no Photos, so thumbnails render their placeholder (the per-set grouping
/// + reassignment UI still works — it's model-driven).
private struct SessionMediaSection: View {
    let session: WorkoutSession
    let resolver: ExerciseResolver
    let unit: WeightUnit
    /// Activity inputs for the B4 highlight engine (passed down from the detail view).
    let sport: SportTag?
    let category: ExerciseCategory?
    /// Open the clip editor — presented by the parent on a stable host (see `SessionDetailView`).
    let onEditClip: (SessionMedia) -> Void
    /// Ask the parent to confirm + perform removal (tag-only or delete-from-Photos).
    let onRemove: (SessionMedia) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL

    @Query private var media: [SessionMedia]

    @State private var isDiscovering = false
    @State private var didAppear = false
    @State private var message: String?
    @State private var studioProject: StudioProject?
    /// One sheet at a time. Stacking several `.sheet` modifiers on this `Group` (which flattens into
    /// the parent `List`) makes them fight — the first presentation collapses immediately, the second
    /// works. A single `item:`-driven sheet (stable identity) presents reliably on the first tap.
    @State private var activeSheet: MediaSheet?

    private enum MediaSheet: Identifiable {
        case picker, highlight
        var id: String { self == .picker ? "picker" : "highlight" }
    }

    init(session: WorkoutSession, resolver: ExerciseResolver, unit: WeightUnit,
         sport: SportTag?, category: ExerciseCategory?,
         onEditClip: @escaping (SessionMedia) -> Void,
         onRemove: @escaping (SessionMedia) -> Void) {
        self.session = session
        self.resolver = resolver
        self.unit = unit
        self.sport = sport
        self.category = category
        self.onEditClip = onEditClip
        self.onRemove = onRemove
        let sid = session.id
        _media = Query(filter: #Predicate<SessionMedia> { $0.sessionID == sid },
                       sort: \SessionMedia.offsetSec, order: .forward)
    }

    private var hasVideo: Bool { media.contains { $0.kind == .video } }

    var body: some View {
        Group {
            actionsSection
            ForEach(session.exercises) { ex in
                Section {
                    if ex.skipped {
                        Text("Skipped").foregroundStyle(.secondary).italic()
                    } else {
                        ForEach(Array(ex.sets.enumerated()), id: \.offset) { i, set in
                            SetTileRow(index: i + 1, set: set, unit: unit,
                                       bpm: bpm(forSetCompletedAt: set.completedAt))
                            ForEach(mediaFor(exercise: ex.id, set: i)) { mediaRow($0) }
                        }
                        ForEach(mediaFor(exercise: ex.id, set: nil)) { mediaRow($0) }
                    }
                } header: {
                    Text(resolver.name(for: ex.exerciseId, override: ex.displayName))
                }
            }
            if !generalMedia.isEmpty {
                Section {
                    ForEach(generalMedia) { mediaRow($0) }
                } header: {
                    Text("General")
                }
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .picker:
                MediaPicker { ids in addManual(ids) }
            case .highlight:
                SessionHighlightView(
                    viewModel: SessionHighlightViewModel(
                        app: app, hrSeries: session.hrSeries,
                        clips: media.map {
                            SessionHighlightInput.Clip(
                                localIdentifier: $0.localIdentifier, isVideo: $0.kind == .video,
                                offsetSec: $0.offsetSec, durationSec: $0.durationSec)
                        },
                        duration: session.duration, sport: sport, category: category))
            }
        }
        .task {
            guard !didAppear else { return }
            didAppear = true
            if app.sessionMedia.canAutoDiscover { await autoDiscover(prompt: false) }
            reconcileAssignments()
        }
    }

    // MARK: Actions header

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

            Button { Task { await ensureAccessThenPick() } } label: {
                Label("Add photos/videos", systemImage: "plus")
            }

            // #4: an escape hatch when Photos access is blocked — auto-discovery can't time-scan the
            // library without full access, so route the user to Settings.
            if app.photoAccess == .denied || app.photoAccess == .restricted || app.photoAccess == .limited {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                } label: {
                    Label(app.photoAccess == .limited ? "Allow full Photos access in Settings"
                                                       : "Enable Photos access in Settings",
                          systemImage: "gear")
                }
                .font(.footnote)
            }

            Button { activeSheet = .highlight } label: {
                Label("Generate highlight", systemImage: "sparkles.tv")
            }
            .disabled(!hasVideo)
            .accessibilityIdentifier("generateHighlight")

            Button { openStudio() } label: {
                Label("Open studio (multi-clip)", systemImage: "film.stack")
            }
            .disabled(!hasVideo)
            .accessibilityIdentifier("openStudio")
            .fullScreenCover(item: $studioProject) { project in
                StudioEditorView(project: project, context: context)
            }
        } header: {
            Text("Media from this workout")
        }
    }

    // MARK: One media row (under a set tile or in General) — tap to edit, swipe/menu to remove/move

    @ViewBuilder private func mediaRow(_ item: SessionMedia) -> some View {
        HStack(spacing: 12) {
            SessionMediaThumb(item: item, side: 54)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.kind == .video ? "Video" : "Photo").font(.subheadline)
                Text("at +\(Int(item.offsetSec.rounded()))s" + (item.kind == .video ? " · tap to edit" : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if item.kind == .video { Image(systemName: "slider.horizontal.3").foregroundStyle(.secondary) }
        }
        .contentShape(Rectangle())
        .onTapGesture { if item.kind == .video { onEditClip(item) } }
        .contextMenu { thumbMenu(for: item) }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) { onRemove(item) } label: { Label("Remove", systemImage: "trash") }
        }
        .swipeActions(edge: .leading) {
            Menu {
                ForEach(moveTargets) { t in
                    Button(t.title) { reassign(item, to: t.exerciseID, set: t.setIndex) }
                }
                Divider()
                Button("General") { reassign(item, to: nil, set: nil) }
            } label: { Label("Move", systemImage: "arrow.left.arrow.right") }
            .tint(SnappetColor.workout)
        }
    }

    @ViewBuilder private func thumbMenu(for item: SessionMedia) -> some View {
        if item.kind == .video {
            Button { onEditClip(item) } label: { Label("Edit clip", systemImage: "slider.horizontal.3") }
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
        Button(role: .destructive) { onRemove(item) } label: {
            Label("Remove…", systemImage: "trash")
        }
    }

    // MARK: Grouping + per-set HR

    /// Media tagged to a specific `(exercise, set)`, or to an exercise with no set (`set == nil`).
    private func mediaFor(exercise: UUID, set setIndex: Int?) -> [SessionMedia] {
        media.filter { !$0.isGeneral && $0.assignedExerciseID == exercise && $0.assignedSetIndex == setIndex }
    }

    /// Everything not placed under any exercise/set tile (explicitly General, unassigned, or pointing
    /// at a missing exercise).
    private var generalMedia: [SessionMedia] {
        let exerciseIDs = Set(session.exercises.map(\.id))
        return media.filter { $0.isGeneral || $0.assignedExerciseID == nil
            || !exerciseIDs.contains($0.assignedExerciseID ?? UUID()) }
    }

    /// The heart rate at a set's completion (nearest `hrSeries` sample), or nil with no HR data.
    private func bpm(forSetCompletedAt completedAt: Date?) -> Double? {
        guard let completedAt, !session.hrSeries.isEmpty else { return nil }
        let offset = completedAt.timeIntervalSince(session.startedAt)
        return session.hrSeries.min { abs($0.t - offset) < abs($1.t - offset) }?.bpm
    }

    private struct MoveTarget: Identifiable {
        let id: String
        let title: String
        let exerciseID: UUID?
        let setIndex: Int?
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

    // MARK: Mutations

    private func reassign(_ item: SessionMedia, to exerciseID: UUID?, set setIndex: Int?) {
        item.assignedExerciseID = exerciseID
        item.assignedSetIndex = setIndex
        item.assignmentSource = exerciseID == nil ? .general : .manual
        try? context.save()
    }

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

    @MainActor
    private func autoDiscover(prompt: Bool) async {
        message = nil
        if prompt, !app.sessionMedia.canAutoDiscover {
            let status = await app.sessionMedia.requestAccess()
            app.photoAccess = status
            if status == .limited {
                message = "Limited Photo access can't auto-search — pick the clips by hand, or allow full access in Settings."
                activeSheet = .picker
                return
            }
            guard status == .authorized else {
                message = "Photo access is needed to find media from this workout. Enable it in Settings."
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
            if prompt {
                message = found.isEmpty
                    ? "No photos or videos were found in this workout's time window (\(windowLabel))."
                    : "Found \(found.count) item\(found.count == 1 ? "" : "s")."
            }
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? "Couldn't search your library."
        }
    }

    /// A short human label for the search window, so an empty result explains *what* was searched.
    private var windowLabel: String {
        let start = session.startedAt, end = session.completedAt ?? session.startedAt
        let f = Date.FormatStyle.dateTime.hour().minute()
        return "\(start.formatted(f))–\(end.formatted(f))"
    }

    @MainActor
    private func ensureAccessThenPick() async {
        if app.sessionMedia.currentStatus == .notDetermined {
            app.photoAccess = await app.sessionMedia.requestAccess()
        }
        activeSheet = .picker
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
        reconcileAssignments()
    }

    /// Find or create the session's `StudioProject` (seeded from its video clips, in capture order)
    /// and present the multi-clip studio editor.
    private func openStudio() {
        let sid = session.id
        if let existing = try? context.fetch(
            FetchDescriptor<StudioProject>(predicate: #Predicate { $0.sessionID == sid })).first {
            studioProject = existing
        } else {
            let clips = media.filter { $0.kind == .video }
                .sorted { $0.offsetSec < $1.offsetSec }
                .enumerated()
                .map { i, m in
                    TimelineClip(sessionMediaID: m.id, localIdentifier: m.localIdentifier,
                                 isPhoto: false, order: i, trimEnd: m.durationSec)
                }
            let project = StudioProject(sessionID: sid, title: session.routineName, clips: clips)
            context.insert(project)
            try? context.save()
            studioProject = project
        }
    }
}

// MARK: - Set tile (reps/weight + the HR at that set)

/// One set's tile: the set number, its reps/weight, and the heart rate at the set's completion
/// (zone-coloured). Its tagged media render as separate rows beneath it (so each is swipe-removable).
private struct SetTileRow: View {
    let index: Int
    let set: SetLog
    let unit: WeightUnit
    let bpm: Double?

    var body: some View {
        HStack(spacing: 10) {
            Text("Set \(index)").font(.subheadline.weight(.medium))
            Spacer()
            if set.completedAt != nil {
                Text(detailText).font(.subheadline.monospacedDigit())
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
            if let bpm {
                let zone = HeartRateZone.forBpm(bpm)
                HStack(spacing: 3) {
                    Image(systemName: "heart.fill").font(.caption2)
                    Text("\(Int(bpm.rounded()))").font(.caption.monospacedDigit().weight(.semibold))
                }
                .foregroundStyle(zone.color)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(zone.color.opacity(0.15), in: Capsule())
                .accessibilityIdentifier("setHRBadge")
            }
        }
    }

    private var detailText: String {
        // Freeform climb / timed sets carry their own fields — render them via the shared formatter so a
        // bouldering or timed-hold session reads correctly here too (dynamic-sessions D5).
        if set.climbGradeLabel != nil || set.climbStatusRaw != nil {
            return SetMeasure.summary(set, kind: .climbAttempt, unit: unit)
        }
        if let d = set.durationSec, d > 0 {
            return SetMeasure.summary(set, kind: .duration, unit: unit)
        }
        if let w = set.actualWeight, w > 0 {
            let kg = WorkoutMath.toKg(w, set.weightUnit)
            return "\(WorkoutMath.formatWeight(kg: kg, unit: unit)) \(unit.display) × \(set.actualReps ?? 0)"
        }
        return set.actualReps.map { "\($0) reps" } ?? "done"
    }
}

/// One thumbnail: loads a `PHImageManager` image for the asset, with an offset badge ("+Ns") and a
/// play glyph for videos. Renders a placeholder where the asset is missing (e.g. the simulator).
/// `side` lets callers use a compact size in list rows. Internal so the live player's per-set strip
/// (M3) can reuse it.
struct SessionMediaThumb: View {
    let item: SessionMedia
    var side: CGFloat = 88
    @State private var image: UIImage?

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
