import SwiftData
import XCTest
@testable import Snappet

/// The clip vault (cloud-connect P4, prompt 269) — the pure core.
final class MediaVaultTests: XCTestCase {

    private let a = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let b = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    private let c = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!
    private let t0 = Date(timeIntervalSince1970: 1_780_000_000)

    private func clip(_ id: UUID, onPhone: Bool, local: String? = nil) -> MediaVaultClip {
        MediaVaultClip(rowID: id, localIdentifier: local ?? id.uuidString, isVideo: true, isOnPhone: onPhone)
    }
    private func index(_ ids: UUID...) -> MediaVaultIndex {
        MediaVaultIndex(files: ids.enumerated().map { (id: "f\($0.offset)", name: MediaVaultNaming.fileName(rowID: $0.element, fileExtension: "mov"), byteCount: 10) })
    }

    func testDefaultsKeepClipsOnThePhone() {
        XCTAssertFalse(MediaVaultSettings().keepCopies)
        XCTAssertTrue(MediaVaultSettings().wifiOnly)
        XCTAssertEqual(MediaVaultPolicy.decide(settings: .init(), signedIn: true, hasDrivePermission: true, network: .wifi),
                       .skip(.off))
    }

    func testPolicyNamesWhatIsInTheWay() {
        let on = MediaVaultSettings(keepCopies: true, started: true)
        XCTAssertEqual(MediaVaultPolicy.decide(settings: on, signedIn: false, hasDrivePermission: false, network: .wifi), .skip(.signedOut))
        XCTAssertEqual(MediaVaultPolicy.decide(settings: on, signedIn: true, hasDrivePermission: false, network: .wifi), .skip(.needsPermission))
        XCTAssertEqual(MediaVaultPolicy.decide(settings: on, signedIn: true, hasDrivePermission: true, network: .offline), .skip(.offline))
        XCTAssertEqual(MediaVaultPolicy.decide(settings: on, signedIn: true, hasDrivePermission: true, network: .cellular), .skip(.waitingForWiFi))
        XCTAssertEqual(MediaVaultPolicy.decide(settings: on, signedIn: true, hasDrivePermission: true, network: .wifi), .run)
        XCTAssertEqual(MediaVaultPolicy.decide(settings: on, signedIn: true, hasDrivePermission: true, network: .wifi,
                                               sessionRunning: true), .skip(.sessionRunning), "no copying mid-session (prompt 279)")
        XCTAssertEqual(MediaVaultPolicy.decide(settings: .init(keepCopies: true, started: true, wifiOnly: false), signedIn: true,
                                               hasDrivePermission: true, network: .cellular), .run)
    }

