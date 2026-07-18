import SwiftUI
import SwiftData

/// Value routes for the festival's programmatic pushes (the `WeeklyReelRoute` pattern) — pushed
/// into whichever `NavigationStack` hosts the schedule (the App Library's).
struct FestivalRecapRoute: Hashable {}
struct FestivalSetReelRoute: Hashable {}
struct FestivalReelRoute: Hashable {}

/// Festival recap (wireframe frame 11): the weekend hero, the ✦ festival-reel CTA, and artists
/// ranked by YOUR heart rate ("who actually made you move"). All numbers come from the pure
/// `FestivalRecap` over plain snapshots of the pack's attendance / tags / dance sessions; the reel
/// CTA hands the whole weekend to the shared `ReelView` (stitched via the Weekly-Highlights
/// machinery). Pushed from the schedule's toolbar; no stack of its own.
struct FestivalRecapView: View {
    let lineup: FestivalLineup
    let pack: FestivalPack

    @Environment(\.modelContext) private var context
    @Environment(AppModel.self) private var app
    @Environment(SuiteRouter.self) private var router

    @Query private var attendance: [FestivalAttendance]
    @Query private var tags: [FestivalClipTag]
    @Query private var stars: [FestivalStar]

    @State private var sessions: [FestivalSessionSnapshot] = []
    @State private var clipsBySession: [UUID: [SessionHighlightInput.Clip]] = [:]
    @State private var showingShare = false

    init(lineup: FestivalLineup, pack: FestivalPack) {
        self.lineup = lineup
        self.pack = pack
        let packID = lineup.packID
        _attendance = Query(filter: #Predicate<FestivalAttendance> { $0.packID == packID })
        _tags = Query(filter: #Predicate<FestivalClipTag> { $0.packID == packID })
        _stars = Query(filter: #Predicate<FestivalStar> { $0.packID == packID })
    }

    private var built: (hero: FestivalRecap.Hero, artists: [FestivalRecap.ArtistRow]) {
        FestivalRecap.build(pack: pack, sessions: sessions,
                            attendance: attendance.map {
                                FestivalAttendanceSnapshot(setID: $0.setID, sessionID: $0.sessionID,
                                                           startedAt: $0.startedAt, endedAt: $0.endedAt)
                            },
                            tags: tags.filter(\.isResolved).map {
                                FestivalTagSnapshot(mediaID: $0.mediaID, setID: $0.setID,
                                                    artist: $0.artist, stage: $0.stage,
                                                    isAuto: $0.source == .auto)
                            })
    }

    var body: some View {
        let (hero, artists) = built
        Group {
            if hero.setsSeen == 0 {
                ContentUnavailableView {
                    Label("No nights on the floor yet", systemImage: "music.mic")
                } description: {
                    Text("Claim a set with \"I'm here\" — your recap builds itself from how you dance.")
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        heroCard(hero)
                        reelCTA
                        artistSection(artists)
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .padding(.bottom, 20)
                }
            }
        }
        .navigationTitle("Recap")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Prompt 05: "Share my plan" from the recap (wireframe frame 11's Share).
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingShare = true } label: {
                    Label("Share my plan", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("festival.recap.share")
            }
        }
        .sheet(isPresented: $showingShare) {
            FestivalShareView(pack: pack, lineupName: lineup.name,
                              starredSetIDs: Set(stars.map(\.setID)), start: .plan,
                              onScan: { shared in
                                  router.pendingFestivalImport = shared
                                  router.open(module: FestivalModule.id)
                              })
        }
        .task { await load() }
        .navigationDestination(for: FestivalReelRoute.self) { _ in
            if let source = ReelSource.festival(named: lineup.name, packID: lineup.packID,
                                                sessions: sessions,
                                                clipsBySession: clipsBySession,
                                                attendance: attendance.map {
                                                    FestivalAttendanceSnapshot(
                                                        setID: $0.setID, sessionID: $0.sessionID,
                                                        startedAt: $0.startedAt, endedAt: $0.endedAt)
                                                },
                                                pack: pack) {
                ReelView(source: source)
            } else {
                ContentUnavailableView("Nothing to cut yet", systemImage: "sparkles.tv",
                                       description: Text("Film during a set and the weekend reel unlocks."))
            }
        }
    }

    // MARK: - Pieces

    private func heroCard(_ hero: FestivalRecap.Hero) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(lineup.name.uppercased()) · YOUR WEEKEND")
                .font(.caption2.weight(.bold))
                .kerning(1)
                .foregroundStyle(.white.opacity(0.85))
            Text(hero.nightsLine)
                .font(.title2.bold())
                .foregroundStyle(.white)
                .accessibilityIdentifier("festival.recap.nights")
            HStack(spacing: 0) {
                heroStat("\(hero.setsSeen)", "sets seen")
                heroStat(hero.dancedStat, "hrs danced")
                heroStat("\(hero.clipCount)", "clips")
                heroStat(hero.peakBpm.map(String.init) ?? "—", "peak ♥")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            LinearGradient(colors: [SnappetColor.festival, SnappetColor.festival.opacity(0.65)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: SnappetRadius.lg))
        // No identifier on the card CONTAINER — it would flatten the child texts out of the
        // XCUITest tree (the highlights-P5 gotcha); `festival.recap.nights` id rides the text.
    }

    private func heroStat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.headline.monospacedDigit()).foregroundStyle(.white)
            Text(label).font(.caption2).foregroundStyle(.white.opacity(0.85))
        }
        .frame(maxWidth: .infinity)
    }

