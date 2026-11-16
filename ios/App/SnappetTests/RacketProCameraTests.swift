import XCTest
@testable import Snappet

/// The pro camera's pure logic (prompt 255, issue #448 part 2): lenses from device discovery, the zoom dial, qualities
/// from supported formats, time / size estimates, the status pill, focus points, exposure bias, the level, the live look
/// approximation and what carries into the recording. No camera needed.
final class RacketProCameraTests: XCTestCase {

    private func formats(_ list: [(Int32, Int32, Double)], tenBit: Bool = false) -> [RacketDeviceFormatInfo] {
        list.map { RacketDeviceFormatInfo(width: $0.0, height: $0.1, maxFps: $0.2, isTenBit: tenBit) }
    }

    private var allFormats: [RacketDeviceFormatInfo] {
        formats([(1920, 1080, 30), (1920, 1080, 60), (1920, 1080, 240), (3840, 2160, 30), (3840, 2160, 60), (1280, 720, 240)])
    }

    // MARK: - Lenses from device discovery

    func testTripleCameraWithA3xTelephotoShowsHalfOneAndThree() {
        // iPhone 13 Pro class: ultra-wide at 1, wide at 2, telephoto at 6 (device units).
        let c = RacketCameraCapabilities(device: .init(hasUltraWide: true, switchOverFactors: [2, 6], minZoom: 1, maxZoom: 123,
                                                       formats: allFormats))
        XCTAssertEqual(c.wideFactor, 2)
        XCTAssertEqual(c.lenses, [0.5, 1, 3], "no 2: the 12 MP main camera has no native 2× crop")
        XCTAssertEqual(c.minZoom, 0.5)
        XCTAssertEqual(c.maxZoom, 9, "digital zoom stops at 3× the longest lens")
        XCTAssertEqual(c.deviceZoom(1), 2)
        XCTAssertEqual(c.displayZoom(6), 3)
    }

    func testANativeCropAddsTheTwoButton() {
        // A 48 MP main camera crops natively at 2× (device units 4 on a virtual device whose 1× is 2).
        let c = RacketCameraCapabilities(device: .init(hasUltraWide: true, switchOverFactors: [2, 6], cropFactors: [4],
                                                       minZoom: 1, maxZoom: 123, formats: allFormats))
        XCTAssertEqual(c.lenses, [0.5, 1, 2, 3])
    }

    func testA5xTelephotoAndNoTeleAndWideOnly() {
        let five = RacketCameraCapabilities(device: .init(hasUltraWide: true, switchOverFactors: [2, 10], cropFactors: [4],
                                                          minZoom: 1, maxZoom: 200, formats: allFormats))
        XCTAssertEqual(five.lenses, [0.5, 1, 2, 5])
        XCTAssertEqual(five.maxZoom, 15)
        let dualWide = RacketCameraCapabilities(device: .init(hasUltraWide: true, switchOverFactors: [2], minZoom: 1,
                                                              maxZoom: 95, formats: allFormats))
        XCTAssertEqual(dualWide.lenses, [0.5, 1], "no telephoto, no 2 or 3")
        XCTAssertEqual(dualWide.maxZoom, 3)
        let wideTele = RacketCameraCapabilities(device: .init(hasUltraWide: false, switchOverFactors: [2], minZoom: 1,
                                                              maxZoom: 16, formats: allFormats))
        XCTAssertEqual(wideTele.lenses, [1, 2], "a dual camera's 2× telephoto; no 0.5 without an ultra-wide")
        XCTAssertEqual(wideTele.minZoom, 1)
        let wide = RacketCameraCapabilities(device: .init(hasUltraWide: false, switchOverFactors: [], minZoom: 1,
                                                          maxZoom: 2.5, formats: allFormats))
        XCTAssertEqual(wide.lenses, [1])
        XCTAssertEqual(wide.maxZoom, 2.5, "never past what the device does")
    }

    func testFakeCapabilitiesFromLaunchArguments() {
        let c = RacketCameraCapabilities.fake(lenses: "0.5,1,2,3", formats: "hd1080-30,uhd4k-30")
        XCTAssertEqual(c.lenses, [0.5, 1, 2, 3])
        XCTAssertEqual(c.formats, [.hd30, .uhd30])
        XCTAssertEqual(RacketCameraCapabilities.fake(lenses: nil, formats: nil), .sample)
        XCTAssertEqual(RacketCameraCapabilities.fake(lenses: "1", formats: nil).minZoom, 1)
    }

