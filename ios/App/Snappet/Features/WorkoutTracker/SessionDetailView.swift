import SwiftUI
import SwiftData
import Photos
import HighlightEngine

/// Detail for a completed session: summary stats, the **live HR chart + band stats** (B2 —
/// avg/max HR + time-in-zone, only when the session has a persisted `hrSeries`), and a unified
/// **per-set** breakdown — each set is one tile showing its reps/weight, the heart rate at that set,
/// and the photos/videos tagged to it (multiple media → multiple rows under the tile). Media is
/// auto-discovered by capture-time window and/or added by hand; a **General** bucket holds anything
/// not tied to a set. An **Edit sets** mode (issue #73) turns the completed reps/weight tiles into
/// text fields so a fat-fingered entry can be corrected after the fact — Save rewrites
/// `SessionExercise.sets` in place (via the pure `SessionSetEditing`), so PRs / volume / progress
/// recompute from the corrected values.
///
/// Tapping a video clip opens the CapCut-style multi-clip Studio **scoped to that one clip** (Kilter
/// parity), and the "Edit in Video Studio" button opens it session-wide — both via `StudioPresentation`.
private struct StudioPresentation: Identifiable {
    let id = UUID()
    let project: StudioProject
    /// `nil` = whole session; `[clip.id]` = one clip (filters the timeline by `TimelineClip.sessionMediaID`).
    let visibleClipMediaIDs: Set<UUID>?
    /// Pre-selects the tapped clip on open. Mirrors the Kilter side's `ClipStudioPresentation`.
    let focusClipMediaID: UUID?
}

struct SessionDetailView: View {
    let session: WorkoutSession
    let resolver: ExerciseResolver
    let unit: WeightUnit
    /// The routine's sport, used by B4 highlight generation's activity mapping (`nil` if the
    /// routine was deleted — the bridge then falls back to the dominant exercise category).
    var sport: SportTag? = nil
    /// Prior completed sessions (used by the type-adaptive recap's PR detection, E2). Empty ⇒ no PR card.
    var history: [WorkoutSession] = []

    /// Dominant exercise category across the session (B4 activity-mapping fallback when there's
    /// no sport). Resolved from the session's exercises via the `resolver`.
    private var dominantCategory: ExerciseCategory? {
        let cats = session.exercises.compactMap { resolver.exercise(id: $0.exerciseId)?.category }
        return WorkoutActivityMapping.dominantCategory(of: cats)
    }

    /// A clip the user asked to remove — drives the destructive confirmation (hosted on the List).
    @State private var pendingRemoval: SessionMedia?
    /// The multi-clip Studio presentation, hosted HERE on the `List` (a stable host) so the cover
    /// survives the media section's `Group` re-renders. `nil` = closed; the section requests it
    /// (session-wide from the button, or scoped to a clip on tap) via the `onOpenStudio` closure.
    @State private var studio: StudioPresentation?
    /// Edit-sets mode (issue #73; all-axis follow-up): while on, each completed set tile shows
    /// discipline-adaptive text fields editing `drafts`; Save parses them back into the session, Cancel discards.
    @State private var editingSets = false
    @State private var setDrafts: [SessionSetEditing.Key: SessionSetEditing.Draft] = [:]
    /// One shared focus across all edit fields — the number pad has no return key, so the keypad
    /// Done toolbar is the only way to dismiss it (the live player's pattern).
    @FocusState private var keypadFocused: Bool
    @Environment(\.modelContext) private var context
    private let mediaLibrary = MediaLibraryService()

    // The type-adaptive recap header (E2) — shared with the post-Finish summary via `SessionRecap`.
    private var maxHR: Double { session.maxHR ?? HeartRateZone.defaultMaxHR }
    private var recapStats: FreeformSummary.Stats { FreeformSummary.stats(for: session, unit: unit) }
    private var recapClimbStats: KilterSessionStats {
        FreeformClimbStats.stats(for: session, now: session.completedAt ?? .now,
                                 hrSeries: session.hrSeries.map { HRSample(t: $0.t, bpm: $0.bpm, rrIntervalsMs: $0.rrIntervalsMs) })
    }
    private var recapMilestones: [FreeformSummary.Milestone] {
        FreeformSummary.milestones(for: session, history: history.filter { $0.startedAt < session.startedAt })
    }

