import SwiftUI
import SwiftData

/// Set detail — "climb detail for music" (wireframe frame 6). Everything comes from the linked
/// dance `WorkoutSession`(s): the hero stats and HR curve are `HRWindowSlicer` slices of the
/// session series under the SET's window (via the pure `FestivalSetStats`), the clips row is the
/// set's tag rows, and the reel CTA feeds the shared `ReelView` with a `festivalSet` source.
/// Pushed from a schedule row; NO stack of its own.
struct FestivalSetDetailView: View {
    let lineup: FestivalLineup
    /// The pack/set as pushed; `pack`/`set` below follow lineup edits made from this page.
    let initialPack: FestivalPack
    let initialSet: FestivalSet

    @Environment(\.modelContext) private var context
    @Environment(AppModel.self) private var app
    @Environment(SnappetCore.self) private var core

    @State private var edited: FestivalPack?
    @State private var showingEditTime = false
    /// The open claim anywhere in this festival — "I'm here" reads "You're here" when it's this set.
    @Query private var openClaims: [FestivalAttendance]

    private var pack: FestivalPack { edited ?? initialPack }
    private var set: FestivalSet { pack.setsByID[initialSet.id] ?? initialSet }

    @Query private var attendance: [FestivalAttendance]
    @Query private var tags: [FestivalClipTag]

    @State private var sessions: [FestivalSessionSnapshot] = []
    /// The set's tagged clips joined to their `SessionMedia` rows, capture order.
    @State private var clipRows: [ClipRow] = []
    @State private var showingReview = false
    @State private var viewer: ViewerState?

    struct ClipRow: Identifiable {
        var mediaID: UUID
        var sessionID: UUID
        var localIdentifier: String
        var isVideo: Bool
        var offsetSec: Double
        var durationSec: Double?
        var aspect: Double?
        var isAuto: Bool
        /// The row's bake flag and time map (prompt 305), so the viewer stands down on a baked
        /// clip and heart rate is read where the frames were filmed.
        var isBaked: Bool = false
        var timeMap: BakedTimeMap? = nil
        /// The clip's Studio edit (prompt 309), so the viewer reads it as the Clips feed does.
        var edit: ClipStudioEdit? = nil
        var id: UUID { mediaID }

        init(mediaID: UUID, sessionID: UUID, localIdentifier: String, isVideo: Bool,
             offsetSec: Double, durationSec: Double?, aspect: Double?, isAuto: Bool,
             isBaked: Bool = false, timeMap: BakedTimeMap? = nil, edit: ClipStudioEdit? = nil) {
            self.edit = edit
            self.mediaID = mediaID; self.sessionID = sessionID
            self.localIdentifier = localIdentifier; self.isVideo = isVideo
            self.offsetSec = offsetSec; self.durationSec = durationSec
            self.aspect = aspect; self.isAuto = isAuto
            self.isBaked = isBaked; self.timeMap = timeMap
        }

        /// One tagged media row as this screen lists it.
        @MainActor init(_ media: SessionMedia, isAuto: Bool, edit: ClipStudioEdit? = nil) {
            self.init(mediaID: media.id, sessionID: media.sessionID,
                      localIdentifier: media.localIdentifier, isVideo: media.kind == .video,
                      offsetSec: media.offsetSec, durationSec: media.durationSec,
                      aspect: media.aspectRatio, isAuto: isAuto,
                      isBaked: media.isBaked, timeMap: media.bakeTimeMap,
                      edit: (media.isBaked || media.isReel) ? nil : edit)
        }

        var captureClock: ClipCaptureClock { ClipCaptureClock(offsetSec: offsetSec, timeMap: timeMap) }

        /// The fullscreen viewer's value: the same fields `MediaInput.from` carries.
        var mediaInput: MediaInput {
            MediaInput(id: mediaID, kind: isVideo ? "video" : "photo",
                       offsetSec: offsetSec, durationSec: durationSec,
                       exerciseId: nil, setIndex: nil, climbUUID: nil,
                       localIdentifier: localIdentifier, aspect: aspect, edit: edit,
                       isBaked: isBaked, timeMap: timeMap)
        }

