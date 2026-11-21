import XCTest

/// Prompts 272–277, device leg, on the screen: take ONE copied clip in the Clips feed through its
/// menu — remove it from the phone, watch it play from Google Drive, see the Wi-Fi-only message,
/// bring it back, remove its copy and ask for it to be copied again — then open the Manage copies
/// confirmations. The original of that one clip goes to Recently Deleted (30 days) and one Drive
/// copy goes to Drive's trash (30 days). "Remove all copies" is opened and CANCELLED.
/// Opt-in, and only with the owner's say-so:
///
///     TEST_RUNNER_SNAPPET_DEVICE_COPY_ACTIONS=1 xcodebuild test -scheme Snappet \
///       -destination 'id=<device udid>' -allowProvisioningUpdates \
///       -only-testing:SnappetUITests/ClipCopyActionsDeviceUITests
@MainActor final class ClipCopyActionsDeviceUITests: XCTestCase {

    override func setUp() { continueAfterFailure = true }

    private let hold = ["-vaultHoldCopies", "YES", "-vaultStreamAbove", "1"]
    private var app: XCUIApplication!

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    private func note(_ text: String) { print("DEVICE-ACTIONS \(text)") }

    private func launch(_ extra: [String] = []) {
        app = XCUIApplication()
        app.launchArguments = hold + extra
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Clips"].waitForExistence(timeout: 40))
        app.tabBars.buttons["Clips"].tap()
        sleep(6)   // the vault listing and the look at Photos
    }

    /// Scroll to the first post that carries a copy mark and return its "…" button.
    private func menuOfFirstCopiedPost() -> XCUIElement? {
        let mark = element("clips.copyMark")
        var swipes = 0
        while !(mark.exists && mark.isHittable) && swipes < 25 {
            app.swipeUp(velocity: .slow)
            swipes += 1
        }
        guard mark.exists else { return nil }
        let y = mark.frame.midY
        let menus = app.buttons.matching(identifier: "clips.post.menu").allElementsBoundByIndex.filter(\.exists)
        return menus.min { abs($0.frame.midY - y) < abs($1.frame.midY - y) }
    }

    private func openMenu() -> Bool {
        guard let menu = menuOfFirstCopiedPost() else { return false }
        menu.tap()
        sleep(1)
        return true
    }
    /// A system menu exposes its rows by their words, not by the identifiers set on them.
    private func menuItem(_ id: String) -> XCUIElement {
        let item = app.buttons[id]
        if !item.waitForExistence(timeout: 3) { app.swipeUp() }
        return item
    }
    private func closeMenu() { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap(); sleep(1) }

    private func mediaState() -> String {
        ["feed.media.player", "feed.media.photo", "feed.media.loadingFromDrive", "feed.media.blocked", "feed.media.placeholder"]
            .filter { element($0).exists }.joined(separator: ",")
    }

    func testOneClipThroughEveryCopyAction() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("needs real Photos and a real Google Drive — device only")
        #else
        guard ProcessInfo.processInfo.environment["SNAPPET_DEVICE_COPY_ACTIONS"] == "1" else {
            throw XCTSkip("opt-in: set SNAPPET_DEVICE_COPY_ACTIONS=1; frees one clip and trashes one Drive copy")
        }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

        // 1. The mark and the menu of a clip that is on the phone and copied.
        launch()
        guard openMenu() else { shot("no copied post found"); return XCTFail("no post with a copy mark in the first screens of the feed") }
        shot("1 menu, clip on the phone")
        note("menu on phone: openInDrive=\(app.buttons["Open in Google Drive"].exists) freeUp=\(app.buttons["Remove from this iPhone"].exists) removeCopy=\(app.buttons["Remove copy from Google Drive"].exists)")
        let freeUp = menuItem("Remove from this iPhone")
        guard freeUp.exists, freeUp.isEnabled else { shot("no free-up item"); return XCTFail("'Remove from this iPhone' is missing or disabled") }

