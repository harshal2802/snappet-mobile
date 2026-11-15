import Foundation
import CoreGraphics

// MARK: - Racket pro camera, before recording (prompt 255, issue #448 part 2) — pure
//
// Boards ProCamera → ProCameraDenied: Apple Camera's layout for framing a match. Everything the camera decides — which
// lens buttons exist, how the zoom dial maps, which qualities the phone records, how long each fits in free space, the
// status pill, where a tap focuses, the level, the live look approximation and what carries into the recording — is
// here as plain values, so it runs in `SnappetTests` (`RacketProCameraTests`) with no camera. The AVFoundation edge is
// `Services/RacketRecorder.swift`; the screens are `RacketProCameraViews.swift`.

// MARK: - Quality (ProCameraQuality)

/// A recording quality as the camera offers it: resolution and frame rate. HD = 1080p.
struct RacketCameraFormat: Hashable, Codable, Sendable {
    var quality: RacketRecordingQuality
    var fps: Int

    static let hd30 = RacketCameraFormat(quality: .hd1080, fps: 30)
    static let hd60 = RacketCameraFormat(quality: .hd1080, fps: 60)
    static let uhd30 = RacketCameraFormat(quality: .uhd4k, fps: 30)
    static let uhd60 = RacketCameraFormat(quality: .uhd4k, fps: 60)
    /// The page's order.
    static let all: [RacketCameraFormat] = [hd30, hd60, uhd30, uhd60]

    /// "HD · 30", "4K · 60".
    var label: String { "\(quality == .uhd4k ? "4K" : "HD") · \(fps)" }
    /// The page's row title: HD · 30 names its resolution (the board's "HD · 30 (1080p)").
    var rowTitle: String { self == .hd30 ? "HD · 30 (1080p)" : label }
    /// "hd1080-30": accessibility identifiers.
    var key: String { "\(quality.rawValue)-\(fps)" }
    var width: Int32 { quality == .uhd4k ? 3840 : 1920 }
    var height: Int32 { quality == .uhd4k ? 2160 : 1080 }

    func config(codec: RacketVideoCodec = .hevc) -> RacketCaptureConfig {
        RacketCaptureConfig(quality: quality, fps: fps, codec: codec)
    }

    /// The board's heat notes: honest about what warms the phone.
    var heatNote: String? {
        switch (quality, fps) {
        case (.hd1080, 30): return nil
        case (.hd1080, _): return "Smoother slow motion. Warms the phone sooner."
        case (.uhd4k, 30): return "Sharper zoom in the player. Warms the phone sooner."
        default: return "Likely to overheat in a long match. Best for short drills."
        }
    }

    /// The shown picture's width / height on the portrait preview (16:9 mapped portrait ⇒ 9:16).
    var portraitAspect: CGFloat { CGFloat(height) / CGFloat(width) }
}

/// One `AVCaptureDevice.Format`, as the edge describes it.
struct RacketDeviceFormatInfo: Equatable, Sendable {
    var width: Int32
    var height: Int32
    var maxFps: Double
    /// 10-bit (HDR) pixel format. The 8-bit one is preferred: plain SDR video every app plays the same.
    var isTenBit: Bool = false
}

enum RacketCameraFormats {
    /// The qualities a device records, in the page's order: a format of that size whose frame rate reaches it.
    static func supported(_ formats: [RacketDeviceFormatInfo]) -> [RacketCameraFormat] {
        RacketCameraFormat.all.filter { f in pick(f, from: formats) != nil }
    }

    /// The device format to use for `target`: that exact size, reaching the frame rate; 8-bit before 10-bit; then the
    /// lowest top frame rate that reaches it (a 240 fps slow-motion format is a worse fit for 30 fps than a 30 fps one).
    static func pick(_ target: RacketCameraFormat, from formats: [RacketDeviceFormatInfo]) -> Int? {
        let fits = formats.indices.filter { i in
            let f = formats[i]
            return f.width == target.width && f.height == target.height && f.maxFps + 0.5 >= Double(target.fps)
        }
        return fits.min { a, b in
            let fa = formats[a], fb = formats[b]
            if fa.isTenBit != fb.isTenBit { return !fa.isTenBit }
            if fa.maxFps != fb.maxFps { return fa.maxFps < fb.maxFps }
            return a < b
        }
    }

