import XCTest

/// UI coverage for the **round trip with another AI app** (prompt 247, issue #438 step 4), on the
/// `-uiTestSeedRacketVideos` seed (a finished match recorded everything, not split yet). The simulator has no saved
/// video, so Send can't export: these cover AISend's gating and the prompt, and the import → compare → Analyzed path
/// with a pasted reply. Sending to a real app and its reply are device items.
@MainActor
final class RacketAIUITests: XCTestCase {
    var app: XCUIApplication!

    /// A reply as another app might write it: one rally over yours, one new, one past the video; "long" is unknown.
    private let reply = #"{"analyzer":{"app":"ChatGPT","model":"gpt-5"},"rallies":[{"start_s":1,"end_s":5,"winner":"far","ending":"net"},{"start_s":40,"end_s":48,"winner":"near","ending":"long"},{"start_s":9000,"end_s":9010}]}"#

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-uiTestSeedRacketVideos", "-uiTestFakeCamera"]
        app.launch()
    }

    private func any(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func tapWhenHittable(_ el: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        var tries = 0
        while !el.waitForExistence(timeout: tries == 0 ? 4 : 1) && tries < 8 { app.swipeUp(velocity: .slow); tries += 1 }
        XCTAssertTrue(el.exists, "\(el) should exist", file: file, line: line)
        tries = 0
        while !el.isHittable && tries < 6 { app.swipeUp(velocity: .slow); tries += 1 }
        el.tap()
    }

    private func openYourVideos() {
        app.tabBars.buttons["Apps"].tap()
        XCTAssertTrue(app.buttons["moduleCard.workout-log"].waitForExistence(timeout: 8))
        app.buttons["moduleCard.workout-log"].tap()
        app.segmentedControls.buttons["History"].tap()
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'historyRow' AND label CONTAINS 'Racket videos'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 6), "the seeded session")
        row.tap()
        tapWhenHittable(app.buttons["racket.recap.videos"])
        XCTAssertTrue(any("racket.videos.header").waitForExistence(timeout: 6))
    }

    private func pasteReply() {
        let box = any("racket.ai.import.text")
        XCTAssertTrue(box.waitForExistence(timeout: 5), "the import screen")
        box.tap()
        box.typeText(reply)
        XCTAssertTrue(any("racket.ai.import.read").waitForExistence(timeout: 5), "the reply is read as it's pasted")
    }

    private func back() {
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    func testImportCompareAndAcceptIntoYourTags() {
        openYourVideos()

        // Mark one rally yourself (0:00–0:05), untagged.
        app.buttons["racket.videos.mark.0"].tap()
        XCTAssertTrue(app.buttons["racket.tl.markStart"].waitForExistence(timeout: 5))
        app.buttons["racket.tl.markStart"].tap()
        app.buttons["racket.tl.fwd5"].tap()
        app.buttons["racket.tl.markEnd"].tap()
        XCTAssertEqual(any("racket.tl.count").label, "1 rally marked · 0 tagged")
        back()

        // Bring results back → paste the app's reply.
        tapWhenHittable(app.buttons["racket.videos.aiImport.0"])
        pasteReply()
        XCTAssertEqual(any("racket.ai.import.read").label, "Read 2 rallies")
        XCTAssertEqual(any("racket.ai.import.skipped").label, "1 skipped")
        XCTAssertEqual(any("racket.ai.import.skip.0").label, "Rally 3: starts after the video ends")
        XCTAssertEqual(any("racket.ai.import.unknown.0").label, "One rally used an ending Snappet doesn’t know: “long”.")
        XCTAssertTrue(app.buttons["racket.ai.import.countAs.0"].label.contains("Out"), app.buttons["racket.ai.import.countAs.0"].label)
        XCTAssertEqual(any("racket.ai.import.model").label, "gpt-5")
        XCTAssertTrue(app.buttons["racket.ai.import.compare"].isSelected, "compare first is the default")

        // Import → Compare: your untagged rally gets a winner and an ending; the other rally is new.
        tapWhenHittable(app.buttons["racket.ai.import.go"])
        XCTAssertTrue(any("racket.ai.compare.count").waitForExistence(timeout: 5))
        XCTAssertEqual(any("racket.ai.compare.count").label, "3 disagreements")
        XCTAssertEqual(any("racket.ai.compare.match").label, "0 of 2 match")
        XCTAssertEqual(any("racket.ai.compare.title.0").label, "Rally 1 · winner")
        XCTAssertEqual(app.buttons["racket.ai.compare.yours.0"].label, "Yours: Not tagged")
        XCTAssertEqual(app.buttons["racket.ai.compare.theirs.0"].label, "ChatGPT: Alex won")
        XCTAssertTrue(app.buttons["racket.ai.compare.yours.0"].isSelected, "nothing changes unless you pick it")
        tapWhenHittable(app.buttons["racket.ai.compare.useAll"])
        XCTAssertTrue(app.buttons["racket.ai.compare.theirs.0"].isSelected)
        tapWhenHittable(app.buttons["racket.ai.compare.keep"])

        // Done → the Analyzed player shows the accepted tags.
        XCTAssertTrue(any("racket.player.overlay").waitForExistence(timeout: 5), "Analyzed opens on the rally")
        XCTAssertTrue(any("racket.player.overlay").label.hasPrefix("Rally 1 · Alex won · Net"), any("racket.player.overlay").label)
        back()

        // Your videos says where the tags came from; From your tags counts them.
        XCTAssertTrue(any("racket.videos.tags.0").waitForExistence(timeout: 5))
        XCTAssertEqual(any("racket.videos.tags.0").label, "2 marked · 2 from ChatGPT")
        tapWhenHittable(app.buttons["racket.videos.seeTags.0"])
        XCTAssertTrue(any("racket.summary.source").waitForExistence(timeout: 5))
        XCTAssertEqual(any("racket.summary.source").label, "From your tags, 2 of 2 · 2 accepted from ChatGPT")
    }

    func testSendGatesOnPermissionAndSuggestionsWaitDashed() {
        openYourVideos()

        // AISend: the privacy note, rallies only off with nothing marked, Send off until permission is on.
        tapWhenHittable(app.buttons["racket.videos.ai.0"])
        XCTAssertTrue(any("racket.ai.send.privacy").waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["racket.ai.send.kind.ralliesOnly"].isEnabled, "no rallies marked yet")
        XCTAssertTrue(app.buttons["racket.ai.send.kind.wholeSmaller"].isSelected)
        XCTAssertFalse(app.buttons["racket.ai.send.go"].isEnabled, "Send stays off until permission is on")
        app.buttons["racket.ai.send.app.claude"].tap()
        XCTAssertTrue(any("racket.ai.send.framesNote").exists, "Claude gets frames")
        app.buttons["racket.ai.send.app.chatGPT"].tap()
        let permission = app.switches["racket.ai.send.permission"]
        tapWhenHittable(permission)
        if !app.buttons["racket.ai.send.go"].isEnabled {
            permission.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        }
        XCTAssertTrue(app.buttons["racket.ai.send.go"].isEnabled)
        XCTAssertEqual(app.buttons["racket.ai.send.go"].label, "Send to ChatGPT")

        // View and edit → the prompt for table tennis, with the reply format.
        app.swipeDown(velocity: .fast)
        tapWhenHittable(app.buttons["racket.ai.send.prompt"])
        XCTAssertTrue(any("racket.ai.prompt.title").waitForExistence(timeout: 5))
        XCTAssertEqual(any("racket.ai.prompt.title").label, "Written for table tennis")
        XCTAssertTrue(any("racket.ai.prompt.tail").label.contains("snappet.racket-analysis/1"))
        XCTAssertTrue(any("racket.ai.prompt.tail").label.contains("This video is 1:14:10 long"), any("racket.ai.prompt.tail").label)
        back()
        app.buttons["racket.ai.send.cancel"].tap()

        // Bring results back → Add as suggestions → Analyzed shows them waiting; Your videos offers Compare.
        tapWhenHittable(app.buttons["racket.videos.aiImport.0"])
        pasteReply()
        tapWhenHittable(app.buttons["racket.ai.import.suggest"])
        tapWhenHittable(app.buttons["racket.ai.import.go"])
        XCTAssertTrue(any("racket.player.aiSuggestions").waitForExistence(timeout: 5))
        XCTAssertTrue(any("racket.player.aiSuggestions").label.contains("ChatGPT suggestions"), any("racket.player.aiSuggestions").label)
        back()
        XCTAssertTrue(any("racket.videos.0.aiPending").waitForExistence(timeout: 5))
        XCTAssertEqual(any("racket.videos.0.aiPending").label, "2 suggested by ChatGPT, not compared yet")
        XCTAssertEqual(any("racket.videos.tags.0").label, "Not marked yet", "suggestions don't count as your tags")
        tapWhenHittable(app.buttons["racket.videos.0.aiCompare"])
        XCTAssertTrue(any("racket.ai.compare.count").waitForExistence(timeout: 5))
        XCTAssertEqual(any("racket.ai.compare.count").label, "2 disagreements")
    }
}
