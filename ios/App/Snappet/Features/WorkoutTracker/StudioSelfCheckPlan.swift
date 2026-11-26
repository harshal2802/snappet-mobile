#if DEBUG
import Foundation

/// The decisions of the Studio render check (prompt 304): which tolerance a comparison gets, what
/// a scene's frames add up to, and the text of the report. The golden-frame unit tests and the
/// debug screen both use them, so the two cannot disagree about what "pass" means. Foundation only.
enum StudioSelfCheck {

    /// How a frame was made.
    enum RenderPath: String, CaseIterable, Sendable {
        /// Written to a file by the export session and read back from the file.
        case export
        /// Drawn by the compositor for the preview's video composition, with no file in between.
        case preview

        var label: String { self == .export ? "Export" : "Preview" }
    }

    /// Where the frame was rendered. The golden images are recorded on the simulator.
    enum Machine: String, Sendable {
        case simulator, device
        var label: String { self == .simulator ? "Simulator" : "Device" }
    }

    /// The tolerance for one comparison. Measured values and the reasons are in
    /// `pdd/context/decisions.md` (2026-11-25, prompt 304).
    ///
    /// - Simulator, export: the golden images were made this way. Two runs on one Mac gave the
    ///   same bytes, so this only leaves room for another Mac's encoder. A region's mean colour
    ///   may be 3 levels off: a filter at 0.7 for 1 moves it by 4, a dropped filter by 9 or more,
    ///   an opacity a tenth off by 8, a dissolve a tenth off by 17.
    /// - Simulator, preview: the same frame without the export's H.264 pass. Measured against the
    ///   export frames over every scene: brightness up to 25 apart on single pixels, averaged
    ///   colour up to 18, a region's mean colour up to 4.2 (where a colour edge crosses it).
    /// - Device: another encoder and decoder made the source files and the export, and another
    ///   GPU drew the frames. NOT MEASURED: these are a first guess, loose enough to pass a
    ///   frame that is a pixel off. The report lists each scene's largest differences so the
    ///   first run on a phone can set real numbers; tighten these then.
    static func tolerance(for path: RenderPath, on machine: Machine) -> StudioGoldenTolerance {
        switch (machine, path) {
        case (.simulator, .export):
            return StudioGoldenTolerance(luma: 10, chroma: 8, maxFraction: 0.002, maxCellFraction: 0.06, mean: 3)
        case (.simulator, .preview):
            return StudioGoldenTolerance(luma: 24, chroma: 22, maxFraction: 0.005, maxCellFraction: 0.10, mean: 6)
        case (.device, .export):
            return StudioGoldenTolerance(luma: 28, chroma: 24, maxFraction: 0.01, maxCellFraction: 0.15, mean: 8)
        case (.device, .preview):
            return StudioGoldenTolerance(luma: 32, chroma: 26, maxFraction: 0.015, maxCellFraction: 0.20, mean: 10)
        }
    }

    // MARK: Results

    /// One frame of one scene, compared (or not) with its golden image.
    struct FrameCheck: Identifiable, Sendable {
        enum Outcome: Equatable, Sendable {
            case compared(StudioGoldenCompare.Result)
            /// No golden image with this name is in the app.
            case missingGolden
        }
        let frame: Int
        let path: RenderPath
        let goldenName: String
        let outcome: Outcome
        /// PNG data for the screen: the rendered frame, and where it differs.
        var actualPNG: Data?
        var diffPNG: Data?

        var id: String { "\(path.rawValue)-\(frame)" }
        var passed: Bool {
            if case .compared(let result) = outcome { return result.passed }
            return false
        }
        var line: String {
            let what: String
            switch outcome {
            case .compared(let result): what = (result.passed ? "pass — " : "FAIL — ") + result.summary
            case .missingGolden: what = "FAIL — no golden image \(goldenName)"
            }
            return "frame \(frame) (\(path.rawValue)): \(what)"
        }
    }

    enum Status: Equatable, Sendable {
        case passed
        case failed(String)
        case skipped(String)

        /// The word the screen and the report show, and the UI test reads.
        var word: String {
            switch self {
            case .passed: return "pass"
            case .failed: return "fail"
            case .skipped: return "skipped"
            }
        }
    }

    struct SceneResult: Identifiable, Sendable {
        let id: String
        let title: String
        let status: Status
        var frames: [FrameCheck] = []
        /// How long the scene took to render and compare.
        var seconds: Double = 0

        /// The largest differences over the scene's frames on one path; `nil` when no frame of
        /// that path was compared.
        func worst(_ path: RenderPath) -> Worst? {
            var worst = Worst()
            var any = false
            for check in frames where check.path == path {
                guard case .compared(let result) = check.outcome, result.sizeMatches else { continue }
                any = true
                worst.luma = max(worst.luma, result.maxLuma)
                worst.chroma = max(worst.chroma, result.maxChroma)
                worst.fraction = max(worst.fraction, result.fraction)
                worst.cellFraction = max(worst.cellFraction, result.cellFraction)
                worst.mean = max(worst.mean, result.maxMean)
            }
            return any ? worst : nil
        }
    }

    /// The largest value of each measure over a set of frames. These are what was measured,
    /// whatever the tolerance: the numbers a tolerance is set from.
    struct Worst: Equatable, Sendable {
        var luma = 0
        var chroma = 0
        /// The share of the frame over the tolerance's brightness or colour limit.
        var fraction = 0.0
        var cellFraction = 0.0
        var mean = 0.0