    var body: some View {
        List {
            // Apple Watch import (watch-workouts-clips P3): an honest note that this workout was recorded
            // on the watch (no exercises/sets), plus its measured distance/energy — the HR chart + clips
            // sections below carry the rest.
            if session.isFromAppleWatch { watchSourceSection }

            // Type-adaptive recap (E2): the same hero + per-discipline cards the Finish summary shows, so
            // "View detail" is richer — not poorer — than the completion screen. HR is shown by the
            // dedicated Heart-rate section below (showsHR: false here to avoid duplicating it).
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    Text("\(session.startedAt.formatted(.dateTime.weekday().month().day())) · \(max(1, Int(session.duration / 60))) min")
                        .font(.footnote).foregroundStyle(.secondary)
                    SessionRecapHero(cells: SessionRecap.heroCells(stats: recapStats, climbStats: recapClimbStats,
                                                                   session: session, unit: unit, milestones: recapMilestones))
                    SessionRecapCards(session: session, resolver: resolver, unit: unit, maxHR: maxHR,
                                      milestones: recapMilestones, showsHR: false)
                }
                .padding(.vertical, 4)
            }
            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 6, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            if let stats = WorkoutHRStats.make(from: session.hrSeries,
                                               maxHR: session.maxHR ?? HeartRateZone.defaultMaxHR) {
                HeartRateSummarySection(series: session.hrSeries, stats: stats,
                                        sourceRaw: session.metricsSourceRaw, kcal: session.kcalEstimate)
            }

