#if DEBUG
import Foundation
import CoreGraphics

/// The test videos behind the Studio's golden frames (prompt 304). They are not in the repo: each
/// is drawn in code from `StudioGoldenPattern` and written to a file when a test or the debug
/// self-check starts. This type only describes them. Foundation only.
enum StudioGoldenSource: String, CaseIterable, Sendable {
    /// 180×320, upright.
    case portraitA
    /// 180×320, upright, other colours (the second clip of a cut or a transition).
    case portraitB
    /// 320×180, upright.
    case landscape
    /// A 320×180 buffer filmed sideways: a quarter-turn `preferredTransform` makes it 180×320.
    case rotated
    /// 1080×1920, 5 s. Only for the self-check's timed export; no golden frame uses it.
    case large
    /// 540×960, upright. The picture behind text, stickers, climb tags and the heart-rate tile
    /// (`StudioOverlayReference`): big enough for the glyphs to be read.
    case overlayBase
    /// 180×320, upright, tagged Display P3 (wide colour). For the pass-through test only.
    case wideColour
    /// 180×320, upright, 10-bit HEVC tagged BT.2020 HLG (HDR). For the pass-through test only.
    case hdr

    /// The sources the golden scenes use.
    static let golden: [StudioGoldenSource] = [.portraitA, .portraitB, .landscape, .rotated]

    /// The size of the stored picture, before any rotation.
    var bufferWidth: Int {
        switch self {
        case .portraitA, .portraitB, .wideColour, .hdr: return 180
        case .landscape, .rotated: return 320
        case .large: return 1080
        case .overlayBase: return 540
        }
    }
    var bufferHeight: Int {
        switch self {
        case .portraitA, .portraitB, .wideColour, .hdr: return 320
        case .landscape, .rotated: return 180
        case .large: return 1920
        case .overlayBase: return 960
        }
    }
    /// How the file's colours are stored and tagged.
    enum Colour: Sendable { case bt709, displayP3, hlg }
    var colour: Colour {
        switch self {
        case .wideColour: return .displayP3
        case .hdr: return .hlg
        default: return .bt709
        }
    }
    /// True when the file carries a quarter turn clockwise.
    var isRotated: Bool { self == .rotated }
    var seconds: Double { self == .large ? 5 : 1 }
    var frameCount: Int { Int((seconds * Double(StudioGoldenPattern.fps)).rounded()) }

    /// Top-left, top-right, bottom-left, bottom-right. Mid-range values, so a filter can move
    /// them both ways, and no two sources share a colour.
    var palette: [StudioGoldenPattern.RGB] {
        switch self {
        case .portraitA, .large, .overlayBase, .wideColour, .hdr:
            return [.init(200, 60, 60), .init(60, 170, 80), .init(60, 90, 200), .init(215, 185, 60)]
        case .portraitB:
            return [.init(60, 180, 190), .init(190, 70, 180), .init(225, 130, 50), .init(120, 120, 120)]
        case .landscape:
            return [.init(150, 80, 200), .init(235, 235, 120), .init(70, 140, 110), .init(210, 110, 130)]
        case .rotated:
            return [.init(225, 150, 40), .init(40, 150, 225), .init(150, 200, 60), .init(120, 60, 150)]
        }
    }
}

/// What a fixture frame looks like: four colour quarters, a black mark in the top-left corner, and
/// a white block that moves right by a fixed step every frame. The quarters show orientation and
/// crop; the block shows which source frame is on screen, so a time-mapping error of one frame
/// moves it. Pure, so a test can say exactly where the block is.
enum StudioGoldenPattern {

    static let fps = 30

    struct RGB: Equatable, Sendable {
        let r: UInt8, g: UInt8, b: UInt8
        init(_ r: UInt8, _ g: UInt8, _ b: UInt8) { self.r = r; self.g = g; self.b = b }
    }

