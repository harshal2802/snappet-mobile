import Foundation
import AVFoundation
import CoreImage
import CoreVideo
import Metal
import os

/// One time range of a Studio video composition (prompt 300): a `StudioRenderPlan.Segment` plus the
/// composition tracks that hold its sources. Immutable, so it is safe to hand to AVFoundation's
/// render threads. `StudioComposer` makes one per plan segment; `StudioCompositor` draws it.
final class StudioCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol, Sendable {

    /// A composition track and how to turn one of its frames upright.
    struct Source: Sendable {
        let trackID: CMPersistentTrackID
        /// Maps the track's natural pixels to its oriented pixels, top-left origin, with the
        /// oriented picture's corner at the origin (`preferredTransform`, moved to the origin).
        let orient: CGAffineTransform
    }

    let timeRange: CMTimeRange
    /// The Core Animation tool (text, climb tags, HR tile) draws over every frame on export.
    let enablePostProcessing = true
    let containsTweening: Bool
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    /// Only the tracks this segment draws, so AVFoundation does not decode the others.
    var requiredSourceTrackIDs: [NSValue]? {
        (main.map(\.source.trackID) + pips.map(\.source.trackID)).map { NSNumber(value: $0) }
    }

    let canvas: CGSize
    let background: StudioBackground
    let main: [(layer: StudioRenderPlan.MainLayer, source: Source)]
    let pips: [(layer: StudioRenderPlan.PiPLayer, source: Source)]

    init(timeRange: CMTimeRange, canvas: CGSize, background: StudioBackground,
         main: [(layer: StudioRenderPlan.MainLayer, source: Source)],
         pips: [(layer: StudioRenderPlan.PiPLayer, source: Source)]) {
        self.timeRange = timeRange
        self.canvas = canvas
        self.background = background
        self.main = main
        self.pips = pips
        self.containsTweening = main.contains { $0.layer.isTweened } || pips.contains { $0.layer.isTweened }
    }
}

/// The Studio's **one** video compositor (prompt 300). It draws a `StudioCompositionInstruction`
/// with Core Image: background, the main clip (orientation, crop or base frame, Ken-Burns scale,
/// filter, adjust), the incoming clip of a transition, and the picture-in-picture layers — in the
/// preview and in the export, from the same plan. It decides nothing; `StudioRenderPlan` does.
///
/// Frames are rendered one at a time on a private serial queue through one shared Metal-backed
/// `CIContext`. Output is SDR BT.709. HDR and wide-colour sources are converted to SDR BT.709 by
/// AVFoundation before they arrive, because `supportsHDRSourceFrames` and
/// `supportsWideColorSourceFrames` are left at their default of `false`.
final class StudioCompositor: NSObject, AVVideoCompositing, Sendable {

