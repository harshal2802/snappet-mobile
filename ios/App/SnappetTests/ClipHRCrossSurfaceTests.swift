import XCTest
import SwiftData
import HighlightEngine
@testable import Snappet

/// One clip gives the same heart rate on every surface (prompt 309).
///
/// Each surface is asked through the function it really calls:
///
/// | Surface | Entry point |
/// |---|---|
/// | Clips feed overlay and viewers | `ClipHROverlay.make`, `ClipHROverlay.fraction` |
/// | "Share with heart rate" | `ClipSharePlan.plan` (the tile it burns) |
/// | Poster chip | `FeedMedia.clipHR(for:)` |
/// | Activity pages | `ActivityMediaIndex.averageBPM` |
/// | Studio preview tile | `StudioEditorViewModel.previewTile` at a playhead time |
/// | Studio HR-window sliders | `StudioEditorViewModel.hrWindowInfo` |
/// | Studio export and bake | `clipHRContent()` through `StudioComposer.placedHR` |
/// | Reel scorebug | `ReelHeartRate.track` + `ReelHeartRate.values` over a planned reel |
///
/// Every comparison is one surface against ANOTHER surface, never against `ClipHeartRate`. So a
/// surface that stops calling the resolver, or calls it with other options, fails here.
///
/// Two windows are compared, because the reel's is not the feed's:
/// - **the clip's own window** (lead-in 5 s, tail 30 s, whole-window numbers): feed, share, chip,
///   activity pages, Studio;
/// - **footage only** (no lead-in, no tail): feed, share, chip, Studio and the reel.
final class ClipHRCrossSurfaceTests: XCTestCase {

    // MARK: Fixtures

    struct Fixture {
        var name: String
        var series: [HRPoint]
        /// The row as a session holds it (offset, the length of the video the asset plays now,
        /// the map of a bake).
        var row: SessionMedia
        var maxHR: Double = 190
        var restHR: Double? = 60
        var hasData = true
    }

    /// Clips A, B and C of prompt 306's seed (never baked; "Save to original" with the first
    /// 20 s trimmed off; "Save to original" at 2×) over its ramp, a clip between sparse samples,
    /// and a clip filmed five minutes after the heart rate ended.
    static func fixtures() -> [Fixture] {
        let session = UUID()
        let seeded = StudioHRTimingSeed.mediaRows(sessionID: session)
        let ramp = StudioHRTimingSeed.rampSeries()
        func row(offset: Double, seconds: Double) -> SessionMedia {
            SessionMedia(sessionID: session, localIdentifier: "X-\(offset)", kind: .video,
                         offsetSec: offset, durationSec: seconds)
        }
        // The feed draws nothing over a clip marked baked (its tile is in the pixels), so the
        // rows are compared with the flag off: a row that carries a map is then read through it.
        for r in seeded { r.isBaked = false }
        return [
            Fixture(name: "never baked", series: ramp, row: seeded[0]),
            Fixture(name: "baked, start trimmed", series: ramp, row: seeded[1]),
            Fixture(name: "baked at 2x", series: ramp, row: seeded[2]),
            Fixture(name: "golden series", series: StudioGoldenScene.heartRate, row: row(offset: 8.3, seconds: 7.4),
                    maxHR: 185),
            Fixture(name: "sparse samples", series: ClipHRCharacterizationTests.sparse, row: row(offset: 55, seconds: 12)),
            Fixture(name: "no samples nearby", series: ramp, row: row(offset: 600, seconds: 10), hasData: false),
        ]
    }

    /// The moments compared: the steps the export's live text is cut at (`HROverlayValues.segments`).
    static let steps = [0, 7, 15, 30, 44, 59]
    static func fraction(_ step: Int) -> Double { Double(step) / 59 }

    /// What one surface shows. `live` is the exact bpm where the surface has one, `liveText` the
    /// number it prints.
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