    /// What a BT.709 video stores for an sRGB value. The pattern's colours are sRGB numbers (what
    /// a decoded frame shows on screen and what a golden PNG holds); a video file keeps them on
    /// a different curve — a plain 1.961 gamma, `CGColorSpace.coreMedia709` — so the fixture
    /// writer converts each value with this before it fills a pixel buffer.
    static func videoValue(forSRGB value: UInt8) -> UInt8 {
        let v = Double(value) / 255
        let linear = v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        return UInt8(max(0, min(255, (pow(linear, 1 / 1.961) * 255).rounded())))
    }

    /// The moving block's side.
    static func blockSide(width: Int, height: Int) -> Int { max(2, min(width, height) / 6) }
    /// How far the block moves each frame: a thirtieth of the width (6 pixels at 180), so one
    /// frame too early or too late changes a strip wide enough to fail even the device tolerance.
    static func blockStep(width: Int) -> Int { max(2, width / 30) }
    /// The corner mark's side.
    static func markSide(width: Int, height: Int) -> Int { max(2, min(width, height) / 9) }

    /// The block's top-left corner in frame `index`. It starts at the left edge, moves right, and
    /// starts again when it would leave the picture.
    static func blockOrigin(frame index: Int, width: Int, height: Int) -> (x: Int, y: Int) {
        let side = blockSide(width: width, height: height)
        let travel = max(1, width - side + 1)
        let x = (max(0, index) * blockStep(width: width)) % travel
        return (x, (height - side) / 2)
    }

    /// The picture without the block.
    static func background(width: Int, height: Int, palette: [RGB]) -> StudioGoldenImage {
        precondition(palette.count == 4, "four quarters")
        var image = StudioGoldenImage(width: width, height: height, r: 0, g: 0, b: 0)
        let halfW = width / 2, halfH = height / 2
        image.fill(x: 0, y: 0, width: halfW, height: halfH, r: palette[0].r, g: palette[0].g, b: palette[0].b)
        image.fill(x: halfW, y: 0, width: width - halfW, height: halfH, r: palette[1].r, g: palette[1].g, b: palette[1].b)
        image.fill(x: 0, y: halfH, width: halfW, height: height - halfH, r: palette[2].r, g: palette[2].g, b: palette[2].b)
        image.fill(x: halfW, y: halfH, width: width - halfW, height: height - halfH,
                   r: palette[3].r, g: palette[3].g, b: palette[3].b)
        let mark = markSide(width: width, height: height)
        image.fill(x: mark / 2, y: mark / 2, width: mark, height: mark, r: 0, g: 0, b: 0)
        return image
    }

    /// Frame `index` of a source, as stored (before its rotation).
    static func frame(_ source: StudioGoldenSource, index: Int) -> StudioGoldenImage {
        var image = background(width: source.bufferWidth, height: source.bufferHeight, palette: source.palette)
        let side = blockSide(width: source.bufferWidth, height: source.bufferHeight)
        let at = blockOrigin(frame: index, width: source.bufferWidth, height: source.bufferHeight)
        image.fill(x: at.x, y: at.y, width: side, height: side, r: 255, g: 255, b: 255)
        return image
    }
}

/// One golden scene: a small Studio project made of fixture sources, and the output frames that
/// are compared with stored images. A scene with a `pendingReason` is a placeholder for something
/// the compositor does not draw yet; it is listed and skipped.
struct StudioGoldenScene: Identifiable, Sendable {
    /// Also the stem of the scene's image files.
    let id: String
    let title: String
    var aspect: ClipEditGeometry.OutputAspect = .portrait9x16
    /// `localIdentifier` is a `StudioGoldenSource` raw value.
    var clips: [TimelineClip] = []
    var transitions: [StudioTransition] = []
    /// Picture-in-picture items; `content` is a `StudioGoldenSource` raw value.
    var overlays: [OverlayItem] = []
    var baseFrame: StudioFrameRect?
    var background: StudioBackground = .black
    /// Output frame numbers at 30 frames a second.
    var frames: [Int] = []
    /// A heart-rate tile for every clip (drawn from `StudioGoldenScene.heartRate`); `nil` for none.
    var heartRateTile: ResolvedHRTile?
    /// Why the scene is not rendered yet; `nil` for a real scene.
    var pendingReason: String?

