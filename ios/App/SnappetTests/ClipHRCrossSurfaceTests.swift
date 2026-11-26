import XCTest
import SwiftData
import HighlightEngine
@testable import Snappet

/// One clip gives the same heart rate on every surface (prompt 309).
///
/// Each surface is asked through the function it really calls, and gets the clip the way it
/// really gets it: from one in-memory store holding the session, the media row and the Studio
/// project (the clip's trim, HR window and scope).
///
/// | Surface | How it gets the clip | Entry point |
/// |---|---|---|
/// | Clips feed overlay and viewers | `ClipStudioEdit.byMedia(projects:media:)` → `MediaInput.from` | `ClipHROverlay.make`, `.fraction` |
/// | "Share with heart rate" | the feed's clip | `ClipSharePlan.plan` (the tile it burns) |
/// | Recap poster chip and viewer | `FeedMediaResolver.mediaInputs(for:)` | `FeedMedia.clipHR(for:)`, `ClipHROverlay.make` |
/// | Activity pages, Kilter library | `ActivityMediaStore.snapshot(context:)` | `ActivityMediaIndex.averageBPM`, `ClipHROverlay.make` |
/// | Festival set viewer | `ClipRow(_:isAuto:edit:)` with `ClipStudioEdit.byMedia(context:media:)` | `ClipHROverlay.make` |
/// | Studio preview tile | the project | `StudioEditorViewModel.previewTile` at a playhead time |
/// | Studio HR-window sliders | the project | `StudioEditorViewModel.hrWindowInfo` |
/// | Studio export and bake | the project | `clipHRContent()` through `StudioComposer.placedHR` |
/// | Reel scorebug | `ReelSource.workoutSession` → `heartRate(for:usesManualMedia:)` | `ReelHeartRate.track`, `ReelExporter.placedScorebugs` |
///
/// Every comparison is one surface against ANOTHER surface, never against `ClipHeartRate`. So a
/// surface that stops calling the resolver, calls it with other options, or drops the clip's
/// Studio edit on the way, fails here.
///
/// Two windows are compared, because the reel's is not the feed's:
/// - **the clip's own window** (its Studio lead-in, tail and scope; 5 s, 30 s and the whole
///   window for a clip never edited): feed, share, Recap, activity pages, festival, Studio;
/// - **footage only** (no lead-in, no tail): feed, share, Recap chip, Studio and the reel.
final class ClipHRCrossSurfaceTests: XCTestCase {

    // MARK: Fixtures

    struct Fixture {
        var name: String
        var series: [HRPoint]
        var offsetSec: Double
        /// The length of the video the asset plays now.
        var durationSec: Double
        var timeMap: BakedTimeMap? = nil
        /// What was set on the clip in the Studio. `nil` = nothing (the Studio's defaults).
        var edit: ClipStudioEdit? = nil
        var maxHR: Double = 190
        var restHR: Double? = 60
        var hasData = true
    }

    static let ramp = StudioHRTimingSeed.rampSeries()

    /// Clips A, B and C of prompt 306's seed (never baked; "Save to original" with the first
    /// 20 s trimmed off; "Save to original" at 2×) over its ramp, the prompt 304 series, a clip
    /// between sparse samples, four clips edited in the Studio (a trim, the "Clip only" scope, a
    /// custom HR window, all three), and a clip filmed five minutes after the heart rate ended.
    static func fixtures() -> [Fixture] {
        let seeded = StudioHRTimingSeed.mediaRows(sessionID: UUID())
        func seed(_ i: Int, _ name: String) -> Fixture {
            Fixture(name: name, series: ramp, offsetSec: seeded[i].offsetSec,
                    durationSec: seeded[i].durationSec ?? 0, timeMap: seeded[i].bakeTimeMap)
        }
        return [
            seed(0, "never baked"),
            seed(1, "baked, start trimmed"),
            seed(2, "baked at 2x"),
            Fixture(name: "golden series", series: StudioGoldenScene.heartRate, offsetSec: 8.3, durationSec: 7.4,
                    maxHR: 185),
            Fixture(name: "sparse samples", series: ClipHRCharacterizationTests.sparse, offsetSec: 55, durationSec: 12),
            Fixture(name: "trimmed in the Studio", series: ramp, offsetSec: 60, durationSec: 10,
                    edit: ClipStudioEdit(trimStart: 4, trimEnd: 9)),
            Fixture(name: "Clip only scope", series: ramp, offsetSec: 60, durationSec: 10,
                    edit: ClipStudioEdit(hrMetricsScope: .clip)),
            Fixture(name: "custom HR window", series: ramp, offsetSec: 60, durationSec: 10,
                    edit: ClipStudioEdit(hrLeadSec: 3, hrTailSec: 4)),
            Fixture(name: "trim, scope and window", series: StudioGoldenScene.heartRate, offsetSec: 8.3,
                    durationSec: 7.4,
                    edit: ClipStudioEdit(trimStart: 1.2, trimEnd: 6.1, hrLeadSec: 3, hrTailSec: 4, hrMetricsScope: .clip),
                    maxHR: 185, restHR: 52),
            Fixture(name: "no samples nearby", series: ramp, offsetSec: 600, durationSec: 10, hasData: false),
        ]
    }

    /// The moments compared: the steps the export's live text is cut at (`HROverlayValues.segments`).
    static let steps = [0, 7, 15, 30, 44, 59]
    static func fraction(_ step: Int) -> Double { Double(step) / 59 }

    /// What one surface shows.
    struct Shown: Equatable {
        var liveText: [String] = []
        var peak: String?
        var average: String?
    }

    // MARK: The surfaces

    private func scorebug(_ restHR: Double?) -> HRTile {
        var tile = HRTile.feedClipScorebug(restHR: restHR)
        tile.entries = tile.entries.map { entry in
            var entry = entry
            if [.bpm, .avgHR, .maxHR].contains(entry.metric) { entry.on = true }
            if entry.metric == .bpm { entry.live = true; entry.animated = true }
            return entry
        }
        return tile
    }

    private func text(_ tile: ResolvedHRTile, _ metric: HROverlayMetric, at f: Double) throws -> String {
        let segments = try XCTUnwrap(tile.metrics.first { $0.metric == metric }?.segments, "\(metric)")
        let segment = try XCTUnwrap(segments.last { $0.start <= f + 1e-9 } ?? segments.first)
        return segment.reading.value
    }

    private func shown(_ tile: ResolvedHRTile) throws -> Shown {
        Shown(liveText: try Self.steps.map { try text(tile, .bpm, at: Self.fraction($0)) },
              peak: try text(tile, .maxHR, at: 0), average: try text(tile, .avgHR, at: 0))
    }