    // MARK: - Qualities from supported formats

    func testOnlyFormatsTheCameraRecordsAreListed() {
        XCTAssertEqual(RacketCameraFormats.supported(allFormats), RacketCameraFormat.all)
        let no4K60 = formats([(1920, 1080, 60), (3840, 2160, 30)])
        XCTAssertEqual(RacketCameraFormats.supported(no4K60), [.hd30, .hd60, .uhd30])
        XCTAssertEqual(RacketCameraFormats.supported(formats([(1280, 720, 30)])), [])
    }

    func testPickPrefersEightBitThenTheLowestFrameRateThatReaches() {
        let list = [RacketDeviceFormatInfo(width: 1920, height: 1080, maxFps: 240),
                    RacketDeviceFormatInfo(width: 1920, height: 1080, maxFps: 30, isTenBit: true),
                    RacketDeviceFormatInfo(width: 1920, height: 1080, maxFps: 60),
                    RacketDeviceFormatInfo(width: 1920, height: 1080, maxFps: 30)]
        XCTAssertEqual(RacketCameraFormats.pick(.hd30, from: list), 3)
        XCTAssertEqual(RacketCameraFormats.pick(.hd60, from: list), 2)
        XCTAssertNil(RacketCameraFormats.pick(.uhd30, from: list))
    }

    func testFallbackKeepsTheResolutionWhenItCan() {
        XCTAssertEqual(RacketCameraFormats.fallback(.uhd60, supported: [.hd30, .hd60, .uhd30]), .uhd30)
        XCTAssertEqual(RacketCameraFormats.fallback(.uhd60, supported: [.hd30, .hd60]), .hd30)
        XCTAssertEqual(RacketCameraFormats.fallback(.hd60, supported: [.hd30, .hd60]), .hd60)
    }

    func testFormatLabelsAndHeatNotes() {
        XCTAssertEqual(RacketCameraFormat.hd30.label, "HD · 30")
        XCTAssertEqual(RacketCameraFormat.uhd60.label, "4K · 60")
        XCTAssertEqual(RacketCameraFormat.hd30.rowTitle, "HD · 30 (1080p)")
        XCTAssertNil(RacketCameraFormat.hd30.heatNote)
        XCTAssertEqual(RacketCameraFormat.hd60.heatNote, "Smoother slow motion. Warms the phone sooner.")
        XCTAssertEqual(RacketCameraFormat.uhd30.heatNote, "Sharper zoom in the player. Warms the phone sooner.")
        XCTAssertEqual(RacketCameraFormat.uhd60.heatNote, "Likely to overheat in a long match. Best for short drills.")
        XCTAssertEqual(RacketCameraFormat.hd30.portraitAspect, 1080.0 / 1920.0, accuracy: 1e-9)
    }

    // MARK: - Time and size

    func testEstimatesComeFromTheBitrateTableAndFreeSpace() {
        let free: Int64 = 45_000_000_000
        let hd = RacketQualityEstimate(format: .hd30, freeBytes: free)
        // 61 MB/min (60 video + 1 audio) ⇒ 1.0167 MB/s; 45 GB less a 2 % margin ⇒ about 12 h.
        XCTAssertEqual(hd.gigabytesPerHour, 3.66, accuracy: 0.001)
        XCTAssertEqual(hd.line, "12 h · 3.7 GB/h")
        let uhd = RacketQualityEstimate(format: .uhd30, freeBytes: free)
        XCTAssertEqual(uhd.line, "4 h 10 min · 10.3 GB/h")
        XCTAssertGreaterThan(RacketQualityEstimate(format: .hd60, freeBytes: free).gigabytesPerHour, hd.gigabytesPerHour)
        XCTAssertGreaterThan(RacketQualityEstimate(format: .uhd60, freeBytes: free).gigabytesPerHour,
                             uhd.gigabytesPerHour)
        XCTAssertGreaterThan(RacketQualityEstimate(format: .hd30, freeBytes: free, codec: .h264).gigabytesPerHour,
                             hd.gigabytesPerHour, "H.264 is about twice HEVC")
        XCTAssertEqual(RacketQualityEstimate.footnote(freeBytes: free),
                       "Based on 45 GB free. The estimate tightens once recording has run for a minute.")
    }

