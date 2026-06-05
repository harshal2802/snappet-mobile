import XCTest
import CoreImage
@testable import Snappet

/// Unit tests for the pure `StudioFilter -> CIFilter` mapping (S2). Core Image renders on the
/// simulator, so these run without a device: every filter must produce a renderable, extent-
/// preserving image, `.none` is a pass-through, and warm/cool actually shift the colour balance.
final class StudioFiltersTests: XCTestCase {

    private let context = CIContext(options: [.useSoftwareRenderer: true])

    private func sample(_ r: Double, _ g: Double, _ b: Double, _ side: CGFloat = 16) -> CIImage {
        CIImage(color: CIColor(red: r, green: g, blue: b))
            .cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
    }

    func testNoneIsPassthrough() {
        XCTAssertNil(StudioFilters.ciFilter(for: .none, intensity: 1))
        let img = sample(0.4, 0.5, 0.6)
        XCTAssertEqual(StudioFilters.apply(.none, intensity: 1, to: img).extent, img.extent)
    }

    func testAdjustNeutralIsPassthroughAndNonNeutralRenders() {
        let img = sample(0.4, 0.5, 0.6)
        XCTAssertEqual(StudioFilters.applyAdjust(nil, to: img).extent, img.extent)
        XCTAssertEqual(StudioFilters.applyAdjust(.neutral, to: img).extent, img.extent)
        let adjusted = StudioFilters.applyAdjust(
            ClipAdjust(brightness: 0.2, contrast: 1.3, saturation: 1.5), to: img)
        XCTAssertEqual(adjusted.extent, img.extent, "adjust preserves the frame extent")
        XCTAssertNotNil(context.createCGImage(adjusted, from: adjusted.extent), "adjust renders to a buffer")
    }

    func testEveryFilterRendersAndPreservesExtent() {
        let img = sample(0.4, 0.5, 0.6)
        for f in StudioFilter.allCases where f != .none {
            let out = StudioFilters.apply(f, intensity: 1, to: img)
            XCTAssertEqual(out.extent, img.extent, "\(f) should preserve the frame extent")
            XCTAssertNotNil(context.createCGImage(out, from: out.extent), "\(f) should render to a buffer")
        }
    }

    func testVividAtZeroIntensityIsIdentityParams() {
        let f = StudioFilters.ciFilter(for: .vivid, intensity: 0)
        XCTAssertEqual(f?.value(forKey: kCIInputSaturationKey) as? Double, 1)
        XCTAssertEqual(f?.value(forKey: kCIInputContrastKey) as? Double, 1)
    }

    func testWarmShiftsRedderThanCool() {
        let gray = sample(0.5, 0.5, 0.5)
        let warm = avgRGB(StudioFilters.apply(.warm, intensity: 1, to: gray))
        let cool = avgRGB(StudioFilters.apply(.cool, intensity: 1, to: gray))
        XCTAssertGreaterThan(warm.r, cool.r, "warm should lift red vs cool")
        XCTAssertLessThan(warm.b, cool.b, "warm should ease blue vs cool")
    }

    /// Average R/G/B (0…255) of a rendered CIImage.
    private func avgRGB(_ image: CIImage) -> (r: Double, g: Double, b: Double) {
        let w = Int(image.extent.width), h = Int(image.extent.height)
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        context.render(image, toBitmap: &buf, rowBytes: w * 4, bounds: image.extent,
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        var r = 0.0, g = 0.0, b = 0.0
        for p in stride(from: 0, to: buf.count, by: 4) {
            r += Double(buf[p]); g += Double(buf[p + 1]); b += Double(buf[p + 2])
        }
        let n = Double(max(1, w * h))
        return (r / n, g / n, b / n)
    }
}