    private func shown(_ values: HROverlayValues, live: [Double?]) -> Shown {
        Shown(liveText: live.map { $0.map { String(ClipHeartRate.rounded($0)) } ?? "none" },
              peak: values.staticValue(.maxHR, fallbackHex: "#FFFFFF")?.value,
              average: values.staticValue(.avgHR, fallbackHex: "#FFFFFF")?.value)
    }

    /// One clip as every surface gets it, out of one store.
    @MainActor
    struct Surfaces {
        var studio: ClipHRStudioHarness
        var session: WorkoutSession
        var clipsFeed: MediaInput
        var recap: MediaInput
        var activity: ActivityMediaInput
        var festival: MediaInput
    }

    /// `footageOnly`: the clip's HR window set to no lead-in and no tail in the Studio (its trim
    /// and scope stay).
    @MainActor
    private func surfaces(_ f: Fixture, footageOnly: Bool) async throws -> Surfaces {
        let h = try await ClipHRStudioHarness.make(
            series: f.series, offsetSec: f.offsetSec, durationSec: f.durationSec, timeMap: f.timeMap,
            trimStart: f.edit?.trimStart ?? 0, trimEnd: f.edit?.trimEnd,
            leadSec: footageOnly ? 0 : (f.edit.map(\.hrLeadSec)), tailSec: footageOnly ? 0 : (f.edit.map(\.hrTailSec)),
            scope: f.edit?.hrMetricsScope, maxHR: f.maxHR, restHR: f.restHR)
        var config = try XCTUnwrap(h.vm.hrOverlay)
        config.tile = scorebug(f.restHR)
        h.vm.updateHROverlay(config)

        let context = h.container.mainContext
        let rows = try context.fetch(FetchDescriptor<SessionMedia>())
        let projects = try context.fetch(FetchDescriptor<StudioProject>())
        let session = try XCTUnwrap(context.fetch(FetchDescriptor<WorkoutSession>()).first)
        let row = try XCTUnwrap(rows.first)
        // The Clips feed (`ClipsFeedView.makeSnapshot`).
        let clipsFeed = MediaInput.from(row, edit: ClipStudioEdit.byMedia(projects: projects, media: rows)[row.id])
        // Recap (`FeedView.cardMedia`, `CardDetailView`).
        let index = FeedMediaIndex(kilterSessions: [], workoutSessions: [session], kilterLogs: [],
                                   allMedia: rows, studioProjects: projects)
        let recap = try XCTUnwrap(FeedMediaResolver(index: index).mediaInputs(for: session.id).first)
        // The activity pages and the Kilter library.
        let activity = try XCTUnwrap(ActivityMediaStore.snapshot(context: context).first)
        // The festival set screen (`FestivalSetDetailView.load`).
        let festival = FestivalSetDetailView.ClipRow(
            row, isAuto: false, edit: ClipStudioEdit.byMedia(context: context, media: rows)[row.id]).mediaInput
        return Surfaces(studio: h, session: session, clipsFeed: clipsFeed, recap: recap,
                        activity: activity, festival: festival)
    }

    /// A viewer: the payload the poster, the inline player and the full-screen viewer draw, read
    /// at the video times a player would report.
    private func viewer(_ media: MediaInput, _ f: Fixture) -> (payload: ClipHROverlay.Payload, live: [Double?])? {
        guard let payload = ClipHROverlay.make(clip: media, hrSeries: f.series, maxHR: f.maxHR, restHR: f.restHR,
                                               tile: scorebug(f.restHR)) else { return nil }
        let played = ClipHROverlay.playedRange(media)
        let live = Self.steps.map { step -> Double? in
            let chart = ClipHROverlay.fraction(videoTime: played.start + Self.fraction(step) * played.span,
                                               clip: media, payload: payload, loops: false)
            return payload.values.bpm(atFraction: chart)
        }
        return (payload, live)
    }

    private func share(_ media: MediaInput, _ f: Fixture) -> ClipSharePlan.Plan? {
        let payload = ClipHROverlay.make(clip: media, hrSeries: f.series, maxHR: f.maxHR, restHR: f.restHR,
                                         tile: scorebug(f.restHR))
        return ClipSharePlan.plan(clip: media, payload: payload, title: nil)
    }

    /// A plan that plays each item in full, in the order given.
    static func fullLengthPlan(_ media: [MediaItem]) -> ReelPlan {
        let highlights = media.enumerated().map { i, m in
            Highlight(id: "h\(i)", mediaItemId: m.id, kind: .high, atOffset: m.startOffset,
                      clipStart: m.startOffset, clipEnd: m.endOffset, score: 1)
        }
        return ReelPlanner(targetDuration: nil).plan(highlights: highlights, media: media)
    }

    /// Where the exporter puts a plan whose every segment loads.
    static func placements(_ plan: ReelPlan) -> [ActivityProgressReel.Placement] {
        ReelHeartRate.slots(plan: plan).map {
            .init(mediaItemId: $0.mediaItemId, startSec: $0.start, durationSec: $0.duration)
        }
    }

    /// The reel of one session, as `ReelSource.workoutSession` makes it: the heart rate the
    /// preview's scorebug reads and the scorebugs the export burns.
    @MainActor
    private func reel(_ s: Surfaces, _ f: Fixture)
        -> (track: ReelHeartRate.Track, live: [Double?], burned: [PlacedClipHR]) {
        let rows = (try? s.studio.container.mainContext.fetch(FetchDescriptor<SessionMedia>())) ?? []
        let source = ReelSource.workoutSession(s.session, media: rows, sport: nil, category: nil)
        // What the source's `makeWorkout` returns (it takes an `AppModel` it does not read).
        let workout = SessionHighlightInput.makeWorkout(
            hrSeries: s.session.hrSeries, clips: rows.map(SessionHighlightInput.Clip.from),
            duration: s.session.duration, sport: nil, category: nil,
            restHR: s.session.restHR, maxHR: s.session.maxHR)
        let plan = Self.fullLengthPlan(workout.media)
        let input = source.heartRate(for: workout, usesManualMedia: false)
        let track = ReelHeartRate.track(plan: plan, input: input)
        let live = Self.steps.map { step -> Double? in
            track.run(at: Self.fraction(step) * plan.totalDuration).flatMap { $0.run.values.bpm(atFraction: $0.fraction) }
        }
        let burned = ReelExporter.placedScorebugs(
            plan: plan, placements: Self.placements(plan), totalDuration: plan.totalDuration,
            overlay: ReelExporter.HROverlay(heartRate: input, tile: scorebug(f.restHR)))
        return (track, live, burned)
    }

    // MARK: The tests

