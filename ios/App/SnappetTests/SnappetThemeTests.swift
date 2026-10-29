import XCTest
@testable import Snappet

/// Design-system reset (prompt 211): the user-pickable accent and the new components' pure helpers.
final class SnappetThemeTests: XCTestCase {

    /// WCAG relative luminance of 0xRRGGBB.
    private func luminance(_ hex: UInt32) -> Double {
        func ch(_ v: UInt32) -> Double {
            let c = Double(v) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * ch((hex >> 16) & 0xFF) + 0.7152 * ch((hex >> 8) & 0xFF) + 0.0722 * ch(hex & 0xFF)
    }
    private func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let (l1, l2) = (luminance(a), luminance(b))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    func testPeriwinkleIsTheDefaultAndUnknownFallsBack() {
        XCTAssertEqual(SnappetAccent.default, .periwinkle)
        XCTAssertEqual(SnappetAccent.resolve(nil), .periwinkle)
        XCTAssertEqual(SnappetAccent.resolve("neon"), .periwinkle)
        XCTAssertEqual(SnappetAccent.resolve("teal"), .teal)
        XCTAssertEqual(SnappetAccent.periwinkle.dark, 0x8EA2FF, "the colour the user picked")
    }

    /// Text on every filled accent stays readable: ≥ 4.5:1 (WCAG AA) in light and dark.
    func testTextOnEveryAccentIsReadable() {
        for a in SnappetAccent.allCases {
            XCTAssertGreaterThanOrEqual(contrast(a.light, SnappetAccent.onLight), 4.5, "\(a) light")
            XCTAssertGreaterThanOrEqual(contrast(a.dark, SnappetAccent.onDark), 4.5, "\(a) dark")
        }
    }

    /// The accent is visible on the page it sits on (≥ 3:1, the non-text minimum) in both modes.
    func testEveryAccentStandsOutOnItsBackground() {
        for a in SnappetAccent.allCases {
            XCTAssertGreaterThanOrEqual(contrast(a.light, 0xF6F7F9), 3, "\(a) on the light page")
            XCTAssertGreaterThanOrEqual(contrast(a.dark, 0x0A0B0D), 3, "\(a) on the dark page")
        }
    }

    func testAppearanceModes() {
        XCTAssertNil(SnappetAppearance.system.colorScheme)
        XCTAssertEqual(SnappetAppearance.dark.colorScheme, .dark)
        XCTAssertEqual(SnappetAppearance.light.interfaceStyle, .light)
    }

    func testBarHeights() {
        XCTAssertEqual(SnappetBars.heights([0, 300, 0, 82]), [0.12, 1, 0.12, 82.0 / 300])
        XCTAssertEqual(SnappetBars.heights([0, 0]), [0.12, 0.12], "an empty week still shows its days")
        XCTAssertEqual(SnappetBars.heights([1, 1000])[0], 0.12, "a tiny day is never thinner than the stub")
    }
}
