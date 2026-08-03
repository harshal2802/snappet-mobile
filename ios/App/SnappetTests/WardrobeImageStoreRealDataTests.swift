import XCTest
import UIKit
@testable import Snappet

/// Runs the real capture-encode pipeline over a folder of ACTUAL closet blobs, to check the
/// reclaim and the alpha handling on real data rather than synthetic fixtures.
///
/// Opt-in and skipped by default — it needs a closet pulled off a device, symlinked (or copied)
/// to `.wardrobe-real-blobs/` at the repo root, which is gitignored:
///
/// ```sh
/// xcrun devicectl device copy from --device <id> \
///   --domain-type appGroupDataContainer --domain-identifier group.com.snappet.app \
///   --source "Library/Application Support" --destination ./out
/// ln -s "$PWD/out/.default_SUPPORT/_EXTERNAL_DATA" <repo>/.wardrobe-real-blobs
/// xcodebuild test -scheme Snappet -only-testing:SnappetTests/WardrobeImageStoreRealDataTests
/// ```
///
/// The folder is found from `#filePath` rather than an environment variable: `xcodebuild` does not
/// forward the shell environment (nor `TEST_RUNNER_`-prefixed vars) into a *hosted unit test*, so
/// an env-gated version of this silently skips, which is worse than useless for a safety check.
///
/// Kept in the suite (rather than thrown away) because it is the only check that the migration's
/// destructive re-encode is safe on the shapes real captures actually produce.
final class WardrobeImageStoreRealDataTests: XCTestCase {

    /// `<repo>/.wardrobe-real-blobs`, derived from this file's compile-time path
    /// (`<repo>/ios/App/SnappetTests/…`).
    private var blobsURL: URL? {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // SnappetTests
            .deletingLastPathComponent()    // App
            .deletingLastPathComponent()    // ios
            .deletingLastPathComponent()    // <repo>
        let url = repoRoot.appendingPathComponent(".wardrobe-real-blobs")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func testRealClosetReencodesSmallerAndKeepsAlpha() throws {
        guard let blobsURL else {
            throw XCTSkip("Symlink a device _EXTERNAL_DATA folder to <repo>/.wardrobe-real-blobs to run this.")
        }
        let files = try FileManager.default
            .contentsOfDirectory(at: blobsURL, includingPropertiesForKeys: [.fileSizeKey])
            .filter { !$0.lastPathComponent.hasPrefix(".") }
        XCTAssertFalse(files.isEmpty, "no blobs at \(blobsURL.path)")

        var beforeBytes = 0, afterDisplay = 0, afterThumb = 0
        var processed = 0, cutouts = 0, skipped = 0
        var worstDisplayEdge = 0.0, worstThumbEdge = 0.0

        for file in files {
            try autoreleasepool {
                let data = try Data(contentsOf: file)
                // Only image blobs — external storage holds other models' bytes too.
                guard let size = WardrobeImageStore.pixelSize(of: data) else { skipped += 1; return }
                guard let image = UIImage(data: data) else { skipped += 1; return }

                let isCutout = WardrobeImageStore.hasAlpha(data)
                if isCutout { cutouts += 1 }
                guard let prepared = WardrobeImageStore.prepare(image: image, isCutout: isCutout)
                else { return XCTFail("prepare returned nil for \(file.lastPathComponent) \(size)") }

                beforeBytes += data.count
                afterDisplay += prepared.display.count
                afterThumb += prepared.thumbnail.count
                processed += 1

                // Every output must be within the caps, or the migration would never terminate.
                if let d = WardrobeImageStore.pixelSize(of: prepared.display) {
                    worstDisplayEdge = max(worstDisplayEdge, max(d.width, d.height))
                    XCTAssertFalse(
                        WardrobeImagePolicy.needsDownscale(d, maxEdge: WardrobeImagePolicy.displayMaxEdge),
                        "display still oversized for \(file.lastPathComponent): \(d)")
                }
                if let t = WardrobeImageStore.pixelSize(of: prepared.thumbnail) {
                    worstThumbEdge = max(worstThumbEdge, max(t.width, t.height))
                }
                // A cut-out that lost its alpha would render as a black rectangle.
                if isCutout {
                    XCTAssertTrue(WardrobeImageStore.hasAlpha(prepared.display),
                                  "cut-out lost alpha: \(file.lastPathComponent)")
                    XCTAssertTrue(WardrobeImageStore.hasAlpha(prepared.thumbnail),
                                  "thumbnail lost alpha: \(file.lastPathComponent)")
                }
            }
        }

        let mb = { (b: Int) in String(format: "%.1f MB", Double(b) / 1_048_576) }
        print("""

        === Wardrobe real-blob re-encode ===
        blobs:     \(processed) processed (\(cutouts) cut-outs), \(skipped) skipped
        before:    \(mb(beforeBytes))
        after:     \(mb(afterDisplay)) master + \(mb(afterThumb)) thumbs = \(mb(afterDisplay + afterThumb))
        reclaimed: \(mb(beforeBytes - afterDisplay - afterThumb))
        largest edge out: display \(Int(worstDisplayEdge))px, thumb \(Int(worstThumbEdge))px

        """)

        XCTAssertGreaterThan(processed, 0)
        XCTAssertLessThan(afterDisplay + afterThumb, beforeBytes / 2,
                          "re-encode should at least halve the closet")
    }
}
