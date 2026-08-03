import XCTest
import SwiftData
import UIKit
@testable import Snappet

/// The migration's `needsWork` predicate (wardrobe prompt 03). It is both the "what's left to do"
/// query and the termination condition, so getting it wrong either strands photos as placeholder
/// tiles or re-encodes the whole closet on every launch.
@MainActor
final class WardrobeImageMigrationTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        container = try ModelContainer(
            for: Schema(SnappetSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
    }

    override func tearDown() {
        context = nil
        container = nil
    }

    /// A solid-color PNG at `size` — big ones stand in for the full-resolution cut-out masters.
    private func png(_ size: CGSize, alpha: CGFloat = 1) -> Data {
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.systemTeal.withAlphaComponent(alpha).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }.pngData()!
    }

    private func item(image: Data?, thumbnail: Data? = nil) -> WardrobeItem {
        let i = WardrobeItem(name: "Tee", category: .top, color: .blue,
                             imageData: image, thumbnailData: thumbnail)
        context.insert(i)
        return i
    }

    // MARK: needsWork

    func testItemWithNoPhotoNeedsNoWork() {
        XCTAssertFalse(WardrobeImageMigration.needsWork(item(image: nil)))
    }

    func testOversizedMasterNeedsWork() {
        let big = png(CGSize(width: 2400, height: 1800))
        XCTAssertTrue(WardrobeImageMigration.needsWork(item(image: big)))
    }

    /// The case that produced the placeholder tiles on device: a compliant master that never got
    /// its thumbnail must still be picked up.
    func testCompliantMasterWithNoThumbnailStillNeedsWork() {
        let small = png(CGSize(width: 800, height: 600))
        XCTAssertTrue(WardrobeImageMigration.needsWork(item(image: small)))
    }

    func testCompliantMasterWithThumbnailIsDone() {
        let small = png(CGSize(width: 800, height: 600))
        let thumb = png(CGSize(width: 300, height: 225))
        XCTAssertFalse(WardrobeImageMigration.needsWork(item(image: small, thumbnail: thumb)))
    }

    /// The migration marks an undecodable blob with empty thumbnail data. Without this the item
    /// is permanently pending and the migration re-runs on every single appearance.
    func testUndecodableBlobIsNotPendingForever() {
        let garbage = Data([0x00, 0x01, 0x02, 0x03])
        XCTAssertFalse(WardrobeImageMigration.needsWork(item(image: garbage, thumbnail: Data())))
    }

    // MARK: end-to-end

    func testRunShrinksMastersBackfillsThumbnailsAndIsIdempotent() async {
        let sizes = [CGSize(width: 2400, height: 1800),
                     CGSize(width: 3024, height: 2820),
                     CGSize(width: 900, height: 700)]
        let items = sizes.map { item(image: png($0)) }
        let before = items.map { $0.imageData!.count }

        let migration = WardrobeImageMigration()
        await migration.runIfNeeded(in: context)

        for (index, item) in items.enumerated() {
            XCTAssertNotNil(item.thumbnailData, "item \(index) got no thumbnail")
            XCTAssertFalse(item.thumbnailData!.isEmpty)
            let master = WardrobeImageStore.pixelSize(of: item.imageData!)!
            XCTAssertFalse(
                WardrobeImagePolicy.needsDownscale(master, maxEdge: WardrobeImagePolicy.displayMaxEdge),
                "item \(index) master still oversized: \(master)")
            let thumb = WardrobeImageStore.pixelSize(of: item.thumbnailData!)!
            XCTAssertLessThanOrEqual(max(thumb.width, thumb.height),
                                     WardrobeImagePolicy.thumbnailMaxEdge)
            // The already-compliant third item must not have been re-encoded larger.
            XCTAssertLessThanOrEqual(item.imageData!.count, before[index])
        }
        if case let .finished(reclaimed) = migration.phase {
            XCTAssertGreaterThan(reclaimed, 0)
        } else {
            XCTFail("expected .finished, got \(migration.phase)")
        }

        // Second pass: nothing left to do, so `phase` is never touched again.
        let second = WardrobeImageMigration()
        await second.runIfNeeded(in: context)
        XCTAssertEqual(second.phase, .idle, "migration is not idempotent — it re-ran")
    }

    /// Cut-outs must survive the migration with alpha intact; a JPEG round-trip or an opaque
    /// renderer would turn the transparent surround black.
    func testCutoutKeepsAlphaThroughMigration() async {
        let cutout = item(image: png(CGSize(width: 2000, height: 1500), alpha: 0.5))
        await WardrobeImageMigration().runIfNeeded(in: context)
        XCTAssertTrue(WardrobeImageStore.hasAlpha(cutout.imageData!))
        XCTAssertTrue(WardrobeImageStore.hasAlpha(cutout.thumbnailData!))
    }
}