            // Unified media + per-set breakdown (the actions header, one section per exercise with
            // per-set tiles + their media, and a General bucket).
            SessionMediaSection(session: session, resolver: resolver, unit: unit,
                                sport: sport, category: dominantCategory,
                                setDrafts: $setDrafts, keypadFocus: $keypadFocused,
                                onRemove: { pendingRemoval = $0 },
                                onOpenStudio: { studio = $0 })
        }
        .navigationTitle("Session")
        .navigationBarTitleDisplayMode(.inline)
        .keypadDoneToolbar($keypadFocused)
        .toolbar {
            // Edit any completed set in place (issue #73; all-axis follow-up — strength reps/weight,
            // timed duration, run distance+duration, climb grade/status/attempts). Hidden only when the
            // session has no completed set to edit.
            if editingSets {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { cancelSetEdits() }
                        .accessibilityIdentifier("session.cancelEditSets")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { saveSetEdits() }
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("session.saveSets")
                }
            } else if !SessionSetEditing.drafts(for: session.exercises, unit: unit).isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { beginSetEdits() }
                        .accessibilityIdentifier("session.editSets")
                }
            }
        }
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
        // The CapCut-style multi-clip Studio, hosted on the List (a stable host) so a clip-tap open
        // from the media section's flattened Group can't collapse it. Scoped to one clip on tap,
        // unscoped from the "Edit in Video Studio" button — both via `studio`.
        .fullScreenCover(item: $studio) { p in
            StudioEditorView(project: p.project, context: context,
                             focusClipMediaID: p.focusClipMediaID,
                             visibleClipMediaIDs: p.visibleClipMediaIDs)
        }
    }

    // MARK: Apple Watch source note (watch-workouts-clips P3)

    private var watchSourceSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "applewatch").foregroundStyle(SnappetColor.perfFresh)
                    Text("Recorded on Apple Watch").font(.subheadline.weight(.semibold))
                }
                Text("This workout was recorded on your Apple Watch, so it has no exercises or sets — just its heart rate and the clips you filmed.")
                    .font(.caption).foregroundStyle(.secondary)
                if !watchStatChips.isEmpty {
                    HStack(spacing: 10) {
                        ForEach(watchStatChips, id: \.self) { chip in
                            Text(chip)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(SnappetColor.perfFresh.opacity(0.12), in: Capsule())
                                .foregroundStyle(SnappetColor.perfFresh)
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// Measured HealthKit stats as compact chips: distance (run) + energy, when the workout recorded them.
    private var watchStatChips: [String] {
        var out: [String] = []
        if let m = session.hkDistanceMeters, m > 0 {
            out.append(m >= 1000 ? String(format: "%.1f km", m / 1000) : "\(Int(m.rounded())) m")
        }
        if let kcal = session.hkEnergyKcal, kcal > 0 { out.append("\(Int(kcal.rounded())) kcal") }
        return out
    }

    // MARK: Edit sets (issue #73)

    private func beginSetEdits() {
        setDrafts = SessionSetEditing.drafts(for: session.exercises, unit: unit)
        editingSets = true
    }

    private func cancelSetEdits() {
        editingSets = false
        setDrafts = [:]
        keypadFocused = false
    }

    /// Parse the drafts back into the session (the player's input rules) and persist. The model is
    /// `@Observable`, so the tiles, header stats, and every history-derived stat re-render from the
    /// corrected values.
    private func saveSetEdits() {
        session.exercises = SessionSetEditing.apply(drafts: setDrafts, to: session.exercises, unit: unit)
        try? context.save()
        cancelSetEdits()
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
    /// `MetricsSourceKind.rawValue` of the HR transport, for the "via …" source label; `nil` hides it.
    var sourceRaw: String? = nil
    /// HR-based calorie estimate (BLE-only, Phase 2); `nil` hides the calories tile (watch sessions
    /// — where energy is measured, not estimated — and incomplete-profile sessions).
    var kcal: Double? = nil

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
                HStack(spacing: 24) {
                    redlineStat(stats)
                    strainStat(stats)
                    if let kcal { calorieStat(kcal) }
                }
                .frame(maxWidth: .infinity)
            }
        } header: {
            HStack(spacing: 6) {
                Text("Heart rate")
                HRMetricsInfoButton()   // explains the HRV / recovery-dot colour codes (#78)
                if let kind = sourceRaw.flatMap(MetricsSourceKind.init(rawValue:)) {
                    Spacer()
                    Text("via \(kind.title)").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Estimated calories tile: the HR-based (Keytel) energy estimate that fills a BLE band's
    /// `energy = 0`. Labelled "est." so it never reads as a measured figure (decisions.md 2026-06-08).
    private func calorieStat(_ kcal: Double) -> some View {
        VStack(spacing: 2) {
            Text("\(Int(kcal.rounded()))")
                .font(.title3.monospacedDigit().weight(.semibold))
            Text("kcal est.").font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("hrCalorieStat")
    }

    private func hrStat(_ label: String, bpm: Double) -> some View {
        VStack(spacing: 2) {
            Text("\(Int(bpm.rounded()))")
                .font(.title3.monospacedDigit().weight(.semibold))
                .contentTransition(.numericText())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Redline tile: minutes in the two hard zones (Z4+Z5) + that as a % of the session.
    private func redlineStat(_ stats: WorkoutHRStats) -> some View {
        VStack(spacing: 2) {
            Text(ZoneBar.minutesLabel(stats.redlineSeconds))
                .font(.title3.monospacedDigit().weight(.semibold))
            Text("Redline · \(Int((stats.redlineFraction * 100).rounded()))%")
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("hrRedlineStat")
    }

    /// Strain tile: Edwards' zone-weighted training load (a within-user session-strain figure).
    private func strainStat(_ stats: WorkoutHRStats) -> some View {
        VStack(spacing: 2) {
            Text("\(Int(stats.edwardsTRIMP.rounded()))")
                .font(.title3.monospacedDigit().weight(.semibold))
            Text("Strain").font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("hrStrainStat")
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
    /// Edit-sets drafts owned by the parent (issue #73): non-empty only while edit mode is on, so a
    /// tile renders edit fields exactly when a draft exists for its (exercise, set index) key.
    @Binding var setDrafts: [SessionSetEditing.Key: SessionSetEditing.Draft]
    /// The parent's shared keypad focus, so its Done toolbar dismisses any edit field.
    var keypadFocus: FocusState<Bool>.Binding
    /// Ask the parent to confirm + perform removal (tag-only or delete-from-Photos).
    let onRemove: (SessionMedia) -> Void
    /// Ask the parent to present the multi-clip Studio. The cover is hosted on the parent `List` (a
    /// stable host) rather than here, because this section's `Group` flattens into the `List` and gets
    /// torn down on re-render — a presentation hosted on it collapses on the first open (decisions.md:
    /// present from a stable host, not a flattened Group). This is the same reason the old per-clip
    /// editor sheet was hosted on the parent.
    let onOpenStudio: (StudioPresentation) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL

    @Query private var media: [SessionMedia]

    @State private var isDiscovering = false
    @State private var didAppear = false
    @State private var message: String?
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
         setDrafts: Binding<[SessionSetEditing.Key: SessionSetEditing.Draft]>,
         keypadFocus: FocusState<Bool>.Binding,
         onRemove: @escaping (SessionMedia) -> Void,
         onOpenStudio: @escaping (StudioPresentation) -> Void) {
        self.session = session
        self.resolver = resolver
        self.unit = unit
        self.sport = sport
        self.category = category
        self._setDrafts = setDrafts
        self.keypadFocus = keypadFocus
        self.onRemove = onRemove
        self.onOpenStudio = onOpenStudio
        let sid = session.id
        _media = Query(filter: #Predicate<SessionMedia> { $0.sessionID == sid },
                       sort: \SessionMedia.offsetSec, order: .forward)
    }

    private var hasVideo: Bool { media.contains { $0.kind == .video } }

    var body: some View {
        // Per-set effort/recovery over the session HR series (empty map when there's no HR), computed
        // once and looked up per row — the WorkoutTracker twin of the Kilter per-climb effort.
        let hrSamples = session.hrSeries.map { HRSample(t: $0.t, bpm: $0.bpm, rrIntervalsMs: $0.rrIntervalsMs) }
        let efforts = WorkoutHRStats.setEfforts(
            for: session.exercises, sessionStart: session.startedAt,
            hr: hrSamples, maxHR: session.maxHR, restHR: session.restHR)
        // Per-set rest HRV (Phase 3): the recovery-quality signal between sets; empty without trusted RR.
        let restHRV = WorkoutHRStats.setRestHRV(
            for: session.exercises, sessionStart: session.startedAt, hr: hrSamples)
        Group {
            actionsSection
            ForEach(session.exercises) { ex in
                Section {
                    if ex.skipped {
                        Text("Skipped").foregroundStyle(.secondary).italic()
                        // Sets completed before the skip still count in volume/PRs (WorkoutMath
                        // ignores `skipped`), so they must stay visible — and editable — here.
                        ForEach(Array(ex.sets.enumerated()).filter { $0.element.completedAt != nil },
                                id: \.offset) { i, set in
                            SetTileRow(index: i + 1, set: set, kind: ex.kind,
                                       discipline: ex.discipline, unit: unit,
                                       distanceUnit: unit == .lb ? .mi : .km,
                                       bpm: bpm(forSetCompletedAt: set.completedAt),
                                       effort: efforts[.init(exerciseID: ex.id, setIndex: i)] ?? .empty,
                                       restHRV: restHRV[.init(exerciseID: ex.id, setIndex: i)] ?? .empty,
                                       maxHR: session.maxHR ?? HeartRateZone.defaultMaxHR,
                                       editDraft: draftBinding(exerciseID: ex.id, setIndex: i),
                                       keypadFocus: keypadFocus)
                        }
                    } else {
                        ForEach(Array(ex.sets.enumerated()), id: \.offset) { i, set in
                            SetTileRow(index: i + 1, set: set, kind: ex.kind,
                                       discipline: ex.discipline, unit: unit,
                                       distanceUnit: unit == .lb ? .mi : .km,
                                       bpm: bpm(forSetCompletedAt: set.completedAt),
                                       effort: efforts[.init(exerciseID: ex.id, setIndex: i)] ?? .empty,
                                       restHRV: restHRV[.init(exerciseID: ex.id, setIndex: i)] ?? .empty,
                                       maxHR: session.maxHR ?? HeartRateZone.defaultMaxHR,
                                       editDraft: draftBinding(exerciseID: ex.id, setIndex: i),
                                       keypadFocus: keypadFocus)
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
                // Highlights convergence (P3): the gym path now feeds the SAME shared reel maker
                // the Kilter session and the weekly cut use — one builder, one export pipeline
                // (format presets, burned HR overlay, Post to Clips). The bespoke
                // `SessionHighlightView`/-`ViewModel` pair is deleted. Peak-effort boosts and the
                // manual-pick override live inside `ReelSource.workoutSession`.
                NavigationStack {
                    ReelView(source: .workoutSession(session, media: media,
                                                     sport: sport, category: category))
                }
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
                Label("Make a Highlight Reel", systemImage: "sparkles.tv")
            }
            .disabled(!hasVideo)
            .accessibilityIdentifier("generateHighlight")

            // Named for what it is (#74): "Open studio (multi-clip)" undersold the CapCut-style
            // editor. Still disabled until the session has video — there is nothing to cut.
            Button { openStudio() } label: {
                Label("Edit in Video Studio", systemImage: "film.stack")
            }
            .disabled(!hasVideo)
            .accessibilityIdentifier("openStudio")
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
        .onTapGesture { editClip(item) }
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
            Button { editClip(item) } label: { Label("Edit in studio", systemImage: "slider.horizontal.3") }
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

    // MARK: Edit drafts (issue #73)

    /// A binding into the parent's draft dictionary for one set — nil (read-only tile) when edit
    /// mode is off or the set isn't editable (never completed). All-axis: drafts exist for completed
    /// sets of every discipline, not just reps/weight.
    private func draftBinding(exerciseID: UUID, setIndex: Int) -> Binding<SessionSetEditing.Draft>? {
        let key = SessionSetEditing.Key(exerciseID: exerciseID, setIndex: setIndex)
        guard setDrafts[key] != nil else { return nil }
        return Binding(get: { setDrafts[key] ?? SessionSetEditing.Draft() },
                       set: { setDrafts[key] = $0 })
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

    /// Identifiers already tagged to THIS session — the dedup set for a MANUAL pick (the user may legitimately
    /// add the same asset to two different sessions by hand, so manual stays session-scoped).
    private var existingIdentifiers: Set<String> { Set(media.map(\.localIdentifier)) }

    /// Identifiers tagged to ANY session — the dedup set for AUTO-discovery, so a clip in the ±90s pad
    /// overlap of two adjacent sessions is auto-tagged into one session, not both (R2/R4: one physical
    /// video → one set). Identifier-only fetch via the shared helper (prompt 114).
    private var allMediaIdentifiers: Set<String> { SessionMedia.allIdentifiers(in: context) }

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
                existingIdentifiers: allMediaIdentifiers)
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

    /// Open the multi-clip Studio for the whole session (the "Edit in Video Studio" button). Shares
    /// the session's one `StudioProject` with the per-clip tap and the module-level entries (#74).
    private func openStudio() {
        onOpenStudio(StudioPresentation(
            project: StudioEntry.resolveProject(for: session, media: media, context: context),
            visibleClipMediaIDs: nil, focusClipMediaID: nil))
    }

    /// Tap a video clip → open the SAME Studio **scoped to just that clip** (big preview, focused on
    /// it), the CapCut-style editor the Kilter side already uses — replacing the old single-clip
    /// "Edit Clip" sheet. Videos only; photos aren't clip-editable.
    private func editClip(_ item: SessionMedia) {
        guard item.kind == .video else { return }
        onOpenStudio(StudioPresentation(
            project: StudioEntry.resolveProject(for: session, media: media, context: context),
            visibleClipMediaIDs: [item.id], focusClipMediaID: item.id))
    }
}

// MARK: - Set tile (reps/weight + the HR at that set)

/// One set's tile: the set number, its reps/weight, and the heart rate at the set's completion
/// (zone-coloured). Its tagged media render as separate rows beneath it (so each is swipe-removable).
private struct SetTileRow: View {
    let index: Int
    let set: SetLog
    /// The owning exercise's authoritative measure kind (from `SessionExercise.kind`), so a climb/
    /// timed/reps-weight set renders the way the freeform player wrote it — no field-sniffing.
    let kind: SetKind
    /// The owning exercise's discipline (Workout-Type Parity) — a `.run` leg renders distance · time · pace.
    var discipline: WorkoutDiscipline = .strength
    let unit: WeightUnit
    /// Distance unit for a running leg's pace/distance rendering.
    var distanceUnit: DistanceUnit = .km
    let bpm: Double?
    /// Per-set HR effort/recovery (peak, %HRR-or-bpm, recovery) over the set's window; `.empty` for
    /// HR-less sessions or sets with no completion → the effort row is hidden.
    var effort: ClimbEffort = .empty
    /// Per-set rest HRV over the recovery gap before this set (Phase 3); `.empty` hides the HRV badge.
    var restHRV: HRVMetrics = .empty
    /// The session's resolved max HR for the zone tints; defaults to the no-profile fallback (Phase 2).
    var maxHR: Double = HeartRateZone.defaultMaxHR
    /// Editable reps/weight draft while the summary's edit mode is on (issue #73); nil renders the
    /// read-only tile. Paired with the host's shared keypad focus for the Done toolbar.
    var editDraft: Binding<SessionSetEditing.Draft>? = nil
    var keypadFocus: FocusState<Bool>.Binding? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text("Set \(index)").font(.subheadline.weight(.medium))
                Spacer()
                if let editDraft, let keypadFocus {
                    SetEditFields(draft: editDraft, discipline: discipline, kind: kind,
                                  unit: unit, distanceUnit: distanceUnit, focus: keypadFocus)
                } else if set.completedAt != nil {
                    Text(detailText).font(.subheadline.monospacedDigit())
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
                if let bpm {
                    let zone = HeartRateZone.forBpm(bpm, maxHR: maxHR)
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
            // Peak effort + recovery for the set, plus rest HRV (shared with the Kilter per-climb row).
            HStack(spacing: 10) {
                HREffortBadge(effort: effort, maxHR: maxHR)
                    .accessibilityIdentifier("setEffort")
                HRVBadge(hrv: restHRV)
            }
        }
    }

    /// The one funnel for the per-set display string (workout-redesign E2): discipline-aware +
    /// unit-converting. Moved into the pure, unit-tested `SetMeasure.displaySummary` so the per-set
    /// grammar has exactly one source (it preserves the kg→display-unit conversion + the timed-strength
    /// "· 0:42" append + the running distance·time·pace row exactly as before).
    private var detailText: String {
        SetMeasure.displaySummary(set, discipline: discipline, kind: kind, unit: unit, distanceUnit: distanceUnit)
    }
}

/// The editable fields a completed set tile swaps to in edit mode. All-axis (workout-redesign follow-up):
/// the field set adapts to the owning exercise's discipline/kind — strength shows reps × weight (the
/// original, unchanged), a timed hold shows a duration field, a run leg shows distance + duration, and a
/// climb shows grade + status + attempts. The text mirrors the player's inputs and is parsed with the same
/// `SetMeasure` rules on Save; weight/distance show — and save — in the preferred display unit (WYSIWYG).
private struct SetEditFields: View {
    @Binding var draft: SessionSetEditing.Draft
    let discipline: WorkoutDiscipline
    let kind: SetKind
    let unit: WeightUnit
    let distanceUnit: DistanceUnit
    var focus: FocusState<Bool>.Binding

    var body: some View {
        Group {
            if discipline == .run {
                runFields
            } else {
                switch kind {
                case .repsWeight:   repsWeightFields
                case .duration:     durationField
                case .climbAttempt: climbFields
                }
            }
        }
        .textFieldStyle(.roundedBorder)
        .font(.subheadline.monospacedDigit())
    }

    private var repsWeightFields: some View {
        HStack(spacing: 6) {
            TextField("Reps", text: $draft.reps)
                .keyboardType(.numberPad).multilineTextAlignment(.center).frame(width: 56)
                .focused(focus).accessibilityIdentifier("session.editReps")
            Text("×").foregroundStyle(.secondary)
            TextField("Weight", text: $draft.weight)
                .keyboardType(.decimalPad).multilineTextAlignment(.center).frame(width: 72)
                .focused(focus).accessibilityIdentifier("session.editWeight")
            Text(unit.display).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var durationField: some View {
        HStack(spacing: 6) {
            TextField("M:SS", text: $draft.duration)
                .keyboardType(.numbersAndPunctuation).multilineTextAlignment(.center).frame(width: 80)
                .focused(focus).accessibilityIdentifier("session.editDuration")
            Image(systemName: "timer").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var runFields: some View {
        HStack(spacing: 6) {
            TextField("Dist", text: $draft.distance)
                .keyboardType(.decimalPad).multilineTextAlignment(.center).frame(width: 60)
                .focused(focus).accessibilityIdentifier("session.editDistance")
            Text(distanceUnit.display).font(.caption).foregroundStyle(.secondary)
            TextField("M:SS", text: $draft.duration)
                .keyboardType(.numbersAndPunctuation).multilineTextAlignment(.center).frame(width: 72)
                .focused(focus).accessibilityIdentifier("session.editDuration")
        }
    }

    private var climbFields: some View {
        HStack(spacing: 6) {
            TextField("Grade", text: $draft.grade)
                .multilineTextAlignment(.center).frame(width: 64)
                .focused(focus).accessibilityIdentifier("session.editGrade")
            Menu {
                ForEach(KilterAscentStatus.allCases, id: \.self) { status in
                    Button(status.label) { draft.statusRaw = status.rawValue }
                }
            } label: {
                Text(draft.statusRaw.flatMap(KilterAscentStatus.init(rawValue:))?.label ?? "Status")
                    .font(.caption.weight(.semibold))
            }
            .accessibilityIdentifier("session.editStatus")
            TextField("×", text: $draft.attempts)
                .keyboardType(.numberPad).multilineTextAlignment(.center).frame(width: 40)
                .focused(focus).accessibilityIdentifier("session.editAttempts")
        }
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
