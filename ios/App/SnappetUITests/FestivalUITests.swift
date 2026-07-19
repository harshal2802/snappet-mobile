import XCTest

/// Festival mini-app walkthrough (festival prompt 02): the catalog empty state + browse sheet on a
/// fresh store, then — via the now-anchored `-uiTestSeedFestivalLineup` lineup — the day schedule
/// (NOW pill, ★ stars, clash marks) and the "I'm here" live sheet on the dance-session spine.
/// Identifiers come from `festival.*`; interactive children (stars, GET, switch) carry their OWN
/// ids — a container identifier flattens child buttons out of the XCUITest tree (highlights-P5).
@MainActor final class FestivalUITests: XCTestCase {

    private func launch(_ arguments: [String]) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += arguments
        app.launch()
        return app
    }

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }

    /// Opens the Festival mini-app from the App Library (Lifestyle section).
    private func openFestival(_ app: XCUIApplication) {
        app.tabBars.buttons["Apps"].tap()
        let card = app.buttons["moduleCard.festival"]
        var tries = 0
        while !card.exists && tries < 10 { app.swipeUp(); tries += 1 }
        XCTAssertTrue(card.waitForExistence(timeout: 6), "App Library should have a Festival card")
        tries = 0
        while !card.isHittable && tries < 10 { app.swipeUp(); tries += 1 }
        card.tap()
    }

    // MARK: - Flow A · catalog (frames 1–3)

    func testEmptyStateLeadsWithDownloadAndOpensTheBrowseSheet() {
        let app = launch(["-uiTestFreshStore"])
        openFestival(app)

        // 1 — the opt-in empty state: download leads, import beneath, data-posture card.
        let browse = app.buttons["festival.catalog.browse"]
        XCTAssertTrue(browse.waitForExistence(timeout: 6), "fresh store should show the empty state")
        XCTAssertTrue(app.buttons["festival.catalog.import"].exists,
                      "the power-user file import should sit beneath the download CTA")
        snap("festival-empty")

        // 2 — the hosted-catalog browse sheet opens with its own stack. Its list content depends
        // on the network, so assert only the sheet chrome (deterministic offline AND online).
        browse.tap()
        XCTAssertTrue(app.navigationBars["Snappet Lineups"].waitForExistence(timeout: 6),
                      "the browse sheet should present")
        snap("festival-browse")
        app.buttons["festival.browse.cancel"].tap()
        XCTAssertTrue(app.buttons["festival.catalog.browse"].waitForExistence(timeout: 6),
                      "cancel should return to the empty state")
    }

    // MARK: - Flow B · the weekend (frames 4–5)

    func testScheduleStarsClashAndTheLiveSheet() {
        let app = launch([FestivalSeed.argument])
        openFestival(app)

        // 1 — the seeded lineup lists; push its schedule.
        let lineup = app.buttons["festival.lineup.snappet-test-festival"]
        XCTAssertTrue(lineup.waitForExistence(timeout: 6), "the seeded lineup should list")
        lineup.tap()

        // 2 — day schedule: stage-grouped rows, the anchor set glowing NOW.
        let nowBadge = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'NOW'")).firstMatch
        XCTAssertTrue(nowBadge.waitForExistence(timeout: 6), "the live set should carry a NOW pill")
        XCTAssertTrue(app.staticTexts["Fred Midnight"].exists)
        XCTAssertTrue(app.staticTexts["PYRAMID STAGE"].exists, "rows group by stage")
        snap("festival-schedule")

        // 3 — star the overlapping pair → both rows flag the clash; unstar clears it.
        app.buttons["festival.star.Overtone"].tap()
        app.buttons["festival.star.Electric Fern"].tap()
        XCTAssertTrue(app.staticTexts["festival.clash.Overtone"].waitForExistence(timeout: 4),
                      "starring two overlapping sets should flag a clash")
        XCTAssertTrue(app.staticTexts["festival.clash.Electric Fern"].exists)
        snap("festival-clash")
        app.buttons["festival.star.Electric Fern"].tap()
        XCTAssertFalse(app.staticTexts["festival.clash.Overtone"].waitForExistence(timeout: 2),
                       "unstarring one side should clear the clash")

        // 4 — "I'm here" starts the dance-session spine and opens the live sheet.
        let imHere = app.buttons["festival.imHere"]
        XCTAssertTrue(imHere.waitForExistence(timeout: 4), "a live set should offer I'm here")
        imHere.tap()
        XCTAssertTrue(app.staticTexts["festival.live.artist"].waitForExistence(timeout: 6),
                      "the live sheet should open on the claimed artist")
        XCTAssertTrue(app.buttons["festival.live.record"].exists, "the record-clip control rides along")
        snap("festival-live")

        // 5 — switch to the up-next set via the dialog; the sheet re-anchors in place.
        app.buttons["festival.live.switch"].tap()
        let overtone = app.buttons["Overtone · West Holts (up next)"]
        XCTAssertTrue(overtone.waitForExistence(timeout: 4), "the switcher should offer up next")
        overtone.tap()
        let reanchored = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == 'Overtone'"),
            object: app.staticTexts["festival.live.artist"])
        XCTAssertEqual(XCTWaiter().wait(for: [reanchored], timeout: 6), .completed,
                       "switching should re-anchor the sheet on Overtone")
        snap("festival-switched")

        // 6 — end the night: the sheet closes and the CTA returns to I'm here for the live set.
        let end = app.buttons["festival.live.end"]
        if !end.isHittable {
            // Below the medium-detent fold — scrolling up expands the sheet to .large first.
            app.swipeUp()
        }
        end.tap()
        XCTAssertTrue(imHere.waitForExistence(timeout: 6), "ending should surface the CTA again")
        XCTAssertTrue(imHere.label.contains("I'm here"),
                      "after ending, the claim CTA should reset from On the floor")
    }

    // MARK: - Flow C · plan & smart nudges (frames 7–8)

    func testForYouSuggestsFromHistoryAndStarringAddsToThePlan() {
        // The plan seed installs the lineup + a pre-star + a past dance session for "Overtone",
        // who plays this festival — so For-You surfaces Overtone with an HR-history reason.
        let app = launch([FestivalSeed.planArgument])

        // The For-You sheet asks for notification permission on open — dismiss the system dialog.
        addUIInterruptionMonitor(withDescription: "Notifications permission") { alert -> Bool in
            for label in ["Allow", "Don't Allow", "OK", "Continue"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return true }
            }
            return false
        }

        openFestival(app)
        let lineup = app.buttons["festival.lineup.snappet-test-festival"]
        XCTAssertTrue(lineup.waitForExistence(timeout: 6), "the seeded lineup should list")
        lineup.tap()

        // Open For You from the schedule's ✨ toolbar button.
        let forYou = app.buttons["festival.forYou"]
        XCTAssertTrue(forYou.waitForExistence(timeout: 6), "the schedule should offer a For-You button")
        forYou.tap()
        // The sheet asks for notification permission on open; the interruption monitor above
        // dismisses the springboard dialog on the next real tap (add / done) — no stray app.tap().

        // The returning artist (Overtone) is suggested, with the HR-history reason line. The ＋★
        // button carries its own id (the container is left id-less so it isn't flattened).
        let add = app.buttons["festival.forYou.add.Overtone"]
        XCTAssertTrue(add.waitForExistence(timeout: 8),
                      "the For-You sheet should open and suggest an artist from your HR history")
        let reason = app.staticTexts["festival.forYou.reason.Overtone"]
        XCTAssertTrue(reason.waitForExistence(timeout: 4)
                      && reason.label.contains("peaked"),
                      "the reason line should cite your heart-rate history")
        snap("festival-foryou")

        // Add it — the card leaves (Overtone is now starred, so it's no longer a suggestion).
        add.tap()
        XCTAssertFalse(add.waitForExistence(timeout: 3),
                       "adding a suggestion should drop it from the list")

        // The lead-time control is present and changeable.
        let lead = app.buttons["festival.forYou.lead"]
        XCTAssertTrue(lead.waitForExistence(timeout: 4), "a lead-time control should be offered")

        app.buttons["festival.forYou.done"].tap()
    }

    // MARK: - Flow C · the morning after (frames 6 · 9 · 11 — festival prompt 03)

    /// The seeded night (`-uiTestSeedFestivalNight`): review sheet with the day timeline + the two
    /// "Needs you" reasons, keep-all + a Change › override, then set detail (HR slice, ✦ AUTO
    /// clips, reel CTA) and the recap (hero + ♥-ranked artists).
    func testTagReviewSetDetailAndRecapAfterASeededNight() {
        let app = launch([FestivalNightSeed.argument])
        openFestival(app)
        app.buttons["festival.lineup.snappet-test-festival"].tap()

        // 1 — the review sheet, from the schedule's toolbar.
        let reviewButton = app.buttons["festival.reviewTags"]
        XCTAssertTrue(reviewButton.waitForExistence(timeout: 6))
        reviewButton.tap()
        let summary = app.staticTexts["festival.review.summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 8), "the sheet should match and summarize")
        XCTAssertTrue(summary.label.contains("3 clips") && summary.label.contains("1 auto-tagged")
                      && summary.label.contains("2 need you"),
                      "seed contract: 1 auto + 2 needs-you (got '\(summary.label)')")
        XCTAssertTrue(app.otherElements["festival.review.timeline"].exists
                      || app.descendants(matching: .any)["festival.review.timeline"].exists,
                      "the day renders as a timeline bar")
        // The machine reasons ARE the captions.
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'between stages'")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'two sets live'")).firstMatch.exists)
        snap("festival-review")

        // 2 — keep the auto block: the button resolves and disappears (tags become sticky).
        app.buttons["festival.review.keepAll"].tap()
        let keepGone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.buttons["festival.review.keepAll"])
        XCTAssertEqual(XCTWaiter().wait(for: [keepGone], timeout: 6), .completed,
                       "keep-all should consume itself")

        // 3 — Change › on the two-sets-live clip (proposed Static Bloom): pick Coral Circuit.
        app.buttons["festival.review.change.Static Bloom"].tap()
        let coral = app.buttons["Coral Circuit · Arcadia"]
        XCTAssertTrue(coral.waitForExistence(timeout: 4), "the dialog offers every live candidate")
        coral.tap()
        let resolved = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS '1 needs you'"), object: summary)
        XCTAssertEqual(XCTWaiter().wait(for: [resolved], timeout: 8), .completed,
                       "an override resolves its row (summary: \(summary.label))")
        snap("festival-review-resolved")
        app.buttons["festival.review.done"].tap()

        // 4 — set detail from the schedule row: hero stats, the set's HR slice + peak callout,
        // the ✦ AUTO clip, and the reel CTA into the shared ReelView.
        let setLink = app.buttons["festival.set.Neon Harbor"]
        XCTAssertTrue(setLink.waitForExistence(timeout: 6))
        setLink.tap()
        XCTAssertTrue(app.staticTexts["festival.set.artist"].waitForExistence(timeout: 6))
        XCTAssertEqual(app.staticTexts["festival.set.artist"].label, "Neon Harbor")
        XCTAssertTrue(app.descendants(matching: .any)["festival.set.stats"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["festival.set.hrChart"]
            .waitForExistence(timeout: 6), "the set window slices a drawable HR curve")
        XCTAssertTrue(app.staticTexts["festival.set.peak"].exists, "the peak-at-the-drop callout")
        XCTAssertTrue(app.buttons["festival.set.reel"].exists, "the shared-reel CTA is offered")
        snap("festival-set-detail")
        app.navigationBars.buttons.firstMatch.tap()   // back to the schedule

        // 5 — recap: hero numbers + artists ranked by YOUR heart rate (Neon Harbor's 171 first).
        app.buttons["festival.recap"].tap()
        XCTAssertTrue(app.staticTexts["festival.recap.nights"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.staticTexts["festival.recap.nights"].label, "1 night on the floor")
        let neonRow = app.buttons["festival.recap.artist.Neon Harbor"]
        let bloomRow = app.buttons["festival.recap.artist.Static Bloom"]
        XCTAssertTrue(neonRow.waitForExistence(timeout: 6))
        XCTAssertTrue(bloomRow.exists)
        XCTAssertLessThan(neonRow.frame.minY, bloomRow.frame.minY,
                          "♥ 171 at Neon Harbor outranks Static Bloom")
        XCTAssertTrue(app.buttons["festival.recap.reel"].exists, "the festival-reel CTA is offered")
        snap("festival-recap")
    }

    // MARK: - Flow E · share by QR (frames 12–13 — festival prompt 05)

    /// The share sheet from the schedule's ⋯ menu (the plan seed pre-stars "Jade Groove", so "Share
    /// my plan" has something to encode): "My plan" renders a scannable QR that carries the plan in
    /// the code, and the Scan tab opens the receive scanner — no camera needed to assert the chrome.
    func testShareSheetRendersAPlanCodeAndOffersScan() {
        let app = launch([FestivalSeed.planArgument])
        openFestival(app)
        let lineup = app.buttons["festival.lineup.snappet-test-festival"]
        XCTAssertTrue(lineup.waitForExistence(timeout: 6), "the seeded lineup should list")
        lineup.tap()

        // Open the ⋯ share menu → "Share my plan".
        let menu = app.buttons["festival.share.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 6), "the schedule should offer a share menu")
        menu.tap()
        app.buttons["Share my plan"].tap()

        // The plan encodes into a black-on-white QR (the plan seed starred Jade Groove).
        let qr = app.images["festival.share.qr"]
        XCTAssertTrue(qr.waitForExistence(timeout: 6), "a small plan renders as a scannable QR")
        XCTAssertTrue(app.staticTexts["festival.share.formNote"].exists,
                      "the sheet says whether the code is in-the-code or an install link")
        snap("festival-share-plan")

        // Switch to the whole lineup — still a code (the seed lineup is small). Segmented-picker
        // segments surface as top-level buttons by their label, not as children of the picker id.
        app.buttons["Whole lineup"].tap()
        XCTAssertTrue(qr.waitForExistence(timeout: 4), "the whole seeded lineup also fits a code")

        // The Scan tab opens the receive scanner (camera permission handled inline — no real camera).
        app.buttons["Scan"].tap()
        let scanner = app.otherElements["festival.scanner"]
        XCTAssertTrue(scanner.waitForExistence(timeout: 4)
                      || app.descendants(matching: .any)["festival.scanner"].waitForExistence(timeout: 4)
                      || app.staticTexts["Camera access"].waitForExistence(timeout: 4),
                      "the Scan tab shows the shared scanner (or its permission prompt)")
        snap("festival-share-scan")
    }
    // MARK: - Flow F · poster scan (frame 2's "Scan a lineup poster", festival prompt 06)

    /// From the empty state: build a lineup from pasted poster text (no camera in the sim), review the
    /// draft the pure floor produced, then install it — the validate-before-install gate lands a real
    /// lineup in "Your festivals".
    func testPosterScanBuildsADraftAndInstallsIt() {
        // Force the deterministic pure floor — the on-device FM path is a real, slow device leg.
        let app = launch(["-uiTestFreshStore", "-uiTestPosterFloorOnly"])
        openFestival(app)

        let poster = app.buttons["festival.poster.scan"]
        XCTAssertTrue(poster.waitForExistence(timeout: 6),
                      "the empty state should offer poster scan")
        poster.tap()

        // The capture sheet: use the canned sample (drives the flow with no camera) then build.
        let sample = app.buttons["festival.poster.sample"]
        XCTAssertTrue(sample.waitForExistence(timeout: 6), "the capture sheet should offer a sample")
        sample.tap()
        app.buttons["festival.poster.build"].tap()
        snap("festival-poster-capture")

        // The draft-review editor, pre-filled from the parsed poster.
        let name = app.textFields["festival.poster.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 6), "building lands in the draft-review editor")
        XCTAssertEqual(name.value as? String, "Sunset Sounds 2026",
                       "the festival title guess pre-fills the name field")
        snap("festival-poster-draft")

        // Install: the draft validates and becomes a lineup in "Your festivals".
        app.buttons["festival.poster.install"].tap()
        XCTAssertTrue(app.staticTexts["Sunset Sounds 2026"].waitForExistence(timeout: 6),
                      "a valid poster draft installs as a lineup")
    }
}

/// Mirrors of the app-side seed arguments (the UI-test target can't import the app module's enums).
private enum FestivalSeed {
    static let argument = "-uiTestSeedFestivalLineup"
    static let planArgument = "-uiTestSeedFestivalPlan"
}

private enum FestivalNightSeed {
    static let argument = "-uiTestSeedFestivalNight"
}