    func testStatusPill() {
        XCTAssertEqual(RacketCameraStatus.pill(roomSec: 34 * 3600 + 50 * 60, batteryPercent: 82),
                       .init(tone: .ready, text: "Ready · 34 h · 82%"))
        XCTAssertEqual(RacketCameraStatus.pill(roomSec: 90 * 60, batteryPercent: nil),
                       .init(tone: .low, text: "Low space · 1 h"))
        XCTAssertEqual(RacketCameraStatus.pill(roomSec: 10 * 60, batteryPercent: 5),
                       .init(tone: .full, text: "No space · 10 min · 5%"))
        XCTAssertEqual(RacketCameraStatus.pill(roomSec: 12 * 3600, batteryPercent: 140).text, "Ready · 12 h · 100%")
    }

    // MARK: - Zoom dial

    private let caps = RacketCameraCapabilities.sample   // 0.5 / 1 / 3, 0.5…9

    func testDialIsLogarithmicAndRoundTrips() {
        XCTAssertEqual(RacketZoomDial.position(of: 0.5, caps), 0, accuracy: 1e-9)
        XCTAssertEqual(RacketZoomDial.position(of: 9, caps), 1, accuracy: 1e-9)
        // Each doubling takes the same width: 0.5→1 and 1→2 are equal steps.
        let a = RacketZoomDial.position(of: 1, caps), b = RacketZoomDial.position(of: 2, caps)
        XCTAssertEqual(a - 0, b - a, accuracy: 1e-9)
        for z in [0.5, 0.7, 1, 1.4, 3, 8.9] {
            XCTAssertEqual(RacketZoomDial.zoom(atPosition: RacketZoomDial.position(of: z, caps), caps), z, accuracy: 1e-9)
        }
        XCTAssertEqual(RacketZoomDial.zoom(atPosition: -1, caps), 0.5)
        XCTAssertEqual(RacketZoomDial.zoom(atPosition: 2, caps), 9)
    }

    func testZoomIsClampedEverywhere() {
        XCTAssertEqual(RacketZoomDial.clamp(0.2, caps), 0.5)
        XCTAssertEqual(RacketZoomDial.clamp(40, caps), 9)
        XCTAssertEqual(RacketZoomDial.clamp(.nan, caps), 1)
        XCTAssertEqual(RacketZoomDial.dragged(from: 1, dx: 110, caps), 2, accuracy: 1e-9, "one doubling per 110 pt, right zooms in")
        XCTAssertEqual(RacketZoomDial.dragged(from: 1, dx: -110, caps), 0.5, accuracy: 1e-9)
        XCTAssertEqual(RacketZoomDial.dragged(from: 1, dx: 5000, caps), 9)
        XCTAssertEqual(RacketZoomDial.pinched(from: 1, scale: 1.4, caps), 1.4, accuracy: 1e-9)
        XCTAssertEqual(RacketZoomDial.pinched(from: 1, scale: 0, caps), 1, "a broken scale changes nothing")
        XCTAssertEqual(RacketZoomDial.pinched(from: 4, scale: 10, caps), 9)
    }

    func testVoiceOverStepsLandOnLenses() {
        XCTAssertEqual(RacketZoomDial.stepped(1, up: true, caps), 1.25, accuracy: 1e-9)
        XCTAssertEqual(RacketZoomDial.stepped(2.8, up: true, caps), 3, "stops at the 3× lens on the way")
        XCTAssertEqual(RacketZoomDial.stepped(0.6, up: false, caps), 0.5)
        XCTAssertEqual(RacketZoomDial.stepped(9, up: true, caps), 9)
    }

    func testSelectedLensAndLabels() {
        XCTAssertEqual(RacketZoomDial.selectedLens(for: 1.4, caps), 1)
        XCTAssertEqual(RacketZoomDial.selectedLens(for: 0.7, caps), 0)
        XCTAssertEqual(RacketZoomDial.selectedLens(for: 2.98, caps), 2, "a ramp that lands a hair short still selects 3")
        XCTAssertEqual(RacketZoomDial.selectedLens(for: 6, caps), 2)
        XCTAssertEqual(RacketZoomDial.label(1), "1×")
        XCTAssertEqual(RacketZoomDial.label(1.4), "1.4×")
        XCTAssertEqual(RacketZoomDial.label(0.5), "0.5×")
        XCTAssertEqual(RacketZoomDial.label(2.96), "3×")
        XCTAssertEqual(RacketZoomDial.buttonText(lens: 1, selected: true, zoom: 1.4), "1.4×")
        XCTAssertEqual(RacketZoomDial.buttonText(lens: 0.5, selected: false, zoom: 1.4), "0.5")
        XCTAssertEqual(RacketZoomDial.buttonText(lens: 3, selected: false, zoom: 1.4), "3")
    }

