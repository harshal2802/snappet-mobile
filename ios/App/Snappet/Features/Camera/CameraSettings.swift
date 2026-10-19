import Foundation

/// **Pure model of the in-app camera** (prompt 190, `docs/ux-research/in-app-camera/wireframes.html`): what the
/// user picked (mode, resolution · frame rate, slo-mo speed, stabilization, countdown, grid, …), what THIS phone's
/// camera can do (`CameraCapabilities`, read from the device by `CameraController`), and the rules between them —
/// clamping a pick the phone can't do, cycling the "4K · 30" chip like the iPhone Camera, lens labels, the timer.
/// Foundation only, so it's unit-tested without a camera.

enum CameraMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case slomo, video, photo
    var id: String { rawValue }
    var label: String {
        switch self {
        case .slomo: return "SLO-MO"
        case .video: return "VIDEO"
        case .photo: return "PHOTO"
        }
    }
    var recordsVideo: Bool { self != .photo }
}

enum CameraResolution: String, Codable, CaseIterable, Sendable {
    case hd, uhd
    var label: String { self == .hd ? "HD" : "4K" }
    var width: Int { self == .hd ? 1920 : 3840 }
    var height: Int { self == .hd ? 1080 : 2160 }
}

enum CameraStabilization: String, Codable, CaseIterable, Sendable {
    case standard, enhanced
    var label: String { self == .standard ? "Standard" : "Enhanced" }
}

struct CameraSettings: Codable, Equatable, Sendable {
    var mode: CameraMode = .video
    var resolution: CameraResolution = .hd
    var fps: Int = 30
    var slomoFPS: Int = 240
    var stabilization: CameraStabilization = .standard
    /// Seconds before a video starts (hands-free); 0 = off.
    var countdown: Int = 0
    var grid: Bool = false
    /// End the clip when the set / attempt is logged (prompt 191).
    var stopOnLog: Bool = true
    /// Open next time with these settings (else the defaults above).
    var remember: Bool = true

    static let storageKey = "camera.settings"
    static let countdownChoices = [0, 3, 10]
    static let fpsChoices = [24, 30, 60]

    /// What the camera opens with: the remembered settings when "Remember my settings" was on, else defaults.
    static func load(from raw: Data?) -> CameraSettings {
        guard let raw, let saved = try? JSONDecoder().decode(CameraSettings.self, from: raw), saved.remember else {
            return CameraSettings()
        }
        return saved
    }

    /// What to store: everything when remembering, else just the "don't remember" choice itself.
    func encodedForStorage() -> Data? {
        try? JSONEncoder().encode(remember ? self : CameraSettings(remember: false))
    }
}

/// What this phone's camera can do — read from the active device's formats and lenses.
struct CameraCapabilities: Equatable, Sendable {
    struct Combo: Hashable, Sendable {
        let resolution: CameraResolution
        let fps: Int
    }

    /// Supported video resolution · frame-rate pairs.
    var video: Set<Combo>
    /// Slo-mo frame rates available (1080p), ascending.
    var slomo: [Int]
    /// Lens buttons in display zoom (0.5 = ultra-wide, 1 = wide, 3 = telephoto), ascending.
    var lenses: [Double]
    var minZoom: Double
    var maxZoom: Double
    var hasTorch: Bool
    var hasFront: Bool
    /// The format can do the enhanced (cinematic-extended / cinematic) stabilization.
    var enhancedStabilization: Bool

    /// The simulator / UI-test stand-in: an iPhone 13 Pro-class camera (`-uiTestFakeCamera`).
    static let sample = CameraCapabilities(
        video: [.init(resolution: .hd, fps: 24), .init(resolution: .hd, fps: 30), .init(resolution: .hd, fps: 60),
                .init(resolution: .uhd, fps: 24), .init(resolution: .uhd, fps: 30), .init(resolution: .uhd, fps: 60)],
        slomo: [120, 240], lenses: [0.5, 1, 3], minZoom: 0.5, maxZoom: 15, hasTorch: true, hasFront: true,
        enhancedStabilization: true)

    /// A device format as plain values, for building capabilities in a test.
    struct Format: Sendable {
        let width: Int
        let height: Int
        let maxFPS: Double
    }

    /// Capabilities from a device's formats + lens switch-over points (display zoom). Pure, so the rules are tested.
    static func from(formats: [Format], lenses: [Double], minZoom: Double, maxZoom: Double, hasTorch: Bool,
                     hasFront: Bool, enhancedStabilization: Bool) -> CameraCapabilities {
        var video = Set<Combo>()
        var slomo = Set<Int>()
        for f in formats {
            for res in CameraResolution.allCases where f.width == res.width && f.height == res.height {
                for fps in CameraSettings.fpsChoices where f.maxFPS + 0.5 >= Double(fps) {
                    video.insert(.init(resolution: res, fps: fps))
                }
                if res == .hd {
                    for rate in [120, 240] where f.maxFPS + 0.5 >= Double(rate) { slomo.insert(rate) }
                }
            }
        }
        return CameraCapabilities(video: video, slomo: slomo.sorted(), lenses: lenses.sorted(), minZoom: minZoom,
                                  maxZoom: maxZoom, hasTorch: hasTorch, hasFront: hasFront,
                                  enhancedStabilization: enhancedStabilization)
    }
}

