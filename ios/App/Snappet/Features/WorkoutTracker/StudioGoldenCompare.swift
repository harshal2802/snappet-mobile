#if DEBUG
import Foundation
import CoreGraphics

/// A decoded frame: 8-bit RGBA rows, top row first, alpha ignored (prompt 304). The golden-frame
/// tests and the debug self-check compare two of these. Foundation only.
struct StudioGoldenImage: Equatable, Sendable {
    let width: Int
    let height: Int
    /// `width * height * 4` bytes: R, G, B, A.
    var rgba: [UInt8]

    init(width: Int, height: Int, rgba: [UInt8]) {
        precondition(width >= 0 && height >= 0 && rgba.count == width * height * 4,
                     "a golden image needs width × height × 4 bytes")
        self.width = width
        self.height = height
        self.rgba = rgba
    }

    /// A one-colour image.
    init(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for i in stride(from: 0, to: bytes.count, by: 4) { bytes[i] = r; bytes[i + 1] = g; bytes[i + 2] = b }
        self.init(width: width, height: height, rgba: bytes)
    }

    /// Paint a rectangle (cut to the image).
    mutating func fill(x: Int, y: Int, width w: Int, height h: Int, r: UInt8, g: UInt8, b: UInt8) {
        guard w > 0, h > 0 else { return }
        for py in max(0, y) ..< min(height, y + h) {
            for px in max(0, x) ..< min(width, x + w) {
                let i = (py * width + px) * 4
                rgba[i] = r; rgba[i + 1] = g; rgba[i + 2] = b; rgba[i + 3] = 255
            }
        }
    }
}

/// How far a rendered frame may be from its golden image and still pass.
///
/// A video file stores brightness for every pixel and colour for every second pixel in each
/// direction. So a frame read back from a file has its brightness almost untouched and its colour
/// smeared a few pixels across every sharp edge. Comparing R, G and B pixel by pixel cannot tell
/// that smear from a real change: both are a band of very different pixels. So the comparison
/// looks at the two separately.
///
/// - `luma`: brightness, per pixel. A moved, missing or resized element changes it.
/// - `chroma`: colour, averaged over `StudioGoldenCompare.chromaBlock` pixels a side. The smear
///   at an edge averages out; a wrong filter or a wrong clip does not.
/// - `maxFraction`: the share of the frame's pixels that may still differ.
/// - `maxCellFraction`: the share of ONE small square that may differ. A wrong element is a
///   patch of differing pixels in one place, even when it is a small part of the frame.
/// - `mean`: how far the MEAN colour of one small square may be from the golden's. The rules
///   above ask "is any pixel far off?", so a small change everywhere (a filter at the wrong
///   strength, an opacity a tenth off, a faint glass tile missing) stays under them. A mean
///   over 256 pixels has almost no encoder noise in it, so it can be held to a few levels.
struct StudioGoldenTolerance: Equatable, Sendable {
    /// A pixel differs when its brightness is further than this from the golden's (0…255).
    var luma: Int
    /// …or when its averaged colour is further than this from the golden's (0…255).
    var chroma: Int
    /// The largest share of the frame's pixels that may differ.
    var maxFraction: Double
    /// The largest share of one `StudioGoldenCompare.cell`-sized square that may differ.
    var maxCellFraction: Double
    /// The largest difference between the two frames' mean R, G or B over one such square.
    var mean: Double
}

/// The pure comparison of a rendered frame with its golden image (prompt 304).
enum StudioGoldenCompare {

    /// The frame is checked in squares of this many pixels a side. The squares overlap by half,
    /// so a patch of differing pixels is never split evenly between two of them.
    static let cell = 16
    private static let half = cell / 2
    /// Colour is averaged over a square of this many pixels a side before it is compared.
    static let chromaBlock = 8

    struct Region: Equatable, Sendable {
        /// The square, cut to the image.
        let x: Int, y: Int, width: Int, height: Int
        /// Differing pixels in the region.
        let differing: Int
        /// The share of a WHOLE square that differs. A square cut by the image's edge is still
        /// measured against a whole one, so a line of encoder noise along the border counts for
        /// no more there than anywhere else.
        var fraction: Double { Double(differing) / Double(StudioGoldenCompare.cell * StudioGoldenCompare.cell) }
    }

