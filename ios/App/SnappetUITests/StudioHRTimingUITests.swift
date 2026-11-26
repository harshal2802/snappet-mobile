import XCTest

/// Prompt 306: heart-rate timing in the RUNNING Studio, through the real editor.
///
/// `-uiTestSeedStudioHRTiming` (`StudioHRTimingSeed`) seeds a session whose heart rate is the ramp
/// `bpm = 60 + seconds / 2` and three clips that all play one generated 10 s video:
/// - A, never baked, filmed from second 60;
/// - B, saved to its original with the first 20 s trimmed off, recording filmed from second 200;
/// - C, saved to its original at 2×, recording filmed from second 120.
///
/// The test opens "Edit this clip" from the session for each clip, switches the heart-rate
/// tile on through the HR tool, moves the playhead by dragging the timeline, and reads the bpm
/// of the preview tile. Because the ramp never repeats a value, the bpm names the second of the session the
/// tile is reading. For clip B it also exports through the Export menu and checks the heart rate
/// the export was given, and what the app's own Photos probe answered for the seeded baked rows.
///
/// The playhead and the unrounded bpm come from invisible elements that exist only on a launch
/// with the seed argument (`StudioHRTimingDebugView`); the number the tile itself shows is read
/// from the tile and must be that bpm rounded.
final class StudioHRTimingUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-uiTestSeedStudioHRTiming"]
        app.launchOnTestStore()
    }

    // MARK: The seed, restated (the test target cannot import the app)

    private let sessionName = "HR Timing Check"
    private func ramp(_ seconds: Double) -> Double { 60 + seconds / 2 }

    private struct SeededClip {
        let name: String
        /// The thumbnail's offset badge: the row's `offsetSec`.
        let offset: Int
        /// When the frame at rendition time `t` was filmed, in seconds from the session's start.
        let capture: (Double) -> Double
    }
    private let clipA = SeededClip(name: "A", offset: 60) { 60 + $0 }
    private let clipB = SeededClip(name: "B", offset: 200) { 200 + 20 + $0 }
    private let clipC = SeededClip(name: "C", offset: 120) { 120 + 2 * $0 }

    /// Half a second of the ramp. The shifts looked for are 20 s (B) and `t` itself (C).
    private let bpmTolerance = 0.25

    // MARK: Tests

    /// One launch for the three clips (a launch and the way to the session take most of a
    /// minute). The session has one Studio project, so the tile switched on in clip A's editor is
    /// the tile clips B and C show: it is added once, through the HR tool, and must be on the
    /// preview of each clip that is opened after.
    func testHeartRateTimingOnUnbakedAndBakedClips() throws {
        try openSession()
        try unbakedClipReadsOffsetPlusTime()
        try clipBakedWithAStartTrimReadsTwentySecondsLaterAndExports()
        try clipBakedAtDoubleSpeedReadsTwoSecondsPerSecond()
    }

    private func unbakedClipReadsOffsetPlusTime() throws {
        try openStudio(for: clipA)
        XCTAssertEqual(debug("previewBPM"), "none", "a new project has no heart-rate tile")
        addHeartRateTile()
        let readings = try readAtStartMiddleAndLate(clipA)
        report(clipA, readings)
        closeStudio()
    }

    private func clipBakedWithAStartTrimReadsTwentySecondsLaterAndExports() throws {
        try openStudio(for: clipB)
        let readings = try readAtStartMiddleAndLate(clipB)
        report(clipB, readings)
        // Not the row's offset plus the time: that is 20 s, 10 bpm, too early.
        for r in readings {
            XCTAssertEqual(r.bpm - ramp(200 + r.time), 10, accuracy: bpmTolerance,
                           "clip B at \(r.time) s must read 20 s later than offset + time")
        }

        // Export as new video, through the menu. Two rows of the session are baked, so the
        // export first asks Photos about them (the "checking" phase of prompt 305).
        let before = try debugReport()
        XCTAssertTrue(app.buttons["studioExport"].isEnabled, "Export is on once the preview is ready")
        app.buttons["studioExport"].tap()
        let exportNew = app.buttons["studioExportNew"].exists
            ? app.buttons["studioExportNew"] : app.buttons["Export as new video"]
        XCTAssertTrue(exportNew.waitForExistence(timeout: 5), "the Export menu offers Export as new video")
        exportNew.tap()

        let exportState = any("studioDebug.export")
        let finished = expectation(for: NSPredicate(format: "label == 'exported' OR label BEGINSWITH 'failed'"),
                                   evaluatedWith: exportState)
        wait(for: [finished], timeout: 90)
        XCTAssertEqual(exportState.label, "exported", "the export finishes")
        XCTAssertEqual(debug("phase"), "finished")
        XCTAssertEqual(app.alerts.count, 0, "no failure and no 'reverted in Photos' message")
        snap("B-exported")

        // What the export was given.
        let after = try debugReport()
        XCTAssertEqual(after.exports, before.exports + 1, "one render")
        XCTAssertEqual(after.lastExport.count, 1, "one clip, one heart-rate tile")
        let placed = try XCTUnwrap(after.lastExport.first)
        XCTAssertTrue(placed.hasTile)
        XCTAssertEqual(placed.startSec, 0, accuracy: 0.001)
        XCTAssertEqual(placed.durationSec, 10, accuracy: 0.05)
        // The window is the footage with the default 5 s before and 30 s after it. The footage
        // was filmed from second 220 to 230, so the window runs from 215 to 260.
        let first = try XCTUnwrap(placed.samples.first), last = try XCTUnwrap(placed.samples.last)
        XCTAssertEqual(first[0], 0, accuracy: 0.001)
        XCTAssertEqual(first[1], ramp(215), accuracy: 0.01, "first bpm of the export's window")
        XCTAssertEqual(last[0], 45, accuracy: 0.001)
        XCTAssertEqual(last[1], ramp(260), accuracy: 0.01, "last bpm of the export's window")
        XCTAssertEqual(try bpm(in: placed.samples, at: 5), ramp(220), accuracy: 0.01, "first frame")
        XCTAssertEqual(try bpm(in: placed.samples, at: 15), ramp(230), accuracy: 0.01, "last frame")
        // Through the row's offset alone the window would have been 195…240: 10 bpm lower.
        XCTAssertEqual(first[1] - ramp(195), 10, accuracy: 0.01)
        XCTAssertEqual(last[1] - ramp(240), 10, accuracy: 0.01)

        // The check before the export: Photos was asked again, answered at once, found nothing.
        XCTAssertGreaterThan(after.checks.count, before.checks.count, "the export asked Photos first")
        for check in after.checks {
            XCTAssertEqual(check.rows, 2, "the two baked rows")
            XCTAssertTrue(check.answered, "the probe answers on the simulator")
            XCTAssertEqual(check.reverted, 0, "nothing is taken for reverted")
            XCTAssertLessThan(check.seconds, 4, "well inside the 4 s wait")
        }
        // What the app's own probe says about a seeded row: Photos does not know the asset.
        XCTAssertEqual(Set(after.probes.map(\.localIdentifier)),
                       ["uitest-generated://studio-hr-timing/b", "uitest-generated://studio-hr-timing/c"])
        for probe in after.probes {
            XCTAssertNil(probe.hasEditedRendition, "\(probe.localIdentifier): asset not found, so no answer")
            XCTAssertNil(probe.currentDuration, probe.localIdentifier)
        }
        print("StudioHRTiming export: \(placed.samples.count) samples, first \(first), last \(last); "
              + "checks \(after.checks); probes \(after.probes)")

        // The share sheet is the finished state's screen. Close it; the editor is ready again
        // and the clip still reads through its map (nothing cleared it).
        closeShareSheet()
        let idle = expectation(for: NSPredicate(format: "label == 'idle'"), evaluatedWith: exportState)
        wait(for: [idle], timeout: 15)
        XCTAssertEqual(debug("phase"), "ready")
        let again = try reading()
        XCTAssertEqual(again.bpm, ramp(clipB.capture(again.time)), accuracy: bpmTolerance,
                       "after the export clip B still reads through its map")
        closeStudio()
    }

    private func clipBakedAtDoubleSpeedReadsTwoSecondsPerSecond() throws {
        try openStudio(for: clipC)
        let readings = try readAtStartMiddleAndLate(clipC)
        report(clipC, readings)
        // Not the row's offset plus the time: by the last reading that is seconds too early.
        let late = try XCTUnwrap(readings.last)
        XCTAssertEqual(late.bpm - ramp(120 + late.time), late.time / 2, accuracy: bpmTolerance)
        XCTAssertGreaterThan(late.bpm - ramp(120 + late.time), 2.5,
                             "clip C at \(late.time) s must read \(late.time) s later than offset + time")
        closeStudio()
    }

    // MARK: Readings

    private struct Reading {
        let time: Double
        let bpm: Double
        let shown: String
    }

    /// The playhead time, the preview tile's bpm at it, and the number the tile shows.
    private func reading() throws -> Reading {
        let bpmElement = any("studioDebug.previewBPM")
        let has = expectation(for: NSPredicate(format: "label != 'none'"), evaluatedWith: bpmElement)
        wait(for: [has], timeout: 10)
        // The playhead is paused; read it on both sides of the bpm so the two belong together.
        var time = try XCTUnwrap(Double(debug("playhead")))
        var bpm = try XCTUnwrap(Double(bpmElement.label))
        for _ in 0 ..< 5 {
            let timeAfter = try XCTUnwrap(Double(debug("playhead")))
            if timeAfter == time { break }
            time = timeAfter
            bpm = try XCTUnwrap(Double(bpmElement.label))
        }
        // The tile itself: its big number (the text before the "BPM" unit) is that bpm, rounded
        // as the tile rounds it. (The tile's texts carry the preview's identifier.)
        let texts = tileTexts()
        let unit = try XCTUnwrap(texts.firstIndex(of: "BPM"), "the tile shows a bpm; it shows \(texts)")
        let shown = try XCTUnwrap(unit > 0 ? texts[unit - 1] : nil)
        let accepted = Set([bpm.rounded(), (bpm - 0.011).rounded(), (bpm + 0.011).rounded()].map { String(Int($0)) })
        XCTAssertTrue(accepted.contains(shown), "the tile shows \(shown) at \(time) s for \(bpm) bpm")
        return Reading(time: time, bpm: bpm, shown: shown)
    }

    /// Read at the start, then drag the timeline twice (about 4 s each) and read again. Each
    /// reading must be the ramp at the clip's capture time of the playhead.
    private func readAtStartMiddleAndLate(_ clip: SeededClip) throws -> [Reading] {
        XCTAssertEqual(try XCTUnwrap(Double(debug("total"))), 10, accuracy: 0.05, "the clip is 10 s long")
        var out: [Reading] = []
        let start = try reading()
        XCTAssertEqual(start.time, 0, accuracy: 0.001, "the Studio opens at the start")
        out.append(start)
        for (index, range) in [(2.5 ... 5.5), (6.0 ... 9.5)].enumerated() {
            scrubForward(points: 200)
            let r = try reading()
            XCTAssertTrue(range.contains(r.time), "drag \(index + 1) left the playhead at \(r.time) s")
            out.append(r)
        }
        for r in out {
            XCTAssertEqual(r.bpm, ramp(clip.capture(r.time)), accuracy: bpmTolerance,
                           "clip \(clip.name) at \(r.time) s reads the session at \(clip.capture(r.time)) s")
        }
        snap("\(clip.name)-read")
        return out
    }

    private func report(_ clip: SeededClip, _ readings: [Reading]) {
        for r in readings {
            print(String(format: "StudioHRTiming clip %@ t=%.3f s: tile shows %@, bpm %.2f, expected %.2f (capture %.3f s)",
                         clip.name, r.time, r.shown, r.bpm, ramp(clip.capture(r.time)), clip.capture(r.time)))
        }
    }

    /// Drag the timeline to the left: the playhead moves forward by `points / 50` seconds.
    private func scrubForward(points: CGFloat) {
        // The playhead line stays in the middle of the timeline (everything else in it moves
        // with the scrub). The drag is made in the empty lane under the clip, 40 points lower:
        // on the simulator a drag that starts on the selected clip or in the ruler does not scrub.
        let playhead = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Playhead'")).firstMatch
        XCTAssertTrue(playhead.waitForExistence(timeout: 5))
        let from = playhead.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .withOffset(CGVector(dx: points / 2, dy: 40))
        let to = from.withOffset(CGVector(dx: -points, dy: 0))
        from.press(forDuration: 0.15, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.4)
        usleep(400_000)
    }

    /// The texts drawn over the preview, in the tile's own order.
    private func tileTexts() -> [String] {
        app.staticTexts.matching(identifier: "studioPreview").allElementsBoundByIndex.map { $0.label }
    }

    // MARK: Getting there

    private func any(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func debug(_ name: String) -> String { any("studioDebug.\(name)").label }

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }

    /// App Library → Gym Tracker → History → the seeded session.
    private func openSession() throws {
        XCTAssertTrue(app.tabBars.buttons["Apps"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Apps"].tap()
        let card = app.buttons["moduleCard.workout-log"]
        XCTAssertTrue(card.waitForExistence(timeout: 8))
        card.tap()
        let history = app.segmentedControls.buttons["History"]
        XCTAssertTrue(history.waitForExistence(timeout: 8))
        history.tap()

        let row = app.staticTexts[sessionName]
        XCTAssertTrue(row.waitForExistence(timeout: 8), "the seeded session is in History")
        row.tap()
    }

    private func closeStudio() {
        app.buttons["studioClose"].tap()
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["studioClose"])
        wait(for: [gone], timeout: 10)
    }

    /// The clip's thumbnail in the session opens the Studio scoped to that clip ("Edit this
    /// clip"), as in the walkthrough.
    private func openStudio(for clip: SeededClip) throws {
        let thumb = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == 'mediaThumb' AND label == %@", "Video at +\(clip.offset)s")).firstMatch
        for _ in 0 ..< 8 where !(thumb.exists && thumb.isHittable) { app.swipeUp() }
        XCTAssertTrue(thumb.waitForExistence(timeout: 5), "clip \(clip.name)'s thumbnail is in the session")
        thumb.tap()
        XCTAssertTrue(app.buttons["studioClose"].waitForExistence(timeout: 10), "the clip opens in the Studio")

        // The preview is built from the generated video: the editor leaves "loading".
        let ready = expectation(for: NSPredicate(format: "label == 'ready'"), evaluatedWith: any("studioDebug.phase"))
        wait(for: [ready], timeout: 45)
        XCTAssertFalse(app.staticTexts["Preview renders on a device"].exists, "the Studio has a real preview")
    }

    /// The HR tool is at the far end of the action bar: scroll to it, switch the tile on, close
    /// the sheet.
    private func addHeartRateTile() {
        let bar = app.scrollViews["studioActionBar"]
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        let tool = app.buttons["studioHRTool"]
        for _ in 0 ..< 3 { bar.swipeLeft() }
        XCTAssertTrue(tool.waitForExistence(timeout: 5))
        XCTAssertTrue(tool.isEnabled, "the session has heart rate")
        tool.tap()
        let enable = app.switches["hrTileEnable"]
        XCTAssertTrue(enable.waitForExistence(timeout: 5))
        XCTAssertEqual(enable.value as? String, "0", "the tile is off in a new project")
        enable.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(enable.value as? String, "1")
        let title = app.staticTexts["Heart-rate tile"]
        if title.exists {
            let start = title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 480)))
        } else {
            app.swipeDown()
        }
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: enable)
        wait(for: [gone], timeout: 5)
        let shown = expectation(for: NSPredicate(format: "label != 'none'"),
                                evaluatedWith: any("studioDebug.previewBPM"))
        wait(for: [shown], timeout: 5)
        XCTAssertTrue(tileTexts().contains("BPM"), "the tile is on the preview")
    }

    private func closeShareSheet() {
        let sheet = app.otherElements["ActivityListView"]
        _ = sheet.waitForExistence(timeout: 8)
        for name in ["Close", "header.closeButton"] where app.buttons[name].exists {
            app.buttons[name].tap()
            return
        }
        // No close button found: drag the sheet down from its top.
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        from.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
    }

    // MARK: The app's record of what it did

    private struct PlacedHR: Decodable {
        let startSec: Double
        let durationSec: Double
        let samples: [[Double]]
        let hasTile: Bool
    }
    private struct Probe: Decodable {
        let localIdentifier: String
        let hasEditedRendition: Bool?
        let currentDuration: Double?
    }
    private struct Check: Decodable {
        let rows: Int
        let answered: Bool
        let reverted: Int
        let seconds: Double
    }
    private struct Report: Decodable {
        let exports: Int
        let lastExport: [PlacedHR]
        let probes: [Probe]
        let checks: [Check]
    }

    private func debugReport() throws -> Report {
        try JSONDecoder().decode(Report.self, from: Data(debug("report").utf8))
    }

    /// The bpm at window time `t`, between the two samples around it.
    private func bpm(in samples: [[Double]], at t: Double) throws -> Double {
        let after = try XCTUnwrap(samples.firstIndex { $0[0] >= t })
        guard after > 0 else { return samples[0][1] }
        let a = samples[after - 1], b = samples[after]
        return a[1] + (b[1] - a[1]) * (t - a[0]) / (b[0] - a[0])
    }
}
