import XCTest
import HighlightEngine
@testable import Snappet

/// Migration-safety tests for the HR tile's `Codable`: persisted blobs saved BEFORE the tile (or
/// before any individual field) existed must still decode. A non-optional property with a default
/// value still **throws** on a missing key under synthesized `Codable` (the repo's documented gotcha),
/// so the hand-written `init(from:)` uses `decodeIfPresent ?? default`. These tests lock that in.
final class HRTileCodableTests: XCTestCase {

    private let uuid = "11111111-1111-1111-1111-111111111111"

    func testLegacyConfigWithoutTileDecodes() throws {
        // An HROverlayConfig saved before the tile feature (no `tile`, no `elements`).
        let legacy = """
        {"normalizedX":0.5,"normalizedY":0.8,"scale":0.86,"colorHex":"#FF3B30","showBPM":true,"zoneColored":false}
        """
        let cfg = try JSONDecoder().decode(HROverlayConfig.self, from: Data(legacy.utf8))
        XCTAssertNil(cfg.tile)
        XCTAssertTrue(cfg.elements.isEmpty)
    }

    func testTileRoundTrips() throws {
        let tile = HRTile.make(template: .scorebug)
        let data = try JSONEncoder().encode(tile)
        let back = try JSONDecoder().decode(HRTile.self, from: data)
        XCTAssertEqual(tile, back)
    }

    func testTileMissingFieldDecodesWithDefault() throws {
        // A tile blob missing `height` (added later) must decode with the default 0.16, not throw.
        let json = """
        {"id":"\(uuid)","templateRaw":"scorebug","entries":[],"centerX":0.5,"centerY":0.8,"width":0.6,"showChart":false,"zoneColored":true}
        """
        let tile = try JSONDecoder().decode(HRTile.self, from: Data(json.utf8))
        XCTAssertEqual(tile.height, 0.16, accuracy: 1e-9)
        XCTAssertEqual(tile.width, 0.6, accuracy: 1e-9)
        XCTAssertEqual(tile.template, .scorebug)
    }

    func testTileOpacityDefaultsToOneWhenAbsentAndClampsOnDecode() throws {
        // A tile blob from before the opacity control → fully opaque.
        let legacy = """
        {"id":"\(uuid)","templateRaw":"hero","entries":[],"centerX":0.5,"centerY":0.3,"width":0.54,"height":0.36,"showChart":true,"zoneColored":true}
        """
        XCTAssertEqual(try JSONDecoder().decode(HRTile.self, from: Data(legacy.utf8)).opacity, 1.0, accuracy: 1e-9)
        // A too-faint persisted opacity is clamped up to the legible floor on decode.
        let faint = """
        {"id":"\(uuid)","templateRaw":"hero","entries":[],"centerX":0.5,"centerY":0.3,"width":0.54,"height":0.36,"showChart":true,"zoneColored":true,"opacity":0.01}
        """
        XCTAssertEqual(try JSONDecoder().decode(HRTile.self, from: Data(faint.utf8)).opacity,
                       HRTile.minOpacity, accuracy: 1e-9)
    }

    func testTileOpacityRoundTrips() throws {
        var tile = HRTile.make(template: .hero)
        tile.opacity = 0.6
        let back = try JSONDecoder().decode(HRTile.self, from: try JSONEncoder().encode(tile))
        XCTAssertEqual(back.opacity, 0.6, accuracy: 1e-9)
    }

    func testMetricEntryMissingOnDefaultsTrue() throws {
        // An entry persisted before the `on` toggle existed must default to visible (on = true).
        let json = """
        {"id":"\(uuid)","metricRaw":"bpm","live":true,"animated":true,"colorHex":"#FFFFFF"}
        """
        let entry = try JSONDecoder().decode(HRTileMetricEntry.self, from: Data(json.utf8))
        XCTAssertTrue(entry.on)
        XCTAssertEqual(entry.metric, .bpm)
    }

    func testConfigWithTileRoundTrips() throws {
        var cfg = HROverlayConfig.default
        cfg.tile = HRTile.make(template: .bento)
        let data = try JSONEncoder().encode(cfg)
        let back = try JSONDecoder().decode(HROverlayConfig.self, from: data)
        XCTAssertEqual(back.tile, cfg.tile)
    }

    /// SwiftData's composite coder materializes a `nil` nested-optional Codable as a content-EMPTY
    /// value (a tile with no entries + a fresh random id) rather than absent — which is nondeterministic
    /// and would wrongly block legacy migration. A real tile always carries every metric entry, so an
    /// entries-empty tile must normalize back to `nil`. (Regression for the backup-determinism break.)
    func testPhantomEmptyTileNormalizesToNil() throws {
        let json = """
        {"normalizedX":0.5,"normalizedY":0.8,"scale":0.86,"colorHex":"#FF3B30","showBPM":true,\
        "zoneColored":false,"showChart":false,"elements":[],\
        "tile":{"id":"\(uuid)","templateRaw":"scorebug","entries":[],"centerX":0.5,"centerY":0.8,\
        "width":0.62,"height":0.16,"showChart":false,"zoneColored":true}}
        """
        let cfg = try JSONDecoder().decode(HROverlayConfig.self, from: Data(json.utf8))
        XCTAssertNil(cfg.tile)        // phantom empty tile → nil

        // A tile WITH entries is a real tile and is preserved.
        var real = HROverlayConfig.default
        real.tile = HRTile.make(template: .scorebug)
        let back = try JSONDecoder().decode(HROverlayConfig.self,
                                            from: try JSONEncoder().encode(real))
        XCTAssertNotNil(back.tile)
    }
}