        // 2. Remove it from the phone; iOS asks.
        freeUp.tap()
        let delete = springboard.alerts.buttons["Delete"]
        guard delete.waitForExistence(timeout: 120) else { shot("no iOS prompt"); return XCTFail("iOS never asked to delete") }
        note("iOS prompt: \(springboard.alerts.firstMatch.label)")
        delete.tap()
        sleep(3)
        shot("2 just after leaving the phone")
        note("media right after: \(mediaState())")
        let player = element("feed.media.player"), photo = element("feed.media.photo")
        var waited = 0
        while !(player.exists || photo.exists) && waited < 60 { sleep(2); waited += 2 }
        note("media after \(waited)s: \(mediaState())")
        shot("3 playing from Google Drive")
        XCTAssertTrue(player.exists || photo.exists, "the freed clip does not show from Drive — \(mediaState())")

        // 3. On cellular with Wi-Fi only: said, with a way past.
        app.terminate()
        launch(["-vaultAssumeCellular", "YES"])
        _ = menuOfFirstCopiedPost()
        sleep(4)
        note("media on 'cellular': \(mediaState())")
        shot("4 wifi only on cellular")
        let anyway = element("feed.media.playAnyway")
        if anyway.waitForExistence(timeout: 15) {
            anyway.tap()
            waited = 0
            while !(player.exists || photo.exists) && waited < 60 { sleep(2); waited += 2 }
            note("after Play anyway (\(waited)s): \(mediaState())")
            shot("5 after play anyway")
            XCTAssertTrue(player.exists || photo.exists)
        } else {
            XCTFail("no Wi-Fi-only message — \(mediaState())")
        }

        // 4. Bring it back.
        XCTAssertTrue(openMenu())
        shot("6 menu, clip only in Drive")
        note("menu in Drive: bringBack=\(app.buttons["Bring back to this iPhone"].exists) removeCopy=\(app.buttons["Remove copy from Google Drive"].exists) freeUp=\(app.buttons["Remove from this iPhone"].exists)")
        let bringBack = menuItem("Bring back to this iPhone")
        if bringBack.exists {
            bringBack.tap()
            sleep(45)   // the whole file, then the save into Photos
            XCTAssertTrue(openMenu())
            shot("7 menu after bringing back")
            note("menu after bring back: bringBack=\(app.buttons["Bring back to this iPhone"].exists) freeUp=\(app.buttons["Remove from this iPhone"].exists)")
            XCTAssertTrue(app.buttons["Remove from this iPhone"].exists, "the clip is not back on the phone")

            // 5. Remove its copy from Drive, then ask for it again.
            let removeCopy = menuItem("Remove copy from Google Drive")
            if removeCopy.exists {
                removeCopy.tap()
                sleep(8)
                // The mark is gone now, so this post is found by position: it has not moved.
                let menus = app.buttons.matching(identifier: "clips.post.menu").allElementsBoundByIndex.filter { $0.exists && $0.isHittable }
                menus.first?.tap()
                sleep(1)
                shot("8 menu after removing the copy")
                let again = app.buttons["Copy to Google Drive again"]
                note("after remove copy: copyAgain=\(again.exists) markStillShown=\(element("clips.copyMark").isHittable)")
                if again.exists { again.tap() } else { closeMenu() }
            } else { closeMenu(); XCTFail("no 'Remove copy' item") }
        } else {
            closeMenu()
            XCTFail("no 'Bring back' item")
        }