    private func clip(_ f: Fixture, footageOnly: Bool) -> MediaInput {
        MediaInput.from(f.row, edit: footageOnly ? ClipStudioEdit(hrLeadSec: 0, hrTailSec: 0) : nil)
    }

    /// The feed: the payload the poster, the inline player and the viewers draw, read at the
    /// video times a player would report.
    private func feed(_ f: Fixture, footageOnly: Bool) -> (payload: ClipHROverlay.Payload, live: [Double?])? {
        let media = clip(f, footageOnly: footageOnly)
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

    private func share(_ f: Fixture, footageOnly: Bool) throws -> ClipSharePlan.Plan? {
        let media = clip(f, footageOnly: footageOnly)
        let payload = ClipHROverlay.make(clip: media, hrSeries: f.series, maxHR: f.maxHR, restHR: f.restHR,
                                         tile: scorebug(f.restHR))
        return ClipSharePlan.plan(clip: media, payload: payload, title: nil)
    }

    @MainActor
    private func studio(_ f: Fixture, footageOnly: Bool) async throws -> ClipHRStudioHarness {
        let h = try await ClipHRStudioHarness.make(
            series: f.series, offsetSec: f.row.offsetSec, durationSec: f.row.durationSec ?? 0,
            timeMap: f.row.bakeTimeMap, leadSec: footageOnly ? 0 : nil, tailSec: footageOnly ? 0 : nil,
            maxHR: f.maxHR, restHR: f.restHR)
        var config = try XCTUnwrap(h.vm.hrOverlay)
        config.tile = scorebug(f.restHR)
        h.vm.updateHROverlay(config)
        return h
    }

    /// The reel: the clip as the session reel's source makes it, planned at full length, and the
    /// scorebug's values as the preview and the export make them.
    private func reel(_ f: Fixture) -> (track: ReelHeartRate.Track, values: HROverlayValues, live: [Double?]) {
        let clips = [SessionHighlightInput.Clip.from(f.row)]
        let workout = SessionHighlightInput.makeWorkout(hrSeries: f.series, clips: clips,
                                                        duration: f.series.last?.t ?? 0, sport: nil, category: nil,
                                                        restHR: f.restHR, maxHR: f.maxHR)
        let item = workout.media[0]
        let highlight = Highlight(id: "h", mediaItemId: item.id, kind: .high, atOffset: item.startOffset,
                                  clipStart: item.startOffset, clipEnd: item.endOffset, score: 1)
        let plan = ReelPlanner(targetDuration: nil).plan(highlights: [highlight], media: workout.media)
        let track = ReelHeartRate.track(plan: plan, media: workout.media,
                                        series: workout.hr.map { HRPoint(t: $0.t, bpm: $0.bpm) },
                                        timeMaps: SessionHighlightInput.timeMaps(of: clips))
        let values = ReelHeartRate.values(track: track, durationSec: plan.totalDuration,
                                          maxHR: workout.maxBpm, restHR: workout.restBpm)
        let live = Self.steps.map { values.bpm(atFraction: Self.fraction($0)) }
        return (track, values, live)
    }

    // MARK: The tests

    private func assertSameLive(_ a: [Double?], _ b: [Double?], _ what: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.count, b.count, what, file: file, line: line)
        for (x, y) in zip(a, b) {
            guard let x, let y else {
                XCTAssertTrue(x == nil && y == nil, what, file: file, line: line)
                continue
            }
            XCTAssertEqual(x, y, accuracy: 1e-9, what, file: file, line: line)
        }
    }