    func testDialTicksLabelEachLens() {
        let ticks = RacketZoomDial.ticks(caps)
        XCTAssertEqual(ticks.compactMap(\.label), ["0.5", "1", "3"])
        XCTAssertEqual(ticks.first?.position, 0)
        XCTAssertEqual(ticks.map(\.position), ticks.map(\.position).sorted())
    }

    // MARK: - Focus and exposure

    func testATapMapsToTheSensorsPointOfInterest() {
        // A 9:16 picture letterboxed in a 390×844 box: 390 wide, 693.3 tall, from y = 75.3.
        let box = CGSize(width: 390, height: 844)
        let aspect: CGFloat = 9.0 / 16.0
        let centre = RacketFocusPoint.devicePoint(tap: CGPoint(x: 195, y: 422), in: box, videoAspect: aspect)
        XCTAssertEqual(centre.x, 0.5, accuracy: 1e-6)
        XCTAssertEqual(centre.y, 0.5, accuracy: 1e-6)
        let r = RacketVideoOrientation.aspectFit(aspect: aspect, in: box)
        // The picture's top right is the sensor's (0, 0) when the portrait preview is the sensor turned 90°.
        let topRight = RacketFocusPoint.devicePoint(tap: CGPoint(x: r.maxX, y: r.minY), in: box, videoAspect: aspect)
        XCTAssertEqual(topRight.x, 0, accuracy: 1e-6)
        XCTAssertEqual(topRight.y, 0, accuracy: 1e-6)
        let bottomLeft = RacketFocusPoint.devicePoint(tap: CGPoint(x: r.minX, y: r.maxY), in: box, videoAspect: aspect)
        XCTAssertEqual(bottomLeft.x, 1, accuracy: 1e-6)
        XCTAssertEqual(bottomLeft.y, 1, accuracy: 1e-6)
        // A tap on the black bar above the picture clamps to its top edge.
        let bar = RacketFocusPoint.devicePoint(tap: CGPoint(x: 195, y: 10), in: box, videoAspect: aspect)
        XCTAssertEqual(bar.x, 0, accuracy: 1e-6)
        XCTAssertEqual(bar.y, 0.5, accuracy: 1e-6)
        // And back.
        let p = CGPoint(x: 120, y: 300)
        let back = RacketFocusPoint.viewPoint(device: RacketFocusPoint.devicePoint(tap: p, in: box, videoAspect: aspect),
                                              in: box, videoAspect: aspect)
        XCTAssertEqual(back.x, p.x, accuracy: 1e-6)
        XCTAssertEqual(back.y, p.y, accuracy: 1e-6)
    }

    func testExposureBias() {
        XCTAssertEqual(RacketExposureBias.dragged(from: 0, dy: -45), 1, accuracy: 1e-9, "up brightens")
        XCTAssertEqual(RacketExposureBias.dragged(from: 0, dy: 45), -1, accuracy: 1e-9)
        XCTAssertEqual(RacketExposureBias.dragged(from: 1.5, dy: -500), 2)
        XCTAssertEqual(RacketExposureBias.clamp(-3, deviceMin: -1.5, deviceMax: 1.5), -1.5)
        XCTAssertEqual(RacketExposureBias.stepped(0, up: true), 0.3, accuracy: 1e-9)
        XCTAssertEqual(RacketExposureBias.label(0.3), "+0.3")
        XCTAssertEqual(RacketExposureBias.label(-1), "−1.0")
        XCTAssertEqual(RacketExposureBias.label(0.01), "0")
        XCTAssertEqual(RacketExposureBias.knobOffset(2, length: 120), -60, accuracy: 1e-9)
    }

    // MARK: - Level