    /// `wanted` if the camera records it, else the same resolution at 30, else HD · 30, else whatever it has.
    static func fallback(_ wanted: RacketCameraFormat, supported: [RacketCameraFormat]) -> RacketCameraFormat {
        if supported.contains(wanted) { return wanted }
        let same = RacketCameraFormat(quality: wanted.quality, fps: 30)
        if supported.contains(same) { return same }
        if supported.contains(.hd30) { return .hd30 }
        return supported.first ?? .hd30
    }
}

/// Time and size per quality for this phone's free space (ProCameraQuality), from the same bitrate table the storage
/// check uses (Apple's published Camera sizes, prompt 244). Once recording, the measured rate takes over.
struct RacketQualityEstimate: Equatable, Sendable {
    let roomSec: TimeInterval
    let gigabytesPerHour: Double

    init(format: RacketCameraFormat, freeBytes: Int64, codec: RacketVideoCodec = .hevc) {
        let rate = RacketBitrate.bytesPerSecond(format.config(codec: codec))
        roomSec = RacketStorageCheck.roomSec(freeBytes: freeBytes, bytesPerSec: rate)
        gigabytesPerHour = rate * 3600 / 1e9
    }

    /// "11 h 50 min · 3.7 GB/h".
    var line: String {
        "\(RacketStorageCheck.roughDuration(roomSec)) · \(String(format: "%.1f", gigabytesPerHour)) GB/h"
    }

    /// "Based on 45 GB free. The estimate tightens once recording has run for a minute."
    static func footnote(freeBytes: Int64) -> String {
        "Based on \(RacketStorageCheck.gigabytes(freeBytes)) free. The estimate tightens once recording has run for a minute."
    }
}

// MARK: - The status pill ("● Ready · 34 h · 82%")

enum RacketCameraStatus {
    enum Tone: Equatable, Sendable { case ready, low, full }

    struct Pill: Equatable, Sendable {
        let tone: Tone
        /// Without the dot: "Ready · 34 h · 82%".
        let text: String
    }

    /// Readiness from the room at the current quality (Ready; Low space under 2 h; No space under 15 min — the
    /// storage check's thresholds), the room itself, and the battery when the phone reports one.
    static func pill(roomSec: TimeInterval, batteryPercent: Int?) -> Pill {
        let tone: Tone = roomSec < RacketStorageCheck.minimumSec ? .full
            : roomSec < RacketStorageCheck.comfortableSec ? .low : .ready
        let word: String
        switch tone {
        case .ready: word = "Ready"
        case .low: word = "Low space"
        case .full: word = "No space"
        }
        var parts = [word, room(roomSec)]
        if let b = batteryPercent { parts.append("\(max(0, min(100, b)))%") }
        return Pill(tone: tone, text: parts.joined(separator: " · "))
    }

    /// "34 h" (whole hours, rounded down) from an hour up; "40 min" below.
    static func room(_ sec: TimeInterval) -> String {
        let minutes = Int(max(0, sec) / 60)
        return minutes >= 60 ? "\(minutes / 60) h" : "\(minutes) min"
    }
}

// MARK: - Lenses and zoom (ProCamera, ProCameraZoom)

/// What the edge found about the back camera, in the device's own zoom units (`AVCaptureDevice.videoZoomFactor`).
struct RacketCameraDeviceInfo: Equatable, Sendable {
    /// A virtual device with an ultra-wide constituent (its zoom factor 1 is the ultra-wide).
    var hasUltraWide: Bool
    /// `virtualDeviceSwitchOverVideoZoomFactors`: where the virtual device moves to its next lens.
    var switchOverFactors: [Double]
    /// `activeFormat.secondaryNativeResolutionZoomFactors`: zooms the sensor crops natively (a 48 MP main camera's 2×),
    /// so they look as good as a lens.
    var cropFactors: [Double] = []
    var minZoom: Double
    var maxZoom: Double
    var formats: [RacketDeviceFormatInfo]
}

/// The lens buttons, the zoom range and the qualities, in display units (1 = the wide camera, as the Camera app counts).
struct RacketCameraCapabilities: Equatable, Sendable {
    /// The device zoom factor shown as "1×".
    var wideFactor: Double
    /// Lens buttons in display units: 0.5 only with an ultra-wide; 2 only for a native crop or a 2× telephoto;
    /// a telephoto's own factor (3, 5) only when the phone has one.
    var lenses: [Double]
    var minZoom: Double
    var maxZoom: Double
    var formats: [RacketCameraFormat]

    /// Digital zoom past the longest lens is capped at 3× of it (the Camera app's video limit on these phones, e.g. 9×
    /// on a 3× telephoto): beyond that the picture is too soft to find a ball in.
    static let digitalReach: Double = 3

