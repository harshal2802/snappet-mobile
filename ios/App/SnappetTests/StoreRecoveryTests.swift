import XCTest
@testable import Snappet

/// The #68 reset path: the store-file URL derivation is pure and the reset deletes
/// exactly SwiftData's default store + sidecars — nothing else, and missing files are
/// not an error (a half-deleted store must still reset cleanly).
final class StoreRecoveryTests: XCTestCase {

    func testStoreURLDerivationCoversTheStoreAndItsSidecars() {
        let dir = URL(fileURLWithPath: "/tmp/snappet-test", isDirectory: true)
        let names = StoreRecovery.storeURLs(in: dir).map(\.lastPathComponent)
        XCTAssertEqual(names, ["default.store", "default.store-shm", "default.store-wal"])
        XCTAssertTrue(StoreRecovery.storeURLs(in: dir).allSatisfy {
            $0.deletingLastPathComponent().path == dir.path
        })
    }

    func testResetDeletesStoreFilesSparesOthersAndToleratesMissing() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "store-recovery-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        // A partial store (no -shm) plus an unrelated file that must survive.
        try Data("db".utf8).write(to: dir.appending(path: "default.store"))
        try Data("wal".utf8).write(to: dir.appending(path: "default.store-wal"))
        let bystander = dir.appending(path: "highlight-feedback.jsonl")
        try Data("keep".utf8).write(to: bystander)

        try StoreRecovery.resetPersistentStore(in: dir)

        XCTAssertFalse(fm.fileExists(atPath: dir.appending(path: "default.store").path))
        XCTAssertFalse(fm.fileExists(atPath: dir.appending(path: "default.store-wal").path))
        XCTAssertTrue(fm.fileExists(atPath: bystander.path), "only the store files are removed")

        // Already-clean directory: a second reset is a no-op, not an error.
        XCTAssertNoThrow(try StoreRecovery.resetPersistentStore(in: dir))
    }
}