    func testLevelUprightSidewaysAndFlat() {
        XCTAssertEqual(RacketLevel.tilt(gx: 0, gy: -1, gz: 0)!, 0, accuracy: 1e-9)
        XCTAssertEqual(RacketLevel.tilt(gx: -1, gy: 0, gz: 0)!, 0, accuracy: 1e-9, "propped on its side counts too")
        let five = 5 * Double.pi / 180
        XCTAssertEqual(RacketLevel.tilt(gx: sin(five), gy: -cos(five), gz: 0)!, 5, accuracy: 1e-6)
        XCTAssertNil(RacketLevel.tilt(gx: 0, gy: -0.1, gz: -0.99), "flat on a table: no horizon")
        XCTAssertTrue(RacketLevel.isLevel(0.6))
        XCTAssertFalse(RacketLevel.isLevel(1.2))
        XCTAssertFalse(RacketLevel.isLevel(nil))
    }

    // MARK: - Looks on the live picture

    func testLookPreviewFollowsThePlaybackParams() {
        XCTAssertEqual(RacketLookPreview(.original), .none)
        let bw = RacketLookPreview(.bw)
        XCTAssertEqual(bw.saturation, 0)
        XCTAssertEqual(bw.contrast, 1.1)
        let warm = RacketLookPreview(.warm)
        XCTAssertLessThan(warm.blue, 1)
        XCTAssertEqual(warm.red, 1)
        let cool = RacketLookPreview(.cool)
        XCTAssertLessThan(cool.red, 1)
        XCTAssertEqual(cool.blue, 1)
        XCTAssertEqual(RacketLookPreview(.vivid).saturation, RacketLook.vivid.params.saturation)
    }

    // MARK: - Mode strip, carry-over, defaults, the log

    func testModeStripLabels() {
        XCTAssertEqual(RacketCameraModeStrip.label(.byUnit, unit: .game), "GAME BY GAME")
        XCTAssertEqual(RacketCameraModeStrip.label(.byUnit, unit: .set), "SET BY SET")
        XCTAssertEqual(RacketCameraModeStrip.label(.everything, unit: .game), "EVERYTHING")
    }

    func testSetupCarriesAndAChangedResolutionStartsAt30() {
        var s = RacketCameraSetup(format: .hd60, zoom: 1.4, focusPoint: CGPoint(x: 0.3, y: 0.6), locked: true,
                                  exposureBias: 0.6, look: .warm)
        XCTAssertEqual(s.with(quality: .hd1080), s)
        s = s.with(quality: .uhd4k)
        XCTAssertEqual(s.format, .uhd30)
        XCTAssertEqual(s.zoom, 1.4)
        XCTAssertTrue(s.locked)
        XCTAssertEqual(s.look, .warm)
    }

    func testDefaultsKeepTheFrameRateAndOldDefaultsDecodeAt30() throws {
        let old = try XCTUnwrap(#"{"matchMode":"byUnit","quality":"uhd4k"}"#.data(using: .utf8))
        let d = RacketRecordingDefaults.load(from: old)
        XCTAssertEqual(d.fps, 30)
        XCTAssertEqual(d.cameraFormat, .uhd30)
        var e = RacketRecordingDefaults()
        e.quality = .hd1080
        e.fps = 60
        XCTAssertEqual(RacketRecordingDefaults.load(from: e.encoded).cameraFormat, .hd60)
    }

    func testTheLogStampsTheFrameRateAndTheLook() {
        var m = RacketRecordingMachine(kind: .match, recording: .byUnit, stillPlayingMinutes: nil, now: Date())
        m.quality = .hd1080
        m.fps = 60
        m.lookRaw = RacketLook.vivid.rawValue
        m.start(now: Date())
        XCTAssertEqual(m.log?.fps, 60)
        XCTAssertEqual(m.log?.lookRaw, "vivid")
        XCTAssertEqual(m.log?.qualityRaw, "hd1080")
        // A continued game-by-game log takes the camera's look as the match's playback look.
        var next = RacketRecordingMachine(kind: .match, recording: .byUnit, stillPlayingMinutes: nil, now: Date())
        next.lookRaw = RacketLook.bw.rawValue
        next.continueLog(RacketRecordingLog(startedAt: Date()))
        XCTAssertEqual(next.log?.lookRaw, "bw")
    }

    func testFramingDefaultsToGridAndLevel() {
        XCTAssertEqual(RacketFraming.load(nil), RacketFraming(grid: true, level: true, courtGuide: false))
        var f = RacketFraming()
        f.courtGuide = true
        XCTAssertEqual(RacketFraming.load(f.encoded), f)
    }
}
