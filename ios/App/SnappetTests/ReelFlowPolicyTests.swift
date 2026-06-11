import XCTest
import HighlightEngine
@testable import Snappet

/// Unit tests for the **pure** reel-flow recovery policy (issue #72) — no PhotoKit, no HealthKit,
/// no simulator: which copy + actions each dead-end shows (denied-state selection especially),
/// when a regenerate needs confirming, where exports land outside tmp, and which old renders get
/// swept. The device-only halves (Settings deep-link, Photos save, real export) are not testable
/// here; the *decisions* that drive them are.
final class ReelFlowPolicyTests: XCTestCase {

    // MARK: - Reel empty state per Photo access

    func testAuthorizedEmptyOffersManualPick() {
        let spec = ReelFlowPolicy.emptyReelSpec(access: .authorized)
        XCTAssertEqual(spec.actions, [.selectClips])
        XCTAssertFalse(spec.actions.contains(.openSettings))
    }

    func testLimitedEmptyExtendsTheGrantInsteadOfPicking() {
        // PHPicker under .limited browses the FULL library but never widens the grant, and
        // media(forIdentifiers:) resolves only granted assets — picks outside the selection
        // silently vanish. The remedy is the system limited-library picker (the one surface
        // that extends the grant), never .selectClips (pre-merge review fix).
        let spec = ReelFlowPolicy.emptyReelSpec(access: .limited)
        XCTAssertEqual(spec.actions.first, .extendLimitedSelection,
                       "extending the limited selection is the remedy that actually works")
        XCTAssertFalse(spec.actions.contains(.selectClips),
                       "the full-library picker silently drops picks outside the grant")
        XCTAssertTrue(spec.actions.contains(.openSettings))
        XCTAssertTrue(spec.message.contains("selected"),
                      "the copy explains Snappet reads only the selected photos")
    }

    func testDeniedEmptyNeverOffersSelectClips() {
        // PHPicker would present under denial, but media(forIdentifiers:) resolves via
        // PHAsset.fetchAssets, which returns nothing — "Select clips" would be a second dead end.
        let spec = ReelFlowPolicy.emptyReelSpec(access: .denied)
        XCTAssertFalse(spec.actions.contains(.selectClips))
        XCTAssertEqual(spec.actions.first, .openSettings, "Settings is the only real remedy")
        XCTAssertTrue(spec.actions.contains(.tryAgain),
                      "returning from Settings needs an in-place retry")
    }

    func testNotDeterminedEmptyAsksForAccess() {
        let spec = ReelFlowPolicy.emptyReelSpec(access: .notDetermined)
        XCTAssertEqual(spec.actions, [.allowPhotoAccess])
    }

    // MARK: - Manual pick resolution (PHAsset.fetchAssets drops unreadable picks)

    func testAllPicksDroppedIsAllDropped() {
        XCTAssertEqual(ReelFlowPolicy.pickedMediaResolution(pickedCount: 3, resolvedCount: 0),
                       .allDropped,
                       "every pick outside the grant must not silently land back in .empty")
    }

    func testPartialDropProceedsAndCountsTheShortfall() {
        XCTAssertEqual(ReelFlowPolicy.pickedMediaResolution(pickedCount: 5, resolvedCount: 3),
                       .proceed(droppedCount: 2))
    }

    func testFullResolutionProceedsClean() {
        XCTAssertEqual(ReelFlowPolicy.pickedMediaResolution(pickedCount: 4, resolvedCount: 4),
                       .proceed(droppedCount: 0))
        XCTAssertEqual(ReelFlowPolicy.pickedMediaResolution(pickedCount: 0, resolvedCount: 0),
                       .proceed(droppedCount: 0), "an empty pick is a cancel, not a failure")
    }

    func testPickedClipsUnavailableSpecNamesTheCauseAndRemedies() {
        let spec = ReelFlowPolicy.pickedClipsUnavailableSpec()
        XCTAssertEqual(spec.actions, [.openSettings, .tryAgain])
        XCTAssertTrue(spec.message.contains("selection"),
                      "explains the picks aren't in Snappet's allowed Photos selection")
        XCTAssertFalse(spec.actions.contains(.selectClips),
                       "re-offering the picker that just failed would be a loop")
    }