    var isPending: Bool { pendingReason != nil }

    /// The golden image's file name for one of the scene's frames.
    func fileName(frame: Int) -> String {
        String(format: "%@-f%03d.png", locale: Locale(identifier: "en_US_POSIX"), id, frame)
    }

    /// The scene's length, by the same rule the editor and the render plan use.
    var durationSec: Double {
        var lengths: [UUID: Double] = [:]
        for clip in clips { lengths[clip.id] = StudioGoldenSource(rawValue: clip.localIdentifier)?.seconds ?? 0 }
        return StudioGeometry.totalDuration(clips: clips, sourceDurations: lengths, transitions: transitions)
    }
}

extension StudioGoldenScene {

    /// The reason every placeholder for text, stickers and climb tags carries.
    static let pendingOverlays = "drawn by the compositor from prompt 310"
    /// The reason every placeholder for the heart-rate tile carries.
    static let pendingHeartRate = "drawn by the compositor from prompt 311"
    static let pendingPhotos = "photo clips are not rendered yet (planned for prompt 318+)"

    static func clip(_ source: StudioGoldenSource, _ order: Int, trimStart: Double = 0,
                             trimEnd: Double? = nil, speed: Double = 1,
                             crop: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
                             filter: StudioFilter = .none, intensity: Double = 1,
                             adjust: ClipAdjust? = nil, volume: Double? = nil,
                             scale: [StudioKeyframe] = []) -> TimelineClip {
        TimelineClip(sessionMediaID: nil, localIdentifier: source.rawValue, isPhoto: false, order: order,
                     trimStart: trimStart, trimEnd: trimEnd, speed: speed, cropRect: crop,
                     filter: filter, filterIntensity: intensity, adjust: adjust, volume: volume,
                     scaleKeyframes: scale)
    }

    private static func transition(_ kind: StudioTransitionKind) -> StudioGoldenScene {
        let a = clip(.portraitA, 0, volume: 0.8), b = clip(.portraitB, 1, volume: 0.5)
        // A 0–1 s, B 0.4–1.4 s. The overlap is frames 12…29, its middle is frame 21, and
        // frame 30 is the first with B alone.
        return StudioGoldenScene(
            id: "transition-\(kind.rawValue)", title: "Transition: \(kind.display)",
            clips: [a, b],
            transitions: [StudioTransition(afterClipID: a.id, kind: kind, durationSec: 0.6)],
            frames: [12, 17, 21, 25, 29, 30])
    }

