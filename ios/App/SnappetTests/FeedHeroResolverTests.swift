import XCTest
@testable import Snappet

/// F3 (R1) — the hero fallback chain `clip → photo → generated`, each tier reached.
/// Pure: no device, no SwiftUI.
final class FeedHeroResolverTests: XCTestCase {

    private let clip = FeedClipRef(assetId: "asset-1", offsetSec: 5, durationSec: 8)

    func testClipTierWhenCentralAndMotionOK() {
        let tier = FeedHeroResolver.resolveHero(clip: clip, photoAssetId: "photo-1",
                                                isCentral: true, reduceMotion: false, lowPower: false)
        XCTAssertEqual(tier, .clip(clip), "central + motion-ok + a clip → animate the clip")
    }

    func testPhotoTierWhenNotCentral() {
        let tier = FeedHeroResolver.resolveHero(clip: clip, photoAssetId: "photo-1",
                                                isCentral: false, reduceMotion: false, lowPower: false)
        XCTAssertEqual(tier, .photo(assetId: "photo-1"), "off-center clip session falls back to the still photo")
    }

    func testPhotoTierWhenReduceMotion() {
        let tier = FeedHeroResolver.resolveHero(clip: clip, photoAssetId: "photo-1",
                                                isCentral: true, reduceMotion: true, lowPower: false)
        XCTAssertEqual(tier, .photo(assetId: "photo-1"), "reduceMotion → no clip, fall to photo")
    }

    func testPhotoTierWhenLowPower() {
        let tier = FeedHeroResolver.resolveHero(clip: clip, photoAssetId: "photo-1",
                                                isCentral: true, reduceMotion: false, lowPower: true)
        XCTAssertEqual(tier, .photo(assetId: "photo-1"), "Low Power Mode → no clip, fall to photo")
    }

    func testGeneratedTierWhenNoMedia() {
        let tier = FeedHeroResolver.resolveHero(clip: nil, photoAssetId: nil,
                                                isCentral: true, reduceMotion: false, lowPower: false)
        XCTAssertEqual(tier, .generated, "no clip + no photo → generated DisciplineHero")
    }

    func testGeneratedTierWhenNoClipAndNoPhotoEvenIfCentral() {
        // A session with neither a clipReady clip nor a still always degrades to generated.
        let tier = FeedHeroResolver.resolveHero(clip: nil, photoAssetId: nil,
                                                isCentral: false, reduceMotion: true, lowPower: true)
        XCTAssertEqual(tier, .generated)
    }

    func testReduceMotionWithNoPhotoFallsAllTheWayToGenerated() {
        // Motion blocked AND no still photo → skip past photo to generated (not a dead clip surface).
        let tier = FeedHeroResolver.resolveHero(clip: clip, photoAssetId: nil,
                                                isCentral: true, reduceMotion: true, lowPower: false)
        XCTAssertEqual(tier, .generated)
    }

    func testClipPreferredOverPhotoWhenBothAvailableAndCentral() {
        let tier = FeedHeroResolver.resolveHero(clip: clip, photoAssetId: "photo-1",
                                                isCentral: true, reduceMotion: false, lowPower: false)
        if case .clip(let ref) = tier { XCTAssertEqual(ref.assetId, "asset-1") }
        else { XCTFail("clip should win over photo when both present + central + motion-ok") }
    }
}