        // 6. Manage copies: the confirmations.
        app.tabBars.buttons["Apps"].tap()
        let open = app.buttons["suite.backup.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()
        let manage = element("mediaVault.manage")
        var swipes = 0
        while !(manage.exists && manage.isHittable) && swipes < 8 { app.swipeUp(); swipes += 1 }
        guard manage.exists else { return XCTFail("no Manage copies row") }
        manage.tap()
        sleep(5)
        shot("9 manage copies")
        let tidy = element("mediaVault.tidy")
        note("manage: emptyFolders=\(tidy.exists) leftovers=\(element("mediaVault.leftovers").exists)")
        let removeAll = element("mediaVault.removeAll")
        XCTAssertTrue(removeAll.waitForExistence(timeout: 5))
        removeAll.tap()
        sleep(2)
        shot("10 remove all, asked")
        note("remove-all sheet buttons: \(app.sheets.buttons.allElementsBoundByIndex.map(\.label) + app.scrollViews.buttons.allElementsBoundByIndex.map(\.label))")
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "no Cancel — NOT tapping anything else")
        if cancel.exists { cancel.tap() }
        sleep(1)
        if tidy.exists {
            tidy.tap()
            sleep(2)
            shot("11 empty folders, asked")
            let toTrash = app.buttons["Move to trash"]
            if toTrash.waitForExistence(timeout: 5) {
                toTrash.tap()
                sleep(25)
                let status = element("mediaVault.manage.status")
                note("after removing empty folders: \(status.exists ? status.label : "no status") stillOffered=\(tidy.exists)")
                shot("12 empty folders removed")
            }
        }
        #endif
    }

    /// The part the first test could not see: the freed clip actually PLAYING from Google Drive, and
    /// the Wi-Fi-only message. Frees one copied clip, opens it, relaunches "on cellular", then
    /// brings it back. Its copy is left alone.
    func testAFreedClipPlaysFromDriveAndWiFiOnlyIsSaid() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("needs real Photos and a real Google Drive — device only")
        #else
        guard ProcessInfo.processInfo.environment["SNAPPET_DEVICE_COPY_ACTIONS"] == "1" else {
            throw XCTSkip("opt-in: set SNAPPET_DEVICE_COPY_ACTIONS=1; frees one clip and brings it back")
        }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        func words() -> String {
            ["Loading from Google Drive…", "Clip copies are set to Wi-Fi only.", "Play anyway", "Couldn’t load this clip from Google Drive",
             "Not on this phone", "You’re offline. It plays when you’re connected."]
                .filter { app.staticTexts[$0].exists || app.buttons[$0].exists }.joined(separator: " / ")
        }
        /// Tap the middle of the post under the first copy mark.
        func tapMedia() {
            let mark = element("clips.copyMark")
            guard mark.exists else { return }
            let window = app.windows.firstMatch.frame
            let y = min(mark.frame.midY + 320, window.maxY - 220)
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: window.midX, dy: y)).tap()
        }

        launch()
        guard openMenu() else { return XCTFail("no post with a copy mark") }
        let freeUp = menuItem("Remove from this iPhone")
        guard freeUp.exists, freeUp.isEnabled else { closeMenu(); return XCTFail("'Remove from this iPhone' is missing or disabled") }
        freeUp.tap()
        let delete = springboard.alerts.buttons["Delete"]
        guard delete.waitForExistence(timeout: 120) else { return XCTFail("iOS never asked to delete") }
        delete.tap()
        sleep(6)
        shot("A1 freed, in the feed")

        tapMedia()
        for second in [1, 3, 6, 10] {
            sleep(second == 1 ? 1 : 3)
            note("after tapping the freed clip (+\(second)s): [\(words())] player=\(element("feed.media.player").exists)")
            shot("A2 opened +\(second)s")
        }

        app.terminate()
        launch(["-vaultAssumeCellular", "YES"])
        _ = menuOfFirstCopiedPost()
        shot("B1 feed on cellular")
        tapMedia()
        sleep(4)
        note("on 'cellular' after tapping: [\(words())]")
        shot("B2 opened on cellular")
        let anyway = app.buttons["Play anyway"]
        XCTAssertTrue(anyway.waitForExistence(timeout: 10), "no Wi-Fi-only message — [\(words())]")
        if anyway.exists {
            anyway.tap()
            for second in [2, 6, 10] {
                sleep(second == 2 ? 2 : 4)
                note("after Play anyway (+\(second)s): [\(words())]")
                shot("B3 play anyway +\(second)s")
            }
        }

        // Put it back on the phone, from a fresh launch so no viewer is in the way.
        app.terminate()
        launch()
        guard openMenu() else { return XCTFail("the post is gone") }
        let bringBack = menuItem("Bring back to this iPhone")
        XCTAssertTrue(bringBack.exists, "no 'Bring back' item — the clip may still be on the phone")
        if bringBack.exists {
            bringBack.tap()
            sleep(60)
            XCTAssertTrue(openMenu())
            note("after bring back: freeUp=\(app.buttons["Remove from this iPhone"].exists) bringBack=\(app.buttons["Bring back to this iPhone"].exists)")
            XCTAssertTrue(app.buttons["Remove from this iPhone"].exists, "the clip is not back on the phone")
            shot("C menu after bringing back")
        }
        closeMenu()
        #endif
    }
}