    /// Every scene, in the order the tests and the self-check run them. The sources are 1 s
    /// (30 frames) long.
    static let all: [StudioGoldenScene] = {
        var scenes: [StudioGoldenScene] = []

        // Two clips and a cut at 1 s (frame 30). Frame 29 is the last of the first clip.
        scenes.append(StudioGoldenScene(
            id: "cut", title: "Plain cut",
            clips: [clip(.portraitA, 0), clip(.portraitB, 1)],
            frames: [10, 29, 30, 50]))

        // 0.6 s of A at double speed (frames 0…8), then 0.5 s of B at half speed (frames 9…38).
        scenes.append(StudioGoldenScene(
            id: "trim-speed", title: "Trim and speed",
            clips: [clip(.portraitA, 0, trimStart: 0.2, trimEnd: 0.8, speed: 2),
                    clip(.portraitB, 1, trimStart: 0, trimEnd: 0.5, speed: 0.5)],
            frames: [2, 8, 9, 25]))

        // A landscape clip on a portrait canvas, cropped to its middle half.
        scenes.append(StudioGoldenScene(
            id: "crop", title: "Crop",
            clips: [clip(.landscape, 0, crop: CGRect(x: 0.25, y: 0, width: 0.5, height: 1))],
            frames: [5, 20]))

        // The same clip, cropped, in the top-half cell, over a white background.
        scenes.append(StudioGoldenScene(
            id: "base-frame", title: "Crop in a base frame, white background",
            clips: [clip(.landscape, 0, crop: CGRect(x: 0, y: 0, width: 0.75, height: 1))],
            baseFrame: .half, background: .white,
            frames: [5]))

        // A portrait clip in a cell of a square canvas, over its own blurred picture.
        scenes.append(StudioGoldenScene(
            id: "base-frame-blur", title: "Base frame, blurred background",
            aspect: .square1x1,
            clips: [clip(.portraitA, 0)],
            baseFrame: StudioFrameRect(centerX: 0.5, centerY: 0.5, width: 0.6, height: 0.8),
            background: .blur,
            frames: [10]))

        // Nine 0.2 s pieces of the same clip, one treatment each; a frame from each.
        let adjust = ClipAdjust(brightness: 0.1, contrast: 1.3, saturation: 0.6)
        let treatments: [(StudioFilter, Double, ClipAdjust?)] = [
            (.mono, 1, nil), (.noir, 1, nil), (.fade, 1, nil), (.vivid, 1, nil), (.vivid, 0.4, nil),
            (.warm, 1, nil), (.cool, 1, nil), (.none, 1, adjust), (.warm, 0.7, adjust)]
        scenes.append(StudioGoldenScene(
            id: "filters", title: "Filters and adjust",
            clips: treatments.enumerated().map { index, t in
                clip(.portraitA, index, trimStart: 0.2, trimEnd: 0.4, filter: t.0, intensity: t.1, adjust: t.2)
            },
            frames: treatments.indices.map { $0 * 6 + 3 }))

        for kind in [StudioTransitionKind.dissolve, .fadeThroughBlack, .slideLeft, .slideRight, .zoomIn] {
            scenes.append(transition(kind))
        }

        // A picture-in-picture, turned 15°, from 0.3 s to 1.3 s of a 2 s timeline, fading in from
        // 20 % to 100 % between 0.5 s and 1 s. Frame 8 is before it, 9 its first, 38 its last.
        scenes.append(StudioGoldenScene(
            id: "pip", title: "Picture-in-picture",
            clips: [clip(.portraitA, 0), clip(.portraitB, 1)],
            overlays: [OverlayItem(
                kind: .video, content: StudioGoldenSource.landscape.rawValue, startSec: 0.3, endSec: 1.3,
                position: CGPoint(x: 0.6, y: 0.3), normalizedWidth: 0.6, normalizedHeight: 0.3,
                rotationDegrees: 15,
                opacityKeyframes: [StudioKeyframe(timeSec: 0.5, value: 0.2, easing: .linear),
                                   StudioKeyframe(timeSec: 1, value: 1, easing: .linear)])],
            frames: [8, 9, 22, 35, 38, 39]))

        // A clip filmed sideways, whole and then cropped to its top half.
        scenes.append(StudioGoldenScene(
            id: "rotated", title: "Rotated source",
            clips: [clip(.rotated, 0), clip(.rotated, 1, crop: CGRect(x: 0, y: 0, width: 1, height: 0.5))],
            frames: [5, 25, 40]))

        // A slow zoom from 1× to 1.6× over the clip.
        scenes.append(StudioGoldenScene(
            id: "ken-burns", title: "Zoom keyframes",
            clips: [clip(.portraitA, 0, scale: [StudioKeyframe(timeSec: 0, value: 1, easing: .linear),
                                                StudioKeyframe(timeSec: 1, value: 1.6, easing: .linear)])],
            frames: [0, 15, 29]))

        // A filter, a transition and a picture-in-picture at once (the timed export's shape).
        let first = clip(.portraitA, 0, filter: .vivid), second = clip(.portraitB, 1, filter: .cool)
        scenes.append(StudioGoldenScene(
            id: "combined", title: "Filter, transition and picture-in-picture together",
            clips: [first, second],
            transitions: [StudioTransition(afterClipID: first.id, kind: .dissolve, durationSec: 0.6)],
            overlays: [OverlayItem(
                kind: .video, content: StudioGoldenSource.landscape.rawValue, startSec: 0.3, endSec: 1.3,
                position: CGPoint(x: 0.7, y: 0.2), normalizedWidth: 0.5, normalizedHeight: 0.25)],
            frames: [10, 21, 35]))

        // Not drawn by the compositor yet. The next prompts fill these in.
        scenes.append(StudioGoldenScene(id: "text", title: "Text", pendingReason: pendingOverlays))
        scenes.append(StudioGoldenScene(id: "stickers", title: "Stickers", pendingReason: pendingOverlays))
        scenes.append(StudioGoldenScene(id: "climb-tags", title: "Climb tags", pendingReason: pendingOverlays))
        scenes.append(StudioGoldenScene(id: "hr-tile", title: "Heart-rate tile", pendingReason: pendingHeartRate))
        scenes.append(StudioGoldenScene(id: "hr-tile-transition", title: "Heart-rate tile across a transition",
                                        pendingReason: pendingHeartRate))
        scenes.append(StudioGoldenScene(id: "photo-clip", title: "Photo clip", pendingReason: pendingPhotos))
        return scenes
    }()