    private func assertSameLive(_ a: [Double?], _ b: [Double?], _ what: String, accuracy: Double = 1e-9,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.count, b.count, what, file: file, line: line)
        for (x, y) in zip(a, b) {
            guard let x, let y else {
                XCTAssertTrue(x == nil && y == nil, what, file: file, line: line)
                continue
            }
            XCTAssertEqual(x, y, accuracy: accuracy, what, file: file, line: line)
        }
    }

    /// Feed, share, Recap, activity pages, the festival viewer and the Studio over the clip's
    /// own window, each with the clip as it gets it from the store.
    @MainActor
    func testEverySurfaceShowsTheSameNumbersOverTheClipsOwnWindow() async throws {
        for f in Self.fixtures() where f.hasData {
            let s = try await surfaces(f, footageOnly: false)
            let feed = try XCTUnwrap(viewer(s.clipsFeed, f), f.name)
            let reference = shown(feed.payload.values, live: feed.live)
            XCTAssertNotNil(reference.peak, f.name)
            XCTAssertNotNil(reference.average, f.name)

            // "Share with heart rate" burns the same tile.
            let plan = try XCTUnwrap(share(s.clipsFeed, f), f.name)
            XCTAssertEqual(try shown(XCTUnwrap(plan.hr.tile)), reference, "share: \(f.name)")
            XCTAssertEqual(plan.hr.samples, feed.payload.values.samples, "share samples: \(f.name)")

            // Recap: the poster chip prints the feed's PEAK and AVG, and its viewer shows the feed's tile.
            let chip = FeedMedia.clipHR(for: s.recap, hrSeries: f.series, maxHR: f.maxHR)
            XCTAssertEqual(chip.peakBpm.map(String.init), reference.peak, "recap chip peak: \(f.name)")
            XCTAssertEqual(chip.avgBpm.map(String.init), reference.average, "recap chip average: \(f.name)")
            let recap = try XCTUnwrap(viewer(s.recap, f), f.name)
            XCTAssertEqual(shown(recap.payload.values, live: recap.live), reference, "recap viewer: \(f.name)")

            // The activity pages: the number in the list, and the viewer it opens.
            let activity = ActivityMediaIndex.averageBPM(for: s.activity, hrSeries: f.series)
            XCTAssertEqual(activity.map(String.init), reference.average, "activity average: \(f.name)")
            let activityViewer = try XCTUnwrap(viewer(s.activity.mediaInput, f), f.name)
            XCTAssertEqual(shown(activityViewer.payload.values, live: activityViewer.live), reference,
                           "activity viewer: \(f.name)")

            // The festival set viewer.
            let festival = try XCTUnwrap(viewer(s.festival, f), f.name)
            XCTAssertEqual(shown(festival.payload.values, live: festival.live), reference, "festival viewer: \(f.name)")

            // The Studio: preview tile, sliders, export.
            let h = s.studio
            let total = h.vm.totalDuration
            let previewLive = Self.steps.map { h.preview(at: Self.fraction($0) * total).bpm }
            assertSameLive(previewLive, feed.live, "studio preview live: \(f.name)")
            let preview = h.preview(at: 0).values
            XCTAssertEqual(shown(preview, live: previewLive), reference, "studio preview: \(f.name)")
            XCTAssertEqual(preview.samples, feed.payload.values.samples, "studio preview samples: \(f.name)")
            let info = try XCTUnwrap(h.vm.hrWindowInfo, f.name)
            XCTAssertEqual(info.effectiveLead, feed.payload.values.window?.leadSec, "sliders lead: \(f.name)")
            XCTAssertEqual(info.footageSec, feed.payload.values.window?.footageSec, "sliders footage: \(f.name)")
            let placed = try XCTUnwrap(h.exported(), f.name)
            XCTAssertEqual(try shown(XCTUnwrap(placed.tile)), reference, "studio export: \(f.name)")
            XCTAssertEqual(placed.samples, feed.payload.values.samples, "studio export samples: \(f.name)")
            withExtendedLifetime(h.container) {}
        }
    }

    /// The fixtures edited in the Studio do change the numbers, so a surface that dropped the
    /// edit would not pass the test above by accident: each edit is set against the same clip
    /// never edited.
    @MainActor
    func testAStudioEditChangesTheNumbersOnEverySurface() async throws {
        let all = Self.fixtures()
        for f in all where f.edit != nil {
            var plain = f
            plain.edit = nil
            let edited = try await surfaces(f, footageOnly: false)
            let unedited = try await surfaces(plain, footageOnly: false)
            XCTAssertEqual(edited.clipsFeed.edit?.hrMetricsScope, f.edit?.hrMetricsScope, f.name)
            for (a, b, what) in [(edited.clipsFeed, unedited.clipsFeed, "clips feed"),
                                 (edited.recap, unedited.recap, "recap"),
                                 (edited.activity.mediaInput, unedited.activity.mediaInput, "activity"),
                                 (edited.festival, unedited.festival, "festival")] {
                XCTAssertEqual(a.edit, edited.clipsFeed.edit, "\(what) carries the edit: \(f.name)")
                let with = try XCTUnwrap(viewer(a, f)), without = try XCTUnwrap(viewer(b, f))
                XCTAssertNotEqual(shown(with.payload.values, live: with.live),
                                  shown(without.payload.values, live: without.live), "\(what): \(f.name)")
            }
            XCTAssertNotEqual(ActivityMediaIndex.averageBPM(for: edited.activity, hrSeries: f.series),
                              ActivityMediaIndex.averageBPM(for: unedited.activity, hrSeries: f.series), f.name)
            withExtendedLifetime(edited.studio.container) {}
            withExtendedLifetime(unedited.studio.container) {}
        }
    }

    /// Feed, share, Recap chip, the Studio and the reel over the footage alone.
    @MainActor
    func testEverySurfaceShowsTheSameNumbersOverTheFootageAlone() async throws {
        // A reel plays the asset as Photos has it: a Studio trim that was not saved to the
        // original does not reach it, and its numbers are always over the footage.
        for f in Self.fixtures() where f.hasData && f.edit == nil {
            let s = try await surfaces(f, footageOnly: true)
            let feed = try XCTUnwrap(viewer(s.clipsFeed, f), f.name)
            let reference = shown(feed.payload.values, live: feed.live)

            let plan = try XCTUnwrap(share(s.clipsFeed, f), f.name)
            XCTAssertEqual(try shown(XCTUnwrap(plan.hr.tile)), reference, "share: \(f.name)")

            let chip = FeedMedia.clipHR(for: s.recap, hrSeries: f.series, maxHR: f.maxHR)
            XCTAssertEqual(chip.peakBpm.map(String.init), reference.peak, "chip peak: \(f.name)")
            XCTAssertEqual(chip.avgBpm.map(String.init), reference.average, "chip average: \(f.name)")

            let h = s.studio
            let total = h.vm.totalDuration
            let previewLive = Self.steps.map { h.preview(at: Self.fraction($0) * total).bpm }
            assertSameLive(previewLive, feed.live, "studio preview live: \(f.name)")
            XCTAssertEqual(shown(h.preview(at: 0).values, live: previewLive), reference, "studio preview: \(f.name)")
            let placed = try XCTUnwrap(h.exported(), f.name)
            XCTAssertEqual(try shown(XCTUnwrap(placed.tile)), reference, "studio export: \(f.name)")

            // The reel: the same bpm at the same moments of the clip, the same peak and average,
            // in the preview and in the tile the export burns.
            let reel = reel(s, f)
            XCTAssertEqual(reel.track.runs.count, 1, f.name)
            assertSameLive(reel.live, feed.live, "reel live: \(f.name)")
            let run = try XCTUnwrap(reel.track.runs.first, f.name)
            XCTAssertEqual(shown(run.values, live: reel.live), reference, "reel preview: \(f.name)")
            XCTAssertEqual(reel.burned.count, 1, f.name)
            let burned = try XCTUnwrap(reel.burned.first, f.name)
            XCTAssertEqual(burned.startSec, 0, f.name)
            XCTAssertEqual(burned.durationSec, f.durationSec, accuracy: 1e-6, f.name)
            XCTAssertEqual(try shown(XCTUnwrap(burned.tile)), reference, "reel export tile: \(f.name)")
            withExtendedLifetime(h.container) {}
        }
    }

    /// A clip with no heart rate near it shows none anywhere: no overlay, a raw share, an empty
    /// chip, no average, no Studio tile in the export, no reel scorebug.
    @MainActor
    func testAClipWithNoSamplesNearbyShowsNoHeartRateAnywhere() async throws {
        let f = try XCTUnwrap(Self.fixtures().first { !$0.hasData })
        for footageOnly in [false, true] {
            let s = try await surfaces(f, footageOnly: footageOnly)
            for media in [s.clipsFeed, s.recap, s.activity.mediaInput, s.festival] {
                XCTAssertNil(viewer(media, f))
                XCTAssertNil(share(media, f))
                XCTAssertEqual(ClipSharePlan.offer(for: media, payload: nil), .raw)
                XCTAssertEqual(FeedMedia.clipHR(for: media, hrSeries: f.series, maxHR: f.maxHR),
                               MediaClipHR(peakBpm: nil, avgBpm: nil, zoneRaw: nil))
            }
            XCTAssertNil(ActivityMediaIndex.averageBPM(for: s.activity, hrSeries: f.series))
            let h = s.studio
            XCTAssertNil(h.exported())
            let preview = h.preview(at: 1)
            XCTAssertNil(preview.bpm)
            XCTAssertTrue(preview.values.samples.isEmpty)
            XCTAssertNil(preview.values.staticValue(.avgHR, fallbackHex: "#FFFFFF"))
            let reel = reel(s, f)
            XCTAssertFalse(reel.track.hasData)
            XCTAssertTrue(reel.burned.isEmpty, "nothing is burned: not even an empty panel")
            XCTAssertTrue(reel.live.allSatisfy { $0 == nil })
            withExtendedLifetime(h.container) {}
        }
    }

    /// The 90 s limit is the same on both sides of the recording and is measured from the
    /// footage's nearest edge, whatever the lead-in and the tail: 90 s out there is a held
    /// reading, 91 s out there is none. On every surface.
    @MainActor
    func testTheLimitOutsideTheRecordingIsTheSameOnBothSidesAndOnEverySurface() async throws {
        // The ramp is recorded from 0 to 300 s. Each clip is 10 s long.
        // After the recording, through the store (a media row cannot hold a negative offset).
        for (offset, held) in [(390.0, true), (391.0, false)] {
            let what = "starts \(offset - 300) s after the last sample"
            let f = Fixture(name: what, series: Self.ramp, offsetSec: offset, durationSec: 10)
            let s = try await surfaces(f, footageOnly: false)
            let feed = viewer(s.clipsFeed, f)
            let chip = FeedMedia.clipHR(for: s.recap, hrSeries: f.series, maxHR: f.maxHR)
            XCTAssertEqual(feed != nil, held, "feed: \(what)")
            XCTAssertEqual(share(s.clipsFeed, f) != nil, held, "share: \(what)")
            XCTAssertEqual(chip.peakBpm != nil, held, "chip: \(what)")
            XCTAssertEqual(viewer(s.activity.mediaInput, f) != nil, held, "activity viewer: \(what)")
            XCTAssertEqual(viewer(s.festival, f) != nil, held, "festival viewer: \(what)")
            XCTAssertEqual(s.studio.exported() != nil, held, "studio export: \(what)")
            XCTAssertEqual(s.studio.preview(at: 1).bpm != nil, held, "studio preview: \(what)")
            XCTAssertEqual(reel(s, f).track.hasData, held, "reel: \(what)")
            // A held reading is the nearest recorded sample, drawn dashed; the activity list,
            // which has no dashed line to say so, prints no number for it.
            if held, let feed {
                XCTAssertEqual(feed.payload.values.staticValue(.avgHR, fallbackHex: "")?.value, "210", what)
                XCTAssertTrue(feed.payload.values.isSparseChart, what)
                XCTAssertEqual(chip.avgBpm, 210, what)
            }
            XCTAssertNil(ActivityMediaIndex.averageBPM(for: s.activity, hrSeries: f.series), "activity: \(what)")
            withExtendedLifetime(s.studio.container) {}
        }
        // Before the recording, through the values each surface reads.
        for (offset, held) in [(-100.0, true), (-101.0, false), (-600.0, false)] {
            let what = "ends \(-offset - 10) s before the first sample"
            let media = MediaInput(id: UUID(), kind: "video", offsetSec: offset, durationSec: 10, exerciseId: nil,
                                   setIndex: nil, climbUUID: nil, localIdentifier: "B")
            let f = Fixture(name: what, series: Self.ramp, offsetSec: offset, durationSec: 10)
            let feed = viewer(media, f)
            let chip = FeedMedia.clipHR(for: media, hrSeries: Self.ramp, maxHR: 190)
            XCTAssertEqual(feed != nil, held, "feed: \(what)")
            XCTAssertEqual(share(media, f) != nil, held, "share: \(what)")
            XCTAssertEqual(chip.peakBpm != nil, held, "chip: \(what)")
            if held { XCTAssertEqual(chip.avgBpm, 60, what) }
            let activity = ActivityMediaInput(id: UUID(), sessionID: UUID(), assignedExerciseID: nil,
                                              assignedSetIndex: nil, kindRaw: "video", offsetSec: offset,
                                              durationSec: 10, localIdentifier: "B")
            XCTAssertNil(ActivityMediaIndex.averageBPM(for: activity, hrSeries: Self.ramp), "activity: \(what)")
            let item = MediaItem(id: "B", kind: .video, startOffset: offset, duration: 10)
            let workout = Workout(activity: .strength, duration: 300,
                                  hr: Self.ramp.map { HRSample(t: $0.t, bpm: $0.bpm) }, restBpm: 60, maxBpm: 190,
                                  media: [item])
            let track = ReelHeartRate.track(plan: Self.fullLengthPlan([item]), input: .oneSession(workout))
            XCTAssertEqual(track.hasData, held, "reel: \(what)")
        }
        // A photo has the same limit: 90 s after the last sample, not 100.
        func photo(_ offset: Double) -> MediaInput {
            MediaInput(id: UUID(), kind: "photo", offsetSec: offset, durationSec: nil, exerciseId: nil,
                       setIndex: nil, climbUUID: nil, localIdentifier: "P")
        }
        XCTAssertNotNil(FeedMedia.clipHR(for: photo(390), hrSeries: Self.ramp, maxHR: 190).peakBpm)
        XCTAssertNil(FeedMedia.clipHR(for: photo(391), hrSeries: Self.ramp, maxHR: 190).peakBpm)
    }

    /// Each recorded sample counts once in the average, at both ends: a window that reaches past
    /// the first or the last recorded sample does not count that sample a second time.
    func testASampleAtTheEdgeOfTheRecordingCountsOnce() throws {
        // Recorded 100…110 s only: 100, 120, 140 bpm. The clip 95…115 s (no lead-in, no tail).
        let series = [HRPoint(t: 100, bpm: 100), HRPoint(t: 105, bpm: 120), HRPoint(t: 110, bpm: 140)]
        let media = MediaInput(id: UUID(), kind: "video", offsetSec: 95, durationSec: 20, exerciseId: nil,
                               setIndex: nil, climbUUID: nil, localIdentifier: "E",
                               edit: ClipStudioEdit(hrLeadSec: 0, hrTailSec: 0))
        let payload = try XCTUnwrap(ClipHROverlay.make(clip: media, hrSeries: series, maxHR: 190, restHR: 60))
        // (100 + 120 + 140) / 3. It was (100 + 100 + 120 + 140 + 140) / 5 = 120 here too, so a
        // lopsided case: 95…108 s holds 100, 120 and the reading at 108 (132): 117, was 113.
        XCTAssertEqual(payload.values.staticValue(.avgHR, fallbackHex: "")?.value, "120")
        var early = media
        early.durationSec = 13
        let lopsided = try XCTUnwrap(ClipHROverlay.make(clip: early, hrSeries: series, maxHR: 190, restHR: 60))
        XCTAssertEqual(lopsided.values.staticValue(.avgHR, fallbackHex: "")?.value, "117")
        XCTAssertEqual(FeedMedia.clipHR(for: early, hrSeries: series, maxHR: 190).avgBpm, 117)
        // The drawn samples are untouched: the edge reading is still there, at the first sample's time.
        XCTAssertEqual(lopsided.values.samples.map(\.bpm), [100, 100, 120, 132])
    }

    /// The numbers themselves, so the agreement above is agreement on the right thing. The ramp
    /// is `bpm = 60 + seconds / 2`: a reading names the second it came from.
    @MainActor
    func testTheNumbersAreTheOnesTheClipWasFilmedAt() async throws {
        let all = Self.fixtures()
        func feed(_ i: Int) async throws -> (payload: ClipHROverlay.Payload, live: [Double?]) {
            let s = try await surfaces(all[i], footageOnly: true)
            defer { withExtendedLifetime(s.studio.container) {} }
            return try XCTUnwrap(viewer(s.clipsFeed, all[i]))
        }
        // Never baked, filmed 60…70 s: 90 → 95 bpm.
        var feed0 = try await feed(0)
        XCTAssertEqual(try XCTUnwrap(feed0.live.first ?? nil), 90, accuracy: 1.0)
        XCTAssertEqual(try XCTUnwrap(feed0.live.last ?? nil), 95, accuracy: 1.0)
        XCTAssertEqual(feed0.payload.values.staticValue(.maxHR, fallbackHex: "")?.value, "95")
        // Baked with the first 20 s trimmed off a recording that began at 200 s: 220…230 s.
        feed0 = try await feed(1)
        XCTAssertEqual(try XCTUnwrap(feed0.live.first ?? nil), 170, accuracy: 1.0)
        XCTAssertEqual(try XCTUnwrap(feed0.live.last ?? nil), 175, accuracy: 1.0)
        // Baked at 2× from 120 s: its 10 s of video are 120…140 s.
        feed0 = try await feed(2)
        XCTAssertEqual(try XCTUnwrap(feed0.live.first ?? nil), 120, accuracy: 1.0)
        XCTAssertEqual(try XCTUnwrap(feed0.live.last ?? nil), 130, accuracy: 1.0)
        XCTAssertEqual(feed0.payload.values.staticValue(.maxHR, fallbackHex: "")?.value, "130")
    }

    /// A clip marked baked carries its tile in the pixels: the feed draws nothing and the share
    /// is raw, as before. The chip and the activity average still read it, through its map.
    func testABakedClipStillStandsDownInTheFeed() throws {
        let rows = StudioHRTimingSeed.mediaRows(sessionID: UUID())
        let baked = MediaInput.from(rows[1], edit: ClipStudioEdit(trimStart: 1, trimEnd: 2))
        XCTAssertTrue(baked.isBaked)
        XCTAssertNil(baked.edit, "a baked clip's edit is in its pixels")
        XCTAssertNil(ClipHROverlay.make(clip: baked, hrSeries: Self.ramp, maxHR: 190, restHR: 60))
        XCTAssertEqual(ClipSharePlan.offer(for: baked, payload: nil), .raw)
        let chip = FeedMedia.clipHR(for: baked, hrSeries: Self.ramp, maxHR: 190)
        // 215…260 s of the ramp (5 s before the kept footage, 30 s after): peak 190.
        XCTAssertEqual(chip.peakBpm, 190)
        XCTAssertEqual(ActivityMediaIndex.averageBPM(for: ActivityMediaInput.from(rows[1]), hrSeries: Self.ramp),
                       chip.avgBpm)
    }

    // MARK: Reels

    private func item(_ id: String, at offset: Double, seconds: Double = 10) -> MediaItem {
        MediaItem(id: id, kind: .video, startOffset: offset, duration: seconds)
    }

    private func bpm(_ track: ReelHeartRate.Track, at time: Double) -> Double? {
        track.run(at: time).flatMap { $0.run.values.bpm(atFraction: $0.fraction) }
    }

    /// A reel of two clips: over each clip the scorebug reads that clip's heart rate, and the
    /// reel's peak and average are over the two clips' footage.
    func testAReelOfTwoClipsReadsEachClipsOwnHeartRate() throws {
        let rows = StudioHRTimingSeed.mediaRows(sessionID: UUID())
        let clips = [rows[0], rows[2]].map(SessionHighlightInput.Clip.from)          // A (60…70 s), C at 2× (120…140 s)
        let workout = SessionHighlightInput.makeWorkout(hrSeries: Self.ramp, clips: clips, duration: 300,
                                                        sport: nil, category: nil, restHR: 60, maxHR: 190)
        let plan = Self.fullLengthPlan(workout.media)
        XCTAssertEqual(plan.totalDuration, 20)
        let track = ReelHeartRate.track(
            plan: plan, input: .oneSession(workout, timeMaps: SessionHighlightInput.timeMaps(of: clips)))
        XCTAssertEqual(track.runs.count, 1, "one session, every clip has heart rate: one scorebug, as before")
        // 5 s into the reel is 5 s into A: session second 65.
        XCTAssertEqual(try XCTUnwrap(bpm(track, at: 5)), 92.5, accuracy: 1.0)
        // 15 s into the reel is 5 s into C, which runs at 2×: session second 130.
        XCTAssertEqual(try XCTUnwrap(bpm(track, at: 15)), 125, accuracy: 1.0)
        XCTAssertEqual(track.runs[0].values.staticValue(.maxHR, fallbackHex: "")?.value, "130")
        // Before prompt 309 the same reel read the whole session stretched over 20 s: 135 bpm at
        // 5 s, 172 at 15 s, peak 210.
    }

    /// The reel's clock for a baked clip is the row's clock: both say when a frame was filmed.
    func testTheReelsClockForABakedClipIsTheRowsClock() throws {
        for row in StudioHRTimingSeed.mediaRows(sessionID: UUID()) {
            let clip = SessionHighlightInput.Clip.from(row)
            let item = try XCTUnwrap(SessionHighlightInput.mediaItems(from: [clip], defaultDuration: nil).first)
            let clock = ReelHeartRate.clock(for: item, timeMap: clip.timeMap)
            for t in [0.0, 2.5, 10] {
                XCTAssertEqual(clock.captureTime(renditionTime: t), row.captureClock.captureTime(renditionTime: t),
                               accuracy: 1e-9)
            }
        }
    }

    /// A reel segment that starts INSIDE a clip (a weekly reel's trimmed window) reads the
    /// seconds its frames were filmed at, not the clip's first seconds.
    func testAReelSegmentInsideAClipReadsItsOwnSeconds() throws {
        let media = [item("A", at: 60, seconds: 30)]
        // Seconds 12…18 of the clip: session seconds 72…78, 96 → 99 bpm.
        let highlight = Highlight(id: "s", mediaItemId: "A", kind: .high, atOffset: 75,
                                  clipStart: 72, clipEnd: 78, score: 1)
        let plan = ReelPlanner(targetDuration: nil).plan(highlights: [highlight], media: media)
        XCTAssertEqual(plan.segments.first?.startWithinMedia ?? 0, 12, accuracy: 1e-9)
        XCTAssertEqual(plan.segments.first?.endWithinMedia ?? 0, 18, accuracy: 1e-9)
        let workout = Workout(activity: .strength, duration: 300,
                              hr: Self.ramp.map { HRSample(t: $0.t, bpm: $0.bpm) }, restBpm: 60, maxBpm: 190, media: media)
        let track = ReelHeartRate.track(plan: plan, input: .oneSession(workout))
        XCTAssertEqual(try XCTUnwrap(bpm(track, at: 0)), 96, accuracy: 0.6)
        XCTAssertEqual(try XCTUnwrap(bpm(track, at: 3)), 97.5, accuracy: 0.6)
        XCTAssertEqual(try XCTUnwrap(bpm(track, at: 6)), 99, accuracy: 0.6)
        XCTAssertEqual(track.runs[0].values.staticValue(.maxHR, fallbackHex: "")?.value, "99")
    }

    /// A clip with no heart rate BETWEEN two that have it (a reel plays clips in the order they
    /// were filmed, so the one in the middle is from a day with no band): the scorebug is not
    /// shown while it plays, in the preview and in the export, and comes back for the next clip.
    /// No reading is made up for it and no line is drawn into or out of it.
    func testAReelClipWithoutHeartRateInTheMiddleHasNoScorebug() throws {
        // Monday 60…70 s (90 → 95 bpm), Tuesday without a band, Wednesday 200…210 s (160 → 165).
        let sessions = [weekSession("Mon", day: 0, series: Self.ramp, clipAt: 60, id: "MON", maxHR: 190),
                        weekSession("Tue", day: 1, series: [], clipAt: 30, id: "TUE", maxHR: nil),
                        weekSession("Wed", day: 2, series: Self.ramp, clipAt: 200, id: "WED", maxHR: 190)]
        let source = try XCTUnwrap(ReelSource.week(sessions: sessions))
        let stitched = try XCTUnwrap(WeeklyHighlights.stitchedWorkout(sessions: sessions))
        let plan = Self.fullLengthPlan(stitched.workout.media)
        XCTAssertEqual(plan.segments.map(\.mediaItemId), ["MON", "TUE", "WED"])
        let input = source.heartRate(for: stitched.workout, usesManualMedia: false)
        let track = ReelHeartRate.track(plan: plan, input: input)
        XCTAssertEqual(track.runs.map(\.start), [0, 20])
        XCTAssertEqual(track.runs.map(\.end), [10, 30])
        guard track.runs.count == 2 else { return }
        XCTAssertEqual(try XCTUnwrap(bpm(track, at: 5)), 92.5, accuracy: 1.0)
        for t in [10.0, 12, 15, 19.99] { XCTAssertNil(track.run(at: t), "no scorebug at \(t) s") }
        XCTAssertEqual(try XCTUnwrap(bpm(track, at: 25)), 162.5, accuracy: 1.0)
        XCTAssertNotNil(track.run(at: 30), "the last instant of the reel")
        // Before this was fixed the line glided across the gap: about 130 bpm at 15 s.
        XCTAssertLessThanOrEqual(track.runs[0].samples.map(\.bpm).max() ?? 999, 95.01)
        XCTAssertGreaterThanOrEqual(track.runs[1].samples.map(\.bpm).min() ?? 0, 159.99)
        XCTAssertEqual(track.runs[0].values.chartSamples.last?.bpm ?? 0, 95, accuracy: 1.0)
        XCTAssertEqual(track.runs[1].values.chartSamples.first?.bpm ?? 0, 160, accuracy: 1.0)

        // The export burns one scorebug for each stretch, shown only while it plays.
        let burned = ReelExporter.placedScorebugs(
            plan: plan, placements: Self.placements(plan), totalDuration: 30,
            overlay: ReelExporter.HROverlay(heartRate: input))
        XCTAssertEqual(burned.map(\.startSec), [0, 20])
        XCTAssertEqual(burned.map(\.durationSec), [10, 10])
        guard burned.count == 2 else { return }
        XCTAssertLessThanOrEqual(burned[0].samples.map(\.bpm).max() ?? 999, 95.01)
        XCTAssertGreaterThanOrEqual(burned[1].samples.map(\.bpm).min() ?? 0, 159.99)
    }

    /// Two clips of ONE session with a third between them in the reel that has no heart rate:
    /// AVG and PEAK are over that session's clips in the reel, the same before and after the gap.
    func testASessionsAverageAndPeakAreTheSameOnBothSidesOfAGap() throws {
        let media = [item("NEAR", at: 60), item("LATE", at: 200), item("FAR", at: 900)]
        let workout = Workout(activity: .strength, duration: 1000,
                              hr: Self.ramp.map { HRSample(t: $0.t, bpm: $0.bpm) }, restBpm: 60, maxBpm: 190, media: media)
        // Where an export would put them if the user dragged FAR between the other two.
        let slots = [("NEAR", 0.0), ("FAR", 10.0), ("LATE", 20.0)].map {
            ReelHeartRate.Slot(mediaItemId: $0.0, isPhoto: false, startWithinMedia: 0, endWithinMedia: 10,
                               start: $0.1, duration: 10)
        }
        let track = ReelHeartRate.track(slots: slots, totalDuration: 30, input: .oneSession(workout))
        XCTAssertEqual(track.runs.map(\.start), [0, 20])
        XCTAssertNil(track.run(at: 15))
        XCTAssertEqual(track.runs.map { $0.values.staticValue(.maxHR, fallbackHex: "")?.value }, ["165", "165"])
    }

    /// The exporter skips a segment whose asset fails to load, and everything after it moves up.
    /// The burned scorebug is timed from where the segments were PUT: the third clip shows its
    /// own heart rate, not the middle of the missing second one.
    func testTheBurnedScorebugIsTimedFromWhereTheExporterPutEachSegment() throws {
        let media = [item("ONE", at: 20), item("TWO", at: 100), item("THREE", at: 220)]
        let workout = Workout(activity: .strength, duration: 300,
                              hr: Self.ramp.map { HRSample(t: $0.t, bpm: $0.bpm) }, restBpm: 60, maxBpm: 190, media: media)
        let plan = Self.fullLengthPlan(media)
        // TWO failed to load: THREE plays from 10 s, not from 20 s.
        let placements: [ActivityProgressReel.Placement] = [
            .init(mediaItemId: "ONE", startSec: 0, durationSec: 10),
            .init(mediaItemId: "THREE", startSec: 10, durationSec: 10),
        ]
        let slots = ReelHeartRate.slots(plan: plan, placements: placements)
        XCTAssertEqual(slots.map(\.mediaItemId), ["ONE", "THREE"])
        XCTAssertEqual(slots.map(\.start), [0, 10])
        let track = ReelHeartRate.track(slots: slots, totalDuration: 20, input: .oneSession(workout))
        // 15 s into the file is 5 s into THREE: session second 225, 172.5 bpm.
        XCTAssertEqual(try XCTUnwrap(bpm(track, at: 15)), 172.5, accuracy: 1.0)
        // Timed from the plan it would be 5 s into TWO: 112.5 bpm.
        let planned = ReelHeartRate.track(plan: plan, input: .oneSession(workout))
        XCTAssertEqual(try XCTUnwrap(bpm(planned, at: 15)), 112.5, accuracy: 1.0)
        let burned = ReelExporter.placedScorebugs(plan: plan, placements: placements, totalDuration: 20,
                                                  overlay: ReelExporter.HROverlay(heartRate: .oneSession(workout)))
        XCTAssertEqual(burned.count, 1)
        XCTAssertEqual(burned[0].durationSec, 20, accuracy: 1e-6)
        XCTAssertEqual(burned[0].samples.map(\.bpm).max() ?? 0, 175, accuracy: 0.5)
    }

    // MARK: Reels of several sessions

    private func weekSession(_ title: String, day: Double, series: [HRPoint], clipAt offset: Double,
                             id: String, maxHR: Double?) -> WeeklyHighlights.SessionInput {
        WeeklyHighlights.SessionInput(
            id: UUID(), title: title, startedAt: Date(timeIntervalSinceReferenceDate: 800_000_000 + day * 86_400),
            duration: 300, hrSeries: series, maxHR: maxHR, restHR: 60,
            clips: [SessionHighlightInput.Clip(localIdentifier: id, isVideo: true, offsetSec: offset, durationSec: 10)],
            isClimbing: false)
    }

    /// A weekly reel: Monday wore a band, Tuesday did not. Tuesday's clip has no scorebug. It
    /// does not show Monday's last reading (the sessions sit one second apart on the stitched
    /// timeline; before this was fixed Tuesday's clip read 210, held from Monday).
    func testAWeeklyReelNeverReadsAClipFromAnotherSession() throws {
        let monday = weekSession("Mon", day: 0, series: Self.ramp, clipAt: 60, id: "MON", maxHR: 190)
        let tuesday = weekSession("Tue", day: 1, series: [], clipAt: 30, id: "TUE", maxHR: nil)
        let source = try XCTUnwrap(ReelSource.week(sessions: [monday, tuesday]))
        let stitched = try XCTUnwrap(WeeklyHighlights.stitchedWorkout(sessions: [monday, tuesday]))
        XCTAssertEqual(source.heartRateSessions, stitched.heartRate)
        let input = source.heartRate(for: stitched.workout, usesManualMedia: false)
        XCTAssertEqual(input.sessions.count, 2)
        let plan = Self.fullLengthPlan(stitched.workout.media)
        XCTAssertEqual(plan.segments.map(\.mediaItemId), ["MON", "TUE"])
        let track = ReelHeartRate.track(plan: plan, input: input)
        XCTAssertEqual(track.runs.count, 1)
        XCTAssertEqual(try XCTUnwrap(bpm(track, at: 5)), 92.5, accuracy: 1.0)
        for t in [10.0, 15, 19.9] { XCTAssertNil(track.run(at: t), "Tuesday has no heart rate at \(t) s") }
        // Read off the stitched series, as it was, Tuesday's clip is within 90 s of Monday's end.
        let acrossTheStitch = ReelHeartRate.track(plan: plan, input: .oneSession(stitched.workout))
        XCTAssertNotNil(bpm(acrossTheStitch, at: 15), "the fixture does sit inside the old hold")
    }

    /// A clip filmed just before its own session's Start reads ITS session's first sample, held,
    /// not the session before. And each session's zones are against its own maximum.
    func testAClipBeforeItsSessionsStartReadsItsOwnSession() throws {
        let monday = weekSession("Mon", day: 0, series: Self.ramp, clipAt: 60, id: "MON", maxHR: 200)
        // Wednesday's heart rate is a flat 100; its clip was filmed 30…20 s before Start.
        let flat = [HRPoint(t: 0, bpm: 100), HRPoint(t: 300, bpm: 100)]
        let wednesday = weekSession("Wed", day: 2, series: flat, clipAt: -30, id: "WED", maxHR: 150)
        let source = try XCTUnwrap(ReelSource.collection(sessions: [monday, wednesday], id: "c", title: "t",
                                                         postTitle: "p", start: monday.startedAt,
                                                         trimToHighlights: false))
        let stitched = try XCTUnwrap(WeeklyHighlights.stitchedWorkout(sessions: [monday, wednesday]))
        let plan = Self.fullLengthPlan(stitched.workout.media)
        XCTAssertEqual(plan.segments.map(\.mediaItemId), ["MON", "WED"])
        let track = ReelHeartRate.track(plan: plan,
                                        input: source.heartRate(for: stitched.workout, usesManualMedia: false))
        XCTAssertEqual(track.runs.count, 2, "a new stretch at the change of session")
        XCTAssertEqual(try XCTUnwrap(bpm(track, at: 15)), 100, accuracy: 0.01)   // not Monday's 210
        XCTAssertEqual(track.runs[0].values.resolvedMaxHR, 200)
        XCTAssertEqual(track.runs[1].values.resolvedMaxHR, 150)
        // Each session's AVG and PEAK are its own.
        XCTAssertEqual(track.runs[0].values.staticValue(.maxHR, fallbackHex: "")?.value, "95")
        XCTAssertEqual(track.runs[1].values.staticValue(.maxHR, fallbackHex: "")?.value, "100")
    }

    // MARK: Wiring

    /// Every reel source hands the baked clips' time maps to the scorebug, and a reel of several
    /// sessions hands over each session's heart rate. Hand-picked media get neither.
    func testEveryReelSourceCarriesWhatTheScorebugNeeds() throws {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let gym = WorkoutSession(routineName: "HR", startedAt: start, completedAt: start.addingTimeInterval(300),
                                 hrSeries: Self.ramp, maxHR: 190, restHR: 60)
        let rows = StudioHRTimingSeed.mediaRows(sessionID: gym.id)
        let baked = rows[2].localIdentifier
        XCTAssertNotNil(rows[2].bakeTimeMap)

        let session = ReelSource.workoutSession(gym, media: rows, sport: nil, category: nil)
        XCTAssertEqual(session.timeMaps[baked], rows[2].bakeTimeMap)
        XCTAssertTrue(session.heartRateSessions.isEmpty)

        let board = KilterSession(startedAt: start, endedAt: start.addingTimeInterval(300), angle: 40, source: "ble")
        board.hrSeries = Self.ramp
        XCTAssertEqual(ReelSource.kilterSession(board, media: rows).timeMaps[baked], rows[2].bakeTimeMap)

        let clips = rows.map(SessionHighlightInput.Clip.from)
        let input = WeeklyHighlights.SessionInput(id: gym.id, title: "t", startedAt: start, duration: 300,
                                                  hrSeries: Self.ramp, maxHR: 190, restHR: 60, clips: clips,
                                                  isClimbing: false)
        for stitched in [ReelSource.week(sessions: [input]),
                         ReelSource.collection(sessions: [input], id: "c", title: "t", postTitle: "p",
                                               start: start, trimToHighlights: true)] {
            let source = try XCTUnwrap(stitched)
            XCTAssertEqual(source.timeMaps[baked], rows[2].bakeTimeMap)
            XCTAssertEqual(source.heartRateSessions.count, 1)
            XCTAssertEqual(source.heartRateSessions.first?.series, Self.ramp)
            XCTAssertEqual(source.heartRateSessions.first?.maxHR, 190)
        }

        // What the reel editor asks for (`ReelViewModel.heartRateTrack`, `export`).
        let workout = SessionHighlightInput.makeWorkout(hrSeries: Self.ramp, clips: clips, duration: 300,
                                                        sport: nil, category: nil, restHR: 60, maxHR: 190)
        let auto = session.heartRate(for: workout, usesManualMedia: false)
        XCTAssertEqual(auto.timeMaps[baked], rows[2].bakeTimeMap)
        XCTAssertEqual(auto.sessions.first?.series, Self.ramp)
        XCTAssertEqual(auto.sessions.first?.maxHR, 190)
        let picked = session.heartRate(for: workout, usesManualMedia: true)
        XCTAssertTrue(picked.timeMaps.isEmpty, "hand-picked media are not this session's rows")
        // The map changes the reading: C at 2× reads 120…140 s with it, 120…130 s without.
        let plan = Self.fullLengthPlan([try XCTUnwrap(workout.media.first { $0.id == baked })])
        XCTAssertEqual(try XCTUnwrap(bpm(ReelHeartRate.track(plan: plan, input: auto), at: 10)), 130, accuracy: 0.6)
        XCTAssertEqual(try XCTUnwrap(bpm(ReelHeartRate.track(plan: plan, input: picked), at: 10)), 125, accuracy: 0.6)
    }

    /// The feed's Animate: the scorebug is read from the session's series with the clips' time
    /// maps and the session's own maximum, and a session without heart rate burns nothing.
    func testAnimateReadsTheSessionThroughTheClipsTimeMaps() throws {
        let rows = StudioHRTimingSeed.mediaRows(sessionID: UUID())
        let clips = rows.map(SessionHighlightInput.Clip.from)
        func context(_ series: [HRPoint]) -> ClipExportCoordinator.Context {
            ClipExportCoordinator.Context(hrSeries: series, clips: clips, duration: 300, maxHR: 185,
                                          restHR: 55, clipName: nil)
        }
        let workout = SessionHighlightInput.makeWorkout(hrSeries: Self.ramp, clips: clips, duration: 300,
                                                        sport: nil, category: nil)
        let input = ClipExportCoordinator.heartRate(context: context(Self.ramp), workout: workout)
        XCTAssertEqual(input.timeMaps[rows[2].localIdentifier], rows[2].bakeTimeMap)
        XCTAssertEqual(input.sessions, [ReelHeartRate.Session(series: Self.ramp, maxHR: 185, restHR: 55)])
        let plan = Self.fullLengthPlan(workout.media)
        let burned = ReelExporter.placedScorebugs(plan: plan, placements: Self.placements(plan),
                                                  totalDuration: plan.totalDuration,
                                                  overlay: ReelExporter.HROverlay(heartRate: input))
        XCTAssertEqual(burned.count, 1)
        XCTAssertEqual(burned.first?.tile?.maxHR, 185)

        // No heart rate in the session: nothing is burned. (Before prompt 309 an empty glass
        // panel was.)
        let none = ClipExportCoordinator.heartRate(context: context([]), workout: workout)
        XCTAssertTrue(ReelExporter.placedScorebugs(plan: plan, placements: Self.placements(plan),
                                                   totalDuration: plan.totalDuration,
                                                   overlay: ReelExporter.HROverlay(heartRate: none)).isEmpty)
    }
}