    init(wideFactor: Double, lenses: [Double], minZoom: Double, maxZoom: Double, formats: [RacketCameraFormat]) {
        self.wideFactor = wideFactor
        self.lenses = lenses
        self.minZoom = minZoom
        self.maxZoom = maxZoom
        self.formats = formats
    }

    init(device d: RacketCameraDeviceInfo) {
        let wide = d.hasUltraWide ? max(1, d.switchOverFactors.first ?? 2) : 1
        wideFactor = wide
        func display(_ device: Double) -> Double { (device / wide * 10).rounded() / 10 }
        var lenses: [Double] = []
        if d.hasUltraWide { lenses.append(display(max(d.minZoom, 1))) }
        lenses.append(1)
        // Telephotos: the switch-overs after the wide one.
        let teles = (d.hasUltraWide ? Array(d.switchOverFactors.dropFirst()) : d.switchOverFactors)
            .map(display).filter { $0 > 1.05 }
        let firstTele = teles.first ?? .infinity
        // A native crop between the wide and the first telephoto.
        for c in d.cropFactors.map(display) where c > 1.05 && c < firstTele - 0.05 && !lenses.contains(c) {
            lenses.append(c)
        }
        for t in teles where !lenses.contains(t) { lenses.append(t) }
        lenses.sort()
        self.lenses = lenses
        minZoom = min(1, display(max(d.minZoom, 1)))
        let deviceMax = d.maxZoom / wide
        maxZoom = max(1, min(deviceMax, (lenses.last ?? 1) * Self.digitalReach))
        formats = RacketCameraFormats.supported(d.formats)
    }

    func deviceZoom(_ display: Double) -> Double { display * wideFactor }
    func displayZoom(_ device: Double) -> Double { device / wideFactor }

    /// A phone with an ultra-wide, a 3× telephoto and all four qualities (iPhone 13 Pro class): the fake camera's default.
    static let sample = RacketCameraCapabilities(wideFactor: 2, lenses: [0.5, 1, 3], minZoom: 0.5, maxZoom: 9,
                                                 formats: RacketCameraFormat.all)

    /// A fake capability set from `-uiTestCameraLenses "0.5,1,2,3"` / `-uiTestCameraFormats "hd1080-30,uhd4k-30"`.
    static func fake(lenses: String?, formats: String?) -> RacketCameraCapabilities {
        var c = sample
        if let lenses {
            let l = lenses.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }.sorted()
            if !l.isEmpty {
                c.lenses = l
                c.minZoom = min(1, l.first!)
                c.wideFactor = l.first! < 1 ? 1 / l.first! : 1
                c.maxZoom = (l.last ?? 1) * digitalReach
            }
        }
        if let formats {
            let keys = Set(formats.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
            let f = RacketCameraFormat.all.filter { keys.contains($0.key) }
            if !f.isEmpty { c.formats = f }
        }
        return c
    }
}

/// The zoom dial (a logarithmic ruler, like the Camera app's: each doubling takes the same width), lens buttons and
/// gestures — all in display units, all clamped to what the phone does.
enum RacketZoomDial {
    static func clamp(_ z: Double, _ c: RacketCameraCapabilities) -> Double {
        guard z.isFinite else { return 1 }
        return min(c.maxZoom, max(c.minZoom, z))
    }

    /// 0…1 across the dial.
    static func position(of z: Double, _ c: RacketCameraCapabilities) -> Double {
        guard c.maxZoom > c.minZoom else { return 0 }
        return log(clamp(z, c) / c.minZoom) / log(c.maxZoom / c.minZoom)
    }

    /// The zoom at a dial position (0…1, clamped).
    static func zoom(atPosition p: Double, _ c: RacketCameraCapabilities) -> Double {
        let q = min(1, max(0, p.isFinite ? p : 0))
        return c.minZoom * pow(c.maxZoom / c.minZoom, q)
    }

    /// A drag across the lens buttons: right zooms in (the dial's numbers grow to the right), `pointsPerDoubling` per
    /// doubling.
    static func dragged(from z0: Double, dx: Double, pointsPerDoubling: Double = 110, _ c: RacketCameraCapabilities) -> Double {
        clamp(z0 * pow(2, dx / pointsPerDoubling), c)
    }

    /// A pinch on the preview.
    static func pinched(from z0: Double, scale: Double, _ c: RacketCameraCapabilities) -> Double {
        clamp(z0 * (scale > 0 && scale.isFinite ? scale : 1), c)
    }

