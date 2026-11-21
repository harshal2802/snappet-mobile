import XCTest

/// A read-only look at the user's own recordings on their phone (no seed arguments, so the real store). Runs only
/// with `TEST_RUNNER_RACKET_REAL_WALK=1`. It opens, plays and cancels; it never saves, splits, tags, rotates or deletes.
@MainActor
final class RacketRealMatchWalkUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RACKET_REAL_WALK"] == "1", "real-data walk is opt-in")
        app = XCUIApplication()
        app.launchOnTestStore()
    }

    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    private func shot(_ name: String) {
        guard app.state == .runningForeground else { return }
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }

    private func dump(_ name: String) {
        let a = XCTAttachment(string: app.debugDescription)
        a.name = name + ".txt"; a.lifetime = .keepAlways; add(a)
    }

    func testListHistory() {
        app.tabBars.buttons["Apps"].tap()
        XCTAssertTrue(app.buttons["moduleCard.workout-log"].waitForExistence(timeout: 8))
        app.buttons["moduleCard.workout-log"].tap()
        app.segmentedControls.buttons["History"].tap()
        Thread.sleep(forTimeInterval: 1.5)
        shot("history")
        dump("history")
    }

    private func openToday() {
        app.tabBars.buttons["Apps"].tap()
        XCTAssertTrue(app.buttons["moduleCard.workout-log"].waitForExistence(timeout: 8))
        app.buttons["moduleCard.workout-log"].tap()
        app.segmentedControls.buttons["History"].tap()
        // `TEST_RUNNER_RACKET_REAL_ROW`: text from the history row to open, e.g. its date line.
        let want = ProcessInfo.processInfo.environment["RACKET_REAL_ROW"] ?? ""
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'historyRow' AND label CONTAINS %@", want)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 6))
        row.tap()
    }

    func testOpenVideosList() {
        openToday()
        Thread.sleep(forTimeInterval: 1.5)
        shot("recap-top"); dump("recap")
        let videos = app.buttons["racket.recap.videos"]
        for _ in 0..<8 where !(videos.exists && videos.isHittable && videos.frame.maxY < app.windows.firstMatch.frame.maxY - 120) {
            app.swipeUp(velocity: .slow)
        }
        shot("recap-videos-button")
        guard videos.exists else { return XCTFail("no Your videos button") }
        videos.tap()
        Thread.sleep(forTimeInterval: 2)
        shot("videos-1"); dump("videos")
        app.swipeUp(velocity: .slow); Thread.sleep(forTimeInterval: 1); shot("videos-2")
        app.swipeUp(velocity: .slow); Thread.sleep(forTimeInterval: 1); shot("videos-3"); dump("videos-end")
    }

    private func bring(_ el: XCUIElement) {
        let bottom = app.windows.firstMatch.frame.maxY - 130
        for _ in 0..<12 where !(el.exists && el.isHittable && el.frame.maxY < bottom && el.frame.minY > 100) {
            if el.exists && el.frame.minY < 100 { app.swipeDown(velocity: .slow) } else { app.swipeUp(velocity: .slow) }
        }
    }

    private func openVideos() {
        openToday()
        let videos = app.buttons["racket.recap.videos"]
        bring(videos)
        videos.tap()
        XCTAssertTrue(any("racket.videos.header").waitForExistence(timeout: 6))
    }

    /// Game 1 of the split match in the Watch player: does it show the picture and advance?
    func testPlayFirstGame() {
        openVideos()
        let play = app.buttons.matching(identifier: "racket.videos.play.0").element(boundBy: 0)
        bring(play); play.tap()
        let surface = any("racket.player.surface")
        XCTAssertTrue(surface.waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 3)
        let a = surface.value as? String ?? ""
        shot("player-1")
        Thread.sleep(forTimeInterval: 4)
        let b = surface.value as? String ?? ""
        shot("player-2"); dump("player")
        print("REALWALK player \(a) -> \(b)")
        XCTAssertNotEqual(a, b, "the player advances")
    }

    /// The unsplit match: the whole recording in the player, then the split screen and one Fix sheet. Never applies.
    func testSplitSheetOnUnsplitMatch() {
        openVideos()
        let split = app.buttons["racket.videos.split"]
        bring(split)
        shot("unsplit-row")
        split.tap()
        Thread.sleep(forTimeInterval: 6)
        shot("split-review-1"); dump("split-review")
        let fix = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'racket.split.fix.'")).element(boundBy: 0)
        guard fix.waitForExistence(timeout: 20) else { shot("split-no-fix"); return XCTFail("no Fix buttons") }
        bring(fix); fix.tap()
        XCTAssertTrue(app.buttons["racket.split.edit.save"].waitForExistence(timeout: 6))
        Thread.sleep(forTimeInterval: 2)
        shot("sheet-1")
        let head = { self.any("racket.split.edit.playhead").label }
        let range = any("racket.split.edit.range").label
        let h0 = head()
        app.buttons["racket.split.edit.play"].tap()
        Thread.sleep(forTimeInterval: 4)
        let h1 = head()
        shot("sheet-playing")
        app.buttons["racket.split.edit.play"].tap()
        // Move the end in the sheet only (cancelled below), then Play again: the reported bug.
        app.buttons["racket.split.edit.end.-10"].tap()
        let h2 = head()
        app.buttons["racket.split.edit.play"].tap()
        Thread.sleep(forTimeInterval: 4)
        let h3 = head()
        shot("sheet-playing-after-end-move"); dump("sheet")
        app.buttons["racket.split.edit.play"].tap()
        print("REALWALK sheet range=\(range) | \(h0) -> \(h1) | after end move \(h2) -> \(h3)")
        app.buttons["Cancel"].tap()
        Thread.sleep(forTimeInterval: 1)
        shot("split-review-after-cancel")
        XCTAssertNotEqual(h0, h1, "Play advances on a real recording")
        XCTAssertNotEqual(h2, h3, "Play advances after moving the end")
    }

    /// The saved split of the first match, as the review screen shows it. Leaves without applying.
    func testShowSavedSplit() {
        openVideos()
        let change = app.buttons.matching(identifier: "racket.videos.changeSplit").element(boundBy: 0)
        bring(change); change.tap()
        XCTAssertTrue(app.buttons["racket.split.apply"].waitForExistence(timeout: 20))
        Thread.sleep(forTimeInterval: 2)
        shot("saved-split-1"); dump("saved-split-1")
        app.swipeUp(velocity: .slow); Thread.sleep(forTimeInterval: 1)
        shot("saved-split-2"); dump("saved-split-2")
        app.swipeUp(velocity: .slow); Thread.sleep(forTimeInterval: 1)
        shot("saved-split-3"); dump("saved-split-3")
    }

    /// The session's logged sets, as the Edit screen lists them. Never saves.
    func testShowLoggedSets() {
        openToday()
        Thread.sleep(forTimeInterval: 1)
        app.buttons["session.editSets"].tap()
        Thread.sleep(forTimeInterval: 2)
        shot("sets-1"); dump("sets-1")
        app.swipeUp(velocity: .slow); Thread.sleep(forTimeInterval: 1)
        shot("sets-2"); dump("sets-2")
    }

    /// Plays the unsplit recording through in the Watch player and keeps a frame every few seconds, named by time.
    func testCaptureFramesOfUnsplitMatch() {
        openVideos()
        let play = app.buttons.matching(identifier: "racket.videos.play.0").element(boundBy: 1)
        bring(play); play.tap()
        let surface = any("racket.player.surface")
        XCTAssertTrue(surface.waitForExistence(timeout: 20))
        var last = "", same = 0
        let until = Date().addingTimeInterval(25 * 60)
        while Date() < until, app.state == .runningForeground {
            let v = (surface.value as? String ?? "").split(separator: " ").first.map(String.init) ?? "?"
            let a = XCTAttachment(image: app.screenshot().image, quality: .low)
            a.name = "f-" + v.replacingOccurrences(of: ":", with: "-"); a.lifetime = .keepAlways; add(a)
            same = v == last ? same + 1 : 0
            last = v
            if same >= 4 { break }   // stopped: the end
            Thread.sleep(forTimeInterval: 3.2)
        }
    }

    private func clock(_ t: String) -> Int { t.split(separator: ":").compactMap { Int($0) }.reduce(0) { $0 * 60 + $1 } }
    private func rangeEnds() -> (Int, Int) {
        let p = any("racket.split.edit.range").label.split(separator: "–").map { clock(String($0)) }
        return (p.first ?? 0, p.last ?? 0)
    }
    private func playheadSec() -> Int { clock(any("racket.split.edit.playhead").label.replacingOccurrences(of: "Playhead ", with: "")) }

    /// Applies a split the user asked for: `RACKET_REAL_CUTS` = "25:notPlay,305:warmup,…" (each piece's end second and
    /// kind, in order; what is left after the last cut becomes `RACKET_REAL_LAST`). Saves only with RACKET_REAL_APPLY=1
    /// and only when every part came out as asked.
    func testApplyAskedSplit() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        let cuts: [(Int, String)] = (env["RACKET_REAL_CUTS"] ?? "").split(separator: ",").compactMap {
            let p = $0.split(separator: ":"); return p.count == 2 ? (Int(p[0]) ?? 0, String(p[1])) : nil
        }
        try XCTSkipIf(cuts.isEmpty, "no cuts given")
        openVideos()
        let split = app.buttons["racket.videos.split"]
        bring(split); split.tap()
        XCTAssertTrue(app.buttons["racket.split.fix.0"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["racket.split.fix.1"].exists, "starts as one part")

        func openFix(_ k: Int) {
            let fix = app.buttons["racket.split.fix.\(k)"]
            XCTAssertTrue(fix.waitForExistence(timeout: 8), "Fix \(k)")
            bring(fix); fix.tap()
            XCTAssertTrue(app.buttons["racket.split.edit.save"].waitForExistence(timeout: 6))
            Thread.sleep(forTimeInterval: 1)
        }
        func choose(_ kind: String) {
            let chip = app.buttons["racket.split.edit.kind.\(kind)"]
            XCTAssertTrue(chip.isEnabled, "kind \(kind) can be chosen")
            chip.tap()
        }
        for (k, cut) in cuts.enumerated() {
            openFix(k)
            let start = rangeEnds().0
            // Put the playhead inside the part: play until it is 7 s in, pause.
            app.buttons["racket.split.edit.play"].tap()
            let limit = Date().addingTimeInterval(40)
            while playheadSec() < start + 7, Date() < limit { Thread.sleep(forTimeInterval: 0.3) }
            app.buttons["racket.split.edit.play"].tap()
            XCTAssertGreaterThanOrEqual(playheadSec(), start + 6, "playhead inside the part")
            let handle = any("racket.split.edit.playhead").coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
            handle.press(forDuration: 0.05, thenDragTo: handle.withOffset(CGVector(dx: 0, dy: -260)))
            let splitHere = app.buttons["racket.split.edit.splitHere"]
            XCTAssertTrue(splitHere.isEnabled, "Split here is on")
            splitHere.tap()
            // No scrolling back: a downward drag pulls the sheet itself down. The end buttons and kinds stay on screen.
            // Move this piece's end to the asked time.
            for _ in 0..<4 {
                let d = cut.0 - rangeEnds().1
                if d == 0 { break }
                let tens = abs(d) / 10, ones = abs(d) % 10
                for _ in 0..<tens { app.buttons["racket.split.edit.end.\(d > 0 ? 10 : -10)"].tap() }
                for _ in 0..<ones { app.buttons["racket.split.edit.end.\(d > 0 ? 1 : -1)"].tap() }
            }
            XCTAssertEqual(rangeEnds().1, cut.0, "piece \(k) ends where asked")
            XCTAssertEqual(rangeEnds().0, start, "piece \(k) start unchanged")
            choose(cut.1)
            shot("cut-\(k)")
            app.buttons["racket.split.edit.save"].tap()
            XCTAssertTrue(app.buttons["racket.split.fix.\(k + 1)"].waitForExistence(timeout: 6), "piece \(k) saved")
        }
        if let last = env["RACKET_REAL_LAST"] {
            openFix(cuts.count)
            choose(last)
            app.buttons["racket.split.edit.save"].tap()
            Thread.sleep(forTimeInterval: 1)
        }
        // Read the parts back.
        var labels: [String] = []
        for k in 0...cuts.count { labels.append(app.buttons["racket.split.part.\(k)"].label) }
        print("REALWALK parts " + labels.joined(separator: " | "))
        shot("review-final"); dump("review-final")
        XCTAssertFalse(app.buttons["racket.split.part.\(cuts.count + 1)"].exists, "no extra part")
        guard env["RACKET_REAL_APPLY"] == "1" else { return }
        let apply = app.buttons["racket.split.apply"]
        bring(apply); apply.tap()
        XCTAssertTrue(app.buttons["racket.assign.save"].waitForExistence(timeout: 8))
        Thread.sleep(forTimeInterval: 1)
        shot("assign"); dump("assign")
        app.buttons["racket.assign.save"].tap()
        let done = app.buttons["racket.splitDone.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 8))
        shot("done")
        bring(done); done.tap()
        XCTAssertTrue(any("racket.videos.header").waitForExistence(timeout: 8))
        Thread.sleep(forTimeInterval: 1)
        shot("videos-after"); dump("videos-after")
    }
}