enum CameraLogic {

    /// The settings the phone can actually do: an unsupported resolution · fps falls back to the nearest the phone
    /// has (same resolution first), slo-mo to its fastest, enhanced stabilization to standard; photo mode needs none.
    static func resolve(_ s: CameraSettings, _ caps: CameraCapabilities) -> CameraSettings {
        var out = s
        if !caps.video.contains(.init(resolution: s.resolution, fps: s.fps)) {
            let sameRes = caps.video.filter { $0.resolution == s.resolution }.map(\.fps)
            if let fps = sameRes.min(by: { abs($0 - s.fps) < abs($1 - s.fps) }) {
                out.fps = fps
            } else if let any = caps.video.min(by: { abs($0.fps - s.fps) < abs($1.fps - s.fps) }) {
                out.resolution = any.resolution
                out.fps = any.fps
            }
        }
        if !caps.slomo.contains(s.slomoFPS), let best = caps.slomo.last { out.slomoFPS = best }
        if s.mode == .slomo && caps.slomo.isEmpty { out.mode = .video }
        if !caps.enhancedStabilization { out.stabilization = .standard }
        if !CameraSettings.countdownChoices.contains(s.countdown) { out.countdown = 0 }
        return out
    }

    /// Tap the resolution half of the chip: HD ↔ 4K (keeping the frame rate when the phone can).
    static func toggleResolution(_ s: CameraSettings, _ caps: CameraCapabilities) -> CameraSettings {
        var out = s
        out.resolution = s.resolution == .hd ? .uhd : .hd
        return resolve(out, caps)
    }

    /// Tap the frame-rate half: video cycles 24 → 30 → 60 among what this resolution supports; slo-mo 120 ↔ 240.
    static func cycleFPS(_ s: CameraSettings, _ caps: CameraCapabilities) -> CameraSettings {
        var out = s
        if s.mode == .slomo {
            guard let i = caps.slomo.firstIndex(of: s.slomoFPS), !caps.slomo.isEmpty else { return s }
            out.slomoFPS = caps.slomo[(i + 1) % caps.slomo.count]
            return out
        }
        let options = CameraSettings.fpsChoices.filter { caps.video.contains(.init(resolution: s.resolution, fps: $0)) }
        guard let i = options.firstIndex(of: s.fps), !options.isEmpty else { return resolve(s, caps) }
        out.fps = options[(i + 1) % options.count]
        return out
    }

    /// The two halves of the top chip ("4K", "30"), or `nil` in photo mode.
    static func chip(_ s: CameraSettings) -> (resolution: String, fps: String)? {
        switch s.mode {
        case .photo: return nil
        case .slomo: return ("HD", "\(s.slomoFPS)")
        case .video: return (s.resolution.label, "\(s.fps)")
        }
    }

    /// The next countdown (off → 3 s → 10 s → off).
    static func nextCountdown(_ seconds: Int) -> Int {
        let c = CameraSettings.countdownChoices
        return c[((c.firstIndex(of: seconds) ?? 0) + 1) % c.count]
    }

    /// A lens button's label: ".5", "1×", "3" — and, while the zoom sits near it, the live zoom ("1.8×").
    static func lensLabel(_ lens: Double, selected: Bool, zoom: Double) -> String {
        if selected {
            let z = (zoom * 10).rounded() / 10
            return z == z.rounded() ? "\(Int(z))×" : String(format: "%.1f×", z)
        }
        if lens < 1 { return "." + String(format: "%.0f", lens * 10) }
        return lens == lens.rounded() ? "\(Int(lens))" : String(format: "%.1f", lens)
    }

    /// The lens a zoom level is "on": the largest lens at or below it (so 1.8× lights 1×, 3.4× lights 3).
    static func activeLens(zoom: Double, lenses: [Double]) -> Double? {
        lenses.filter { $0 <= zoom + 0.001 }.max() ?? lenses.first
    }

    static func clampZoom(_ zoom: Double, _ caps: CameraCapabilities) -> Double {
        min(max(zoom, caps.minZoom), caps.maxZoom)
    }

    /// The recording timer, "00:00:14".
    static func timer(_ seconds: TimeInterval) -> String {
        let t = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60)
    }
}

/// What the camera is filming for (prompt 191) — the set / attempt its clips will be tagged to, how to stop-and-log
/// it from the camera, and how many sets are logged so far (a set logged elsewhere — the watch — stops the clip when
/// "Stop when I log the set" is on).
struct CameraContext: Equatable {
    /// "Bench Press".
    var title: String
    /// "set 3", "attempt 2", "next set".
    var detail: String?
    /// The in-camera "Stop & log set" / "Stop attempt" — `nil` where logging isn't one tap (an exercise page).
    var logLabel: String?
    /// Sets logged on the target so far; `nil` when the host can't observe it.
    var loggedCount: Int?

    var label: String { [title, detail].compactMap { $0 }.joined(separator: " · ") }
}