        var line: String {
            "brightness \(luma), colour \(chroma), frame \(StudioGoldenCompare.Result.percent(fraction)), "
                + "one region \(StudioGoldenCompare.Result.percent(cellFraction)), "
                + "region mean \(StudioGoldenCompare.Result.decimal(mean))"
        }
    }

    /// What a scene's frames add up to. A render error fails the scene. A scene with no frames
    /// did not check anything, so it fails too. Otherwise every frame on every path must pass.
    static func status(frames: [FrameCheck], expectedFrames: Int, error: String? = nil) -> Status {
        if let error { return .failed(error) }
        guard !frames.isEmpty else { return .failed("no frame was rendered") }
        let failing = frames.filter { !$0.passed }
        if let first = failing.first {
            return .failed(failing.count == 1 ? first.line : "\(failing.count) frames differ; first: \(first.line)")
        }
        let wanted = expectedFrames * RenderPath.allCases.count
        guard frames.count == wanted else {
            return .failed("\(frames.count) of \(wanted) frames were checked")
        }
        return .passed
    }

    /// The result of a placeholder scene.
    static func skipped(_ scene: StudioGoldenScene) -> SceneResult {
        SceneResult(id: scene.id, title: scene.title, status: .skipped(scene.pendingReason ?? "not rendered"))
    }

    struct Summary: Equatable, Sendable {
        let passed: Int, failed: Int, skipped: Int

        /// True when something was checked and nothing failed.
        var allPassed: Bool { failed == 0 && passed > 0 }
        var line: String {
            var parts = ["\(passed) passed", "\(failed) failed"]
            if skipped > 0 { parts.append("\(skipped) skipped") }
            return parts.joined(separator: ", ")
        }
    }

    static func summary(_ results: [SceneResult]) -> Summary {
        var passed = 0, failed = 0, skipped = 0
        for result in results {
            switch result.status {
            case .passed: passed += 1
            case .failed: failed += 1
            case .skipped: skipped += 1
            }
        }
        return Summary(passed: passed, failed: failed, skipped: skipped)
    }

    // MARK: The timed export

    struct Timing: Equatable, Sendable {
        /// The exported video's length and size.
        var outputSeconds: Double
        var width: Int
        var height: Int
        /// Wall-clock time of the export session alone.
        var exportSeconds: Double
        /// The app's memory just before the export, and the most it reached during it.
        var baselineBytes: UInt64
        var peakBytes: UInt64
        var fileBytes: UInt64

        /// Output seconds rendered per second of waiting.
        var speed: Double { exportSeconds > 0 ? outputSeconds / exportSeconds : 0 }
        var addedBytes: UInt64 { peakBytes > baselineBytes ? peakBytes - baselineBytes : 0 }

        var lines: [String] {
            ["\(format(outputSeconds, 1)) s at \(width)×\(height) exported in \(format(exportSeconds, 2)) s "
                + "(\(format(speed, 1))× real time)",
             "Peak memory \(megabytes(peakBytes)) MB (\(megabytes(addedBytes)) MB above the \(megabytes(baselineBytes)) MB before the export)",
             "File \(megabytes(fileBytes)) MB"]
        }
    }

    static func megabytes(_ bytes: UInt64) -> String { format(Double(bytes) / 1_048_576, 1) }

    static func format(_ value: Double, _ digits: Int) -> String {
        String(format: "%.\(digits)f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    // MARK: Report

    /// The plain-text report behind "Copy report". `header` is whatever identifies the run (the
    /// device, the system version, the build); it is passed in so this stays a pure function.
    static func report(header: [String], machine: Machine, results: [SceneResult],
                       timing: Timing?, timingError: String? = nil) -> String {
        var lines = ["Snappet Studio render check"]
        lines += header
        let summary = summary(results)
        lines.append("Result: \(summary.allPassed ? "PASS" : "FAIL") — \(summary.line)")
        for path in RenderPath.allCases {
            let t = tolerance(for: path, on: machine)
            lines.append("Tolerance, \(path.rawValue) on \(machine.rawValue): brightness \(t.luma), colour \(t.chroma), "
                + "frame \(StudioGoldenCompare.Result.percent(t.maxFraction)), "
                + "one region \(StudioGoldenCompare.Result.percent(t.maxCellFraction)), "
                + "region mean \(StudioGoldenCompare.Result.decimal(t.mean))")
        }
        if machine == .device {
            lines.append("The device tolerances are a first guess. Set them from the measured lines below.")
        }
        lines.append("")
        for result in results {
            switch result.status {
            case .passed:
                lines.append("pass     \(result.id) — \(result.frames.count) frames, \(format(result.seconds, 2)) s")
            case .skipped(let reason):
                lines.append("skipped  \(result.id) — \(reason)")
            case .failed(let reason):
                lines.append("FAIL     \(result.id) — \(reason)")
                for frame in result.frames where !frame.passed { lines.append("         \(frame.line)") }
            }
            // What was measured, pass or fail: the largest differences on each path.
            for path in RenderPath.allCases {
                if let worst = result.worst(path) {
                    lines.append("         measured, \(path.rawValue): \(worst.line)")
                }
            }
        }
        lines.append("")
        if let timing {
            lines.append("Timed export")
            lines += timing.lines
        } else if let timingError {
            lines.append("Timed export failed: \(timingError)")
        } else {
            lines.append("Timed export: not run")
        }
        return lines.joined(separator: "\n")
    }
}
#endif