    /// VoiceOver's adjustable zoom: the next / previous lens when it is close, else a quarter step.
    static func stepped(_ z: Double, up: Bool, _ c: RacketCameraCapabilities) -> Double {
        let step = clamp(up ? z * 1.25 : z / 1.25, c)
        if up, let next = c.lenses.first(where: { $0 > z + 0.01 }), next < step { return next }
        if !up, let prev = c.lenses.last(where: { $0 < z - 0.01 }), prev > step { return prev }
        return step
    }

    /// The button that shows the current zoom: the longest lens at or below it.
    static func selectedLens(for z: Double, _ c: RacketCameraCapabilities) -> Int {
        c.lenses.lastIndex(where: { $0 <= z + 0.04 }) ?? 0
    }

    /// "1×", "1.4×", "0.5×".
    static func label(_ z: Double) -> String { "\(number(z))×" }

    /// "0.5", "1", "1.4": one decimal, a whole number without it.
    static func number(_ z: Double) -> String {
        let r = (z * 10).rounded() / 10
        return r == r.rounded() ? "\(Int(r))" : String(format: "%.1f", r)
    }

    /// A lens button's text: the selected one shows the current zoom with "×" ("1.4×"); the others their bare factor.
    static func buttonText(lens: Double, selected: Bool, zoom: Double) -> String {
        selected ? label(zoom) : number(lens)
    }

    /// The dial's ticks: `count` evenly spaced minor ticks, and a major tick labelled at each lens.
    struct Tick: Equatable, Sendable {
        let position: Double
        let label: String?
    }

    static func ticks(_ c: RacketCameraCapabilities, minor count: Int = 24) -> [Tick] {
        let majors = c.lenses.map { Tick(position: position(of: $0, c), label: number($0)) }
        let minors = (0...max(1, count)).map { Tick(position: Double($0) / Double(max(1, count)), label: nil) }
            .filter { m in !majors.contains { abs($0.position - m.position) < 0.02 } }
        return (majors + minors).sorted { $0.position < $1.position }
    }
}

// MARK: - Focus and exposure (ProCameraFocus, ProCameraLock)

enum RacketFocusPoint {
    /// A tap on the portrait preview → the camera's point of interest (0…1 in the sensor's landscape frame, top-left
    /// origin, as `AVCaptureDevice.focusPointOfInterest` wants). The preview is letterboxed (`videoAspect` = the shown
    /// picture's width / height) and turned 90° to portrait, so a picture point (u, v) is the sensor point (v, 1 − u).
    /// A tap on the black bars clamps to the picture's edge.
    static func devicePoint(tap: CGPoint, in box: CGSize, videoAspect: CGFloat?) -> CGPoint {
        let r = RacketVideoOrientation.aspectFit(aspect: videoAspect, in: box)
        guard r.width > 0, r.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        let u = min(1, max(0, (tap.x - r.minX) / r.width))
        let v = min(1, max(0, (tap.y - r.minY) / r.height))
        return CGPoint(x: v, y: 1 - u)
    }

    /// The inverse: where a point of interest sits on the preview (to redraw the square after a carry-over).
    static func viewPoint(device p: CGPoint, in box: CGSize, videoAspect: CGFloat?) -> CGPoint {
        let r = RacketVideoOrientation.aspectFit(aspect: videoAspect, in: box)
        return CGPoint(x: r.minX + (1 - p.y) * r.width, y: r.minY + p.x * r.height)
    }
}

/// The sun slider beside the focus square: exposure bias in EV.
enum RacketExposureBias {
    /// The slider's reach (the device's own range is wider; past ±2 EV the court washes out or goes black).
    static let range: ClosedRange<Double> = -2...2
    /// Dragging this many points moves one EV; up brightens.
    static let pointsPerEV: Double = 45

    static func clamp(_ b: Double, deviceMin: Double = -8, deviceMax: Double = 8) -> Double {
        min(min(range.upperBound, deviceMax), max(max(range.lowerBound, deviceMin), b))
    }

    static func dragged(from b0: Double, dy: Double) -> Double { clamp(b0 - dy / pointsPerEV) }

    static func stepped(_ b: Double, up: Bool) -> Double { clamp(((b + (up ? 0.3 : -0.3)) * 10).rounded() / 10) }

    /// The knob's offset from the slider's centre (negative = up), for a slider `length` points long.
    static func knobOffset(_ b: Double, length: Double) -> Double {
        -clamp(b) / (range.upperBound - range.lowerBound) * length
    }

    /// "+0.3", "0", "−1.0" (VoiceOver and the readout).
    static func label(_ b: Double) -> String {
        let r = (b * 10).rounded() / 10
        if r == 0 { return "0" }
        return (r > 0 ? "+" : "−") + String(format: "%.1f", abs(r))
    }
}

