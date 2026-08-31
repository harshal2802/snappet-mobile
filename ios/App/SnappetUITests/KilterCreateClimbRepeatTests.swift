import XCTest

/// Regression guard for the **create-climb → detail push race** (prompt 124, PR #307).
///
/// `CreateClimbView`'s hosts used to call `onCreated(uuid)` — which pushes `KilterClimbRoute` — and
/// `dismiss()` in the SAME transaction. SwiftUI intermittently drops the second change, so saving a
/// new climb sometimes closed the sheet and opened nothing. The fix stashes the uuid and promotes it
/// to the push in the sheet's `onDismiss`.
///
/// Because the failure was **intermittent**, one pass proves nothing: this drives the real
/// create → save → detail hop `repeats` times and requires the detail to open EVERY time. It runs
/// from both hosts that push — browse `+` and Your Climbs — since the race lived in each.
///
/// Placing four valid holds means tapping exact points on a rendered board, which no UI test can do
/// reliably, so the draft comes from the launch-arg-gated "Sample" seam
/// (`-uiTestKilterCreateSample`); everything after it — validation, save, the uuid hand-off, the
/// push — is the real production path.
final class KilterCreateClimbRepeatTests: XCTestCase {
    var app: XCUIApplication!

    /// Enough passes to catch an intermittent drop without making the suite crawl (~15 s/pass).
    private let repeats = 5

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["apps", "-uiTestFreshStore", "-uiTestInstallKilterCatalog",
                                "-uiTestKilterCreateSample"]
        app.launch()
    }

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }

    /// Open the Kilter module from the App Library.
    private func openKilter() {
        app.tabBars.buttons["Apps"].tap()
        let card = app.buttons["moduleCard.kilter"]
        var tries = 0
        while !card.exists && tries < 10 { app.swipeUp(); tries += 1 }
        XCTAssertTrue(card.waitForExistence(timeout: 8), "the App Library should offer Kilter")
        tries = 0
        while !card.isHittable && tries < 10 { app.swipeUp(); tries += 1 }
        card.tap()
        XCTAssertTrue(app.buttons["kilter.create"].waitForExistence(timeout: 10),
                      "the Kilter browse screen should offer Create climb")
    }

    /// One create → save → detail hop. Returns once the detail is confirmed open.
    private func createOnce(pass: Int, from entry: XCUIElement) {
        entry.tap()
        let sample = app.buttons["kilter.create.sample"]
        XCTAssertTrue(sample.waitForExistence(timeout: 8),
                      "pass \(pass): the create sheet should present with its sample seam")
        sample.tap()

        let save = app.buttons["kilter.create.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 4), "pass \(pass): Save should exist")
        XCTAssertTrue(save.isEnabled, "pass \(pass): a four-hold sample must satisfy validation")
        save.tap()

        // THE ASSERTION: the sheet dismissed AND the pushed detail actually arrived. Before the fix
        // this is where the race showed — the sheet closed and nothing opened.
        let detailFavorite = app.buttons["kilter.favorite"]
        XCTAssertTrue(detailFavorite.waitForExistence(timeout: 8),
                      "pass \(pass): saving a climb must open its detail — the push was dropped")
        snap("pass-\(pass)-detail")

        // Back to the host screen for the next pass.
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 8),
                      "pass \(pass): popping the detail should return to the host screen")
    }

    /// Browse `+` — the `KilterRootView` host.
    func testCreatingFromBrowseOpensTheDetailEveryTime() {
        openKilter()
        for pass in 1...repeats {
            createOnce(pass: pass, from: app.buttons["kilter.create"])
        }
    }

    /// "Set a climb" in Your Climbs — the `KilterCreatedView` host, which had the same race.
    func testCreatingFromYourClimbsOpensTheDetailEveryTime() {
        openKilter()
        app.buttons["kilter.more"].tap()
        let yourClimbs = app.buttons["kilter.yourClimbs"]
        XCTAssertTrue(yourClimbs.waitForExistence(timeout: 6), "the ··· menu should offer Your Climbs")
        yourClimbs.tap()

        // The gallery's entry point is its toolbar + when it already has climbs, or the empty-state
        // CTA on a fresh store — take whichever is present.
        let toolbarAdd = app.buttons["kilter.created.add"]
        let emptyAdd = app.buttons["kilter.created.emptySet"]
        XCTAssertTrue(toolbarAdd.waitForExistence(timeout: 8) || emptyAdd.waitForExistence(timeout: 2),
                      "Your Climbs should offer a way to set a climb")

        for pass in 1...repeats {
            // After the first pass the gallery is non-empty, so the toolbar + is the stable entry.
            let entry = (pass == 1 && !toolbarAdd.exists) ? emptyAdd : toolbarAdd
            createOnce(pass: pass, from: entry)
        }
    }
}