        /// The reel maker's clip: it starts when the first frame of the current video was filmed.
        var reelClip: SessionHighlightInput.Clip {
            SessionHighlightInput.Clip(localIdentifier: localIdentifier, isVideo: isVideo,
                                       offsetSec: captureClock.captureStartSec, durationSec: durationSec,
                                       timeMap: timeMap)
        }
    }

    struct ViewerState: Identifiable {
        var clips: [MediaInput]
        var startIndex: Int
        var series: [HRPoint]
        var maxHR: Double
        var restHR: Double?
        var id: Int { startIndex }
    }

    init(lineup: FestivalLineup, pack: FestivalPack, set: FestivalSet) {
        self.lineup = lineup
        self.initialPack = pack
        self.initialSet = set
        let packID = lineup.packID
        _openClaims = Query(filter: #Predicate<FestivalAttendance> {
            $0.packID == packID && $0.endedAt == nil
        })
        let setID = set.id
        _attendance = Query(filter: #Predicate<FestivalAttendance> {
            $0.packID == packID && $0.setID == setID
        })
        _tags = Query(filter: #Predicate<FestivalClipTag> {
            $0.packID == packID && $0.setID == setID
        })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                nightActions
                statsRow
                hrCard
                clipsSection
                reelCTA
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
        .navigationTitle("Set")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onChange(of: lineup.editsData) { _, _ in edited = lineup.pack() }
        .sheet(isPresented: $showingEditTime) {
            FestivalEditTimeSheet(lineup: lineup, setID: set.id)
        }
        .onChange(of: tags.count) { _, _ in Task { await load(refreshTags: false) } }
        .sheet(isPresented: $showingReview) {
            FestivalTagReviewView(lineup: lineup, pack: pack,
                                  initialDay: pack.day(containing: set.start)?.date)
                .presentationDetents([.large])
        }
        .navigationDestination(for: FestivalSetReelRoute.self) { _ in
            if let source = reelSource() {
                ReelView(source: source)
            } else {
                ContentUnavailableView("No clips to cut yet", systemImage: "sparkles.tv",
                                       description: Text("Tag a video to this set first."))
            }
        }
        .fullScreenCover(item: $viewer) { v in
            MediaBrowserView.clipsViewer(clips: v.clips, startIndex: v.startIndex,
                                         hrSeries: v.series, maxHR: v.maxHR, restHR: v.restHR,
                                         nameFor: { _ in "\(set.artist) · \(set.stage)" }, tile: nil)
        }
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(set.artist)
                .font(.title.weight(.semibold))
                .accessibilityIdentifier("festival.set.artist")
            Text("\(set.stage) · "
                 + "\(FestivalSchedule.timeLabel(set.start, offsetSeconds: pack.utcOffsetSeconds))–"
                 + "\(FestivalSchedule.timeLabel(set.end, offsetSeconds: pack.utcOffsetSeconds))"
                 + " · \(lineup.name)")
                .font(.subheadline)
                .foregroundStyle(SnappetColor.textSecondary)
            if let original = lineup.originalPack(),
               let was = lineup.edits.originalTimes(of: set.id, in: original) {
                Text("Edited (was \(FestivalSchedule.timeLabel(was.start, offsetSeconds: pack.utcOffsetSeconds))"
                     + "–\(FestivalSchedule.timeLabel(was.end, offsetSeconds: pack.utcOffsetSeconds)))")
                    .font(.caption)
                    .foregroundStyle(SnappetColor.brand)
                    .accessibilityIdentifier("festival.set.edited")
            }
        }
    }

    /// "I'm here" for THIS set — works whatever the printed clock says (a late start is exactly
    /// when you need it) — and "Edit time" for when the stage runs late (prompt 232).
    private var nightActions: some View {
        let here = openClaims.contains { $0.setID == set.id }
        return HStack(spacing: 8) {
            Button {
                FestivalNightController(lineup: lineup, pack: pack, context: context, app: app, core: core)
                    .claim(set)
            } label: {
                Label(here ? "You're here" : "I'm here",
                      systemImage: here ? "checkmark" : "smallcircle.filled.circle")
            }
            .buttonStyle(SnappetWidePrimaryStyle())
            .disabled(here)
            .accessibilityIdentifier("festival.set.imHere")
            Button {
                showingEditTime = true
            } label: {
                Label("Edit time", systemImage: "clock")
                    .font(.system(size: 15))
                    .foregroundStyle(SnappetColor.ink)
                    .padding(.vertical, 11)
                    .frame(maxWidth: .infinity)
                    .pagerOutline()
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("festival.set.editTime")
        }
    }

    private var statsRow: some View {
        let danced = FestivalSetStats.dancedSeconds(for: set.id, attendance: attendanceSnapshots)
        let slice = hrSlice
        let peak = FestivalSetStats.peak(of: slice)
        let avg = FestivalSetStats.average(of: slice)
        return HStack(spacing: 0) {
            stat(danced > 0 ? FestivalSetStats.dancedLabel(danced) : "—", "Danced")
            stat(peak.map { "\(Int($0.bpm.rounded()))" } ?? "—", "Peak HR",
                 tint: SnappetColor.perfHard)
            stat(avg.map { "\(Int($0.rounded()))" } ?? "—", "Avg HR")
            stat("\(resolvedTags.count)", "Clips")
        }
        .padding(.vertical, 12)
        .snappetPanel()
        .accessibilityIdentifier("festival.set.stats")
    }

    private func stat(_ value: String, _ label: String, tint: Color = SnappetColor.ink) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 22, weight: .light).monospacedDigit()).foregroundStyle(tint)
            Text(label).font(.caption2).foregroundStyle(SnappetColor.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    /// The set's HR curve with the peak-at-the-drop callout (frame 6) — the shared chart over the
    /// windowed slice, honest-empty when nothing was recorded under this set.
    @ViewBuilder private var hrCard: some View {
        let slice = hrSlice
        if slice.count >= 2 {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Your heart rate")
                        .snappetLabel()
                    Spacer()
                    if let callout = peakCallout {
                        Text(callout)
                            .font(.caption2)
                            .foregroundStyle(SnappetColor.perfHard)
                            .accessibilityIdentifier("festival.set.peak")
                    }
                }
                HeartRateChart(series: slice)
                    .frame(height: 120)
                    .accessibilityIdentifier("festival.set.hrChart")
            }
            .padding(12)
            .snappetPanel()
        }
    }

    @ViewBuilder private var clipsSection: some View {
        HStack {
            Text("Clips from this set")
                .snappetLabel()
            Spacer()
            Button("Review tags ›") { showingReview = true }
                .font(.caption.weight(.medium))
                .tint(SnappetColor.brand)
                .accessibilityIdentifier("festival.set.reviewTags")
        }
        if clipRows.isEmpty {
            Text("Nothing tagged here yet — anything filmed during this set tags itself.")
                .font(.caption)
                .foregroundStyle(SnappetColor.textSecondary)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(clipRows.enumerated()), id: \.element.id) { index, row in
                        Button {
                            openViewer(at: index)
                        } label: {
                            clipCell(row)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .accessibilityIdentifier("festival.set.clips")
        }
    }

    private func clipCell(_ row: ClipRow) -> some View {
        ZStack(alignment: .topLeading) {
            FestivalClipThumb(localIdentifier: row.localIdentifier, isVideo: row.isVideo,
                              posterTime: ClipHROverlay.playedRange(row.mediaInput).start)
                .frame(width: 84, height: 106)
            if row.isAuto {
                Text("✦ Auto")
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(SnappetColor.brand, in: Capsule())
                    .foregroundStyle(SnappetColor.onBrand)
                    .padding(4)
            }
        }
    }

    private var reelCTA: some View {
        NavigationLink(value: FestivalSetReelRoute()) {
            Label("Make a reel of this set", systemImage: "sparkles")
        }
        .buttonStyle(SnappetWidePrimaryStyle())
        .disabled(clipRows.isEmpty)
        .accessibilityIdentifier("festival.set.reel")
    }

    // MARK: - Data (thin edges over the pure stats)

    private var resolvedTags: [FestivalClipTag] { tags.filter(\.isResolved) }

    private var attendanceSnapshots: [FestivalAttendanceSnapshot] {
        attendance.map {
            FestivalAttendanceSnapshot(setID: $0.setID, sessionID: $0.sessionID,
                                       startedAt: $0.startedAt, endedAt: $0.endedAt)
        }
    }

    private var chartSession: FestivalSessionSnapshot? {
        FestivalSetStats.chartSession(for: set, sessions: sessions,
                                      attendance: attendanceSnapshots)
    }

    private var hrSlice: [HRPoint] {
        guard let session = chartSession else { return [] }
        return FestivalSetStats.hrSlice(for: set, session: session)
    }

    private var peakCallout: String? {
        guard let session = chartSession,
              let overlap = session.interval().intersection(with: set.window) else { return nil }
        return FestivalSetStats.peakCallout(slice: hrSlice, sliceStart: overlap.start,
                                            utcOffsetSeconds: pack.utcOffsetSeconds)
    }

    /// Run one tag pass (so the sheet's promise holds even if the user came straight here after a
    /// night), then join this set's tags to their media rows.
    private func load(refreshTags: Bool = true) async {
        if refreshTags {
            await FestivalTagSync.refresh(pack: pack, packID: lineup.packID, context: context,
                                          mediaService: app.sessionMedia)
        }
        // Sessions this set could chart from: the ones attendance/tags reference.
        let ids = Array(Set(attendance.map(\.sessionID)).union(tags.map(\.sessionID)))
        sessions = FestivalTagSync.fetchSessions(ids: ids, context: context).map {
            FestivalSessionSnapshot(id: $0.id, startedAt: $0.startedAt, endedAt: $0.completedAt,
                                    hrSeries: $0.hrSeries, maxHR: $0.maxHR, restHR: $0.restHR)
        }
        let sessionStart = Dictionary(sessions.map { ($0.id, $0.startedAt) },
                                      uniquingKeysWith: { a, _ in a })
        let tagged = resolvedTags.compactMap { tag in
            mediaRow(id: tag.mediaID).map { (media: $0, isAuto: tag.source == .auto) }
        }
        let rows = Self.rows(tagged, context: context)
        clipRows = rows.sorted {
            let a = sessionStart[$0.sessionID] ?? .distantPast
            let b = sessionStart[$1.sessionID] ?? .distantPast
            let at = a.addingTimeInterval($0.offsetSec), bt = b.addingTimeInterval($1.offsetSec)
            return at != bt ? at < bt : $0.mediaID.uuidString < $1.mediaID.uuidString
        }
    }

    /// The screen's clip rows for its tagged media, each with its Studio edit, looked up once
    /// for the screen (prompt 309). What `load` lists, and what the test reads.
    @MainActor
    static func rows(_ tagged: [(media: SessionMedia, isAuto: Bool)], context: ModelContext) -> [ClipRow] {
        let edits = ClipStudioEdit.byMedia(context: context, media: tagged.map(\.media))
        return tagged.map { ClipRow($0.media, isAuto: $0.isAuto, edit: edits[$0.media.id]) }
    }

    private func mediaRow(id: UUID) -> SessionMedia? {
        (try? context.fetch(FetchDescriptor<SessionMedia>(
            predicate: #Predicate { $0.id == id })))?.first
    }

    /// What the viewer is handed for this screen's clips: each row's own `mediaInput`, so the
    /// baked flag and the time map go with it (prompt 305). Pure, and what the test reads.
    static func viewerInputs(_ rows: [ClipRow]) -> [MediaInput] { rows.map(\.mediaInput) }

    /// What the set's reel is made from: the rows of its own session, each as its `reelClip`
    /// (the capture time of its first frame, not the bare offset — prompt 305).
    static func reelClips(_ rows: [ClipRow], sessionID: UUID) -> [SessionHighlightInput.Clip] {
        rows.filter { $0.sessionID == sessionID }.map(\.reelClip)
    }

    private func openViewer(at index: Int) {
        guard let session = chartSession else { return }
        let clips = Self.viewerInputs(clipRows)
        viewer = ViewerState(clips: clips, startIndex: index,
                             series: session.hrSeries,
                             maxHR: session.maxHR ?? 190, restHR: session.restHR)
    }

    /// The shared-ReelView source for this set: the chart session's HR + the set's tagged clips
    /// FROM that session, the set window boosted, posting back as "Artist · Stage".
    private func reelSource() -> ReelSource? {
        guard let session = chartSession else { return nil }
        let clips = Self.reelClips(clipRows, sessionID: session.id)
        guard !clips.isEmpty else { return nil }
        return ReelSource.festivalSet(set, session: session, clips: clips)
    }
}