    private var reelCTA: some View {
        NavigationLink(value: FestivalReelRoute()) {
            Label("Make my festival reel", systemImage: "sparkles")
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(SnappetColor.festival)
        .disabled(clipsBySession.values.allSatisfy(\.isEmpty))
        .accessibilityIdentifier("festival.recap.reel")
    }

    @ViewBuilder private func artistSection(_ artists: [FestivalRecap.ArtistRow]) -> some View {
        Text("BY ARTIST")
            .font(.caption2.weight(.bold))
            .foregroundStyle(SnappetColor.textSecondary)
            .kerning(1)
        ForEach(artists) { row in
            NavigationLink(value: pack.setsByID[row.setID]) {
                artistRow(row)
            }
            .buttonStyle(.plain)
            .disabled(pack.setsByID[row.setID] == nil)
            // The id rides the LINK (one element) — on the inner container it surfaced twice
            // (link + label) and broke single-match XCUITest queries.
            .accessibilityIdentifier("festival.recap.artist.\(row.artist)")
        }
    }

    private func artistRow(_ row: FestivalRecap.ArtistRow) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "music.mic")
                .font(.subheadline)
                .foregroundStyle(SnappetColor.festival)
                .frame(width: 36, height: 36)
                .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 1) {
                Text(row.artist).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(meta(for: row))
                    .font(.caption)
                    .foregroundStyle(SnappetColor.textSecondary)
            }
            Spacer(minLength: 6)
            if let peak = row.peakBpm {
                Text("♥ \(peak)")
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(SnappetColor.perfHard)
            }
        }
        .padding(10)
        .background(SnappetColor.surface, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
        .overlay(RoundedRectangle(cornerRadius: SnappetRadius.md)
            .strokeBorder(SnappetColor.hairline))
    }

    private func meta(for row: FestivalRecap.ArtistRow) -> String {
        var parts = ["\(row.stage) · \(row.dayLabel)"]
        if row.clipCount > 0 { parts.append("\(row.clipCount) clip\(row.clipCount == 1 ? "" : "s")") }
        if row.dancedSeconds > 0 { parts.append("\(FestivalSetStats.dancedLabel(row.dancedSeconds)) danced") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Data

    /// One tag pass (keeps the recap honest after a night), then snapshot the pack's sessions and
    /// their non-reel clips for the stitched weekend reel.
    private func load() async {
        await FestivalTagSync.refresh(pack: pack, packID: lineup.packID, context: context,
                                      mediaService: app.sessionMedia)
        let ids = Array(Set(attendance.map(\.sessionID)).union(tags.map(\.sessionID)))
        let rows = FestivalTagSync.fetchSessions(ids: ids, context: context)
        sessions = rows.map {
            FestivalSessionSnapshot(id: $0.id, startedAt: $0.startedAt, endedAt: $0.completedAt,
                                    hrSeries: $0.hrSeries, maxHR: $0.maxHR, restHR: $0.restHR)
        }
        var bySession: [UUID: [SessionHighlightInput.Clip]] = [:]
        for row in rows {
            let sid = row.id
            let media = (try? context.fetch(FetchDescriptor<SessionMedia>(
                predicate: #Predicate { $0.sessionID == sid }))) ?? []
            bySession[sid] = media.filter { !$0.isReel }.map {
                SessionHighlightInput.Clip(localIdentifier: $0.localIdentifier,
                                           isVideo: $0.kind == .video,
                                           offsetSec: $0.offsetSec, durationSec: $0.durationSec)
            }
        }
        clipsBySession = bySession
    }
}