    struct Result: Equatable, Sendable {
        let sizeMatches: Bool
        let actualWidth: Int, actualHeight: Int
        let goldenWidth: Int, goldenHeight: Int
        /// Pixels whose brightness or averaged colour is outside the tolerance.
        let differing: Int
        let total: Int
        /// The largest brightness difference and the largest averaged-colour difference anywhere
        /// in the frame, rounded.
        let maxLuma: Int
        let maxChroma: Int
        /// The square with the most differing pixels; `nil` when no pixel differs.
        let worst: Region?
        /// The largest difference of a square's mean R, G or B, and that square (`differing` is 0).
        let maxMean: Double
        let meanRegion: Region?
        let tolerance: StudioGoldenTolerance

        var fraction: Double { total > 0 ? Double(differing) / Double(total) : 0 }

        var passed: Bool {
            guard sizeMatches else { return false }
            if fraction > tolerance.maxFraction { return false }
            if let worst, worst.fraction > tolerance.maxCellFraction { return false }
            if maxMean > tolerance.mean { return false }
            return true
        }

        /// The share of one square that differs, in the worst square (0 when no pixel differs).
        var cellFraction: Double { worst?.fraction ?? 0 }

        /// One line for a test failure or the self-check report.
        var summary: String {
            guard sizeMatches else {
                return "size \(actualWidth)×\(actualHeight), golden is \(goldenWidth)×\(goldenHeight)"
            }
            var text = "\(differing) of \(total) pixels differ (\(Self.percent(fraction)), allowed "
                + "\(Self.percent(tolerance.maxFraction))), largest brightness difference \(maxLuma) "
                + "(allowed \(tolerance.luma)), largest colour difference \(maxChroma) (allowed \(tolerance.chroma))"
            if let worst {
                text += "; worst region x \(worst.x)–\(worst.x + worst.width - 1), "
                    + "y \(worst.y)–\(worst.y + worst.height - 1): \(worst.differing) pixels "
                    + "(\(Self.percent(worst.fraction)), allowed \(Self.percent(tolerance.maxCellFraction)))"
            }
            text += "; largest region mean difference \(Self.decimal(maxMean)) (allowed \(Self.decimal(tolerance.mean)))"
            if let meanRegion, maxMean > tolerance.mean {
                text += " at x \(meanRegion.x)–\(meanRegion.x + meanRegion.width - 1), "
                    + "y \(meanRegion.y)–\(meanRegion.y + meanRegion.height - 1)"
            }
            return text
        }

        static func decimal(_ value: Double) -> String {
            String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
        }

        static func percent(_ fraction: Double) -> String {
            String(format: "%.2f%%", locale: Locale(identifier: "en_US_POSIX"), fraction * 100)
        }
    }

    static func compare(actual: StudioGoldenImage, golden: StudioGoldenImage,
                        tolerance: StudioGoldenTolerance) -> Result {
        guard let d = differences(actual: actual, golden: golden) else {
            return Result(sizeMatches: false, actualWidth: actual.width, actualHeight: actual.height,
                          goldenWidth: golden.width, goldenHeight: golden.height,
                          differing: 0, total: golden.width * golden.height, maxLuma: 0, maxChroma: 0,
                          worst: nil, maxMean: 0, meanRegion: nil, tolerance: tolerance)
        }
        let w = actual.width, h = actual.height
        let lumaLimit = Double(tolerance.luma), chromaLimit = Double(tolerance.chroma)
        // Count per half-cell tile, then add 2 × 2 tiles for each square.
        let columns = max(1, (w + half - 1) / half), rows = max(1, (h + half - 1) / half)
        var tiles = [Int](repeating: 0, count: columns * rows)
        var differing = 0
        var maxLuma = 0.0, maxChroma = 0.0
        d.luma.withUnsafeBufferPointer { luma in
            d.chroma.withUnsafeBufferPointer { chroma in
                tiles.withUnsafeMutableBufferPointer { tiles in
                    for y in 0 ..< h {
                        let row = (y / half) * columns
                        for x in 0 ..< w {
                            let i = y * w + x
                            if luma[i] > maxLuma { maxLuma = luma[i] }
                            if chroma[i] > maxChroma { maxChroma = chroma[i] }
                            if luma[i] > lumaLimit || chroma[i] > chromaLimit {
                                differing += 1
                                tiles[row + x / half] += 1
                            }
                        }
                    }
                }
            }
        }
        var worst: Region?
        if differing > 0 {
            var most = 0, at = (column: 0, row: 0)
            for row in 0 ..< max(1, rows - 1) {
                for column in 0 ..< max(1, columns - 1) {
                    var count = 0
                    for dy in 0 ... 1 where row + dy < rows {
                        for dx in 0 ... 1 where column + dx < columns { count += tiles[(row + dy) * columns + column + dx] }
                    }
                    if count > most { most = count; at = (column, row) }
                }
            }
            let x = at.column * half, y = at.row * half
            worst = Region(x: x, y: y, width: min(cell, w - x), height: min(cell, h - y), differing: most)
        }
        var maxMean = 0.0, meanRegion: Region?
        for square in meanDifferences(actual: actual, golden: golden) where square.value > maxMean {
            maxMean = square.value
            meanRegion = Region(x: square.x, y: square.y, width: square.width, height: square.height, differing: 0)
        }
        return Result(sizeMatches: true, actualWidth: w, actualHeight: h, goldenWidth: w, goldenHeight: h,
                      differing: differing, total: w * h,
                      maxLuma: Int(maxLuma.rounded()), maxChroma: Int(maxChroma.rounded()),
                      worst: worst, maxMean: (maxMean * 10).rounded() / 10, meanRegion: meanRegion,
                      tolerance: tolerance)
    }