    /// One clip of `source` with no edits at all. It has no golden image: the pass-through test
    /// compares it with the source file decoded directly.
    static func passThrough(_ source: StudioGoldenSource) -> StudioGoldenScene {
        StudioGoldenScene(id: "pass-through-\(source.rawValue)", title: "Unedited clip",
                          clips: [clip(source, 0)], frames: [0, 14, 29])
    }

    /// The scenes that are rendered.
    static var rendered: [StudioGoldenScene] { all.filter { !$0.isPending } }

    /// Every golden image file the rendered scenes need.
    static var fileNames: [String] {
        rendered.flatMap { scene in scene.frames.map { scene.fileName(frame: $0) } }
    }

    /// The shape of the self-check's timed export: five clips of `source` with a filter each,
    /// four transitions of `transitionSec`, and a picture-in-picture of the same source from a
    /// tenth to nine tenths of the timeline. It has no golden frames.
    static func timedScene(source: StudioGoldenSource, transitionSec: Double) -> StudioGoldenScene {
        let filters: [StudioFilter] = [.vivid, .warm, .mono, .cool, .fade]
        let clips = filters.enumerated().map { index, filter in clip(source, index, filter: filter) }
        let kinds: [StudioTransitionKind] = [.dissolve, .slideLeft, .zoomIn, .fadeThroughBlack]
        let total = source.seconds * Double(clips.count) - transitionSec * Double(kinds.count)
        return StudioGoldenScene(
            id: "timed", title: "Filters, transitions and a picture-in-picture",
            clips: clips,
            transitions: zip(clips, kinds).map { StudioTransition(afterClipID: $0.id, kind: $1, durationSec: transitionSec) },
            overlays: [OverlayItem(
                kind: .video, content: source.rawValue, startSec: total * 0.1, endSec: total * 0.9,
                position: CGPoint(x: 0.72, y: 0.22), normalizedWidth: 0.4, normalizedHeight: 0.3)])
    }

    /// The timed export itself: 20 s at 1080×1920 (five 5 s clips, four 1.25 s transitions, a
    /// picture-in-picture for 16 s). Only its export time and memory are reported.
    static let timed = timedScene(source: .large, transitionSec: 1.25)

    /// A fixed heart-rate series for the scenes that will draw a heart-rate tile (prompt 311):
    /// one sample a second for 40 s, rising from 96 to 172 and easing back. Whole numbers, written
    /// out, so it is the same on every machine.
    static let heartRate: [HRPoint] = {
        let bpm: [Double] = [96, 98, 101, 105, 110, 116, 122, 128, 134, 139,
                             144, 148, 152, 155, 158, 161, 163, 165, 167, 169,
                             170, 171, 172, 172, 171, 169, 166, 162, 158, 153,
                             148, 143, 138, 133, 129, 125, 121, 118, 115, 112]
        return bpm.enumerated().map { HRPoint(t: Double($0.offset), bpm: $0.element) }
    }()
}
#endif
