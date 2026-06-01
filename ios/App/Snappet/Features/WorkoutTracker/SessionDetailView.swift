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

            SessionMediaSection(session: session, sport: sport, category: dominantCategory)

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
        .animation(snappetAnimation(SnappetMotion.expressive, reduceMotion: reduceMotion), value: drawn)
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
                .animation(snappetAnimation(SnappetMotion.standard, reduceMotion: reduceMotion), value: drawn)
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

// MARK: - Tagged-media gallery (B1)

/// The "Media from this workout" section: a thumbnail grid ordered by `offsetSec`, an
/// "Add photos/videos" PHPicker, a "Find media from this workout" auto-discovery action,
/// and swipe-to-remove. Photos access is requested value-first (on first appear / on tap),
/// reusing `SessionMediaService` (→ `PhotoLibraryService.requestAccess`).
///
/// `.limited` access can't be scanned by time window, so auto-discovery is hidden and only
/// the PHPicker is offered (the suite-wide limited-access fallback). The simulator has no
/// Photos, so this renders its empty / "add media" state there.
private struct SessionMediaSection: View {
    let session: WorkoutSession
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
    @State private var didAutoDiscover = false
    @State private var message: String?
    /// The video clip being edited in the B3 clip-editor sheet (videos only — photos aren't
    /// editable in the clip editor). `item:` sheet so the editor owns its own `NavigationStack`.
    @State private var editingClip: SessionMedia?
    /// Presents the B4 highlight-generation sheet (clip selection → generate → preview).
    @State private var showingHighlight = false

    init(session: WorkoutSession, sport: SportTag?, category: ExerciseCategory?) {
        self.session = session
        self.sport = sport
        self.category = category
        let sid = session.id
        _media = Query(filter: #Predicate<SessionMedia> { $0.sessionID == sid },
                       sort: \SessionMedia.offsetSec, order: .forward)
    }

    /// "Generate highlight" is enabled only when the session has at least one tagged **video**
    /// (the reel stitch is video-first; a photo-only session has nothing to cut). On the
    /// simulator there's no media, so this stays disabled and the action can't run — keeping
    /// `WorkoutWalkthroughTests` green (decisions.md 2026-06-01, B4).
    private var hasVideo: Bool { media.contains { $0.kind == .video } }

    private let columns = [GridItem(.adaptive(minimum: 88), spacing: 8)]

    var body: some View {
        Section {
            if media.isEmpty {
                ContentUnavailableView {
                    Label("No media yet", systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text("Add photos and videos you took during this workout, or find them automatically.")
                }
                .frame(maxWidth: .infinity)
            } else {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(media) { item in
                        SessionMediaThumb(item: item)
                            .onTapGesture {
                                // A tagged video opens the B3 clip editor; photos aren't editable there.
                                if item.kind == .video { editingClip = item }
                            }
                            .contextMenu {
                                if item.kind == .video {
                                    Button { editingClip = item } label: {
                                        Label("Edit clip", systemImage: "slider.horizontal.3")
                                    }
                                }
                                Button(role: .destructive) { remove(item) } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                    }
                }
                .padding(.vertical, 4)
                // Newly discovered / added thumbnails settle in gently (gated by Reduce Motion).
                .snappetAnimation(SnappetMotion.standard, value: media.count)
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
            // Auto-discover once when the detail first appears, but only silently — never
            // prompt unless the user already granted full access (value-first).
            guard !didAutoDiscover else { return }
            didAutoDiscover = true
            if app.sessionMedia.canAutoDiscover { await autoDiscover(prompt: false) }
        }
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
