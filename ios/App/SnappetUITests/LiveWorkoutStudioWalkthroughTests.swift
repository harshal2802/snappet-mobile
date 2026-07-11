import XCTest

/// A chronological, screenshot-capturing walkthrough of the **Live Workout Capture + Video
/// Studio** initiative (A1–A4 live capture + B1–B5 video studio). It launches with
/// `-uiTestSeedStudioDemo`, which seeds a **completed** `WorkoutSession` carrying a synthetic
/// `hrSeries` (a fresh in-memory store, see `SnappetApp` / `StudioDemoSeed`), so the headline
/// B2 enriched summary (HR chart + avg/max/min + time-in-zone) actually RENDERS on the
/// simulator — which otherwise has no live HR source.
///
/// Each step captures a zero-padded, ordered screenshot via `snap("NN-name")`
/// (`XCTAttachment`, `.keepAlways`); the `NN` carries the chronological order so the frames can
/// be stitched into a video. Extract with `xcrun xcresulttool export attachments`.
///
/// What renders on the simulator vs. what is device-only (gracefully skipped, with a snapshot of
/// the real state):
///  - RENDERS: suite home, app library, dashboard, routines, routine detail / Start bar, the
///    live player (A2 overall-timer header + A4 live-metrics overlay no-source state), the rest
///    screen, finish, History, the seeded session's **B2 HR summary**, the **media gallery grouped
///    by set + a General bucket** (seeded synthetic clips) with the per-clip "Move to…"
///    reassignment menu + the now-enabled "Generate highlight" entry, Settings, the A3 heart-rate
///    source picker sheet.
///  - DEVICE-ONLY (not shown here): a real live-HR overlay value, real media thumbnails (the
///    seeded clips render their placeholder — the grouping/reassignment UI is model-driven), the
///    multi-clip Studio's actual preview/export render (the canvas shows its device-only
///    placeholder on the sim — its timeline + edits are exercised model-driven in 11c/11g), an
///    actual generated highlight reel — they need a paired Apple Watch / BLE band + a real Photos
///    video. Expected; the seed showcases the HR summary + the live UI.
final class LiveWorkoutStudioWalkthroughTests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments += ["-uiTestSeedStudioDemo"]
        app.launch()
    }

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }

    private func section(_ t: String) -> XCUIElement { app.segmentedControls.buttons[t] }

    /// The seeded demo routine/session name (must match `StudioDemoSeed.routineName`).
    private let demoName = "Studio Demo — Full Body"

    func testStudioWalkthrough() {
        // 1 — Suite home (dashboard).
        snap("01-suite-home")

        // 2 — App Library.
        XCTAssertTrue(app.tabBars.buttons["Apps"].waitForExistence(timeout: 6))
        app.tabBars.buttons["Apps"].tap()
        snap("02-app-library")

        // 3 — Enter WorkoutTracker → dashboard.
        XCTAssertTrue(app.buttons["moduleCard.workout-log"].waitForExistence(timeout: 6),
                      "the workout card should be in the App Library")
        app.buttons["moduleCard.workout-log"].tap()
        XCTAssertTrue(section("Routines").waitForExistence(timeout: 6),
                      "the workout dashboard's section picker should appear")
        sleep(1); snap("03-workout-dashboard")

        // 4 — Routines.
        section("Routines").tap(); sleep(1); snap("04-routines")

        // 5 — A routine's detail (with the Start bar). Use a starter routine so the prescription
        // + Start bar render (the seeded session is a completed one, surfaced later in History).
        let rRow = app.buttons.matching(identifier: "routineRow").firstMatch
        if rRow.waitForExistence(timeout: 6) {
            rRow.tap()
            if app.buttons["Start Workout"].waitForExistence(timeout: 6) {
                snap("05-routine-detail")

                // 6 — Start the workout → the live player: A2 overall-timer header + A4
                // live-metrics overlay (no-source state on the sim).
                app.buttons["Start Workout"].tap(); sleep(2); snap("06-player")
                XCTAssertTrue(app.staticTexts["overallWorkoutTimer"].waitForExistence(timeout: 5)
                    || app.otherElements["overallWorkoutTimer"].waitForExistence(timeout: 1),
                    "the player should show the A2 overall workout timer")
                XCTAssertTrue(app.otherElements["liveMetricsOverlay"].waitForExistence(timeout: 5)
                    || app.staticTexts["liveMetricsOverlay"].waitForExistence(timeout: 1),
                    "the player should show the A4 live-metrics overlay (no-source state)")

                // 6b — M3: the per-exercise media-capture affordance is reachable in the pager player
                // (the PHPicker/record itself is device-only; the affordance renders anywhere).
                let attach = app.buttons["freeform.page.record"]
                if !attach.exists { app.swipeUp() }
                XCTAssertTrue(attach.waitForExistence(timeout: 3),
                    "the player should offer the per-exercise media-capture affordance")
                snap("06b-attach-to-set")

                // 7 — Drive a couple of sets to reach the rest screen (overall timer + overlay
                // + rest countdown), then finish.
                driveToRestThenFinish()
                sleep(2)

                // 8 — After finish (lands on the dashboard).
                snap("08-after-finish")
            } else {
                snap("NOTREACHED-05-routine-detail")
            }
        } else {
            snap("NOTREACHED-04-routine-row")
        }

        // 9 — History (now also holds the seeded completed demo session).
        section("History").tap(); sleep(1); snap("09-history")
        XCTAssertTrue(app.staticTexts[demoName].waitForExistence(timeout: 6)
            || app.cells.firstMatch.waitForExistence(timeout: 2),
            "the seeded demo session should appear in History")

        // 10 — Open the seeded completed session → its B2 enriched summary (HR chart +
        // avg/max/min + time-in-zone). This is the headline screen: open the DEMO session
        // specifically (its synthetic hrSeries is what makes the HR section render).
        if openDemoSession() {
            // The HR chart renders only when the session has a non-empty hrSeries (the seed's job).
            XCTAssertTrue(app.otherElements["hrChart"].waitForExistence(timeout: 6)
                || app.staticTexts["Heart rate"].waitForExistence(timeout: 2),
                "the seeded session's summary should render the B2 HR chart / Heart rate section")
            sleep(1); snap("10-session-summary-hr")

            // 11 — The tagged-media gallery, now grouped **by set** with a **General** bucket
            // (seeded synthetic clips — thumbnails are placeholders on the sim, but the per-set
            // grouping + reassignment UI is model-driven and renders fully). Scroll it into view.
            let summary = app.collectionViews.firstMatch.exists
                ? app.collectionViews.firstMatch : app.tables.firstMatch
            if app.staticTexts["Media from this workout"].waitForExistence(timeout: 3) == false {
                summary.swipeUp(); summary.swipeUp()
            }
            // A per-set group header (e.g. "… · Set 1") and the General bucket should be present.
            let setHeader = app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "Set 1")).firstMatch
            let generalHeader = app.staticTexts["General"]
            for _ in 0..<3 where !(setHeader.exists && generalHeader.exists) { summary.swipeUp() }
            XCTAssertTrue(setHeader.waitForExistence(timeout: 3) || generalHeader.exists,
                          "the gallery should group clips by set and/or a General bucket")
            snap("11-media-grouped-by-set")
            // The Generate-highlight button now enables (the seed includes videos).
            _ = app.buttons["generateHighlight"].waitForExistence(timeout: 3)

            // 11b — The per-clip "Move to…" reassignment menu (fix a wrong auto-guess / pin to
            // General). Long-press a media thumbnail to surface the context menu. The thumb is an
            // accessibility element labelled "<kind> at +Ns"; it surfaces as an otherElement /
            // image / cell, so try each. Best-effort: snap the menu if it opens, else snap the
            // gallery state (never flakes the run).
            // A SwiftUI context menu via long-press is flaky in XCUITest, so retry a few times,
            // pressing the thumb's centre coordinate (more reliable than element.press) and
            // nudging the scroll between attempts to re-seat the layout.
            var openedMenu = false
            for attempt in 0..<3 {
                guard let thumb = firstMediaThumb() else { break }
                thumb.press(forDuration: 2.0)
                if app.buttons["Move to…"].waitForExistence(timeout: 3) { openedMenu = true; break }
                thumb.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 2.0)
                if app.buttons["Move to…"].waitForExistence(timeout: 3) { openedMenu = true; break }
                if attempt < 2 { summary.swipeUp() }
            }
            if openedMenu {
                snap("11b-reassign-menu")
                // Dismiss the context menu WITHOUT `app.tap()`: the menu anchors near the pressed
                // thumb, so a centre-of-screen tap can land ON a menu item — observed expanding
                // "Move to…" into its submenu, whose dimming overlay then swallowed every later
                // step (the back-pop never fired and the section picker was unreachable). Tap the
                // nav-bar title region instead — always above/outside the menu — and wait for the
                // menu to actually close before moving on.
                let menuItem = app.buttons["Move to…"]
                var dismissTries = 0
                while menuItem.exists && dismissTries < 3 {
                    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.07)).tap()
                    let gone = XCTNSPredicateExpectation(
                        predicate: NSPredicate(format: "exists == false"), object: menuItem)
                    _ = XCTWaiter().wait(for: [gone], timeout: 3)
                    dismissTries += 1
                }
            } else {
                snap("11b-reassign-menu-NOTSHOWN")
            }

            // 11g — tapping a VIDEO opens the CapCut-style multi-clip Studio *scoped to that clip*
            // (Kilter parity; replaces the old single-clip "Edit Clip" sheet). It opens on the first
            // tap and STAYS open — the Studio's close ("studioClose") must still be present a moment
            // after it appears.
            if let videoThumb = firstVideoMediaThumb() {
                videoThumb.tap()
                // Hard assertion (not best-effort): once a clip is tapped the scoped Studio MUST open —
                // this guards the parity rewire + the stable-host presentation (a section-hosted cover
                // would collapse on this first tap; see decisions.md). studioClose lives on the Studio's
                // custom top bar (it's a fullScreenCover, not a NavigationStack).
                XCTAssertTrue(app.buttons["studioClose"].waitForExistence(timeout: 8),
                              "tapping a clip must open the scoped Studio")
                usleep(900_000)
                XCTAssertTrue(app.buttons["studioClose"].exists,
                              "the scoped Studio must stay open on the first tap, not collapse")
                snap("11g-clip-studio")
                app.buttons["studioClose"].tap()
            }

            // 11c — The full multi-clip Studio (S1): open it over the session's video clips and
            // exercise the timeline + an edit (split) + undo. The preview render is device-only, so
            // on the sim the canvas shows its placeholder while the timeline + edits work on the
            // model. Best-effort (the editor is reachable only when the session has videos).
            // The "Edit in Video Studio" button (identifier "openStudio", relabelled by #74) is in
            // the actions section (above the grouped clips); steps
            // 11/11b scrolled DOWN to General, so scroll back UP (swipeDown) to bring it into view.
            let openStudio = app.buttons["openStudio"]
            for _ in 0..<5 where !openStudio.exists { summary.swipeDown() }
            if openStudio.waitForExistence(timeout: 3), openStudio.isEnabled {
                openStudio.tap()
                if app.buttons["studioExport"].waitForExistence(timeout: 6)
                    || app.navigationBars["Studio"].waitForExistence(timeout: 1) {
                    XCTAssertTrue(app.staticTexts["Preview renders on a device"].waitForExistence(timeout: 3)
                                  || app.otherElements["studioPreview"].exists,
                                  "the studio should show its preview canvas")
                    // The edits-style chrome (always present): transport, export-quality, action bar.
                    XCTAssertTrue(app.buttons["studioPlayPause"].waitForExistence(timeout: 3),
                                  "the studio transport (play/pause) should appear")
                    XCTAssertTrue(app.buttons["studioQuality"].exists, "the export-quality control should appear")
                    XCTAssertTrue(app.buttons["studioSplit"].waitForExistence(timeout: 3),
                                  "the studio action bar should appear")
                    snap("11c-studio")
                    // Best-effort: select the first clip strip and split at the playhead, then undo.
                    let clip = app.buttons["timelineClip"].firstMatch
                    if clip.waitForExistence(timeout: 2), clip.isHittable { clip.tap() }
                    if app.buttons["studioSplit"].isEnabled {
                        app.buttons["studioSplit"].tap()
                        XCTAssertTrue(app.buttons["studioUndo"].isEnabled, "undo enables after a split")
                        snap("11d-studio-edit")
                        app.buttons["studioUndo"].tap()    // undo the split
                    }
                    // Open a tool sheet from an on-screen action: "Speed" is near the start of the bar.
                    // (Deeper interactions on the scrolling action bar / clipped timeline are covered
                    // by the device verification checklist — they're flaky to drive on the sim.)
                    let speed = app.buttons["Speed"]
                    if speed.exists, speed.isHittable, app.buttons["studioSplit"].isEnabled {
                        speed.tap()
                        if app.staticTexts["Speed"].waitForExistence(timeout: 2) {
                            snap("11e-studio-tool-sheet")
                            app.swipeDown()   // dismiss the sheet
                        }
                    }
                    // 11f — The HR stat tile builder (the overlay redesign): open the HR tool, enable
                    // the tile, pick a design from the catalog, and toggle a metric off. The HR tool sits
                    // at the far end of the horizontally-scrolling action bar, so scroll it into view
                    // first (a fixed count — `isHittable` throws on an off-screen scroll element).
                    let bar = app.scrollViews["studioActionBar"]
                    let hrTool = app.buttons["studioHRTool"]
                    if bar.exists { for _ in 0..<5 { bar.swipeLeft() } }
                    if hrTool.exists, hrTool.isEnabled {
                        hrTool.tap()
                        let enable = app.switches["hrTileEnable"]
                        if enable.waitForExistence(timeout: 3) {
                            if (enable.value as? String) != "1" { enable.tap() }   // turn the tile on
                            // The design catalog (one button per template) appears once the tile is on.
                            XCTAssertTrue(app.buttons["studioTileTemplate.scorebug"].waitForExistence(timeout: 3),
                                          "the tile design catalog should appear when the HR tile is enabled")
                            snap("11f-hr-tile-builder")
                            let bento = app.buttons["studioTileTemplate.bento"]
                            if bento.waitForExistence(timeout: 2) { bento.tap() }
                            // Every metric is ON by default — toggling one off proves the per-metric control.
                            let zone = app.switches["studioTileMetric.zone"]
                            if zone.waitForExistence(timeout: 2) { zone.tap() }
                            snap("11g-hr-tile-bento")
                            // Dismiss with a long downward drag from the sheet's (non-scrollable) title —
                            // a SwiftUI sheet ignores outside taps and a swipe in the scrollable body just
                            // scrolls the metric list; a short swipe may not clear the detent.
                            let sheetTitle = app.staticTexts["Heart-rate tile"]
                            if sheetTitle.exists {
                                let start = sheetTitle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                                start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 480)))
                            }
                            _ = app.buttons["studioPlayPause"].waitForExistence(timeout: 3)  // sheet gone → studio back
                        }
                    }
                    app.buttons["studioClose"].tap()
                } else {
                    snap("11c-studio-NOTREACHED")
                }
            }

            // Pop back to the section view for Settings. The session detail's trailing toolbar now
            // carries an Edit button (issue #73) that can enumerate before the back chevron in the
            // element tree, so index 0 is no longer reliably Back — tap the leading-most button.
            let navButtons = app.navigationBars.firstMatch.buttons
            let leadingMost = (0..<navButtons.count)
                .map { navButtons.element(boundBy: $0) }
                .min { $0.frame.minX < $1.frame.minX }
            leadingMost?.tap()
        } else {
            // History → detail is a value-based NavigationLink (a known XCUITest-tap limitation in
            // this app, decisions.md 2026-05-31). If it didn't push, snap the real History state so
            // the chronological story still shows where the headline summary lives.
            snap("10-session-summary-NOTREACHED")
            snap("11-media-and-highlight-NOTREACHED")
        }

        // 12 — Settings, pushed from the toolbar gear (#74 — it used to be a fifth segment).
        let gear = app.buttons["workout.settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 6), "the Settings gear should be in the toolbar")
        gear.tap(); sleep(1); snap("12-settings")

        // 13 — The A3 heart-rate source picker sheet (Apple Watch + BLE scan). The entry is a
        // `.buttonStyle(.plain)` row; tap it, and if the sheet doesn't present, fall back to the
        // row's label / a coordinate tap before giving up (robust, never flakes the run).
        if openHRSourcePicker() {
            sleep(1); snap("13-hr-source-picker")
        } else {
            snap("13-hr-source-picker-NOTREACHED")
        }
    }

    /// Open the A3 heart-rate source picker sheet from Settings. Returns `true` once the sheet's
    /// "Apple Watch" row is visible.
    private func openHRSourcePicker() -> Bool {
        let sheetMarker = app.buttons["hrSourceAppleWatch"]
        let openHR = app.buttons["openHeartRateSource"]
        // Attempt 1: the identified row button.
        if openHR.waitForExistence(timeout: 5) {
            openHR.tap()
            if sheetMarker.waitForExistence(timeout: 4) { return true }
        }
        // Attempt 2: the row's label text.
        let label = app.staticTexts["Heart-rate source"]
        if label.exists {
            label.tap()
            if sheetMarker.waitForExistence(timeout: 4) { return true }
        }
        // Attempt 3: a coordinate tap on the row (last resort).
        if openHR.exists {
            openHR.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            if sheetMarker.waitForExistence(timeout: 4) { return true }
        }
        return false
    }

    /// A media thumbnail in the grouped gallery (accessibilityIdentifier "mediaThumb"). It can
    /// surface as an otherElement / image / cell depending on layout, so try each. Returns the
    /// first hittable match (or `nil` — the 11b snap is best-effort, never flakes the run).
    private func firstMediaThumb() -> XCUIElement? {
        let queries = [app.otherElements.matching(identifier: "mediaThumb"),
                       app.images.matching(identifier: "mediaThumb"),
                       app.cells.matching(identifier: "mediaThumb")]
        for q in queries {
            let el = q.firstMatch
            if el.waitForExistence(timeout: 2), el.isHittable { return el }
        }
        return nil
    }

    /// The first **video** media thumb (label "Video at +Ns") — videos open the clip editor on tap.
    private func firstVideoMediaThumb() -> XCUIElement? {
        func match(_ base: XCUIElementQuery) -> XCUIElement {
            base.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "mediaThumb", "Video"))
                .firstMatch
        }
        for el in [match(app.otherElements), match(app.images), match(app.cells)] {
            if el.waitForExistence(timeout: 2), el.isHittable { return el }
        }
        return nil
    }

    // MARK: - Player driving

    /// Log one set in the (single) pager player to surface the on-page rest ring (snapping it), then
    /// finish and save. A routine now plays through the same grow-as-you-go pager as Quick Session:
    /// turn auto-rest on so a log surfaces the rest count-down, log one strength set (the first starter
    /// routine opens on a strength exercise), skip the rest, then Finish → summary → Done.
    private func driveToRestThenFinish() {
        let toggle = app.buttons["freeform.restToggle"]
        if toggle.exists { toggle.tap() }   // auto-start the rest after a log so it's captured
        let log = app.buttons["freeform.quickLog"]
        if log.waitForExistence(timeout: 4) { log.tap(); usleep(600_000) }
        if app.buttons["freeform.restDismiss"].waitForExistence(timeout: 3) {
            snap("07-rest-screen")
            app.buttons["freeform.restDismiss"].tap()
        }
        let finish = app.buttons["freeform.finish"]
        if finish.waitForExistence(timeout: 4) { finish.tap() }
        let done = app.buttons["freeform.done"]   // saves (a set was logged) and dismisses the cover
        if done.waitForExistence(timeout: 4) { done.tap() }
    }

    // MARK: - History → demo session

    /// Open the seeded demo session from History. The row is a value-based `NavigationLink`
    /// (the one row in the suite kept as such — see decisions.md 2026-05-31); we try the
    /// identifier'd cell, then a cell carrying the demo name, then the first history row. Returns
    /// `true` once the session-detail (the "Session" nav title) is on screen.
    private func openDemoSession() -> Bool {
        let candidates: [XCUIElement] = [
            app.cells.containing(.staticText, identifier: nil)
                .matching(NSPredicate(format: "label CONTAINS %@", demoName)).firstMatch,
            app.staticTexts[demoName],
            app.cells.matching(identifier: "historyRow")
                .containing(NSPredicate(format: "label CONTAINS %@", demoName)).firstMatch,
            app.cells.matching(identifier: "historyRow").firstMatch,
            app.cells.firstMatch,
        ]
        for el in candidates {
            guard el.waitForExistence(timeout: 3), el.isHittable else { continue }
            el.tap()
            if app.navigationBars["Session"].waitForExistence(timeout: 5)
                || app.staticTexts["Heart rate"].waitForExistence(timeout: 2) {
                return true
            }
        }
        return false
    }
}