// MARK: - Framing (ProCameraOptions: Grid, Level, Court guide)

enum RacketLevel {
    /// Within this many degrees the level line turns green.
    static let thresholdDegrees: Double = 1

    /// The tilt of the picture's horizon, in degrees, from gravity in the device's frame (x right, y up in portrait,
    /// z out of the screen): 0 when the phone stands square, upright or on its side (the nearest quarter turn), signed
    /// so turning the line by `-tilt` keeps it on the real horizon. `nil` when the phone lies nearly flat (no horizon).
    static func tilt(gx: Double, gy: Double, gz: Double) -> Double? {
        guard abs(gz) < 0.85, gx * gx + gy * gy > 0.01 else { return nil }
        let roll = atan2(gx, -gy) * 180 / .pi
        return roll - (roll / 90).rounded() * 90
    }

    static func isLevel(_ tilt: Double?) -> Bool { tilt.map { abs($0) < thresholdDegrees } ?? false }
}

/// The three framing overlays. Drawn over the preview only: nothing is ever recorded into the video.
struct RacketFraming: Codable, Equatable, Sendable {
    var grid = true
    var level = true
    var courtGuide = false

    static let storageKey = "racket.camera.framing"

    static func load(_ data: Data?) -> RacketFraming {
        data.flatMap { try? JSONDecoder().decode(RacketFraming.self, from: $0) } ?? RacketFraming()
    }
    var encoded: Data { (try? JSONEncoder().encode(self)) ?? Data() }
}

// MARK: - Looks on the live picture (ProCameraLooks)

/// How the live preview shows a look. The preview layer can't run Core Image, so the look is approximated with the
/// compositor's colour effects (saturation, contrast, brightness, a colour multiply for warm / cool) from the same
/// `RacketLook.Params` the playback filter uses. Preview only: the recorded file is never filtered; playback applies
/// the exact Core Image look.
struct RacketLookPreview: Equatable, Sendable {
    var saturation: Double = 1
    var contrast: Double = 1
    var brightness: Double = 0
    /// Multiply per channel (1, 1, 1 = none).
    var red: Double = 1
    var green: Double = 1
    var blue: Double = 1

    static let none = RacketLookPreview()

    init() {}

    init(_ look: RacketLook) {
        let p = look.params
        saturation = p.saturation
        contrast = p.contrast
        brightness = p.brightness
        if p.temperature < 6500 {
            let k = min(1.5, (6500 - p.temperature) / 1900)
            green = 1 - 0.06 * k
            blue = 1 - 0.2 * k
        } else if p.temperature > 6500 {
            let k = min(1.5, (p.temperature - 6500) / 2300)
            red = 1 - 0.15 * k
            green = 1 - 0.05 * k
        }
    }
}

// MARK: - The mode strip and what carries into the recording

enum RacketCameraModeStrip {
    /// "GAME BY GAME" / "SET BY SET" / "EVERYTHING" — the match's two recording modes.
    static func label(_ mode: RacketRecordingMode, unit: RacketUnit) -> String {
        switch mode {
        case .byUnit: return unit == .set ? "SET BY SET" : "GAME BY GAME"
        case .everything: return "EVERYTHING"
        case .off: return "DON’T FILM"
        }
    }
}

/// What the camera was set to when the shutter was tapped, carried into the recording (game by game keeps the same
/// camera; record everything opens a new screen whose camera applies this before its first frame).
struct RacketCameraSetup: Equatable, Sendable {
    var format: RacketCameraFormat = .hd30
    /// Display units (1 = wide).
    var zoom: Double = 1
    /// The focus / exposure point of interest; nil = continuous auto at the centre.
    var focusPoint: CGPoint?
    /// AE/AF lock at `focusPoint`.
    var locked = false
    var exposureBias: Double = 0
    /// The look picked on the camera: the match's playback look ("Whole match"), never baked into the file.
    var look: RacketLook = .original

    /// The storage check can change the resolution; a different resolution starts at 30 fps.
    func with(quality: RacketRecordingQuality) -> RacketCameraSetup {
        var s = self
        if quality != format.quality { s.format = RacketCameraFormat(quality: quality, fps: 30) }
        return s
    }
}

extension RacketRecordingDefaults {
    /// "Use for every match": the quality the camera opens on.
    var cameraFormat: RacketCameraFormat { RacketCameraFormat(quality: quality, fps: fps == 60 ? 60 : 30) }
}
