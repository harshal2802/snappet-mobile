import XCTest
@testable import Snappet

/// The in-app camera's rules (prompt 190): what the phone can do, clamping, the "4K · 30" chip, lenses, memory.
final class CameraSettingsTests: XCTestCase {

    /// An iPhone 13 Pro-class back camera: 1080p up to 240 fps, 4K up to 60, three lenses.
    private let pro = CameraCapabilities.from(
        formats: [.init(width: 1920, height: 1080, maxFPS: 60), .init(width: 1920, height: 1080, maxFPS: 240),
                  .init(width: 3840, height: 2160, maxFPS: 60), .init(width: 1280, height: 720, maxFPS: 240)],
        lenses: [1, 3, 0.5], minZoom: 0.5, maxZoom: 15, hasTorch: true, hasFront: true, enhancedStabilization: true)

    /// A front camera / older phone: 1080p30 and 4K30 only, no slo-mo, no lenses.
    private let basic = CameraCapabilities.from(
        formats: [.init(width: 1920, height: 1080, maxFPS: 30), .init(width: 3840, height: 2160, maxFPS: 30)],
        lenses: [], minZoom: 1, maxZoom: 5, hasTorch: false, hasFront: false, enhancedStabilization: false)

    func testCapabilitiesFromFormats() {
        XCTAssertTrue(pro.video.contains(.init(resolution: .uhd, fps: 60)))
        XCTAssertTrue(pro.video.contains(.init(resolution: .hd, fps: 24)))
        XCTAssertEqual(pro.slomo, [120, 240])
        XCTAssertEqual(pro.lenses, [0.5, 1, 3], "ascending")
        XCTAssertEqual(basic.slomo, [], "720p-only high frame rates don't count; 1080p30 has none")
        XCTAssertFalse(basic.video.contains(.init(resolution: .hd, fps: 60)))
    }

    func testAPickThePhoneCantDoFallsBackToTheNearest() {
        var s = CameraSettings(); s.resolution = .uhd; s.fps = 60; s.mode = .slomo; s.stabilization = .enhanced
        let r = CameraLogic.resolve(s, basic)
        XCTAssertEqual(r.resolution, .uhd, "keeps 4K")
        XCTAssertEqual(r.fps, 30, "the nearest frame rate 4K has")
        XCTAssertEqual(r.mode, .video, "no slo-mo on this camera")
        XCTAssertEqual(r.stabilization, .standard)
        XCTAssertEqual(CameraLogic.resolve(s, pro), s, "the Pro can do all of it")
    }

    func testTheChipCyclesLikeTheIPhoneCamera() {
        var s = CameraSettings()   // HD · 30
        s = CameraLogic.cycleFPS(s, pro); XCTAssertEqual(s.fps, 60)
        s = CameraLogic.cycleFPS(s, pro); XCTAssertEqual(s.fps, 24, "wraps")
        s = CameraLogic.toggleResolution(s, pro); XCTAssertEqual(s.resolution, .uhd)
        XCTAssertEqual(s.fps, 24, "4K keeps the frame rate")
        XCTAssertEqual(CameraLogic.chip(s)?.resolution, "4K")
        XCTAssertEqual(CameraLogic.chip(s)?.fps, "24")

        var slomo = CameraSettings(); slomo.mode = .slomo
        XCTAssertEqual(CameraLogic.chip(slomo)?.fps, "240")
        XCTAssertEqual(CameraLogic.cycleFPS(slomo, pro).slomoFPS, 120)
        var photo = CameraSettings(); photo.mode = .photo
        XCTAssertNil(CameraLogic.chip(photo), "no chip for photos")
    }

    func testCountdownCycles() {
        XCTAssertEqual(CameraLogic.nextCountdown(0), 3)
        XCTAssertEqual(CameraLogic.nextCountdown(3), 10)
        XCTAssertEqual(CameraLogic.nextCountdown(10), 0)
    }

    func testLensLabelsAndTheActiveLens() {
        XCTAssertEqual(CameraLogic.lensLabel(0.5, selected: false, zoom: 1), ".5")
        XCTAssertEqual(CameraLogic.lensLabel(1, selected: false, zoom: 1), "1")
        XCTAssertEqual(CameraLogic.lensLabel(3, selected: false, zoom: 1), "3")
        XCTAssertEqual(CameraLogic.lensLabel(1, selected: true, zoom: 1), "1×")
        XCTAssertEqual(CameraLogic.lensLabel(1, selected: true, zoom: 1.84), "1.8×", "the live zoom on the active lens")
        XCTAssertEqual(CameraLogic.activeLens(zoom: 1.8, lenses: pro.lenses), 1)
        XCTAssertEqual(CameraLogic.activeLens(zoom: 0.7, lenses: pro.lenses), 0.5)
        XCTAssertEqual(CameraLogic.activeLens(zoom: 6, lenses: pro.lenses), 3)
        XCTAssertEqual(CameraLogic.clampZoom(40, pro), 15)
        XCTAssertEqual(CameraLogic.clampZoom(0.2, pro), 0.5)
    }

    func testRememberedSettings() {
        var s = CameraSettings(); s.resolution = .uhd; s.grid = true; s.countdown = 3
        XCTAssertEqual(CameraSettings.load(from: s.encodedForStorage()), s, "remembered")
        s.remember = false
        let loaded = CameraSettings.load(from: s.encodedForStorage())
        XCTAssertEqual(loaded.resolution, .hd, "not remembering → defaults")
        XCTAssertFalse(loaded.grid)
        XCTAssertEqual(CameraSettings.load(from: nil), CameraSettings())
    }

    func testTimer() {
        XCTAssertEqual(CameraLogic.timer(14), "00:00:14")
        XCTAssertEqual(CameraLogic.timer(3_725), "01:02:05")
    }
}