    func testSwitchingCopiesOnDoesNotCopyUntilStarted() throws {
        let on = MediaVaultSettings(keepCopies: true)
        XCTAssertFalse(on.started)
        XCTAssertEqual(MediaVaultPolicy.decide(settings: on, signedIn: true, hasDrivePermission: true, network: .wifi),
                       .skip(.notStarted))
        XCTAssertNil(MediaVaultText.skipped(.notStarted))
        // Settings saved before the Start button: copies that were on keep running, off stays off.
        let wasOn = try JSONDecoder().decode(MediaVaultSettings.self, from: Data(#"{"keepCopies":true}"#.utf8))
        XCTAssertTrue(wasOn.started)
        let wasOff = try JSONDecoder().decode(MediaVaultSettings.self, from: Data(#"{"keepCopies":false}"#.utf8))
        XCTAssertFalse(wasOff.started)
        XCTAssertEqual(try JSONDecoder().decode(MediaVaultSettings.self, from: try JSONEncoder().encode(on)), on)
    }

    func testACopySaysWhereItIsAndASessionSaysHowManyAreCopied() {
        let tree = MediaVaultFolderTree(rootID: "root", folders: [
            MediaVaultFolder(id: "f1", name: "Climbing", parentID: "root"),
            MediaVaultFolder(id: "f2", name: "2026-11-14 18.42", parentID: "f1"),
            MediaVaultFolder(id: "x", name: "Elsewhere", parentID: "not-ours")])
        let paths = tree.paths()
        XCTAssertEqual(paths["root"], [])
        XCTAssertEqual(paths["f2"], ["Climbing", "2026-11-14 18.42"])
        XCTAssertNil(paths["x"], "a folder that does not hang off the root is not ours to describe")
        XCTAssertEqual(MediaVaultText.location(folders: paths["f2"]), "Snappet Clips / Climbing / 2026-11-14 18.42")
        XCTAssertEqual(MediaVaultText.location(folders: paths["root"]), "Snappet Clips")
        XCTAssertEqual(MediaVaultText.location(folders: nil), "Google Drive", "moved by the person: no guess")

        XCTAssertNil(MediaVaultText.sessionCopies(copied: 0, total: 0))
        XCTAssertEqual(MediaVaultText.sessionCopies(copied: 0, total: 9), "None of 9 clips copied to Google Drive yet")
        XCTAssertEqual(MediaVaultText.sessionCopies(copied: 8, total: 9), "8 of 9 clips copied to Google Drive")
        XCTAssertEqual(MediaVaultText.sessionCopies(copied: 9, total: 9), "All 9 clips copied to Google Drive")
        XCTAssertEqual(MediaVaultText.sessionCopies(copied: 1, total: 1), "Clip copied to Google Drive")

        let index = self.index(a)
        XCTAssertEqual(index.copiedCount(of: [a, b, a]), 1)
        XCTAssertEqual(index.entry(for: a)?.driveURL?.absoluteString, "https://drive.google.com/file/d/f0/view")
    }

    func testEmptyFoldersAreTheOnesWithNoCopyAnywhereBelow() {
        let tree = MediaVaultFolderTree(rootID: "root", folders: [
            MediaVaultFolder(id: "act", name: "Climbing", parentID: "root"),
            MediaVaultFolder(id: "s1", name: "2026-11-14 18.42", parentID: "act"),
            MediaVaultFolder(id: "s2", name: "2026-11-15 19.00", parentID: "act"),
            MediaVaultFolder(id: "old", name: "2026-11-14 18.42 Climbing", parentID: "root"),
            MediaVaultFolder(id: "year", name: "2026", parentID: "root"),
            MediaVaultFolder(id: "month", name: "11 November", parentID: "year")])
        let empty = tree.emptyFolders(occupied: ["s1"])
        XCTAssertEqual(empty.count, 4, "s2, old, year and the month inside it")
        XCTAssertEqual(Set(empty.topmost), ["s2", "old", "year"], "the month goes with its year; Climbing still holds a copy below")
        XCTAssertEqual(tree.emptyFolders(occupied: ["s1", "s2", "old", "month"]).count, 0)
        XCTAssertEqual(MediaVaultText.emptyFolders(1), "1 empty folder left in Snappet Clips")
        XCTAssertEqual(MediaVaultText.removedFolders(17), "17 empty folders moved to Drive’s trash.")
        let trash = GoogleDriveAPI.trash(id: "abc")
        XCTAssertEqual(trash.httpMethod, "PATCH")
        XCTAssertEqual(trash.url?.absoluteString, "https://www.googleapis.com/drive/v3/files/abc?fields=id")
        XCTAssertEqual(String(data: trash.httpBody ?? Data(), encoding: .utf8), #"{"trashed":true}"#)
    }

    func testTwoClipsShotInTheSameSecondGetDifferentNames() {
        var first = info, second = info, later = info
        first.capturedAt = t0.addingTimeInterval(27.1)
        second.capturedAt = t0.addingTimeInterval(27.6)
        later.capturedAt = t0.addingTimeInterval(28.2)
        let placed = MediaVaultPaths.placements([a: second, b: first, c: later], layout: .bySession, timeZone: utc)
        let plain = place(first, .bySession).baseName
        XCTAssertEqual(placed[b]?.baseName, plain, "the earlier shot keeps the plain name")
        XCTAssertEqual(placed[a]?.baseName, plain + " 2")
        XCTAssertFalse(placed[c]!.baseName.hasSuffix(" 2"), "a different second is a different name already")
        XCTAssertNotEqual(placed[a]?.stamp, placed[b]?.stamp)
        XCTAssertEqual(MediaVaultPaths.placements([a: second, b: first, c: later], layout: .bySession, timeZone: utc), placed,
                       "the same answer every pass, so nothing is renamed back and forth")
        // The very same instant: the id decides.
        let tie = MediaVaultPaths.placements([a: first, b: first], layout: .flat, timeZone: utc)
        XCTAssertEqual(tie[a]?.baseName, plain)
        XCTAssertEqual(tie[b]?.baseName, plain + " 2")
    }

    // MARK: Cleaning up (prompt 274)

    private func entry(_ id: UUID, bytes: Int64 = 10, sent: Int64? = nil, md5: String? = nil, sentMD5: String? = nil) -> MediaVaultEntry {
        MediaVaultEntry(rowID: id, fileID: "f-" + id.uuidString.suffix(1), name: "x.mov", byteCount: bytes, sentBytes: sent,
                        md5: md5, sentMD5: sentMD5)
    }
    private func indexOf(_ entries: MediaVaultEntry...) -> MediaVaultIndex {
        var out = MediaVaultIndex()
        entries.forEach { out.insert($0) }
        return out
    }

    func testOnlyClipsThisPhoneDeletedLoseTheirCopyWithoutAsking() {
        let index = indexOf(entry(a), entry(b), entry(c))
        // a is still a clip; b was a clip here and is gone; c was never a clip on this phone.
        let plan = MediaVaultCleanup.plan(index: index, storeIDs: [a], known: [a, b], followDeletions: true)
        XCTAssertEqual(plan.remove.map(\.rowID), [b])
        XCTAssertEqual(plan.leftovers.map(\.rowID), [c], "another phone's copy is only ever offered")

        let off = MediaVaultCleanup.plan(index: index, storeIDs: [a], known: [a, b], followDeletions: false)
        XCTAssertTrue(off.remove.isEmpty, "switch off: nothing is removed without asking")
        XCTAssertEqual(Set(off.leftovers.map(\.rowID)), [b, c])
    }

    func testAnEmptyOrReplacedStoreNeverRemovesCopies() {
        let ids = (0..<40).map { _ in UUID() }
        var index = MediaVaultIndex()
        ids.forEach { index.insert(entry($0)) }
        XCTAssertEqual(MediaVaultCleanup.plan(index: index, storeIDs: [], known: Set(ids), followDeletions: true), .init(),
                       "a new or unrestored phone: every copy would look abandoned, so say nothing")
        // 30 of 40 known clips vanish at once: a restore or a broken store, not a person deleting.
        let mass = MediaVaultCleanup.plan(index: index, storeIDs: Set(ids.prefix(10)), known: Set(ids), followDeletions: true)
        XCTAssertTrue(mass.remove.isEmpty)
        XCTAssertEqual(mass.leftovers.count, 30, "offered, not done")
        // 5 of 40 is an ordinary clear-out.
        let few = MediaVaultCleanup.plan(index: index, storeIDs: Set(ids.prefix(35)), known: Set(ids), followDeletions: true)
        XCTAssertEqual(few.remove.count, 5)
    }

    func testAnOriginalMayLeaveThePhoneOnlyWhenDriveHoldsAllOfIt() {
        XCTAssertTrue(MediaVaultCleanup.isVerified(entry(a, bytes: 500, sent: 500, md5: "AB12", sentMD5: "ab12")))
        XCTAssertFalse(MediaVaultCleanup.isVerified(entry(a, bytes: 499, sent: 500, md5: "ab12", sentMD5: "ab12")), "Drive holds less than was sent")
        XCTAssertFalse(MediaVaultCleanup.isVerified(entry(a, bytes: 0, sent: 0, md5: "ab12", sentMD5: "ab12")), "an empty file proves nothing")
        XCTAssertFalse(MediaVaultCleanup.isVerified(entry(a, bytes: 500, sent: 500, md5: "ab12", sentMD5: "cd34")),
                       "the right size and the wrong content")
        XCTAssertFalse(MediaVaultCleanup.isVerified(entry(a, bytes: 500, sent: 500, sentMD5: "ab12")), "no checksum from Drive proves nothing")
        XCTAssertFalse(MediaVaultCleanup.isVerified(entry(a, bytes: 500, sent: 500, md5: "ab12")), "no recorded checksum and nothing measured")
        XCTAssertFalse(MediaVaultCleanup.isVerified(entry(a, bytes: 500, md5: "ab12")), "no recorded size and nothing measured")
        XCTAssertTrue(MediaVaultCleanup.isVerified(entry(a, bytes: 500, md5: "ab12"), measured: 500, measuredMD5: "ab12"),
                      "an older copy: measured against the original")
        XCTAssertFalse(MediaVaultCleanup.isVerified(entry(a, bytes: 500, md5: "ab12"), measured: 501, measuredMD5: "ab12"))
        XCTAssertFalse(MediaVaultCleanup.isVerified(entry(a, bytes: 500, md5: "ab12"), measured: 500, measuredMD5: "ff00"))
        XCTAssertTrue(MediaVaultCleanup.needsMeasuring(entry(a, sent: 10)))
        XCTAssertFalse(MediaVaultCleanup.needsMeasuring(entry(a, sent: 10, sentMD5: "ab12")))

        // a and b are two clips of ONE asset; only a is verified, so the asset stays.
        let shared = [clip(a, onPhone: true, local: "L1"), clip(b, onPhone: true, local: "L1"), clip(c, onPhone: true, local: "L2")]
        XCTAssertEqual(MediaVaultCleanup.freeable(shared, verified: [a, c]), ["L2"])
        XCTAssertEqual(MediaVaultCleanup.freeable(shared, verified: [a, b, c]), ["L1", "L2"])
        XCTAssertEqual(MediaVaultCleanup.freeable([clip(a, onPhone: false, local: "L1")], verified: [a]), [], "already off the phone")
    }

    // MARK: Fetching a clip that is only in Drive (prompt 276)

    func testLargeVideosStreamAndEverythingElseDownloadsOnce() {
        let big = MediaVaultFetch.streamAbove + 1
        XCTAssertEqual(MediaVaultFetch.mode(isVideo: true, byteCount: big, isCached: false), .stream)
        XCTAssertEqual(MediaVaultFetch.mode(isVideo: true, byteCount: MediaVaultFetch.streamAbove, isCached: false), .download)
        XCTAssertEqual(MediaVaultFetch.mode(isVideo: false, byteCount: big, isCached: false), .download, "a photo is never streamed")
        XCTAssertEqual(MediaVaultFetch.mode(isVideo: true, byteCount: big, isCached: true), .cached)
    }

    func testWhatStandsInTheWayOfAFetch() {
        func blocked(_ network: CloudBackupNetwork, mode: MediaVaultFetch.Mode = .download, drive: Bool = true,
                     wifiOnly: Bool = true, allowed: Bool = false) -> MediaVaultFetch.Blocked? {
            MediaVaultFetch.blocked(mode: mode, canUseDrive: drive, wifiOnly: wifiOnly, network: network, allowed: allowed, bytes: 900)
        }
        XCTAssertNil(blocked(.wifi))
        XCTAssertEqual(blocked(.cellular), .wifiOnly(bytes: 900))
        XCTAssertEqual(blocked(.cellular, mode: .stream), .wifiOnly(bytes: 900), "streaming is a fetch too")
        XCTAssertNil(blocked(.cellular, allowed: true), "the person said play anyway")
        XCTAssertNil(blocked(.cellular, wifiOnly: false))
        XCTAssertEqual(blocked(.offline), .offline)
        XCTAssertEqual(blocked(.offline, allowed: true), .offline)
        XCTAssertEqual(blocked(.wifi, drive: false), .signedOut)
        XCTAssertNil(blocked(.offline, mode: .cached, drive: false), "a cached clip needs no network and no account")
        XCTAssertEqual(MediaVaultText.blocked(.wifiOnly(bytes: 900)).action, "Play anyway")
        XCTAssertNil(MediaVaultText.blocked(.offline).action)
        XCTAssertNil(MediaVaultText.blocked(.signedOut).action)
    }

    func testAStreamAsksForTheFileInPieces() {
        XCTAssertEqual(MediaVaultFetch.chunks(offset: 0, length: 10, total: 100, chunk: 4), [0..<4, 4..<8, 8..<10])
        XCTAssertEqual(MediaVaultFetch.chunks(offset: 95, length: 50, total: 100, chunk: 4), [95..<99, 99..<100], "never past the end")
        XCTAssertEqual(MediaVaultFetch.chunks(offset: 100, length: 5, total: 100, chunk: 4), [])
        XCTAssertEqual(MediaVaultFetch.chunks(offset: 3, length: 0, total: 100, chunk: 4), [])
        XCTAssertEqual(MediaVaultFetch.rangeHeader(0..<1024), "bytes=0-1023", "HTTP ranges include their last byte")
        XCTAssertEqual(MediaVaultFetch.contentType(fileExtension: "MOV"), "com.apple.quicktime-movie")
        XCTAssertEqual(MediaVaultFetch.contentType(fileExtension: "mp4"), "public.mpeg-4")
        XCTAssertEqual(MediaVaultFetch.contentType(fileExtension: "xyz"), "public.movie")
        XCTAssertNil(MediaVaultText.usedInStudio(0))
        XCTAssertEqual(MediaVaultText.usedInStudio(1)?.hasPrefix("1 of these is used in a Studio project."), true)
    }

    func testOnlyAnAssetFiledUnderTheMomentItWasSavedIsRedated() {
        let saved = Date(timeIntervalSince1970: 1_800_000_000), ended = saved.addingTimeInterval(8)
        let filmed = saved.addingTimeInterval(-90 * 86_400)
        func fix(_ assigned: Date?, known: Date? = filmed) -> Date? {
            MediaVaultRestoreDate.correction(assigned: assigned, saveStarted: saved, saveEnded: ended, known: known)
        }
        XCTAssertEqual(fix(saved.addingTimeInterval(3)), filmed, "Photos filed it under now")
        XCTAssertEqual(fix(ended.addingTimeInterval(60)), filmed, "a slow save is still now")
        XCTAssertEqual(fix(nil), filmed, "no date at all")
        XCTAssertNil(fix(filmed.addingTimeInterval(40)), "the file's own date stands, even where it differs from Snappet's")
        XCTAssertNil(fix(saved.addingTimeInterval(-3_600)), "an hour before the save is a real date, not a stamp")
        XCTAssertNil(fix(saved.addingTimeInterval(86_400)), "a date in the future is the file's business")
        XCTAssertNil(fix(saved, known: nil), "nothing known: nothing to put there")
        XCTAssertNil(fix(saved, known: saved.addingTimeInterval(-30)), "filmed a moment ago: now is right")
        XCTAssertNil(fix(saved, known: saved.addingTimeInterval(500)), "a known date in the future is wrong")
        XCTAssertNil(fix(saved, known: Date(timeIntervalSince1970: 0)), "a zeroed date is not a capture time")
    }

    // MARK: Choosing what to free up (prompt 275)

    private func item(_ id: UUID, asset: String, daysAgo: Int, activity: String, session: UUID, bytes: Int64 = 100,
                      now: Date) -> MediaVaultFreeUpItem {
        let filmed = now.addingTimeInterval(-Double(daysAgo) * 86_400)
        return MediaVaultFreeUpItem(id: id, asset: asset, capturedAt: filmed, activity: activity, sessionID: session,
                                    sessionStartedAt: filmed, bytes: bytes)
    }

    func testFreeUpChoiceNarrowsByAgeActivityAndSession() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        let s1 = UUID(), s2 = UUID(), s3 = UUID()
        let items = [item(a, asset: "L1", daysAgo: 5, activity: "Climbing", session: s1, now: now),
                     item(b, asset: "L2", daysAgo: 45, activity: "Climbing", session: s2, now: now),
                     item(c, asset: "L3", daysAgo: 400, activity: "Gym", session: s3, now: now)]
        func ids(_ choice: MediaVaultFreeUpChoice) -> Set<UUID> {
            Set(MediaVaultFreeUp.selection(items, choice: choice, now: now, calendar: utc).map(\.id))
        }
        XCTAssertEqual(ids(.init()), [a, b, c], "nothing chosen: everything")
        XCTAssertEqual(ids(.init(age: .days30)), [b, c])
        XCTAssertEqual(ids(.init(age: .months6)), [c])
        XCTAssertEqual(ids(.init(age: .year1)), [c])
        XCTAssertEqual(ids(.init(activities: ["Climbing"])), [a, b])
        XCTAssertEqual(ids(.init(activities: [])), [], "every activity unticked: nothing")
        XCTAssertEqual(ids(.init(sessions: [s1, s3])), [a, c])
        XCTAssertEqual(ids(.init(age: .days30, activities: ["Climbing"])), [b], "the parts narrow each other")
        XCTAssertEqual(ids(.init(age: .days30, activities: ["Climbing"], sessions: [s1])), [])
        // The session list follows age and activity, newest first.
        let listed = MediaVaultFreeUp.sessions(MediaVaultFreeUp.narrowed(items, choice: .init(age: .days30), now: now, calendar: utc))
        XCTAssertEqual(listed.map(\.id), [s2.uuidString, s3.uuidString])
        XCTAssertEqual(MediaVaultFreeUp.activities(items).map(\.name), ["Climbing", "Gym"])
        XCTAssertEqual(MediaVaultFreeUp.activities(items).map(\.clips), [2, 1])
    }

    func testAnOriginalSharedByTwoClipsLeavesOnlyWhenBothAreChosen() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let s1 = UUID(), s2 = UUID()
        // a and b are one original, used in two sessions.
        let items = [item(a, asset: "L1", daysAgo: 5, activity: "Climbing", session: s1, bytes: 700, now: now),
                     item(b, asset: "L1", daysAgo: 5, activity: "Gym", session: s2, bytes: 700, now: now),
                     item(c, asset: "L2", daysAgo: 5, activity: "Gym", session: s2, bytes: 50, now: now)]
        XCTAssertEqual(MediaVaultFreeUp.selection(items, choice: .init(sessions: [s2]), now: now).map(\.id), [c],
                       "freeing one session never takes footage out from under another")
        XCTAssertEqual(MediaVaultFreeUp.selection(items, choice: .init(activities: ["Climbing"]), now: now).map(\.id), [])
        let everything = MediaVaultFreeUp.selection(items, choice: .init(), now: now)
        XCTAssertEqual(everything.map(\.id), [a, b, c])
        XCTAssertEqual(MediaVaultFreeUp.total(everything).count, 2, "a shared original counts once")
        XCTAssertEqual(MediaVaultFreeUp.total(everything).bytes, 750)
        XCTAssertEqual(MediaVaultText.freeUpTotal(count: 1, bytes: 0).hasPrefix("1 clip · "), true)
    }

    func testTheSentSizeTravelsOnTheDriveFileAndARemovedCopyIsNotCopiedAgain() throws {
        XCTAssertEqual(MediaVaultTag.properties(rowID: a, stamp: "s", bytes: 1234)["bytes"], "1234")
        XCTAssertNil(MediaVaultTag.properties(rowID: a, stamp: "s")["bytes"])
        let json = #"{"files":[{"id":"f1","name":"x.mov","size":"1234","parents":["p"],"appProperties":{"snappet":"clip","clip":"00000000-0000-0000-0000-00000000000a","bytes":"1234"}}]}"#
        let file = try JSONDecoder().decode(GoogleDriveAPI.SizedPage.self, from: Data(json.utf8)).files[0].vaultFile
        XCTAssertEqual(file.sentBytes, 1234)
        XCTAssertEqual(MediaVaultIndex(files: [file]).entry(for: a)?.sentBytes, 1234)

        let clips = [clip(a, onPhone: true), clip(b, onPhone: true)]
        XCTAssertEqual(MediaVaultPlanner.toUpload(clips, index: .init(), excluding: [a]).map(\.rowID), [b])
        XCTAssertEqual(MediaVaultPlanner.coverage(clips, index: index(b), excluding: [a]),
                       .init(copied: 1, total: 1, onlyInVault: 0), "a clip left out on purpose is not counted as waiting")
        XCTAssertTrue(MediaVaultSettings().removeWithClip)
        XCTAssertTrue(try JSONDecoder().decode(MediaVaultSettings.self, from: Data(#"{"keepCopies":true}"#.utf8)).removeWithClip)
        XCTAssertEqual(MediaVaultText.leftovers(3), "3 copies of clips that are no longer in Snappet")
        XCTAssertEqual(MediaVaultText.freed(count: 2, bytes: 0, unverified: 1).hasSuffix("1 was kept: its copy could not be confirmed."), true)
    }

    func testFileNamesRoundTripToTheClipAndIgnoreForeignFiles() {
        let name = MediaVaultNaming.fileName(rowID: a, fileExtension: "MOV")
        XCTAssertEqual(name, "00000000-0000-0000-0000-00000000000a.mov")
        XCTAssertEqual(MediaVaultNaming.rowID(fromFileName: name), a)
        XCTAssertNil(MediaVaultNaming.rowID(fromFileName: "holiday.mov"))
        XCTAssertNil(MediaVaultNaming.rowID(fromFileName: "no-extension"))
        XCTAssertEqual(MediaVaultNaming.fileName(rowID: a, fileExtension: "../x"), "00000000-0000-0000-0000-00000000000a.x")
        XCTAssertEqual(MediaVaultNaming.fileExtension(isVideo: true, mimeType: "video/mp4", fileName: nil), "mp4")
        XCTAssertEqual(MediaVaultNaming.fileExtension(isVideo: true, mimeType: "video/mp4", fileName: "IMG_1.MOV"), "mov")
        XCTAssertEqual(MediaVaultNaming.fileExtension(isVideo: false, mimeType: nil, fileName: nil), "jpg")
    }

    func testIndexIsBuiltFromAListingAndIsStableUnderDuplicates() {
        let name = MediaVaultNaming.fileName(rowID: a, fileExtension: "mov")
        let files: [(id: String, name: String, byteCount: Int64)] =
            [("z9", name, 5), ("a1", name, 7), ("m", "notes.txt", 1),
             ("b2", MediaVaultNaming.fileName(rowID: b, fileExtension: "jpg"), 3)]
        let index = MediaVaultIndex(files: files)
        XCTAssertEqual(index.count, 2)
        XCTAssertEqual(index.entry(for: a)?.fileID, "a1", "a clip uploaded twice resolves to one file, whatever the listing order")
        XCTAssertEqual(MediaVaultIndex(files: files.reversed()), index)
        XCTAssertEqual(index.totalBytes, 10)
        XCTAssertFalse(index.contains(c))
    }

    func testOnlyClipsOnThePhoneAndNotYetCopiedAreUploaded() {
        let clips = [clip(c, onPhone: true), clip(a, onPhone: true), clip(b, onPhone: false)]
        XCTAssertEqual(MediaVaultPlanner.toUpload(clips, index: index(a)).map(\.rowID), [c])
        XCTAssertEqual(MediaVaultPlanner.toUpload(clips, index: index()).map(\.rowID), [a, c], "stable order")
        XCTAssertEqual(MediaVaultPlanner.toUpload(clips, index: index(), limit: 1).map(\.rowID), [a])
        XCTAssertEqual(MediaVaultPlanner.coverage(clips, index: index(a, b)),
                       .init(copied: 2, total: 3, onlyInVault: 1))
    }

    func testSourceOrderIsPhotosThenCacheThenVault() {
        XCTAssertEqual(MediaSource.resolve(isOnPhone: true, isCached: true, isInVault: true), .photos)
        XCTAssertEqual(MediaSource.resolve(isOnPhone: false, isCached: true, isInVault: true), .cache)
        XCTAssertEqual(MediaSource.resolve(isOnPhone: false, isCached: false, isInVault: true), .vault)
        XCTAssertEqual(MediaSource.resolve(isOnPhone: false, isCached: false, isInVault: false), .missing)
    }

    func testCacheEvictsLeastRecentlyUsedButNeverTheClipAboutToPlay() {
        let files = [MediaVaultCache.File(name: "old", byteCount: 60, lastUsed: t0),
                     .init(name: "mid", byteCount: 60, lastUsed: t0.addingTimeInterval(10)),
                     .init(name: "new", byteCount: 60, lastUsed: t0.addingTimeInterval(20))]
        XCTAssertEqual(MediaVaultCache.toEvict(files, limit: 200), [])
        XCTAssertEqual(MediaVaultCache.toEvict(files, limit: 130), ["old"])
        XCTAssertEqual(MediaVaultCache.toEvict(files, limit: 70), ["old", "mid"])
        XCTAssertEqual(MediaVaultCache.toEvict(files, limit: 70, keeping: "old"), ["mid", "new"])
        XCTAssertEqual(MediaVaultCache.toEvict(files, limit: 0, keeping: "new"), ["old", "mid"])
    }

    func testWording() {
        XCTAssertEqual(MediaVaultText.coverage(.init(copied: 0, total: 0, onlyInVault: 0), bytes: 0), "No clips yet")
        XCTAssertTrue(MediaVaultText.coverage(.init(copied: 312, total: 420, onlyInVault: 0), bytes: 0).hasPrefix("312 of 420 clips copied"))
        XCTAssertEqual(MediaVaultText.importOutcome(saved: 2, unmatched: 1, failed: 0), "2 clips brought back · 1 pick didn’t match a missing clip")
        XCTAssertEqual(MediaVaultText.importOutcome(saved: 0, unmatched: 0, failed: 1), "1 couldn’t be copied")
        XCTAssertEqual(MediaVaultText.importOutcome(saved: 0, unmatched: 0, failed: 0), "Nothing was picked")
        XCTAssertEqual(MediaVaultText.skipped(.waitingForWiFi), "Waiting for Wi-Fi.")
    }

    // MARK: - Folder layout (prompt 270)

    private let utc = TimeZone(identifier: "UTC")!
    /// 2026-05-28 20:26:40 UTC.
    private var info: MediaVaultClipInfo {
        MediaVaultClipInfo(capturedAt: t0.addingTimeInterval(27), sessionStartedAt: t0, activity: "Climbing")
    }
    private func place(_ info: MediaVaultClipInfo, _ layout: MediaVaultLayout, zone: TimeZone? = nil) -> MediaVaultPlacement {
        MediaVaultPaths.placement(info, layout: layout, timeZone: zone ?? utc)
    }

    func testSettingsSavedBeforeLayoutsStillLoadAndDefaultToBySession() throws {
        let old = try JSONDecoder().decode(MediaVaultSettings.self, from: Data(#"{"keepCopies":true,"wifiOnly":false}"#.utf8))
        XCTAssertEqual(old, MediaVaultSettings(keepCopies: true, started: true, wifiOnly: false, layout: .bySession, timeZoneID: nil))
        let unknown = try JSONDecoder().decode(MediaVaultSettings.self, from: Data(#"{"keepCopies":true,"layout":"byMoonPhase"}"#.utf8))
        XCTAssertEqual(unknown.layout, .bySession, "a layout this build does not know is not a crash")
        var chosen = MediaVaultSettings(keepCopies: true, started: true)
        chosen.layout = .byMonth
        chosen.timeZoneID = "Europe/Amsterdam"
        XCTAssertEqual(try JSONDecoder().decode(MediaVaultSettings.self, from: try JSONEncoder().encode(chosen)), chosen)
        XCTAssertEqual(chosen.timeZone.identifier, "Europe/Amsterdam")
        XCTAssertEqual(MediaVaultLayout.allCases.map(\.label), ["By session", "By activity, then session", "By month", "One folder"])
    }

    func testEachLayoutPutsAClipWhereItsLabelSays() {
        XCTAssertEqual(place(info, .bySession), .init(folders: ["2026-05-28 20.26 Climbing"], baseName: "2026-05-28 20.27.07 Climbing"))
        XCTAssertEqual(place(info, .byActivity).folders, ["Climbing", "2026-05-28 20.26"])
        XCTAssertEqual(place(info, .byMonth).folders, ["2026", "05 May"])
        XCTAssertEqual(place(info, .flat).folders, [])
        XCTAssertEqual(place(info, .flat).baseName, "2026-05-28 20.27.07 Climbing", "the name carries the date in every layout")
        XCTAssertEqual(place(info, .bySession).fileName(fileExtension: "MOV"), "2026-05-28 20.27.07 Climbing.mov")
    }

    func testNamesAreWrittenInTheGivenTimeZone() {
        let amsterdam = TimeZone(identifier: "Europe/Amsterdam")!   // UTC+2 in May
        XCTAssertEqual(place(info, .bySession, zone: amsterdam).folders, ["2026-05-28 22.26 Climbing"])
        let lateNight = MediaVaultClipInfo(capturedAt: t0.addingTimeInterval(4 * 3600), sessionStartedAt: t0, activity: "Festival")
        let placed = place(lateNight, .byMonth, zone: amsterdam)
        XCTAssertEqual(placed.folders, ["2026", "05 May"], "a session is filed by when it STARTED")
        XCTAssertEqual(placed.baseName, "2026-05-29 02.26.40 Festival", "a clip after midnight still sorts after the ones before")
    }

    func testAFestivalNightIsFiledUnderItsFestivalAndNamedByArtist() {
        var night = MediaVaultClipInfo(capturedAt: t0.addingTimeInterval(60), sessionStartedAt: t0, activity: "Festival",
                                       festival: "Dekmantel 2026", artist: nil)
        XCTAssertEqual(place(night, .byActivity).folders, ["Festival", "Dekmantel 2026", "2026-05-28 20.26"])
        XCTAssertEqual(place(night, .bySession).folders, ["2026-05-28 20.26 Dekmantel 2026"])
        XCTAssertEqual(place(night, .byActivity).baseName, "2026-05-28 20.27.40 Festival", "not tagged to an artist yet")
        let untagged = place(night, .byActivity)
        night.artist = "AC/DC: Live"
        let tagged = place(night, .byActivity)
        XCTAssertEqual(tagged.baseName, "2026-05-28 20.27.40 AC-DC- Live", "no path separators in a name")
        XCTAssertEqual(tagged.folders, untagged.folders, "tagging an artist renames the file; it does not move it")
        night.festival = nil
        XCTAssertEqual(place(night, .byActivity).folders, ["Festival", "2026-05-28 20.26"], "a night whose lineup is gone")
    }

    func testNamesAreCleaned() {
        XCTAssertEqual(MediaVaultPaths.clean("  a/b\\c:d\n e  "), "a-b-c-d e")
        XCTAssertEqual(MediaVaultPaths.clean(" \n "), "Untitled")
        XCTAssertEqual(MediaVaultPaths.clean(String(repeating: "x", count: 200)).count, 80)
    }

    func testTheStampChangesExactlyWhenThePlaceDoes() {
        let one = place(info, .bySession)
        XCTAssertEqual(one.stamp, place(info, .bySession).stamp)
        XCTAssertEqual(one.stamp, "9d05ca9b0b4d3c0c", "stable across launches and phones — it is stored in Drive")
        XCTAssertNotEqual(one.stamp, place(info, .byMonth).stamp)
        XCTAssertNotEqual(place(info, .flat).stamp, MediaVaultPlacement(folders: [], baseName: "other").stamp)
        XCTAssertLessThan(MediaVaultTag.clipKey.utf8.count + 36, 124, "Drive allows 124 bytes per private property")
    }

    func testAFileSaysWhoseItIsInItsPropertiesOrItsOldName() {
        let tagged = MediaVaultFile(id: "f2", name: "2026-05-28 20.27.07 Climbing.mov", byteCount: 9, parentID: "P",
                                    clipID: a, stamp: "s1")
        let legacy = MediaVaultFile(id: "f1", name: MediaVaultNaming.fileName(rowID: b, fileExtension: "mov"), byteCount: 4,
                                    parentID: "ROOT", clipID: nil, stamp: "ignored")
        let foreign = MediaVaultFile(id: "f0", name: "holiday.mov", byteCount: 1)
        let index = MediaVaultIndex(files: [tagged, legacy, foreign])
        XCTAssertEqual(index.count, 2)
        XCTAssertEqual(index.entry(for: a), MediaVaultEntry(rowID: a, fileID: "f2", name: tagged.name, byteCount: 9, parentID: "P", stamp: "s1"))
        XCTAssertNil(index.entry(for: b)?.stamp, "a copy from before prompt 270 has never been placed")
        XCTAssertEqual(index.entry(for: a)?.cacheName, "00000000-0000-0000-0000-00000000000a.mov", "cached by clip id: Drive names may repeat")
        XCTAssertEqual(MediaVaultTag.clipID(from: MediaVaultTag.properties(rowID: a, stamp: nil)), a)
        XCTAssertNil(MediaVaultTag.clipID(from: ["clip": a.uuidString]), "without Snappet's marker it is not ours")
        XCTAssertNil(MediaVaultTag.clipID(from: nil))
    }

    func testAJustUploadedClipIsKeptWhenTheListingLags() {
        var mine = MediaVaultIndex()
        mine.insert(MediaVaultEntry(rowID: a, fileID: "new", name: "x.mov", byteCount: 1, addedAt: t0))
        mine.insert(MediaVaultEntry(rowID: b, fileID: "old", name: "y.mov", byteCount: 1, addedAt: t0.addingTimeInterval(-3600)))
        mine.insert(MediaVaultEntry(rowID: c, fileID: "listed-before", name: "z.mov", byteCount: 1))
        let listing = MediaVaultIndex()
        let merged = listing.keepingRecentUploads(from: mine, now: t0.addingTimeInterval(30))
        XCTAssertTrue(merged.contains(a), "uploaded 30 s ago: Drive search may not show it yet")
        XCTAssertFalse(merged.contains(b), "an hour on, a file missing from the listing is gone")
        XCTAssertFalse(merged.contains(c), "and so is one this phone only ever saw listed")
    }

    func testFolderPathsAreFoundBeforeTheyAreCreated() {
        var tree = MediaVaultFolderTree(rootID: "ROOT", folders: [
            .init(id: "z", name: "Climbing", parentID: "ROOT"), .init(id: "b", name: "Climbing", parentID: "ROOT"),
            .init(id: "s1", name: "2026-05-28 20.26", parentID: "b"), .init(id: "ROOT", name: "Snappet Clips", parentID: "drive-root"),
            .init(id: "orphan", name: "Climbing", parentID: nil)])
        XCTAssertEqual(tree.resolve([]).id, "ROOT")
        XCTAssertEqual(tree.resolve(["Climbing"]).id, "b", "two folders with one name: the lowest id, whatever the order")
        XCTAssertEqual(tree.resolve(["Climbing", "2026-05-28 20.26"]).id, "s1")
        let partly = tree.resolve(["Climbing", "2026-06-01 09.00", "deeper"])
        XCTAssertEqual(partly.id, "b")
        XCTAssertEqual(partly.missing, ["2026-06-01 09.00", "deeper"])
        tree.insert(.init(id: "new", name: "2026-06-01 09.00", parentID: "b"))
        XCTAssertEqual(tree.resolve(["Climbing", "2026-06-01 09.00"]).missing, [])
    }

    func testOnlyCopiesWhoseWantedPlaceChangedAreMoved() {
        let here = place(info, .bySession), there = place(info, .byMonth)
        let index = MediaVaultIndex(files: [
            MediaVaultFile(id: "f1", name: "renamed by me.MOV", byteCount: 1, parentID: "P1", clipID: a, stamp: here.stamp),
            MediaVaultFile(id: "f2", name: MediaVaultNaming.fileName(rowID: b, fileExtension: "mp4"), byteCount: 1, parentID: "ROOT"),
            MediaVaultFile(id: "f3", name: "gone.mov", byteCount: 1, parentID: "P1", clipID: c, stamp: "whatever")])
        XCTAssertEqual(MediaVaultOrganizer.moves(index: index, placements: [a: here, b: here]), [
            .init(rowID: b, fileID: "f2", folders: here.folders, name: "2026-05-28 20.27.07 Climbing.mp4", stamp: here.stamp, fromParentID: "ROOT")],
            "a is where the app last put it — the person's own rename is left alone; c is no longer a clip here")
        let all = MediaVaultOrganizer.moves(index: index, placements: [a: there, b: there])
        XCTAssertEqual(all.map(\.rowID), [a, b], "a new layout moves every copy, in a stable order")
        XCTAssertEqual(all.first?.name, "2026-05-28 20.27.07 Climbing.mov")
        XCTAssertEqual(all.first?.fromParentID, "P1")
        XCTAssertEqual(MediaVaultOrganizer.moves(index: index, placements: [a: there, b: there], limit: 1).map(\.rowID), [a])
    }

    func testLayoutRequestShapes() throws {
        func items(_ request: URLRequest) -> [String: String] {
            Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .map { ($0.name, $0.value ?? "") })
        }
        func body(_ request: URLRequest) throws -> String { String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self) }
        XCTAssertEqual(items(GoogleDriveAPI.clipFiles())["q"], "appProperties has { key='snappet' and value='clip' } and trashed = false")
        XCTAssertEqual(items(GoogleDriveAPI.clipFiles())["fields"], "nextPageToken,files(id,name,size,parents,appProperties,md5Checksum)")
        XCTAssertEqual(items(GoogleDriveAPI.folders(pageToken: "p2"))["q"], "mimeType = 'application/vnd.google-apps.folder' and trashed = false")
        XCTAssertEqual(items(GoogleDriveAPI.folders(pageToken: "p2"))["pageToken"], "p2")
        XCTAssertEqual(try body(GoogleDriveAPI.createFolder(named: "Climbing", parent: "ROOT")),
                       #"{"mimeType":"application/vnd.google-apps.folder","name":"Climbing","parents":["ROOT"]}"#)
        let upload = GoogleDriveAPI.startUpload(name: "x.mov", byteCount: 9, parent: "F1", appProperties: ["snappet": "clip"])
        XCTAssertEqual(try body(upload), #"{"appProperties":{"snappet":"clip"},"name":"x.mov","parents":["F1"]}"#)

        let move = GoogleDriveAPI.relocate(id: "f1", name: "n.mov", appProperties: ["placed": "s"], addParent: "NEW", removeParent: "OLD")
        XCTAssertEqual(move.httpMethod, "PATCH")
        XCTAssertEqual(move.url?.path, "/drive/v3/files/f1")
        XCTAssertEqual(items(move)["addParents"], "NEW")
        XCTAssertEqual(items(move)["removeParents"], "OLD")
        XCTAssertEqual(try body(move), #"{"appProperties":{"placed":"s"},"name":"n.mov"}"#)
        let rename = GoogleDriveAPI.relocate(id: "f1", name: "n.mov", appProperties: [:], addParent: "SAME", removeParent: "SAME")
        XCTAssertNil(items(rename)["addParents"], "already in the right folder: a rename only")
        let page = try GoogleDriveAPI.sizedPage(from: Data(#"{"files":[{"id":"f1","name":"n.mov","size":"12","parents":["P"],"appProperties":{"snappet":"clip","clip":"00000000-0000-0000-0000-00000000000a","placed":"s"}}]}"#.utf8))
        XCTAssertEqual(page.files.first?.vaultFile, MediaVaultFile(id: "f1", name: "n.mov", byteCount: 12, parentID: "P", clipID: a, stamp: "s"))
    }

    // MARK: - Drive + Picker request shapes

    func testClipFolderRequestsAreScopedToTheFolder() throws {
        func q(_ request: URLRequest) -> String? {
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value
        }
        XCTAssertEqual(q(GoogleDriveAPI.findFolder(named: "Snappet Clips")),
                       "name = 'Snappet Clips' and mimeType = 'application/vnd.google-apps.folder' and trashed = false")
        XCTAssertEqual(q(GoogleDriveAPI.children(ofFolder: "F1")), "'F1' in parents and trashed = false")
        XCTAssertEqual(GoogleDriveAPI.escape("it's"), "it\\'s")
        let create = GoogleDriveAPI.createFolder(named: "Snappet Clips")
        XCTAssertEqual(String(decoding: try XCTUnwrap(create.httpBody), as: UTF8.self),
                       #"{"mimeType":"application/vnd.google-apps.folder","name":"Snappet Clips"}"#)
        let upload = GoogleDriveAPI.startUpload(name: "x.mov", byteCount: 9, parent: "F1")
        XCTAssertEqual(String(decoding: try XCTUnwrap(upload.httpBody), as: UTF8.self), #"{"name":"x.mov","parents":["F1"]}"#)
    }

    func testPickerRepliesParse() throws {
        let session = try GooglePhotosPickerAPI.session(from: Data(#"{"id":"s1","pickerUri":"https://photos.google.com/picker/s1","pollingConfig":{"pollInterval":"0.5s","timeoutIn":"1800s"}}"#.utf8))
        XCTAssertEqual(session.id, "s1")
        XCTAssertFalse(session.mediaItemsSet)
        XCTAssertEqual(session.pollInterval, 2, "never poll faster than every 2 s")
        XCTAssertEqual(session.timeout, 1800)
        XCTAssertTrue(try GooglePhotosPickerAPI.session(from: Data(#"{"id":"s1","mediaItemsSet":true}"#.utf8), fallback: session).mediaItemsSet)

        let page = try GooglePhotosPickerAPI.items(from: Data("""
            {"mediaItems":[
              {"id":"v1","createTime":"2026-07-04T18:30:05Z","type":"VIDEO","mediaFile":{"baseUrl":"https://lh3/x","mimeType":"video/mp4","filename":"IMG_0042.MOV","mediaFileMetadata":{"width":1920,"height":1080}}},
              {"id":"p1","createTime":"2026-07-04T18:31:00.250Z","type":"PHOTO","mediaFile":{"baseUrl":"https://lh3/y","mimeType":"image/jpeg","filename":"IMG_0043.JPG"}},
              {"id":"broken","type":"PHOTO"}
            ],"nextPageToken":"n2"}
            """.utf8))
        XCTAssertEqual(page.nextPageToken, "n2")
        XCTAssertEqual(page.items.map(\.id), ["v1", "p1"], "an item without bytes or a time is skipped")
        let video = page.items[0]
        XCTAssertEqual(video.downloadURL?.absoluteString, "https://lh3/x=dv")
        XCTAssertEqual(page.items[1].downloadURL?.absoluteString, "https://lh3/y=d")
        XCTAssertEqual(video.pickIdentifier, "google:v1")
        XCTAssertEqual(video.fingerprint, MediaFingerprint(capturedAt: Date(timeIntervalSince1970: 1_783_189_805), isVideo: true,
                                                           durationSec: nil, pixelWidth: 1920, pixelHeight: 1080,
                                                           originalFilename: "IMG_0042.MOV"))
        XCTAssertEqual(page.items[1].createTime.timeIntervalSince1970, 1_783_189_860.25, accuracy: 0.001)
    }

    // MARK: - Google picks → missing clips (the prompt 266 rules still hold)

    private func row(_ id: UUID, dead: String, at offset: TimeInterval, video: Bool = true) -> MediaLinkRow {
        MediaLinkRow(id: id, localIdentifier: dead, cloudIdentifier: nil,
                     fingerprint: MediaFingerprint(capturedAt: t0.addingTimeInterval(offset), isVideo: video, durationSec: video ? 12 : nil,
                                                   pixelWidth: nil, pixelHeight: nil, originalFilename: nil),
                     fallbackFingerprint: nil)
    }
    private func pick(_ id: String, at offset: TimeInterval, video: Bool = true) -> GooglePickedItem {
        GooglePickedItem(id: id, createTime: t0.addingTimeInterval(offset), isVideo: video, baseURL: "https://lh3.test/\(id)",
                         mimeType: nil, fileName: nil, width: nil, height: nil)
    }

    func testAPickIsMatchedByCaptureTimeAndKind() {
        let plan = GoogleImportPlanner.plan(missing: [row(a, dead: "dead-a", at: 0), row(b, dead: "dead-b", at: 600)],
                                            picks: [pick("g1", at: 1), pick("g2", at: 5000), pick("g3", at: 600, video: false)],
                                            alreadyInVault: [])
        XCTAssertEqual(plan.matches.mapValues(\.id), [a: "g1"])
        XCTAssertEqual(plan.unmatchedPickCount, 2)
    }

    func testATieIsNoMatch() {
        let plan = GoogleImportPlanner.plan(missing: [row(a, dead: "dead-a", at: 0)],
                                            picks: [pick("g1", at: 0), pick("g2", at: 1)], alreadyInVault: [])
        XCTAssertTrue(plan.matches.isEmpty, "two picks that fit equally well: neither is attached")
        XCTAssertEqual(plan.unmatchedPickCount, 2)
    }

    func testTwoRowsSharingOneDeadIdentifierLandOnTheSamePick() {
        let plan = GoogleImportPlanner.plan(missing: [row(a, dead: "same", at: 0), row(b, dead: "same", at: 0)],
                                            picks: [pick("g1", at: 0)], alreadyInVault: [])
        XCTAssertEqual(plan.matches.mapValues(\.id), [a: "g1", b: "g1"])
        XCTAssertEqual(plan.unmatchedPickCount, 0)
    }

    func testAClipAlreadyInTheVaultIsNotFetchedAgain() {
        let plan = GoogleImportPlanner.plan(missing: [row(a, dead: "dead-a", at: 0)], picks: [pick("g1", at: 0)],
                                            alreadyInVault: [a])
        XCTAssertTrue(plan.matches.isEmpty)
        XCTAssertEqual(plan.unmatchedPickCount, 1)
    }
}

/// The vault service against the fake Google and a fake Photos library.
@MainActor
final class MediaVaultServiceTests: XCTestCase {

    final class FakeLibrary: MediaVaultExporter, @unchecked Sendable {
        private let lock = NSLock()
        private var assets: [String: Data] = [:]
        private(set) var exports = 0
        /// On the phone, but will not export (an iCloud-only original, a damaged file).
        var failing: Set<String> = []
        func add(_ id: String, _ data: Data) { lock.withLock { assets[id] = data } }
        func remove(_ id: String) { lock.withLock { assets[id] = nil } }
        func present(_ ids: [String]) async -> Set<String> { lock.withLock { Set(ids.filter { assets[$0] != nil }) } }
        func export(localIdentifier: String) async throws -> (url: URL, fileExtension: String) {
            let data: Data? = lock.withLock { exports += 1; return failing.contains(localIdentifier) ? nil : assets[localIdentifier] }
            guard let data else { throw CloudVaultError.notFound(localIdentifier) }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("fake-\(UUID().uuidString).mov")
            try data.write(to: url)
            return (url, "mov")
        }
        /// What the person answers when iOS asks "Allow Snappet to delete these?".
        var refusesDelete = false
        private(set) var deleted: [String] = []
        func delete(localIdentifiers: [String]) async throws {
            if refusesDelete { throw CloudVaultError.unavailable }
            lock.withLock { deleted += localIdentifiers; for id in localIdentifiers { assets[id] = nil } }
        }
        private(set) var saved: [String] = []
        func save(file: URL, isVideo: Bool) async throws -> String {
            if refusesSave { throw MediaVaultFailure("Photos did not save the clip.") }
            let data = try Data(contentsOf: file)
            return lock.withLock {
                let id = "restored-\(saved.count + 1)"
                assets[id] = data
                dates[id] = embeddedDate ?? Date()   // like Photos: the file's own date, else the moment of saving
                saved.append(id)
                return id
            }
        }
        func data(_ id: String) -> Data? { lock.withLock { assets[id] } }
        /// The capture date the saved file carries; nil = none, so Photos files it under "now".
        var embeddedDate: Date?
        var refusesDateChange = false
        private var dates: [String: Date] = [:]
        private(set) var dateChanges = 0
        func creationDate(of localIdentifier: String) async -> Date? { lock.withLock { dates[localIdentifier] } }
        func setCreationDate(_ date: Date, of localIdentifier: String) async throws {
            if refusesDateChange { throw CloudVaultError.unavailable }
            lock.withLock { dates[localIdentifier] = date; dateChanges += 1 }
        }
        /// Limited Photos access: only some assets can be seen.
        var seesWholeLibrary = true
        var refusesSave = false
        func canSeeWholeLibrary() async -> Bool { seesWholeLibrary }
        func poster(localIdentifier: String) async -> Data? { lock.withLock { assets[localIdentifier].map { Data("poster:".utf8) + $0 } } }
    }

    final class Flags: @unchecked Sendable {
        private let lock = NSLock()
        private var signedIn = true, scopes: Set<String> = [GoogleScope.driveFile, GoogleScope.photosPicker]
        var isSignedIn: Bool { get { lock.withLock { signedIn } } set { lock.withLock { signedIn = newValue } } }
        func grants(_ s: String) -> Bool { lock.withLock { scopes.contains(s) } }
        func revoke(_ s: String) { lock.withLock { _ = scopes.remove(s) } }
    }

    private var container: ModelContainer!
    private var google: FakeGoogle!
    private var library: FakeLibrary!
    private var flags: Flags!
    private var cache: URL!
    private let suite = "MediaVaultServiceTests"
    private let sessionID = UUID()
    private let start = Date(timeIntervalSince1970: 1_780_000_000)

    override func setUp() async throws {
        container = try ModelContainer(for: Schema(SnappetSchema.models),
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        google = FakeGoogle()
        library = FakeLibrary()
        flags = Flags()
        cache = FileManager.default.temporaryDirectory.appendingPathComponent("vaultcache-\(UUID().uuidString)")
        UserDefaults().removePersistentDomain(forName: suite)
        // Sign the fake in so Drive calls carry a token it accepts.
        let account = GoogleAccount(config: GoogleOAuthConfig(clientID: "1-a.apps.googleusercontent.com"),
                                    store: MemoryGoogleTokenStore(), http: google)
        let pending = try account.beginSignIn(scopes: [])
        let state = URLComponents(url: pending.url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "state" }!.value!
        try await account.finishSignIn(pending, callback: URL(string: "\(pending.callbackScheme):/oauth2redirect?state=\(state)&code=c")!)
        self.account = account
        container.mainContext.insert(WorkoutSession(id: sessionID, routineName: "Bouldering", startedAt: start,
                                                    completedAt: start.addingTimeInterval(3600)))
        try container.mainContext.save()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: cache)
        UserDefaults().removePersistentDomain(forName: suite)
        container = nil
    }

    private var account: GoogleAccount!

    private var authorized: GoogleAuthorizedHTTP {
        let account = account!
        return GoogleAuthorizedHTTP(accessToken: { force in try await account.accessToken(forceRefresh: force) }, http: google)
    }
    private func service() -> MediaVaultService {
        let flags = flags!, net = net
        return MediaVaultService(
            defaults: UserDefaults(suiteName: suite)!,
            account: .init(isSignedIn: { flags.isSignedIn }, grants: { flags.grants($0) }),
            google: authorized,
            exporter: library, network: { net.value }, cacheDirectory: cache,
            posterDirectory: cache.appendingPathComponent("posters"))
    }
    final class Net: @unchecked Sendable {
        private let lock = NSLock()
        private var current = CloudBackupNetwork.wifi
        var value: CloudBackupNetwork { get { lock.withLock { current } } set { lock.withLock { current = newValue } } }
    }
    private let net = Net()

    /// The service with clip copies on, names written in UTC (the session starts 2026-05-28 20:26:40 UTC).
    private func vaultOn(_ layout: MediaVaultLayout = .bySession) -> MediaVaultService {
        let vault = service()
        vault.update { $0.keepCopies = true; $0.started = true; $0.layout = layout; $0.timeZoneID = "UTC" }
        return vault
    }
    private let folder = "Snappet Clips/2026-05-28 20.26 Other"

    @discardableResult
    private func addClip(_ local: String, offset: Double, bytes: String? = nil) throws -> UUID {
        let media = SessionMedia(sessionID: sessionID, localIdentifier: local, kind: .video, offsetSec: offset, durationSec: 12)
        container.mainContext.insert(media)
        try container.mainContext.save()
        if let bytes { library.add(local, Data(bytes.utf8)) }
        return media.id
    }

    func testNothingIsCopiedWhileTheSwitchIsOff() async throws {
        try addClip("L1", offset: 10, bytes: "one")
        let vault = service()
        await vault.runIfNeeded(context: container.mainContext)
        XCTAssertTrue(google.driveFileNames.isEmpty)
        XCTAssertTrue(google.folderNames.isEmpty, "off: not even the folder is created")
        XCTAssertEqual(google.count(of: "GET www.googleapis.com/drive"), 0)
    }

    func testClipsOnThePhoneAreCopiedOnceIntoOneFolder() async throws {
        let one = try addClip("L1", offset: 10, bytes: "one")
        let two = try addClip("L2", offset: 20, bytes: "two-two")
        let gone = try addClip("GONE", offset: 30)
        let vault = vaultOn()
        await vault.runIfNeeded(context: container.mainContext)

        XCTAssertEqual(vault.phase, .idle)
        XCTAssertEqual(google.folderNames, ["Snappet Clips", "2026-05-28 20.26 Other"])
        XCTAssertEqual(google.drivePaths, ["\(folder)/2026-05-28 20.26.50 Other.mov", "\(folder)/2026-05-28 20.27.00 Other.mov"])
        XCTAssertEqual(google.data(named: "2026-05-28 20.27.00 Other.mov"), Data("two-two".utf8))
        XCTAssertEqual(google.props(named: "2026-05-28 20.27.00 Other.mov")?["clip"], two.uuidString.lowercased(),
                       "the clip id travels in a private property, not the name")
        XCTAssertTrue(vault.contains(one))
        XCTAssertFalse(vault.contains(gone), "a clip that is not on the phone has nothing to copy")
        XCTAssertEqual(vault.coverage, .init(copied: 2, total: 3, onlyInVault: 0))
        XCTAssertEqual(vault.index.totalBytes, 10)

        await vault.runIfNeeded(context: container.mainContext)
        XCTAssertEqual(google.driveFileNames.count, 2, "a second pass copies nothing again")
        XCTAssertEqual(google.folderNames, ["Snappet Clips", "2026-05-28 20.26 Other"], "and creates no folder twice")
        XCTAssertEqual(library.exports, 2)
        XCTAssertEqual(google.count(of: "PATCH www.googleapis.com/drive/v3/files/"), 0, "and moves nothing: every copy is where it belongs")
    }

    // MARK: - Quiet during a session, and Wi-Fi only means it (prompt 279)

    func testNothingIsCopiedWhileASessionIsRunning() async throws {
        try addClip("L1", offset: 10, bytes: "one")
        let vault = vaultOn()
        await vault.runIfNeeded(context: container.mainContext, sessionRunning: { true })
        XCTAssertTrue(google.driveFileNames.isEmpty)
        XCTAssertEqual(google.count(of: "GET www.googleapis.com/drive"), 0, "not even a listing")
        XCTAssertEqual(vault.note, "Paused while a session is running.")

        await vault.runIfNeeded(context: container.mainContext, sessionRunning: { false })
        XCTAssertEqual(google.driveFileNames.count, 1, "and it picks up once the session has ended")
    }

    func testACopyPassStopsWhenASessionStarts() async throws {
        try addClip("L1", offset: 10, bytes: "one")
        try addClip("L2", offset: 20, bytes: "two-two")
        let vault = vaultOn()
        var asked = 0
        // Not running when the pass begins; running by the time the second clip's turn comes.
        await vault.runIfNeeded(context: container.mainContext, sessionRunning: { asked += 1; return asked > 1 })
        XCTAssertEqual(google.driveFileNames.count, 1, "the clip in flight finishes, the next one waits")
        XCTAssertEqual(vault.phase, .idle)
        XCTAssertEqual(vault.note, "Paused while a session is running.")
    }

    func testWiFiOnlyCopiesAreBarredFromCellularAtTheConnection() async throws {
        try addClip("L1", offset: 10, bytes: "one")
        let vault = vaultOn()
        await vault.runIfNeeded(context: container.mainContext)
        XCTAssertEqual(google.putsBarredFromCellular, [true], "an upload begun on Wi-Fi cannot finish on mobile data")

        try addClip("L2", offset: 20, bytes: "two-two")
        vault.update { $0.wifiOnly = false }
        await vault.runIfNeeded(context: container.mainContext)
        XCTAssertEqual(google.putsBarredFromCellular, [true, false])
    }

    // MARK: - Folder layout (prompt 270)

    func testChangingTheLayoutMovesTheCopiesWithoutUploadingThemAgain() async throws {
        try addClip("L1", offset: 10, bytes: "one")
        try addClip("L2", offset: 20, bytes: "two-two")
        let vault = vaultOn()
        await vault.runIfNeeded(context: container.mainContext)
        XCTAssertEqual(google.drivePaths.first, "\(folder)/2026-05-28 20.26.50 Other.mov")

        vault.update { $0.layout = .byActivity }
        await vault.runIfNeeded(context: container.mainContext)
        XCTAssertEqual(vault.phase, .idle)
        XCTAssertEqual(google.drivePaths, ["Snappet Clips/Other/2026-05-28 20.26/2026-05-28 20.26.50 Other.mov",
                                           "Snappet Clips/Other/2026-05-28 20.26/2026-05-28 20.27.00 Other.mov"])
        XCTAssertEqual(library.exports, 2, "moved, not exported and uploaded again")
        XCTAssertEqual(google.count(of: "PATCH www.googleapis.com/drive/v3/files/"), 2)
        XCTAssertEqual(google.data(named: "2026-05-28 20.27.00 Other.mov"), Data("two-two".utf8))

        vault.update { $0.layout = .byMonth }
        await vault.runIfNeeded(context: container.mainContext)
        XCTAssertEqual(google.drivePaths.first, "Snappet Clips/2026/05 May/2026-05-28 20.26.50 Other.mov")
        vault.update { $0.layout = .flat }
        await vault.runIfNeeded(context: container.mainContext)
        XCTAssertEqual(google.drivePaths, ["Snappet Clips/2026-05-28 20.26.50 Other.mov", "Snappet Clips/2026-05-28 20.27.00 Other.mov"])
        await vault.runIfNeeded(context: container.mainContext)
        XCTAssertEqual(google.count(of: "PATCH www.googleapis.com/drive/v3/files/"), 6, "a pass with nothing to change moves nothing")
        XCTAssertEqual(vault.coverage, .init(copied: 2, total: 2, onlyInVault: 0))
    }

    func testARenameMadeInDriveIsLeftAloneAndTheClipStillPlays() async throws {
        let id = try addClip("L1", offset: 10, bytes: "footage")
        let vault = vaultOn()
        await vault.runIfNeeded(context: container.mainContext)
        google.rename("2026-05-28 20.26.50 Other.mov", to: "My best send.mov")

        await vault.runIfNeeded(context: container.mainContext)
        XCTAssertEqual(google.drivePaths, ["\(folder)/My best send.mov"], "the app did not rename it back")
        XCTAssertEqual(library.exports, 1, "nor upload it again")
        library.remove("L1")
        let url = try await vault.localURL(for: id)
        XCTAssertEqual(try Data(contentsOf: url), Data("footage".utf8), "the name is for people; the clip id is in the properties")

        vault.update { $0.layout = .flat }   // the person asks for a different arrangement: now it is the app's to place
        await vault.runIfNeeded(context: container.mainContext)
        XCTAssertEqual(google.drivePaths, ["Snappet Clips/2026-05-28 20.26.50 Other.mov"])
    }

    func testACopyFromBeforeLayoutsIsFiledNotUploadedAgain() async throws {
        let id = try addClip("L1", offset: 10, bytes: "new bytes")
        let first = vaultOn()
        await first.runIfNeeded(context: container.mainContext)   // makes the root folder
        XCTAssertEqual(library.exports, 1)
        let other = try addClip("L2", offset: 20, bytes: "unused")
        google.addLegacyFile(named: MediaVaultNaming.fileName(rowID: other, fileExtension: "mov"), data: Data("old copy".utf8),
                             inFolderNamed: "Snappet Clips")

        await first.runIfNeeded(context: container.mainContext)
        XCTAssertEqual(library.exports, 1, "the old copy counts: nothing is exported for it")
        XCTAssertEqual(google.drivePaths, ["\(folder)/2026-05-28 20.26.50 Other.mov", "\(folder)/2026-05-28 20.27.00 Other.mov"])
        XCTAssertEqual(google.data(named: "2026-05-28 20.27.00 Other.mov"), Data("old copy".utf8))
        XCTAssertEqual(google.props(named: "2026-05-28 20.27.00 Other.mov")?["clip"], other.uuidString.lowercased(), "and it is tagged now")
        XCTAssertTrue(first.contains(id))
    }

    func testAFestivalNightGoesUnderItsFestivalAndATagRenamesTheFile() async throws {
        let clip = try addClip("L1", offset: 10, bytes: "set")
        let context = container.mainContext
        context.insert(FestivalLineup(packID: "dkm", name: "Dekmantel 2026", location: "Amsterdam", startDate: "2026-05-28",
                                      endDate: "2026-05-30", utcOffsetSeconds: 7200, stageCount: 1, setCount: 1,
                                      sourceLabel: "test", fpackData: Data()))
        context.insert(FestivalAttendance(packID: "dkm", setID: UUID(), artist: "Someone", stage: "Main", sessionID: sessionID))
        try context.save()
        let vault = vaultOn(.byActivity)
        await vault.runIfNeeded(context: context)
        XCTAssertEqual(google.drivePaths, ["Snappet Clips/Festival/Dekmantel 2026/2026-05-28 20.26/2026-05-28 20.26.50 Festival.mov"])

        context.insert(FestivalClipTag(packID: "dkm", setID: UUID(), artist: "Skee Mask", stage: "Main", mediaID: clip,
                                       sessionID: sessionID, confidence: 1, reason: "test", source: .auto))
        try context.save()
        await vault.runIfNeeded(context: context)
        XCTAssertEqual(google.drivePaths, ["Snappet Clips/Festival/Dekmantel 2026/2026-05-28 20.26/2026-05-28 20.26.50 Skee Mask.mov"])
        XCTAssertEqual(library.exports, 1)
    }

    func testAPickFromGooglePhotosIsFiledLikeAnyOtherCopy() async throws {
        let wanted = try addClip("DEAD-1", offset: 100)
        google.pickerItems = [.init(id: "g1", createTime: ISO8601DateFormatter().string(from: start.addingTimeInterval(100)),
                                    isVideo: true, fileName: "IMG_1.MOV", data: Data("from google".utf8))]
        let vault = vaultOn(.byMonth)
        let picks = try await vault.waitForPicks(try await vault.beginGooglePick(), sleep: { _ in })
        let rows = MediaLinkService.rows(for: [wanted], context: container.mainContext)
        let result = await vault.importFromGoogle(picks, missing: rows, placements: vault.placements(context: container.mainContext))
        XCTAssertEqual(result, .init(saved: 1, unmatched: 0, failed: 0))
        XCTAssertEqual(google.drivePaths, ["Snappet Clips/2026/05 May/2026-05-28 20.28.20 Other.mov"])
        await vault.runIfNeeded(context: container.mainContext)
        XCTAssertEqual(google.count(of: "PATCH www.googleapis.com/drive/v3/files/"), 0, "already in its place")
    }

    func testNothingIsUploadedBetweenSwitchingOnAndStart() async throws {
        try addClip("L1", offset: 10, bytes: "one")
        let vault = service()
        vault.update { $0.keepCopies = true; $0.timeZoneID = "UTC" }
        vault.update { $0.layout = .byMonth }   // choosing folders first copies nothing
        await vault.runIfNeeded(context: container.mainContext)
        XCTAssertTrue(google.driveFileNames.isEmpty, "on, but not started: nothing leaves the phone")
        XCTAssertNil(vault.note)

        vault.update { $0.started = true }
        await vault.runIfNeeded(context: container.mainContext)
        XCTAssertEqual(google.drivePaths, ["Snappet Clips/2026/05 May/2026-05-28 20.26.50 Other.mov"],
                       "the first copy lands in the layout chosen before starting")
    }

    func testSwitchingOffPausesAndSwitchingOnCarriesOnWithoutCopyingAgain() async throws {
        try addClip("L1", offset: 10, bytes: "one")
        let vault = vaultOn()
        await vault.runIfNeeded(context: container.mainContext)
        XCTAssertEqual(google.drivePaths.count, 1)

        vault.update { $0.keepCopies = false }
        XCTAssertTrue(vault.settings.started, "off is a pause, not a reset")
        try addClip("L2", offset: 20, bytes: "two")
        await vault.runIfNeeded(context: container.mainContext)
        XCTAssertEqual(google.drivePaths.count, 1, "paused: nothing is copied")

        let uploadsBefore = google.requests.filter { $0 == "POST www.googleapis.com/upload/drive/v3/files" }.count
        vault.update { $0.keepCopies = true }
        await vault.runIfNeeded(context: container.mainContext)
        XCTAssertEqual(google.drivePaths.count, 2, "on again: only the clip that is not there yet")
        XCTAssertEqual(google.requests.filter { $0 == "POST www.googleapis.com/upload/drive/v3/files" }.count, uploadsBefore + 1)
        XCTAssertEqual(MediaVaultText.copying(.init(copied: 32, total: 191, onlyInVault: 0), done: 0, total: 20), "Copying… 32 of 191 clips copied")
    }

    func testAfterAPassTheAppKnowsWhereEachCopySits() async throws {
        let id = try addClip("L1", offset: 10, bytes: "one")
        let other = try addClip("L2", offset: 20)   // no footage on the phone: never copied
        let fresh = service()
        XCTAssertFalse(fresh.showsCopyState, "copies never used: screens say nothing")
        let vault = vaultOn(.byActivity)
        XCTAssertTrue(vault.showsCopyState)
        await vault.runIfNeeded(context: container.mainContext)
        XCTAssertEqual(vault.location(of: id), "Snappet Clips / Other / 2026-05-28 20.26")
        XCTAssertNil(vault.location(of: other))
        XCTAssertEqual(service().location(of: id), "Snappet Clips / Other / 2026-05-28 20.26", "remembered across launches")
    }

    func testOnePassCopiesEveryClipNotJustAFirstBatch() async throws {
        for n in 0..<25 { try addClip("L\(n)", offset: Double(10 + n), bytes: "clip \(n)") }
        let vault = vaultOn()
        await vault.runIfNeeded(context: container.mainContext)
        XCTAssertEqual(google.drivePaths.count, 25, "the pass keeps going until nothing is left")
        XCTAssertEqual(vault.coverage.copied, 25)
        XCTAssertNil(vault.note)
    }

    func testAClipThatWillNotCopyIsSkippedAndTheRestStillGo() async throws {
        for n in 0..<4 { try addClip("L\(n)", offset: Double(10 + n), bytes: "clip \(n)") }
        library.failing = ["L1"]
        let vault = vaultOn()
        await vault.runIfNeeded(context: container.mainContext)
        XCTAssertEqual(google.drivePaths.count, 3, "one bad clip does not hold up the others")
        XCTAssertEqual(vault.note, "1 clip couldn’t be copied. It will be tried again.")
        XCTAssertEqual(vault.phase, .idle)

        library.failing = []
        await vault.runIfNeeded(context: container.mainContext)
        XCTAssertEqual(google.drivePaths.count, 4, "and it is tried again on the next pass")
        XCTAssertNil(vault.note)
    }

    func testFailuresInARowStopThePassAndSayWhy() async throws {
        for n in 0..<6 { try addClip("L\(n)", offset: Double(10 + n), bytes: "clip \(n)") }
        library.failing = Set((0..<6).map { "L\($0)" })
        let vault = vaultOn()
        await vault.runIfNeeded(context: container.mainContext)
        XCTAssertTrue(google.drivePaths.isEmpty)
        XCTAssertEqual(library.exports, 3, "three in a row is not one bad clip: stop, do not grind through all of them")
        guard case .failed = vault.phase else { return XCTFail("the pass should say it failed: \(vault.phase)") }
    }

    func testALayoutChangeOffersToRemoveTheFoldersItEmptiedAndOnlyThose() async throws {
        try addClip("L1", offset: 10, bytes: "one")
        let vault = vaultOn()
        await vault.runIfNeeded(context: container.mainContext)
        XCTAssertEqual(vault.emptyFolderCount, 0, "nothing to tidy: the one folder holds the copy")

        vault.update { $0.layout = .byMonth }
        await vault.runIfNeeded(context: container.mainContext)
        XCTAssertEqual(vault.emptyFolderCount, 1, "the by-session folder is now empty")
        XCTAssertTrue(google.trashedNames.isEmpty, "found, not removed: removing is the person's choice")

        await vault.removeEmptyFolders()
        XCTAssertEqual(google.trashedNames, ["2026-05-28 20.26 Other"])
        XCTAssertEqual(google.drivePaths, ["Snappet Clips/2026/05 May/2026-05-28 20.26.50 Other.mov"], "the copy is untouched")
        XCTAssertEqual(vault.emptyFolderCount, 0)
        XCTAssertEqual(vault.note, "1 empty folder moved to Drive’s trash.")
        XCTAssertFalse(google.requests.contains { $0.hasPrefix("DELETE") }, "trash, never a hard delete")

        await vault.removeEmptyFolders()
        XCTAssertEqual(google.trashedNames.count, 1, "nothing left to remove")
    }

    func testAFolderThatGainedACopySinceTheLastPassIsNotRemoved() async throws {
        try addClip("L1", offset: 10, bytes: "one")
        let vault = vaultOn()
        await vault.runIfNeeded(context: container.mainContext)
        vault.update { $0.layout = .byMonth }
        await vault.runIfNeeded(context: container.mainContext)
        XCTAssertEqual(vault.emptyFolderCount, 1)
        // Another phone files a copy into the old folder before the person taps Remove.
        let other = UUID()
        google.addLegacyFile(named: "from another phone.mov", data: Data("x".utf8), inFolderNamed: "2026-05-28 20.26 Other",
                             props: MediaVaultTag.properties(rowID: other, stamp: "elsewhere"))
        await vault.removeEmptyFolders()
        XCTAssertTrue(google.trashedNames.isEmpty, "listed again first: it is no longer empty")
    }

    // MARK: Cleaning up (prompt 274)

    private func deleteClip(_ id: UUID) throws {
        let context = container.mainContext
        let row = try XCTUnwrap(try context.fetch(FetchDescriptor<SessionMedia>()).first { $0.id == id })
        context.delete(row)
        try context.save()
    }
    private func row(_ id: UUID) throws -> SessionMedia {
        try XCTUnwrap(try container.mainContext.fetch(FetchDescriptor<SessionMedia>()).first { $0.id == id })
    }
    private let copy1 = "2026-05-28 20.26.50 Other.mov", copy2 = "2026-05-28 20.27.00 Other.mov"

    func testDeletingAClipTrashesItsCopyOnTheNextPassAndNoOther() async throws {
        let one = try addClip("L1", offset: 10, bytes: "one")
        try addClip("L2", offset: 20, bytes: "two")
        let vault = vaultOn()
        await vault.runIfNeeded(context: container.mainContext)
        XCTAssertEqual(google.drivePaths.count, 2)

        try deleteClip(one)
        await vault.runIfNeeded(context: container.mainContext)
        XCTAssertEqual(google.trashedNames, [copy1])
        XCTAssertEqual(google.drivePaths, ["\(folder)/\(copy2)"])
        XCTAssertFalse(vault.contains(one))
        XCTAssertEqual(vault.leftoverCount, 0)
        XCTAssertFalse(google.requests.contains { $0.hasPrefix("DELETE") }, "trash, never a hard delete")
    }

    func testWithTheSwitchOffADeletedClipsCopyIsOnlyOffered() async throws {
        let one = try addClip("L1", offset: 10, bytes: "one")
        try addClip("L2", offset: 20, bytes: "two")
        let vault = vaultOn()
        vault.update { $0.removeWithClip = false }
        await vault.runIfNeeded(context: container.mainContext)
        try deleteClip(one)
        await vault.runIfNeeded(context: container.mainContext)
        XCTAssertTrue(google.trashedNames.isEmpty)
        XCTAssertEqual(vault.leftoverCount, 1)

        await vault.removeLeftovers(context: container.mainContext)
        XCTAssertEqual(google.trashedNames, [copy1])
        XCTAssertEqual(vault.leftoverCount, 0)
        XCTAssertEqual(vault.note, "1 copy moved to Drive’s trash.")
    }

    func testAPhoneWithNoClipsYetLeavesEveryCopyAlone() async throws {
        try addClip("L1", offset: 10, bytes: "one")
        let first = vaultOn()
        await first.runIfNeeded(context: container.mainContext)

        // The same account on a phone whose store is empty (new install, nothing restored yet).
        for row in try container.mainContext.fetch(FetchDescriptor<SessionMedia>()) { container.mainContext.delete(row) }
        try container.mainContext.save()
        await first.runIfNeeded(context: container.mainContext)
        XCTAssertTrue(google.trashedNames.isEmpty, "no clips at all is not 'the person deleted everything'")
        XCTAssertEqual(first.leftoverCount, 0)
        await first.removeLeftovers(context: container.mainContext)
        XCTAssertTrue(google.trashedNames.isEmpty)
    }

    func testARestoreForgetsWhatThisPhoneKnewSoNothingIsRemoved() async throws {
        let one = try addClip("L1", offset: 10, bytes: "one")
        try addClip("L2", offset: 20, bytes: "two")
        let vault = vaultOn()
        await vault.runIfNeeded(context: container.mainContext)
        // A backup from before clip one existed replaces the store.
        try deleteClip(one)
        vault.storeWasReplaced()
        await vault.runIfNeeded(context: container.mainContext)
        XCTAssertTrue(google.trashedNames.isEmpty, "missing after a restore is not deleted by the person")
        XCTAssertEqual(vault.leftoverCount, 1, "it is offered instead")
    }

    func testRemovingOneCopyTrashesItAndDoesNotCopyItAgainUntilAsked() async throws {
        let one = try addClip("L1", offset: 10, bytes: "one")
        let vault = vaultOn()
        await vault.runIfNeeded(context: container.mainContext)
        await vault.removeCopy(of: one)
        XCTAssertEqual(google.trashedNames, [copy1])
        XCTAssertFalse(vault.contains(one))
        XCTAssertTrue(vault.excluded.contains(one))

        await vault.runIfNeeded(context: container.mainContext)
        XCTAssertTrue(google.drivePaths.isEmpty, "removed by hand: the next pass leaves it out")
        XCTAssertEqual(vault.coverage.total, 0, "and does not count it as waiting")

        vault.copyAgain(one)
        await vault.runIfNeeded(context: container.mainContext)
        XCTAssertEqual(google.drivePaths, ["\(folder)/\(copy1)"])
    }

    func testRemovingAllCopiesTrashesTheFolderAndSwitchesCopiesOff() async throws {
        try addClip("L1", offset: 10, bytes: "one")
        try addClip("L2", offset: 20, bytes: "two")
        let vault = vaultOn()
        await vault.runIfNeeded(context: container.mainContext)
        await vault.removeAllCopies()
        XCTAssertEqual(google.trashedNames, ["Snappet Clips"])
        XCTAssertTrue(google.drivePaths.isEmpty)
        XCTAssertEqual(vault.index.count, 0)
        XCTAssertFalse(vault.settings.keepCopies)
        XCTAssertFalse(vault.settings.started, "switching on again asks before copying")
        XCTAssertEqual(vault.note, "2 copies moved to Drive’s trash.")
        await vault.runIfNeeded(context: container.mainContext)
        XCTAssertTrue(google.drivePaths.isEmpty)
    }

    func testFreeingUpSpaceRemovesOnlyOriginalsWhoseCopyIsConfirmed() async throws {
        let good = try addClip("L1", offset: 10, bytes: "footage one")
        let broken = try addClip("L2", offset: 20, bytes: "footage two")
        let vault = vaultOn()
        await vault.runIfNeeded(context: container.mainContext)
        XCTAssertEqual(vault.freeable.count, 2)
        google.replaceData(named: copy2, with: Data("foot".utf8))   // Drive holds less than was sent

        await vault.freeUpSpace(context: container.mainContext)
        XCTAssertEqual(library.deleted, ["L1"], "the clip whose copy is short stays on the phone")
        XCTAssertEqual(vault.onlyInDrive, [good])
        XCTAssertFalse(vault.onlyInDrive.contains(broken))
        XCTAssertEqual(vault.note?.hasSuffix("1 was kept: its copy could not be confirmed."), true)
        // It still plays, from Drive.
        let fetched = try await vault.localURL(for: good)
        XCTAssertEqual(try Data(contentsOf: fetched), Data("footage one".utf8))
        // And the next pass does not upload anything again or remove the copy.
        await vault.runIfNeeded(context: container.mainContext)
        XCTAssertTrue(google.trashedNames.isEmpty)
        XCTAssertEqual(google.drivePaths.count, 2)
    }

    func testFreeingUpOnlyTheChosenClipsLeavesTheRestOnThePhone() async throws {
        let chosen = try addClip("L1", offset: 10, bytes: "footage one")
        let other = try addClip("L2", offset: 20, bytes: "footage two")
        let vault = vaultOn()
        await vault.runIfNeeded(context: container.mainContext)
        let items = await vault.freeUpItems(context: container.mainContext)
        XCTAssertEqual(Set(items.map(\.id)), [chosen, other])
        XCTAssertEqual(Set(items.map(\.sessionID)), [sessionID])
        XCTAssertEqual(items.first { $0.id == chosen }?.bytes, 11)

        await vault.freeUpSpace(context: container.mainContext, only: [chosen])
        XCTAssertEqual(library.deleted, ["L1"])
        XCTAssertEqual(vault.onlyInDrive, [chosen])
        XCTAssertEqual(vault.note, "1 clip removed from this iPhone (11 bytes). It plays from Google Drive.")
        let after = await vault.freeUpItems(context: container.mainContext)
        XCTAssertEqual(after.map(\.id), [other], "what already left is not offered again")
    }

    func testRemovingOneClipFromThePhoneTakesEveryClipThatSharesItsOriginal() async throws {
        let first = try addClip("L1", offset: 10, bytes: "footage one")
        let twin = try addClip("L1", offset: 30)          // the same original, used twice
        try addClip("L2", offset: 20, bytes: "footage two")
        let vault = vaultOn()
        await vault.runIfNeeded(context: container.mainContext)

        // Chosen alone, the shared original stays: its other clip was not chosen.
        await vault.freeUpSpace(context: container.mainContext, only: [first])
        XCTAssertTrue(library.deleted.isEmpty)
        // From the clip's own menu, the original goes and both clips play from Drive.
        await vault.freeUpClip(first, context: container.mainContext)
        XCTAssertEqual(library.deleted, ["L1"])
        XCTAssertEqual(vault.onlyInDrive, [first, twin])
    }

    func testACopyOfTheRightSizeAndTheWrongContentKeepsItsOriginalOnThePhone() async throws {
        try addClip("L1", offset: 10, bytes: "footage one")
        try addClip("L2", offset: 20, bytes: "footage two")
        let vault = vaultOn()
        await vault.runIfNeeded(context: container.mainContext)
        XCTAssertEqual(google.props(named: copy1)?[MediaVaultTag.md5Key]?.count, 32, "the checksum of what was sent travels on the file")
        google.replaceData(named: copy2, with: Data("FOOTAGE TWO".utf8))   // same length, different bytes

        await vault.freeUpSpace(context: container.mainContext)
        XCTAssertEqual(library.deleted, ["L1"], "size alone would have passed the damaged copy")
    }

    func testAFreedClipKeepsAThumbnailAndLosesItWhenBroughtBack() async throws {
        let id = try addClip("L1", offset: 10, bytes: "footage one")
        let vault = vaultOn()
        await vault.runIfNeeded(context: container.mainContext)
        let poster = MediaVaultPosters.url(for: "L1", in: vault.posterDirectory)
        await vault.freeUpSpace(context: container.mainContext)
        XCTAssertEqual(try Data(contentsOf: poster), Data("poster:footage one".utf8))
        await vault.bringBackNow(id, context: container.mainContext)
        XCTAssertFalse(FileManager.default.fileExists(atPath: poster.path))
    }

    func testSayingNoToIOSLeavesNoThumbnailBehind() async throws {
        try addClip("L1", offset: 10, bytes: "one")
        let vault = vaultOn()
        await vault.runIfNeeded(context: container.mainContext)
        library.refusesDelete = true
        await vault.freeUpSpace(context: container.mainContext)
        XCTAssertFalse(FileManager.default.fileExists(atPath: MediaVaultPosters.url(for: "L1", in: vault.posterDirectory).path))
    }

    func testWithLimitedPhotosAccessNothingIsCalledDriveOnlyOrOfferedOrCopied() async throws {
        let copied = try addClip("L1", offset: 10, bytes: "footage one")
        let vault = vaultOn()
        await vault.runIfNeeded(context: container.mainContext)
        try addClip("L2", offset: 20, bytes: "footage two")
        // Access drops to "limited": neither asset can be seen any more.
        library.seesWholeLibrary = false
        library.remove("L1"); library.remove("L2")

        await vault.runIfNeeded(context: container.mainContext)
        XCTAssertFalse(vault.libraryVisible)
        XCTAssertTrue(vault.onlyInDrive.isEmpty, "an asset that cannot be seen is not an asset that is gone")
        XCTAssertEqual(vault.freeable.count, 0)
        XCTAssertEqual(vault.note, "Allow full access to Photos to copy clips.")
        XCTAssertEqual(google.drivePaths.count, 1, "nothing was uploaded, and nothing failed clip by clip")
        let items = await vault.freeUpItems(context: container.mainContext)
        XCTAssertTrue(items.isEmpty)
        await vault.freeUpSpace(context: container.mainContext)
        XCTAssertTrue(library.deleted.isEmpty)
        XCTAssertEqual(vault.note, "Allow full access to Photos to free up space.")
        XCTAssertTrue(vault.contains(copied))
    }

    // MARK: Playing a clip that is only in Drive (prompt 276)

    /// One clip, copied, then gone from the phone.
    private func freedClip(_ bytes: String = "0123456789abcdef") async throws -> (MediaVaultService, UUID) {
        let id = try addClip("L1", offset: 10, bytes: bytes)
        let vault = vaultOn()
        await vault.runIfNeeded(context: container.mainContext)
        library.remove("L1")
        await vault.refreshCoverage(context: container.mainContext)
        return (vault, id)
    }
    private func blocked(_ vault: MediaVaultService, _ id: UUID) async -> MediaVaultFetch.Blocked? {
        do { _ = try await vault.playback(for: id, isVideo: true); return nil }
        catch let why as MediaVaultFetch.Blocked { return why }
        catch { XCTFail("unexpected \(error)"); return nil }
    }

    func testASmallClipDownloadsOnceAndALargeVideoStreams() async throws {
        let (vault, id) = try await freedClip()
        guard case .file(let file) = try await vault.playback(for: id, isVideo: true) else { return XCTFail("small: a file") }
        XCTAssertEqual(try Data(contentsOf: file), Data("0123456789abcdef".utf8))
        try FileManager.default.removeItem(at: file)

        vault.streamAbove = 4   // anything over 4 bytes counts as large
        guard case .stream(let asset) = try await vault.playback(for: id, isVideo: true) else { return XCTFail("large: a stream") }
        XCTAssertEqual(asset.url.scheme, MediaVaultStream.scheme)
        XCTAssertEqual(asset.url.pathExtension, "mov")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "a stream downloads nothing whole")
        guard case .file = try await vault.playback(for: id, isVideo: false) else { return XCTFail("a photo is never streamed") }
    }

    func testAStreamReadsExactlyThePartsAskedFor() async throws {
        let (vault, id) = try await freedClip()
        let entry = try XCTUnwrap(vault.index.entry(for: id))
        let reader = MediaVaultRangeReader(google: authorized, fileID: entry.fileID, total: entry.byteCount)
        var got = Data()
        for piece in MediaVaultFetch.chunks(offset: 2, length: 9, total: entry.byteCount, chunk: 4) { got += try await reader.read(piece) }
        XCTAssertEqual(String(decoding: got, as: UTF8.self), "23456789a")
        XCTAssertEqual(google.rangeRequests, ["bytes=2-5", "bytes=6-9", "bytes=10-10"])

        // A server that ignores the range and sends everything: the right part is still cut out.
        google.ignoresRanges = true
        let cut = try await reader.read(4..<8)
        XCTAssertEqual(String(decoding: cut, as: UTF8.self), "4567")
        // A reply that is neither the part nor the whole file is refused, not played.
        google.replaceData(named: copy1, with: Data("short".utf8))
        do { _ = try await reader.read(0..<3); XCTFail("should refuse") } catch {}
    }

    func testWiFiOnlyHoldsBackAFetchOnCellularUntilThePersonSaysPlayAnyway() async throws {
        let (vault, id) = try await freedClip()
        net.value = .cellular
        let first = await blocked(vault, id)
        XCTAssertEqual(first, .wifiOnly(bytes: 16))
        XCTAssertEqual(google.count(of: "GET www.googleapis.com/drive/v3/files/file-"), 0, "nothing was fetched")
        vault.allowOnCellular(id)
        guard case .file(let file) = try await vault.playback(for: id, isVideo: true) else { return XCTFail() }
        // Cached now: it plays offline and signed out.
        net.value = .offline
        flags.isSignedIn = false
        guard case .file(let again) = try await vault.playback(for: id, isVideo: true) else { return XCTFail() }
        XCTAssertEqual(again, file)
    }

    func testOfflineAndSignedOutAreSaidNotShownAsABrokenClip() async throws {
        let (vault, id) = try await freedClip()
        net.value = .offline
        let offline = await blocked(vault, id)
        XCTAssertEqual(offline, .offline)
        net.value = .wifi
        flags.isSignedIn = false
        let signedOut = await blocked(vault, id)
        XCTAssertEqual(signedOut, .signedOut)
        XCTAssertTrue(vault.contains(id), "neither is a reason to forget the copy")
        // Signed in as far as the phone knows, but Google no longer honours the sign-in.
        flags.isSignedIn = true
        google.expireAccessToken()
        google.refreshRevoked = true
        let lapsed = await blocked(vault, id)
        XCTAssertEqual(lapsed, .signedOut)
        XCTAssertTrue(vault.contains(id))
    }

    func testACopyDeletedInDriveIsSaidAndForgotten() async throws {
        let (vault, id) = try await freedClip()
        google.deleteFile(named: copy1)
        let why = await blocked(vault, id)
        XCTAssertEqual(why, .gone)
        XCTAssertFalse(vault.contains(id), "the app stops promising a copy that is not there")
        XCTAssertFalse(vault.onlyInDrive.contains(id))

        // The same for a large video, which would otherwise hand the player a dead stream.
        let second = try addClip("L2", offset: 20, bytes: "another clip here")
        await vault.runIfNeeded(context: container.mainContext)
        XCTAssertTrue(vault.contains(second))
        library.remove("L2")
        vault.streamAbove = 4
        google.deleteFile(named: copy2)
        let gone = await blocked(vault, second)
        XCTAssertEqual(gone, .gone)
    }

    func testBringingBackThatFailsChangesNothingAndSaysWhy() async throws {
        let (vault, id) = try await freedClip()
        // The download breaks off.
        google.failingFileDownloads = [copy1]
        await vault.bringBackNow(id, context: container.mainContext)
        XCTAssertEqual(vault.bringBackFailure?.clip, id)
        XCTAssertEqual(try row(id).localIdentifier, "L1", "the clip still points where it did")
        XCTAssertTrue(library.saved.isEmpty)
        XCTAssertTrue(vault.onlyInDrive.contains(id))
        XCTAssertTrue(vault.contains(id))
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: cache.path))?.filter { $0.hasSuffix(".part") } ?? [], [],
                       "no half file is left to be played later")

        // The download works, Photos refuses the save.
        google.failingFileDownloads = []
        library.refusesSave = true
        await vault.bringBackNow(id, context: container.mainContext)
        XCTAssertEqual(vault.bringBackFailure?.message, "Photos did not save the clip.")
        XCTAssertEqual(try row(id).localIdentifier, "L1")
        XCTAssertTrue(vault.onlyInDrive.contains(id))

        // Then it works.
        library.refusesSave = false
        await vault.bringBackNow(id, context: container.mainContext)
        XCTAssertNil(vault.bringBackFailure)
        XCTAssertEqual(try row(id).localIdentifier, "restored-1")
    }

    // MARK: The date a brought-back clip sits under in Photos (prompt 277)

    func testAFileWithNoDateOfItsOwnIsFiledWhereTheClipWasFilmed() async throws {
        let (vault, id) = try await freedClip()
        // Nothing recorded from the original: session start + the clip's offset.
        await vault.bringBackNow(id, context: container.mainContext)
        let derived = await library.creationDate(of: "restored-1")
        XCTAssertEqual(derived, start.addingTimeInterval(10))
        XCTAssertNil(vault.bringBackFailure)
    }

    func testTheOriginalsOwnRecordedDateBeatsTheSessionsClock() async throws {
        let (vault, id) = try await freedClip()
        let filmed = start.addingTimeInterval(-3_600)   // attached to the session later; filmed an hour before
        try row(id).linkCapturedAt = filmed
        try container.mainContext.save()
        await vault.bringBackNow(id, context: container.mainContext)
        let date = await library.creationDate(of: "restored-1")
        XCTAssertEqual(date, filmed)
    }

    func testADateTheFileCarriesIsNeverOverruled() async throws {
        let (vault, id) = try await freedClip()
        let embedded = start.addingTimeInterval(4_242)
        library.embeddedDate = embedded
        await vault.bringBackNow(id, context: container.mainContext)
        let date = await library.creationDate(of: "restored-1")
        XCTAssertEqual(date, embedded)
        XCTAssertEqual(library.dateChanges, 0)
    }

    func testAClipStillComesBackWhenItsDateCannotBeSet() async throws {
        let (vault, id) = try await freedClip()
        library.refusesDateChange = true
        await vault.bringBackNow(id, context: container.mainContext)
        XCTAssertNil(vault.bringBackFailure, "the date is a nicety; the clip is back")
        XCTAssertEqual(try row(id).localIdentifier, "restored-1")
        XCTAssertFalse(vault.onlyInDrive.contains(id))
    }

    func testAClipRecoveredFromRecentlyDeletedIsNotBroughtBackTwice() async throws {
        let (vault, id) = try await freedClip("footage one")
        library.add("L1", Data("footage one".utf8))   // the person recovered it in Photos
        await vault.bringBackNow(id, context: container.mainContext)
        XCTAssertNil(vault.bringBackFailure)
        XCTAssertTrue(library.saved.isEmpty, "a second copy in Photos would be a duplicate")
        XCTAssertEqual(try row(id).localIdentifier, "L1")
        XCTAssertFalse(vault.onlyInDrive.contains(id))
    }

    func testACopyFromBeforeSizesWereRecordedIsMeasuredAgainstTheOriginal() async throws {
        let vault = vaultOn()
        await vault.runIfNeeded(context: container.mainContext)   // no clips yet: just makes the folder
        vault.update { $0.keepCopies = false }                    // paused, so nothing new is uploaded
        let same = try addClip("L1", offset: 10, bytes: "footage one")
        let different = try addClip("L2", offset: 20, bytes: "footage two")
        // Copies made by an older build: tagged with the clip, no recorded size.
        google.addLegacyFile(named: "a.mov", data: Data("footage one".utf8), inFolderNamed: "Snappet Clips",
                             props: MediaVaultTag.properties(rowID: same, stamp: nil))
        google.addLegacyFile(named: "b.mov", data: Data("short".utf8), inFolderNamed: "Snappet Clips",
                             props: MediaVaultTag.properties(rowID: different, stamp: nil))
        await vault.refreshIndex()
        await vault.freeUpSpace(context: container.mainContext)
        XCTAssertEqual(library.deleted, ["L1"], "same size as the original: confirmed; a different size: kept")
    }

    func testSayingNoToIOSRemovesNothing() async throws {
        try addClip("L1", offset: 10, bytes: "one")
        let vault = vaultOn()
        await vault.runIfNeeded(context: container.mainContext)
        library.refusesDelete = true
        await vault.freeUpSpace(context: container.mainContext)
        XCTAssertTrue(library.deleted.isEmpty)
        XCTAssertEqual(vault.note, "Nothing was removed from this iPhone.")
        XCTAssertTrue(vault.onlyInDrive.isEmpty)
        XCTAssertTrue(google.trashedNames.isEmpty)
    }

    func testAClipOnlyInDriveCanBeBroughtBackToThePhone() async throws {
        let id = try addClip("L1", offset: 10, bytes: "footage one")
        let vault = vaultOn()
        await vault.runIfNeeded(context: container.mainContext)
        await vault.freeUpSpace(context: container.mainContext)
        XCTAssertEqual(vault.onlyInDrive, [id])

        await vault.bringBackNow(id, context: container.mainContext)
        XCTAssertNil(vault.bringBackFailure)
        XCTAssertEqual(try row(id).localIdentifier, "restored-1", "the clip points at the new original")
        XCTAssertEqual(library.data("restored-1"), Data("footage one".utf8))
        XCTAssertFalse(vault.onlyInDrive.contains(id))
        XCTAssertTrue(vault.contains(id), "the copy stays")
        await vault.runIfNeeded(context: container.mainContext)
        XCTAssertEqual(google.drivePaths.count, 1, "and it is not uploaded a second time")
    }

    func testMissingDrivePermissionIsSaidNotGuessedAround() async throws {
        try addClip("L1", offset: 10, bytes: "one")
        flags.revoke(GoogleScope.driveFile)
        let vault = service()
        vault.update { $0.keepCopies = true; $0.started = true }
        await vault.runIfNeeded(context: container.mainContext)
        XCTAssertEqual(vault.note, "Allow Snappet to save to Google Drive to copy clips.")
        XCTAssertTrue(google.driveFileNames.isEmpty)
    }

    func testAClipRemovedFromThePhonePlaysFromTheVaultAndIsCachedOnce() async throws {
        let id = try addClip("L1", offset: 10, bytes: "footage")
        let vault = vaultOn()
        await vault.runIfNeeded(context: container.mainContext)
        library.remove("L1")   // "Free up space"

        XCTAssertEqual(vault.source(for: id), .vault)
        async let first = vault.localURL(for: id)
        async let second = vault.localURL(for: id)
        let (urlA, urlB) = try await (first, second)
        XCTAssertEqual(urlA, urlB)
        XCTAssertEqual(try Data(contentsOf: urlA), Data("footage".utf8))
        XCTAssertEqual(google.count(of: "GET www.googleapis.com/drive/v3/files/file-"), 1, "concurrent callers share one download")
        XCTAssertEqual(vault.source(for: id), .cache)
        _ = try await vault.localURL(for: id)
        XCTAssertEqual(google.count(of: "GET www.googleapis.com/drive/v3/files/file-"), 1, "and the cached file is reused")

        await vault.refreshCoverage(context: container.mainContext)
        XCTAssertEqual(vault.coverage, .init(copied: 1, total: 1, onlyInVault: 1))
        do { _ = try await vault.localURL(for: UUID()); XCTFail("not in the vault") }
        catch { XCTAssertNotNil(error as? CloudVaultError) }
    }

    func testARestoredPhoneLearnsTheVaultFromTheFolderListing() async throws {
        let id = try addClip("L1", offset: 10, bytes: "footage")
        let first = service()
        first.update { $0.keepCopies = true; $0.started = true }
        await first.runIfNeeded(context: container.mainContext)

        UserDefaults().removePersistentDomain(forName: suite)   // a new install: no saved index, switch off
        let fresh = service()
        XCTAssertFalse(fresh.contains(id))
        await fresh.refreshIndex()
        XCTAssertTrue(fresh.contains(id), "each copy carries its clip id, so a listing rebuilds the index")
        XCTAssertFalse(fresh.settings.keepCopies)
    }

    func testGooglePhotosPicksThatMatchAreCopiedToDriveAndTheRestAreCounted() async throws {
        let wanted = try addClip("DEAD-1", offset: 100)   // captured at start + 100 s
        try addClip("DEAD-2", offset: 900)
        let stamp = ISO8601DateFormatter()
        google.pickerItems = [
            .init(id: "g-match", createTime: stamp.string(from: start.addingTimeInterval(101)), isVideo: true, fileName: "IMG_1.MOV", data: Data("from google".utf8)),
            .init(id: "g-other", createTime: stamp.string(from: start.addingTimeInterval(50_000)), isVideo: true, fileName: "IMG_2.MOV", data: Data("unrelated".utf8)),
        ]
        google.pollsBeforePicked = 3
        let vault = service()

        let session = try await vault.beginGooglePick()
        XCTAssertEqual(session.pickerURL.host, "photos.google.com")
        let picks = try await vault.waitForPicks(session, sleep: { _ in })
        XCTAssertEqual(picks.map(\.id), ["g-match", "g-other"])
        XCTAssertEqual(google.count(of: "GET photospicker.googleapis.com/v1/sessions/sess-1"), 3, "polled until the person was done")
        XCTAssertEqual(google.requests.last, "DELETE photospicker.googleapis.com/v1/sessions/sess-1")

        let media = try container.mainContext.fetch(FetchDescriptor<SessionMedia>())
        let rows = MediaLinkService.rows(for: Set(media.map(\.id)), context: container.mainContext)
        let result = await vault.importFromGoogle(picks, missing: rows)
        XCTAssertEqual(result, .init(saved: 1, unmatched: 1, failed: 0))
        XCTAssertEqual(result.message, "1 clip brought back · 1 pick didn’t match a missing clip")
        let name = MediaVaultNaming.fileName(rowID: wanted, fileExtension: "mov")
        XCTAssertEqual(google.driveFileNames, [name])
        XCTAssertEqual(google.data(named: name), Data("from google".utf8))
        let playable = try await vault.localURL(for: wanted)
        XCTAssertEqual(try Data(contentsOf: playable), Data("from google".utf8), "and it plays from the vault")
        XCTAssertEqual(media.first { $0.id == wanted }?.localIdentifier, "DEAD-1", "the row itself is not rewritten")
    }

    func testAFailedDownloadIsCountedAndTheOthersStillLand() async throws {
        let one = try addClip("DEAD-1", offset: 100)
        try addClip("DEAD-2", offset: 900)
        let stamp = ISO8601DateFormatter()
        google.pickerItems = [
            .init(id: "g1", createTime: stamp.string(from: start.addingTimeInterval(100)), isVideo: true, fileName: "a.mp4", data: Data("a".utf8)),
            .init(id: "g2", createTime: stamp.string(from: start.addingTimeInterval(900)), isVideo: true, fileName: "b.mp4", data: Data("b".utf8)),
        ]
        google.failingDownloads = ["g2"]
        let vault = service()
        let picks = try await vault.waitForPicks(try await vault.beginGooglePick(), sleep: { _ in })
        let media = try container.mainContext.fetch(FetchDescriptor<SessionMedia>())
        let result = await vault.importFromGoogle(picks, missing: MediaLinkService.rows(for: Set(media.map(\.id)), context: container.mainContext))
        XCTAssertEqual(result, .init(saved: 1, unmatched: 0, failed: 1))
        XCTAssertEqual(google.driveFileNames, [MediaVaultNaming.fileName(rowID: one, fileExtension: "mp4")])
    }

    func testWaitingForPicksGivesUpAtTheSessionTimeout() async throws {
        google.pollsBeforePicked = 1000
        let vault = service()
        let session = try await vault.beginGooglePick()
        do { _ = try await vault.waitForPicks(session, sleep: { _ in }); XCTFail("should time out") }
        catch { XCTAssertEqual(error as? GoogleAuthError, .cancelled) }
        XCTAssertEqual(google.count(of: "GET photospicker.googleapis.com/v1/sessions/sess-1"), 20, "60 s timeout / 3 s interval")
    }
}
