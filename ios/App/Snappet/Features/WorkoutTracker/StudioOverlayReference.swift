#if DEBUG
import Foundation
import CoreGraphics

/// The "before" pictures for what the compositor does not draw yet (prompt 304): text, stickers,
/// climb tags and the heart-rate tile. Today the Core Animation tool draws them, on export only.
/// Prompts 310 and 311 move them into the compositor, and the golden frames cannot guard that
/// move, because nothing draws them the old way once it is done. So the debug "Studio render
/// check" screen can render these fixed scenes on a phone through today's export and save the
/// frames; committed, they are what the compositor's own drawing is compared with (loosely: the
/// two renderers will not agree pixel for pixel).
///
/// This file only describes the scenes and the list of saved files. Foundation only.
enum StudioOverlayReference {

    /// The folder the frames are saved to, inside the temporary directory.
    static let folderName = "studio-overlay-reference"
    static let manifestName = "manifest.json"
    /// What drew the overlays in a capture made by this code.
    static let renderer = "AVVideoCompositionCoreAnimationTool (before prompt 305)"

    /// Committed frames that show a bug in the export they were captured from, not the look the
    /// compositor is to match (prompt 307). A comparison against the reference skips them.
    /// - `ref-sticker-f010.png`: the export burned each sticker as a solid black box (the phone
    ///   capture of 2026-11-26); prompt 308 fixes the export, and a new capture of that scene
    ///   replaces the frame.
    /// - `ref-hr-tile-transition-f021.png`: frame 21 is 0.7 s, exactly the handover between the
    ///   two clips' tiles, and both windows include that instant, so both tiles are drawn (darker
    ///   glass, two chart markers). One frame at most in a real export. The Core Animation path is
    ///   replaced by prompt 311, which must draw exactly one tile there; this frame stays wrong.
    static let knownWrongFrames: Set<String> = ["ref-sticker-f010.png", "ref-hr-tile-transition-f021.png"]

    /// The fixed scenes. Each is one or two clips of `StudioGoldenSource.overlayBase` (540×960,
    /// four strong colours and a moving white block), so every overlay sits over an edge
    /// between colours.
    static let scenes: [StudioGoldenScene] = {
        var scenes: [StudioGoldenScene] = []
        func base(_ order: Int = 0) -> TimelineClip { StudioGoldenScene.clip(.overlayBase, order) }

        // Plain bold text for the whole clip; an italic line on a yellow highlight, turned 10°
        // and at 80 %, from 0.3 s to 0.8 s. Frame 5 has one line, 15 both, 27 one again.
        scenes.append(StudioGoldenScene(
            id: "ref-text", title: "Text",
            clips: [base()],
            overlays: [
                OverlayItem(kind: .text, content: "REP PR", startSec: 0, endSec: 1,
                            position: CGPoint(x: 0.5, y: 0.3)),
                OverlayItem(kind: .text, content: "Second go", startSec: 0.3, endSec: 0.8,
                            position: CGPoint(x: 0.5, y: 0.6), rotationDegrees: 10, opacity: 0.8,
                            colorHex: "#000000", highlightHex: "#FFD60A", bold: false, italic: true)],
            frames: [5, 15, 27]))

        scenes.append(StudioGoldenScene(
            id: "ref-sticker", title: "Stickers",
            clips: [base()],
            overlays: [
                OverlayItem(kind: .sticker, content: "star.fill", startSec: 0, endSec: 1,
                            position: CGPoint(x: 0.3, y: 0.3)),
                OverlayItem(kind: .sticker, content: "flame.fill", startSec: 0, endSec: 1,
                            position: CGPoint(x: 0.7, y: 0.7), scale: 2, rotationDegrees: -20,
                            colorHex: "#FF9500")],
            frames: [10]))

        let tagged = base()
        scenes.append(StudioGoldenScene(
            id: "ref-climb-tag", title: "Climb tag",
            clips: [tagged],
            overlays: [
                OverlayItem(kind: .climbName, content: "Pinch Me · V5 · 40°", startSec: 0, endSec: 1,
                            position: CGPoint(x: 0.5, y: 0.85), clipID: tagged.id,
                            showsAttempt: true, attemptNumber: 2, highlightHex: "#000000")],
            frames: [10]))

        // The tile in the middle, over all four colours and the white block's path.
        scenes.append(StudioGoldenScene(
            id: "ref-hr-tile", title: "Heart-rate tile",
            clips: [base()],
            frames: [3, 15, 27],
            heartRateTile: tile))

        // Two clips and a dissolve: each clip's tile shows only over the stretch the clip owns.
        let first = base(0), second = base(1)
        scenes.append(StudioGoldenScene(
            id: "ref-hr-tile-transition", title: "Heart-rate tile across a transition",
            clips: [first, second],
            transitions: [StudioTransition(afterClipID: first.id, kind: .dissolve, durationSec: 0.6)],
            frames: [10, 21, 35],
            heartRateTile: tile))
        return scenes
    }()