    /// For every square (the same overlapping squares as above, cut to the image): the largest of
    /// the differences between the two frames' mean R, mean G and mean B. Sizes must match.
    private static func meanDifferences(actual: StudioGoldenImage, golden: StudioGoldenImage)
        -> [(x: Int, y: Int, width: Int, height: Int, value: Double)] {
        let w = actual.width, h = actual.height
        guard w > 0, h > 0 else { return [] }
        let columns = max(1, (w + half - 1) / half), rows = max(1, (h + half - 1) / half)
        // Signed sums of the difference per half-cell tile: red, then green, then blue.
        let tileCount = columns * rows
        var sums = [Int](repeating: 0, count: tileCount * 3)
        actual.rgba.withUnsafeBufferPointer { a in
            golden.rgba.withUnsafeBufferPointer { g in
                sums.withUnsafeMutableBufferPointer { sums in
                    for y in 0 ..< h {
                        let row = (y / half) * columns
                        for x in 0 ..< w {
                            let i = (y * w + x) * 4, tile = row + x / half
                            sums[tile] += Int(a[i]) - Int(g[i])
                            sums[tileCount + tile] += Int(a[i + 1]) - Int(g[i + 1])
                            sums[2 * tileCount + tile] += Int(a[i + 2]) - Int(g[i + 2])
                        }
                    }
                }
            }
        }
        var out: [(x: Int, y: Int, width: Int, height: Int, value: Double)] = []
        for row in 0 ..< max(1, rows - 1) {
            for column in 0 ..< max(1, columns - 1) {
                let x = column * half, y = row * half
                let width = min(cell, w - x), height = min(cell, h - y)
                var largest = 0.0
                for channel in 0 ..< 3 {
                    var sum = 0
                    for dy in 0 ... 1 where row + dy < rows {
                        for dx in 0 ... 1 where column + dx < columns {
                            sum += sums[channel * tileCount + (row + dy) * columns + column + dx]
                        }
                    }
                    largest = max(largest, abs(Double(sum)) / Double(width * height))
                }
                out.append((x, y, width, height, largest))
            }
        }
        return out
    }

    /// A picture of where two frames differ: the rendered frame, darkened, with every differing
    /// pixel in magenta. `nil` when the sizes differ (there is nothing to line up).
    static func diffImage(actual: StudioGoldenImage, golden: StudioGoldenImage,
                          tolerance: StudioGoldenTolerance) -> StudioGoldenImage? {
        guard let d = differences(actual: actual, golden: golden) else { return nil }
        let lumaLimit = Double(tolerance.luma), chromaLimit = Double(tolerance.chroma)
        var out = actual
        for p in 0 ..< actual.width * actual.height {
            let i = p * 4
            if d.luma[p] > lumaLimit || d.chroma[p] > chromaLimit {
                out.rgba[i] = 255; out.rgba[i + 1] = 0; out.rgba[i + 2] = 255
            } else {
                out.rgba[i] /= 3; out.rgba[i + 1] /= 3; out.rgba[i + 2] /= 3
            }
            out.rgba[i + 3] = 255
        }
        // A square whose mean colour is off gets a yellow outline.
        for q in meanDifferences(actual: actual, golden: golden) where q.value > tolerance.mean {
            out.fill(x: q.x, y: q.y, width: q.width, height: 1, r: 255, g: 230, b: 0)
            out.fill(x: q.x, y: q.y + q.height - 1, width: q.width, height: 1, r: 255, g: 230, b: 0)
            out.fill(x: q.x, y: q.y, width: 1, height: q.height, r: 255, g: 230, b: 0)
            out.fill(x: q.x + q.width - 1, y: q.y, width: 1, height: q.height, r: 255, g: 230, b: 0)
        }
        return out
    }

