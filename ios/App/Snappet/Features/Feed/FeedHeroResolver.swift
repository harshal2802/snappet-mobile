import Foundation

// MARK: - Recap Feed — hero fallback-chain resolver (F3, pure)
//
// The honest degradation chain the session card's hero slot resolves through:
//
//     clip → photo → generated DisciplineHero
//
// A clip animates ONLY when the card is central AND motion is allowed (not reduceMotion,
// not Low Power Mode); otherwise it falls to a still photo if one exists; otherwise to
// F1's generated `DisciplineHero` (the no-media hero). A session with no media degrades
// silently into F1's existing hero with no dead surface (`_locked-design.md:213`).
//
// PURE: Foundation only — NO AVFoundation/SwiftUI/UIKit. The tier decision is a value
// function so each tier is unit-testable without a device; the card view (R2) just asks
// the resolver for the best available tier and renders it.

/// The resolved hero tier for a session card. Carries just enough to drive the view:
/// the clip's looped time-range ref, the still photo's asset id, or "use the generated hero".
enum HeroTier: Sendable, Equatable {
    /// Animate the top-ranked clip segment (only when central + motion allowed).
    case clip(FeedClipRef)
    /// Show a still photo (the existing thumbnail surface) — video not central / not eligible / motion off.
    case photo(assetId: String)
    /// F1's generated `DisciplineHero` — no media at all.
    case generated
}

enum FeedHeroResolver {

    /// Resolve the best available hero tier for a session card.
    ///
    /// - Parameters:
    ///   - clip: the top-ranked clip ref when the session is `clipReady`, else `nil`.
    ///   - photoAssetId: a still photo's PHAsset `localIdentifier` when one is available, else `nil`.
    ///   - isCentral: whether this card is the one nearest the viewport center (single-active rule).
    ///   - reduceMotion: the system `reduceMotion` accessibility setting.
    ///   - lowPower: whether Low Power Mode is engaged.
    /// - Returns: `.clip` only when a clip is present AND central AND motion is allowed;
    ///   else `.photo` if a still is present; else `.generated`.
    static func resolveHero(clip: FeedClipRef?,
                            photoAssetId: String?,
                            isCentral: Bool,
                            reduceMotion: Bool,
                            lowPower: Bool) -> HeroTier {
        let motionAllowed = !reduceMotion && !lowPower
        if let clip, isCentral, motionAllowed {
            return .clip(clip)
        }
        if let photoAssetId {
            return .photo(assetId: photoAssetId)
        }
        return .generated
    }
}