    /// Feed, share, chip, activity pages and the Studio over the clip's own window.
    @MainActor
    func testEverySurfaceShowsTheSameNumbersOverTheClipsOwnWindow() async throws {
        for f in Self.fixtures() where f.hasData {
            let feed = try XCTUnwrap(feed(f, footageOnly: false), f.name)
            let reference = shown(feed.payload.values, live: feed.live)
            XCTAssertNotNil(reference.peak, f.name)
            XCTAssertNotNil(reference.average, f.name)

            // "Share with heart rate" burns the same tile.
            let plan = try XCTUnwrap(share(f, footageOnly: false), f.name)
            XCTAssertEqual(try shown(XCTUnwrap(plan.hr.tile)), reference, "share: \(f.name)")
            XCTAssertEqual(plan.hr.samples, feed.payload.values.samples, "share samples: \(f.name)")

            // The poster chip and the activity pages print the feed's PEAK and AVG.
            let chip = FeedMedia.clipHR(for: clip(f, footageOnly: false), hrSeries: f.series, maxHR: f.maxHR)
            XCTAssertEqual(chip.peakBpm.map(String.init), reference.peak, "chip peak: \(f.name)")
            XCTAssertEqual(chip.avgBpm.map(String.init), reference.average, "chip average: \(f.name)")
            let activity = ActivityMediaIndex.averageBPM(for: ActivityMediaInput.from(f.row), hrSeries: f.series)
            XCTAssertEqual(activity.map(String.init), reference.average, "activity average: \(f.name)")

            // The Studio: preview tile, sliders, export.
            let h = try await studio(f, footageOnly: false)
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

    /// Feed, share, chip, the Studio and the reel over the footage alone.
    @MainActor
    func testEverySurfaceShowsTheSameNumbersOverTheFootageAlone() async throws {
        for f in Self.fixtures() where f.hasData {
            let feed = try XCTUnwrap(feed(f, footageOnly: true), f.name)
            let reference = shown(feed.payload.values, live: feed.live)

            let plan = try XCTUnwrap(share(f, footageOnly: true), f.name)
            XCTAssertEqual(try shown(XCTUnwrap(plan.hr.tile)), reference, "share: \(f.name)")

            let chip = FeedMedia.clipHR(for: clip(f, footageOnly: true), hrSeries: f.series, maxHR: f.maxHR)
            XCTAssertEqual(chip.peakBpm.map(String.init), reference.peak, "chip peak: \(f.name)")
            XCTAssertEqual(chip.avgBpm.map(String.init), reference.average, "chip average: \(f.name)")

            let h = try await studio(f, footageOnly: true)
            let total = h.vm.totalDuration
            let previewLive = Self.steps.map { h.preview(at: Self.fraction($0) * total).bpm }
            assertSameLive(previewLive, feed.live, "studio preview live: \(f.name)")
            XCTAssertEqual(shown(h.preview(at: 0).values, live: previewLive), reference, "studio preview: \(f.name)")
            let placed = try XCTUnwrap(h.exported(), f.name)
            XCTAssertEqual(try shown(XCTUnwrap(placed.tile)), reference, "studio export: \(f.name)")
            withExtendedLifetime(h.container) {}

            // The reel: the same bpm at the same moments of the clip, the same peak and average.
            let reel = reel(f)
            XCTAssertTrue(reel.track.hasData, f.name)
            assertSameLive(reel.live, feed.live, "reel live: \(f.name)")
            XCTAssertEqual(shown(reel.values, live: reel.live), reference, "reel: \(f.name)")
            let burned = try XCTUnwrap(reel.values.resolveTile(scorebug(f.restHR)), f.name)
            XCTAssertEqual(try shown(burned), reference, "reel export tile: \(f.name)")
        }
    }

    /// A clip with no heart rate near it shows none anywhere: no overlay, a raw share, an empty
    /// chip, no average, no Studio tile in the export, no reel scorebug.
    @MainActor
    func testAClipWithNoSamplesNearbyShowsNoHeartRateAnywhere() async throws {
        let f = try XCTUnwrap(Self.fixtures().first { !$0.hasData })
        for footageOnly in [false, true] {
            let media = clip(f, footageOnly: footageOnly)
            XCTAssertNil(feed(f, footageOnly: footageOnly))
            XCTAssertNil(try share(f, footageOnly: footageOnly))
            XCTAssertEqual(ClipSharePlan.offer(for: media, payload: nil), .raw)
            XCTAssertEqual(FeedMedia.clipHR(for: media, hrSeries: f.series, maxHR: f.maxHR),
                           MediaClipHR(peakBpm: nil, avgBpm: nil, zoneRaw: nil))
            let h = try await studio(f, footageOnly: footageOnly)
            XCTAssertNil(h.exported())
            let preview = h.preview(at: 1)
            XCTAssertNil(preview.bpm)
            XCTAssertTrue(preview.values.samples.isEmpty)
            XCTAssertNil(preview.values.staticValue(.avgHR, fallbackHex: "#FFFFFF"))
            withExtendedLifetime(h.container) {}
        }
        XCTAssertNil(ActivityMediaIndex.averageBPM(for: ActivityMediaInput.from(f.row), hrSeries: f.series))
        let reel = reel(f)
        XCTAssertFalse(reel.track.hasData)
        XCTAssertTrue(reel.track.samples.isEmpty, "the reel maker draws no scorebug without a track")
        XCTAssertNil(reel.values.staticValue(.avgHR, fallbackHex: "#FFFFFF"))
    }

    /// The numbers themselves, so the agreement above is agreement on the right thing. The ramp
    /// is `bpm = 60 + seconds / 2`: a reading names the second it came from.
    func testTheNumbersAreTheOnesTheClipWasFilmedAt() throws {
        let all = Self.fixtures()
        // Never baked, filmed 60…70 s: 90 → 95 bpm.
        var feed = try XCTUnwrap(feed(all[0], footageOnly: true))
        XCTAssertEqual(try XCTUnwrap(feed.live.first ?? nil), 90, accuracy: 1.0)
        XCTAssertEqual(try XCTUnwrap(feed.live.last ?? nil), 95, accuracy: 1.0)
        XCTAssertEqual(feed.payload.values.staticValue(.maxHR, fallbackHex: "")?.value, "95")
        // Baked with the first 20 s trimmed off a recording that began at 200 s: 220…230 s.
        feed = try XCTUnwrap(self.feed(all[1], footageOnly: true))
        XCTAssertEqual(try XCTUnwrap(feed.live.first ?? nil), 170, accuracy: 1.0)
        XCTAssertEqual(try XCTUnwrap(feed.live.last ?? nil), 175, accuracy: 1.0)
        // Baked at 2× from 120 s: its 10 s of video are 120…140 s.
        feed = try XCTUnwrap(self.feed(all[2], footageOnly: true))
        XCTAssertEqual(try XCTUnwrap(feed.live.first ?? nil), 120, accuracy: 1.0)
        XCTAssertEqual(try XCTUnwrap(feed.live.last ?? nil), 130, accuracy: 1.0)
        XCTAssertEqual(feed.payload.values.staticValue(.maxHR, fallbackHex: "")?.value, "130")
    }

    /// A clip marked baked carries its tile in the pixels: the feed draws nothing and the share
    /// is raw, as before. The chip and the activity average still read it, through its map.
    func testABakedClipStillStandsDownInTheFeed() throws {
        let rows = StudioHRTimingSeed.mediaRows(sessionID: UUID())
        let ramp = StudioHRTimingSeed.rampSeries()
        let baked = MediaInput.from(rows[1])
        XCTAssertTrue(baked.isBaked)
        XCTAssertNil(ClipHROverlay.make(clip: baked, hrSeries: ramp, maxHR: 190, restHR: 60))
        XCTAssertEqual(ClipSharePlan.offer(for: baked, payload: nil), .raw)
        let chip = FeedMedia.clipHR(for: baked, hrSeries: ramp, maxHR: 190)
        // 215…260 s of the ramp (5 s before the kept footage, 30 s after): peak 190.
        XCTAssertEqual(chip.peakBpm, 190)
        XCTAssertEqual(ActivityMediaIndex.averageBPM(for: ActivityMediaInput.from(rows[1]), hrSeries: ramp),
                       chip.avgBpm)
    }

    // MARK: Reels

    /// A reel of two clips: over each clip the scorebug reads that clip's heart rate, and the
    /// whole reel's peak and average are over the two clips' footage.
    func testAReelOfTwoClipsReadsEachClipsOwnHeartRate() throws {
        let rows = StudioHRTimingSeed.mediaRows(sessionID: UUID())
        let ramp = StudioHRTimingSeed.rampSeries()
        let clips = [rows[0], rows[2]].map(SessionHighlightInput.Clip.from)          // A (60…70 s), C at 2× (120…140 s)
        let workout = SessionHighlightInput.makeWorkout(hrSeries: ramp, clips: clips, duration: 300,
                                                        sport: nil, category: nil, restHR: 60, maxHR: 190)
        let highlights = workout.media.enumerated().map { i, m in
            Highlight(id: "h\(i)", mediaItemId: m.id, kind: .high, atOffset: m.startOffset,
                      clipStart: m.startOffset, clipEnd: m.endOffset, score: 1)
        }
        let plan = ReelPlanner(targetDuration: nil).plan(highlights: highlights, media: workout.media)
        XCTAssertEqual(plan.totalDuration, 20)
        let track = ReelHeartRate.track(plan: plan, media: workout.media, series: ramp,
                                        timeMaps: SessionHighlightInput.timeMaps(of: clips))
        let values = ReelHeartRate.values(track: track, durationSec: plan.totalDuration, maxHR: 190, restHR: 60)
        XCTAssertTrue(track.segmentsWithoutData.isEmpty)
        // 5 s into the reel is 5 s into A: session second 65.
        XCTAssertEqual(try XCTUnwrap(values.bpm(atFraction: 5.0 / 20)), 92.5, accuracy: 1.0)
        // 15 s into the reel is 5 s into C, which runs at 2×: session second 130.
        XCTAssertEqual(try XCTUnwrap(values.bpm(atFraction: 15.0 / 20)), 125, accuracy: 1.0)
        XCTAssertEqual(values.staticValue(.maxHR, fallbackHex: "")?.value, "130")
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

    /// A clip with no heart rate inside a reel: the other clip's readings are where its frames
    /// are, and the line runs flat across the clip without any.
    func testAReelClipWithoutHeartRateLeavesTheOthersInPlace() throws {
        let ramp = StudioHRTimingSeed.rampSeries()
        let session = UUID()
        let far = SessionMedia(sessionID: session, localIdentifier: "FAR", kind: .video, offsetSec: 900, durationSec: 10)
        let near = SessionMedia(sessionID: session, localIdentifier: "NEAR", kind: .video, offsetSec: 60, durationSec: 10)
        let clips = [near, far].map(SessionHighlightInput.Clip.from)
        let workout = SessionHighlightInput.makeWorkout(hrSeries: ramp, clips: clips, duration: 1000,
                                                        sport: nil, category: nil)
        let highlights = workout.media.enumerated().map { i, m in
            Highlight(id: "h\(i)", mediaItemId: m.id, kind: .high, atOffset: m.startOffset,
                      clipStart: m.startOffset, clipEnd: m.endOffset, score: 1)
        }
        let plan = ReelPlanner(targetDuration: nil).plan(highlights: highlights, media: workout.media)
        let track = ReelHeartRate.track(plan: plan, media: workout.media, series: ramp)
        XCTAssertEqual(track.segmentsWithoutData, ["h1"])
        XCTAssertEqual(track.samples.last?.t, 20)
        let values = ReelHeartRate.values(track: track, durationSec: 20, maxHR: nil, restHR: nil)
        XCTAssertEqual(try XCTUnwrap(values.bpm(atFraction: 0.25)), 92.5, accuracy: 1.0)
        XCTAssertEqual(try XCTUnwrap(values.bpm(atFraction: 0.9)), 95, accuracy: 0.6)   // held
    }
}