    func testShortfallNoteOnlyForActualDrops() {
        XCTAssertNil(ReelFlowPolicy.pickedMediaShortfallNote(droppedCount: 0),
                     "the common everything-resolved case stays clean")
        let one = ReelFlowPolicy.pickedMediaShortfallNote(droppedCount: 1)
        XCTAssertTrue(one!.contains("1 picked clip "), "singular form")
        let three = ReelFlowPolicy.pickedMediaShortfallNote(droppedCount: 3)
        XCTAssertTrue(three!.contains("3 picked clips"), "plural form names the count")
    }

    // MARK: - Export failure is recoverable

    func testExportFailureOffersRetryThenBackToEdit() {
        let spec = ReelFlowPolicy.exportFailureSpec(message: "Export failed: out of space.")
        XCTAssertEqual(spec.actions, [.retryExport, .backToEdit])
        XCTAssertTrue(spec.message.contains("Export failed: out of space."),
                      "the underlying error is surfaced, not swallowed")
        XCTAssertTrue(spec.message.lowercased().contains("pins"),
                      "the copy reassures that curation survives")
    }

    func testGenerateFailureOffersTryAgain() {
        let spec = ReelFlowPolicy.generateFailureSpec(message: "boom")
        XCTAssertEqual(spec.actions, [.tryAgain])
        XCTAssertEqual(spec.message, "boom")
    }

    // MARK: - Workout list: truthful Health copy

    func testWorkoutsEmptyAcknowledgesInvisibleDenial() {
        let spec = ReelFlowPolicy.workoutsEmptySpec()
        XCTAssertEqual(spec.actions, [.refresh, .openSettings])
        XCTAssertTrue(spec.message.contains("permission"),
                      "must acknowledge that HealthKit read denial is possible")
        XCTAssertTrue(spec.message.contains("Privacy & Security > Health"),
                      "names the REAL path — the per-app Settings page has no Health row")
        XCTAssertFalse(spec.message.contains("pull to refresh"),
                       "the old copy promised a remedy that can't work under denial")
    }

    func testWorkoutsErrorOffersRetryAndSettings() {
        let spec = ReelFlowPolicy.workoutsErrorSpec(message: "Health data isn't available.")
        XCTAssertEqual(spec.actions, [.tryAgain, .openSettings])
        XCTAssertEqual(spec.message, "Health data isn't available.")
    }

    // MARK: - Regenerate confirmation

    func testNoConfirmationWhenNothingToLose() {
        XCTAssertNil(ReelFlowPolicy.regenerateConfirmation(
            pinnedCount: 0, removedCount: 0, hasCustomOrder: false, exportedUnsaved: false))
    }

    func testEachCurationDimensionTriggersConfirmation() {
        XCTAssertNotNil(ReelFlowPolicy.regenerateConfirmation(
            pinnedCount: 1, removedCount: 0, hasCustomOrder: false, exportedUnsaved: false))
        XCTAssertNotNil(ReelFlowPolicy.regenerateConfirmation(
            pinnedCount: 0, removedCount: 2, hasCustomOrder: false, exportedUnsaved: false))
        XCTAssertNotNil(ReelFlowPolicy.regenerateConfirmation(
            pinnedCount: 0, removedCount: 0, hasCustomOrder: true, exportedUnsaved: false))
    }

    func testUnsavedExportAloneTriggersConfirmation() {
        let message = ReelFlowPolicy.regenerateConfirmation(
            pinnedCount: 0, removedCount: 0, hasCustomOrder: false, exportedUnsaved: true)
        XCTAssertNotNil(message)
        XCTAssertTrue(message!.contains("Photos"), "names what's at stake")
        XCTAssertTrue(message!.contains("discards"),
                      "honest stakes: nothing implies the replaced cut is retrievable on-device")
        XCTAssertFalse(message!.contains("keeps your last few exports"),
                       "the keep-3 sweep is an internal safety net, not a user-facing promise")
    }

    func testCurationPlusUnsavedExportNamesBoth() {
        let message = ReelFlowPolicy.regenerateConfirmation(
            pinnedCount: 1, removedCount: 1, hasCustomOrder: true, exportedUnsaved: true)!
        XCTAssertTrue(message.contains("pins"))
        XCTAssertTrue(message.contains("Photos"))
    }