    // MARK: Brightness and colour

    /// Per pixel: how far the brightness is from the golden's, and how far the averaged colour
    /// is (the larger of its two parts). `nil` when the sizes differ.
    ///
    /// Brightness and the two colour-difference values are BT.709, on a 0…255 scale. They are
    /// sums of R, G and B, so the difference of two frames' values is the value of the frames'
    /// difference; the colour is averaged once, on the difference. (Unsafe buffers because a
    /// Debug build checks every array index, and the suite compares 112 frames.)
    private static func differences(actual: StudioGoldenImage, golden: StudioGoldenImage)
        -> (luma: [Double], chroma: [Double])? {
        guard actual.width == golden.width, actual.height == golden.height else { return nil }
        let w = actual.width, h = actual.height, count = w * h
        var luma = [Double](repeating: 0, count: count)
        var blue = luma, red = luma
        actual.rgba.withUnsafeBufferPointer { a in
            golden.rgba.withUnsafeBufferPointer { g in
                luma.withUnsafeMutableBufferPointer { l in
                    blue.withUnsafeMutableBufferPointer { cb in
                        red.withUnsafeMutableBufferPointer { cr in
                            for p in 0 ..< count {
                                let i = p * 4
                                let r = Double(Int(a[i]) - Int(g[i]))
                                let gr = Double(Int(a[i + 1]) - Int(g[i + 1]))
                                let b = Double(Int(a[i + 2]) - Int(g[i + 2]))
                                let y = 0.2126 * r + 0.7152 * gr + 0.0722 * b
                                l[p] = abs(y)
                                cb[p] = (b - y) / 1.8556
                                cr[p] = (r - y) / 1.5748
                            }
                        }
                    }
                }
            }
        }
        let b = averaged(blue, width: w, height: h), r = averaged(red, width: w, height: h)
        var chroma = [Double](repeating: 0, count: count)
        chroma.withUnsafeMutableBufferPointer { c in
            b.withUnsafeBufferPointer { b in
                r.withUnsafeBufferPointer { r in
                    for p in 0 ..< count { c[p] = max(abs(b[p]), abs(r[p])) }
                }
            }
        }
        return (luma, chroma)
    }

    /// Each value replaced by the mean of the `chromaBlock`-sized square around it (cut to the
    /// image at the edges).
    private static func averaged(_ plane: [Double], width w: Int, height h: Int) -> [Double] {
        guard w > 0, h > 0 else { return plane }
        let stride = w + 1
        // Summed-area table with a zero row and column in front.
        var sums = [Double](repeating: 0, count: stride * (h + 1))
        var out = [Double](repeating: 0, count: w * h)
        let before = chromaBlock / 2, after = chromaBlock - before
        plane.withUnsafeBufferPointer { source in
            sums.withUnsafeMutableBufferPointer { sums in
                for y in 0 ..< h {
                    var row = 0.0
                    for x in 0 ..< w {
                        row += source[y * w + x]
                        sums[(y + 1) * stride + x + 1] = sums[y * stride + x + 1] + row
                    }
                }
                out.withUnsafeMutableBufferPointer { out in
                    for y in 0 ..< h {
                        let y0 = max(0, y - before), y1 = min(h, y + after)
                        for x in 0 ..< w {
                            let x0 = max(0, x - before), x1 = min(w, x + after)
                            let sum = sums[y1 * stride + x1] - sums[y0 * stride + x1]
                                - sums[y1 * stride + x0] + sums[y0 * stride + x0]
                            out[y * w + x] = sum / Double((x1 - x0) * (y1 - y0))
                        }
                    }
                }
            }
        }
        return out
    }
}
#endif