    /// One context for every compositor instance (preview and export each get their own instance
    /// from AVFoundation). Building a `CIContext` is expensive and it caches compiled kernels.
    static let context: CIContext = {
        let options: [CIContextOption: Any] = [.cacheIntermediates: false, .name: "snappet.studio.compositor"]
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: options)
        }
        return CIContext(options: options)
    }()

    private static let outputColorSpace = CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()

    private let queue = DispatchQueue(label: "snappet.studio.compositor", qos: .userInitiated)
    /// Bumped by a cancel. A queued request that was started under an older value is answered
    /// with `finishCancelledRequest` and not rendered.
    private let generation = OSAllocatedUnfairLock(initialState: 0)

    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelFormatType_32BGRA],
        kCVPixelBufferMetalCompatibilityKey as String: true]

    /// BGRA, which the Core Animation post-processing tool also accepts.
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true]

    /// Nothing is kept from a render context: each request carries its own.
    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        let started = generation.withLock { $0 }
        queue.async { [generation] in
            guard generation.withLock({ $0 }) == started else {
                request.finishCancelledRequest()
                return
            }
            autoreleasepool { Self.render(request) }
        }
    }

    /// Blocks until every request that was pending has been answered: the ones still queued are
    /// cancelled, the one being rendered finishes.
    func cancelAllPendingVideoCompositionRequests() {
        generation.withLock { $0 += 1 }
        queue.sync {}
    }

    private static func render(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? StudioCompositionInstruction,
              let output = request.renderContext.newPixelBuffer() else {
            request.finish(with: NSError(domain: AVFoundationErrorDomain,
                                         code: AVError.Code.failedToParse.rawValue))
            return
        }
        let size = request.renderContext.size
        var image = compose(instruction, at: request.compositionTime.seconds) { trackID in
            request.sourceFrame(byTrackID: trackID).map { CIImage(cvPixelBuffer: $0) }
        }
        // The plan works top-left; a pixel buffer drawn by Core Image is bottom-left. Flip once,
        // and scale if the render context is not the canvas size (`renderScale` other than 1).
        let canvas = instruction.canvas
        image = image.transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: canvas.height))
        if canvas.width > 0, canvas.height > 0, size != canvas {
            image = image.transformed(by: CGAffineTransform(scaleX: size.width / canvas.width,
                                                            y: size.height / canvas.height))
        }
        context.render(image, to: output, bounds: CGRect(origin: .zero, size: size),
                       colorSpace: outputColorSpace)
        request.finish(withComposedVideoFrame: output)
    }

    // MARK: Drawing (Core Image only — no AVFoundation below this line)

    /// The frame for `instruction` at output time `t`, in **canvas pixels with a top-left origin**
    /// (the caller flips it for a pixel buffer). `frame` returns a track's current source frame as
    /// Core Image sees it (bottom-left origin), or `nil` when the track has none at this time; a
    /// layer with no frame is left out.
    static func compose(_ instruction: StudioCompositionInstruction, at t: Double,
                        frame: (CMPersistentTrackID) -> CIImage?) -> CIImage {
        let canvas = instruction.canvas
        let canvasRect = CGRect(origin: .zero, size: canvas)

        // Each main layer's upright source, filtered. Kept apart from placement so the blurred
        // background can reuse the first one.
        let mains: [(layer: StudioRenderPlan.MainLayer, image: CIImage)] = instruction.main.compactMap { entry in
            guard let raw = frame(entry.source.trackID) else { return nil }
            var image = upright(raw, orient: entry.source.orient)
            if entry.layer.filter != .none {
                image = StudioFilters.apply(entry.layer.filter, intensity: entry.layer.filterIntensity, to: image)
            }
            image = StudioFilters.applyAdjust(entry.layer.adjust, to: image)
            return (entry.layer, image)
        }

        var result = backgroundImage(instruction.background, canvas: canvasRect, behind: mains.first?.image)

        var curtain = 0.0
        for (layer, source) in mains {
            var transform = layer.placement.transform
            let zoom = StudioRenderPlan.kenBurnsScale(layer, at: t)
            if abs(zoom - 1) > 0.0001 {
                let clip = layer.placement.clip
                transform = transform.concatenating(
                    StudioRenderPlan.scale(zoom, about: CGPoint(x: clip.midX, y: clip.midY)))
            }
            var image = source.transformed(by: transform).cropped(to: layer.placement.clip)
            var opacity = 1.0
            if let phase = layer.leaving {
                let p = phase.progress(at: t)
                let pose = StudioRenderPlan.pose(kind: phase.kind, role: .outgoing, progress: p, canvas: canvas)
                image = image.transformed(by: pose.transform)
                opacity *= pose.opacity
                curtain = max(curtain, StudioRenderPlan.curtain(kind: phase.kind, progress: p))
            }
            if let phase = layer.entering {
                let p = phase.progress(at: t)
                let pose = StudioRenderPlan.pose(kind: phase.kind, role: .incoming, progress: p, canvas: canvas)
                image = image.transformed(by: pose.transform)
                opacity *= pose.opacity
                curtain = max(curtain, StudioRenderPlan.curtain(kind: phase.kind, progress: p))
            }
            guard opacity > 0.001 else { continue }
            result = faded(image, opacity).composited(over: result)
        }
        if curtain > 0.001 {
            result = faded(CIImage(color: .black).cropped(to: canvasRect), curtain).composited(over: result)
        }

        for entry in instruction.pips {
            let opacity = StudioRenderPlan.pipOpacity(entry.layer, at: t)
            guard opacity > 0.001, let raw = frame(entry.source.trackID) else { continue }
            var image = upright(raw, orient: entry.source.orient)
                .transformed(by: entry.layer.transform)
                .cropped(to: entry.layer.frame)
            if abs(entry.layer.rotationDegrees) > 0.01 {
                let f = entry.layer.frame
                image = image.transformed(by: StudioRenderPlan.rotation(
                    degrees: entry.layer.rotationDegrees, about: CGPoint(x: f.midX, y: f.midY)))
            }
            result = faded(image, opacity).composited(over: result)
        }
        return result.cropped(to: canvasRect)
    }

    /// A source frame turned upright with a top-left origin: flip Core Image's bottom-left rows,
    /// then apply the track's orientation.
    private static func upright(_ raw: CIImage, orient: CGAffineTransform) -> CIImage {
        let e = raw.extent
        return raw
            .transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: -e.minX, ty: e.maxY))
            .transformed(by: orient)
    }

    private static func faded(_ image: CIImage, _ opacity: Double) -> CIImage {
        guard opacity < 0.999 else { return image }
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(max(0, opacity)))])
    }

    /// The canvas fill. `blur` is the main clip filling the canvas, blurred; with no frame to blur
    /// it is black.
    private static func backgroundImage(_ background: StudioBackground, canvas: CGRect,
                                        behind main: CIImage?) -> CIImage {
        switch background {
        case .white:
            return CIImage(color: .white).cropped(to: canvas)
        case .blur:
            let black = CIImage(color: .black).cropped(to: canvas)
            guard let main else { return black }
            let radius = max(8, canvas.width / 24)
            return StudioFilters.aspectFill(main, to: canvas.size)
                .clampedToExtent()
                .applyingGaussianBlur(sigma: radius)
                .cropped(to: canvas)
                .composited(over: black)
        case .black:
            return CIImage(color: .black).cropped(to: canvas)
        }
    }
}