    /// A glass hero tile with a heart-rate number and the chart.
    static let tile = ResolvedHRTile(
        templateRaw: HRTileTemplate.hero.rawValue, centerX: 0.5, centerY: 0.5, width: 0.62, height: 0.16,
        showChart: true, zoneColored: true, maxHR: 190, opacity: 1, window: nil,
        metrics: [ResolvedTileMetric(
            metricRaw: HROverlayMetric.bpm.rawValue,
            segments: [HROverlayValues.Segment(
                reading: HROverlayValues.Reading(text: "152", hex: "#FF9500", value: "152", unit: "BPM", fraction: nil),
                start: 0, end: 1)])])

    /// Every file a capture writes, the manifest last.
    static var fileNames: [String] {
        scenes.flatMap { scene in scene.frames.map { scene.fileName(frame: $0) } } + [manifestName]
    }

    // MARK: The manifest

    /// What was captured, where and how: saved next to the frames so a committed reference says
    /// what it is.
    struct Manifest: Codable, Equatable, Sendable {
        struct Frame: Codable, Equatable, Sendable {
            var scene: String
            var title: String
            var frame: Int
            var timeSec: Double
            var file: String
            var width: Int
            var height: Int
        }
        var version = 1
        var renderer: String
        /// "simulator" or "device".
        var machine: String
        /// Free text that identifies the phone and the build.
        var device: String
        var capturedAt: String
        var note: String
        var frames: [Frame]
    }

    /// The note a capture carries. The simulator's pictures are not a reference.
    static func note(for machine: StudioSelfCheck.Machine) -> String {
        switch machine {
        case .device:
            return "Rendered on a phone through the Studio export. Text, stickers, climb tags and the "
                + "heart-rate tile were drawn by the Core Animation tool."
        case .simulator:
            return "Rendered on the simulator: NOT a reference. The simulator draws the Core Animation "
                + "tool's boxes but not its letters or symbols. Capture on a phone."
        }
    }

    /// The manifest for a capture. `sizes` is each scene's frame size as rendered.
    static func manifest(machine: StudioSelfCheck.Machine, device: String, capturedAt: String,
                         sizes: [String: (width: Int, height: Int)]) -> Manifest {
        var frames: [Manifest.Frame] = []
        for scene in scenes {
            guard let size = sizes[scene.id] else { continue }
            for frame in scene.frames {
                frames.append(.init(scene: scene.id, title: scene.title, frame: frame,
                                    timeSec: Double(frame) / Double(StudioGoldenPattern.fps),
                                    file: scene.fileName(frame: frame), width: size.width, height: size.height))
            }
        }
        return Manifest(renderer: renderer, machine: machine.rawValue, device: device, capturedAt: capturedAt,
                        note: note(for: machine), frames: frames)
    }

    static func encoded(_ manifest: Manifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(manifest)
    }

    /// What the screen says after a capture.
    static func statusLine(fileCount: Int, machine: StudioSelfCheck.Machine) -> String {
        guard fileCount > 0 else { return "Nothing was saved" }
        let saved = "\(fileCount) files saved"
        return machine == .simulator
            ? saved + ". This is the simulator: the pictures are not a reference. Capture on a phone."
            : saved + ". Share them and commit them as the overlay reference."
    }
}
#endif