    // MARK: - Export destination (out of tmp)

    func testExportDirectoryAndFileNaming() {
        let support = URL(fileURLWithPath: "/data/Application Support", isDirectory: true)
        let dir = ReelFlowPolicy.exportsDirectory(under: support)
        XCTAssertEqual(dir.lastPathComponent, "Reels")
        XCTAssertTrue(dir.path.hasPrefix(support.path), "stays inside Application Support — not tmp")

        let id = UUID()
        let file = ReelFlowPolicy.exportURL(in: dir, id: id)
        XCTAssertEqual(file.pathExtension, "mp4")
        XCTAssertEqual(file.lastPathComponent, "snappet-reel-\(id.uuidString).mp4")
        XCTAssertEqual(file.deletingLastPathComponent(), dir)
    }

    // MARK: - Sweep keeps the newest renders

    private func render(_ name: String, age: TimeInterval) -> (url: URL, modifiedAt: Date) {
        (url: URL(fileURLWithPath: "/reels/\(name).mp4"),
         modifiedAt: Date(timeIntervalSince1970: 1_000_000 - age))
    }

    func testSweepKeepsNewestAndReturnsOlder() {
        let existing = [render("c", age: 30), render("a", age: 10), render("d", age: 40), render("b", age: 20)]
        let doomed = ReelFlowPolicy.sweepableExports(existing: existing, keepLatest: 2)
        XCTAssertEqual(doomed.map(\.lastPathComponent), ["c.mp4", "d.mp4"],
                       "oldest first dropped; newest two survive regardless of array order")
    }

    func testSweepUnderLimitDeletesNothing() {
        let existing = [render("a", age: 10), render("b", age: 20)]
        XCTAssertTrue(ReelFlowPolicy.sweepableExports(existing: existing, keepLatest: 3).isEmpty)
        XCTAssertTrue(ReelFlowPolicy.sweepableExports(existing: [], keepLatest: 3).isEmpty)
    }

    func testSweepTieBreaksDeterministically() {
        let same = Date(timeIntervalSince1970: 500)
        let existing = [
            (url: URL(fileURLWithPath: "/reels/b.mp4"), modifiedAt: same),
            (url: URL(fileURLWithPath: "/reels/a.mp4"), modifiedAt: same),
        ]
        let doomed = ReelFlowPolicy.sweepableExports(existing: existing, keepLatest: 1)
        XCTAssertEqual(doomed.map(\.lastPathComponent), ["b.mp4"],
                       "equal dates fall back to path order, so the sweep is stable")
    }

    func testDefaultKeepLatestIsSmallButNonZero() {
        XCTAssertGreaterThan(ReelFlowPolicy.keepLatestExports, 0,
                             "the cut on screen must always survive a sweep")
        XCTAssertLessThanOrEqual(ReelFlowPolicy.keepLatestExports, 5,
                                 "full-length renders are large; the net stays bounded")
    }

    // MARK: - Activity icons (workout rows)

    func testEveryActivityHasAnIcon() {
        for activity in Activity.allCases {
            XCTAssertFalse(ReelFlowPolicy.activityIcon(for: activity).isEmpty)
        }
    }

    func testIconsDistinguishTheHeadlineActivities() {
        XCTAssertEqual(ReelFlowPolicy.activityIcon(for: .climbing), "figure.climbing")
        XCTAssertNotEqual(ReelFlowPolicy.activityIcon(for: .running),
                          ReelFlowPolicy.activityIcon(for: .strength))
    }

    // MARK: - Action presentation (titles + identifiers)

    func testActionTitlesAndIdentifierSuffixesAreUnique() {
        let all: [ReelFlowPolicy.RecoveryAction] = [
            .selectClips, .extendLimitedSelection, .allowPhotoAccess, .openSettings, .tryAgain,
            .retryExport, .backToEdit, .refresh,
        ]
        XCTAssertEqual(Set(all.map(\.buttonTitle)).count, all.count)
        XCTAssertEqual(Set(all.map(\.identifierSuffix)).count, all.count)
        for action in all {
            XCTAssertFalse(action.buttonTitle.isEmpty)
            XCTAssertFalse(action.identifierSuffix.isEmpty)
        }
    }
}
