import Foundation

// How big a closet photo is allowed to be (wardrobe prompt 03). PURE — the arithmetic and the
// numbers live here so they're unit-testable without a simulator; the pixel work is the thin
// `Services/WardrobeImageStore` edge.
//
// The bug this exists to prevent: capture used to store the background-removed cut-out as a
// full-resolution lossless RGBA PNG (measured on a real closet: 97 photos averaging 10.4 MB,
// 1.01 GB total) and every tile decoded that master to fill a 96pt square — a 3024×2820 RGBA
// bitmap is ~34 MB, roughly 110× the pixels the tile can show.

/// The size/encoding contract for stored garment photos.
enum WardrobeImagePolicy {
    /// Longest edge of the stored **display master**. The biggest on-screen use is the 240pt
    /// detail hero (720px at 3x), so 1024 is right-sized with headroom for a future zoom.
    static let displayMaxEdge: CGFloat = 1024

    /// Longest edge of the stored **thumbnail**. The biggest tile use is 100pt (300px at 3x).
    static let thumbnailMaxEdge: CGFloat = 320

    /// JPEG quality for non-cut-out originals. Cut-outs need alpha and go to PNG instead.
    static let jpegQuality: CGFloat = 0.85

    /// Slack before the migration bothers to re-encode. Without it, rounding in the resize
    /// (e.g. 1024.4 → 1024) could leave an item permanently one pixel over the line and the
    /// migration would rewrite it on every launch forever.
    static let downscaleSlackPixels: CGFloat = 8

    /// The aspect-preserving target for `size` clamped to `maxEdge`.
    ///
    /// **Never upscales** — a photo already smaller than the cap is returned unchanged, so
    /// re-encoding can only ever shrink. Degenerate (zero/negative) sizes pass through so the
    /// caller's own guard, not a divide-by-zero here, decides what to do.
    static func fittedSize(for size: CGSize, maxEdge: CGFloat) -> CGSize {
        let longest = max(size.width, size.height)
        guard longest > maxEdge, longest > 0, size.width > 0, size.height > 0 else { return size }
        let scale = maxEdge / longest
        return CGSize(width: (size.width * scale).rounded(),
                      height: (size.height * scale).rounded())
    }

    /// Whether an image at `size` is over the cap by enough to be worth re-encoding.
    /// Drives the migration's "does this item still need work?" check, so it MUST return false
    /// for anything `fittedSize` would leave alone — otherwise the migration never terminates.
    static func needsDownscale(_ size: CGSize, maxEdge: CGFloat) -> Bool {
        max(size.width, size.height) > maxEdge + downscaleSlackPixels
    }

    /// Rough decoded-bitmap cost in bytes (RGBA8) — the `NSCache` cost function and the
    /// "how bad is this?" number in diagnostics.
    static func bitmapBytes(for size: CGSize, scale: CGFloat = 1) -> Int {
        let w = Int((size.width * scale).rounded()), h = Int((size.height * scale).rounded())
        return max(0, w) * max(0, h) * 4
    }
}
