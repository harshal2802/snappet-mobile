#if DEBUG
import Foundation
import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox
import os

/// The device edge of the Studio render check (prompt 304): writes the fixture videos, renders a
/// `StudioGoldenScene` through `StudioComposer` the way the Studio does, and turns frames into
/// `StudioGoldenImage`s. Everything it decides is in `StudioGoldenScenes`, `StudioGoldenCompare`
/// and `StudioSelfCheck`; the golden-frame unit tests and the debug screen both call `check`.
enum StudioGoldenRenderer {

    enum Failure: LocalizedError {
        case writer(String), frame(String), unknownSource(String)
        var errorDescription: String? {
            switch self {
            case .writer(let m): return "The test video could not be written: \(m)"
            case .frame(let m): return "A frame could not be read: \(m)"
            case .unknownSource(let m): return "No test video named \(m)"
            }
        }
    }

    // MARK: Fixture files

    /// The fixture videos on disk. Made once per test run or per self-check and deleted after.
    struct Fixture: Sendable {
        let directory: URL
        func url(_ source: StudioGoldenSource) -> URL {
            directory.appendingPathComponent("\(source.rawValue).mp4")
        }
        func remove() { try? FileManager.default.removeItem(at: directory) }
    }

    /// A new, empty folder for a fixture in the temporary directory.
    static func newFixtureDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(fixturePrefix + UUID().uuidString, isDirectory: true)
    }
    static let fixturePrefix = "studio-golden-"

    /// Write `sources` into `directory` (a file that is already there is kept). Blocks until the
    /// files are finished; call it off the main thread.
    @discardableResult
    static func makeFixture(_ sources: [StudioGoldenSource], in directory: URL) throws -> Fixture {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = Fixture(directory: directory)
        for source in sources where !FileManager.default.fileExists(atPath: fixture.url(source).path) {
            try write(source, to: fixture.url(source))
        }
        return fixture
    }

    /// One fixture video: H.264 with fixed settings (no frame reordering, a key frame every
    /// second, a fixed bit rate, BT.709), 30 frames a second, with a 440 Hz tone as its sound.
    /// The fixed settings are what makes two runs on one machine give the same pictures.
    /// Picture and sound are handed over in turns, each when the writer asks for it.
    private static func write(_ source: StudioGoldenSource, to url: URL) throws {
        let w = source.bufferWidth, h = source.bufferHeight
        let fps = Int32(StudioGoldenPattern.fps)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        // How the file is tagged, and the same three tags for every pixel buffer handed to it.
        let primaries: String, transfer: String, matrix: String
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: w * h * 12,
            AVVideoMaxKeyFrameIntervalKey: Int(fps),
            AVVideoAllowFrameReorderingKey: false,
            AVVideoExpectedSourceFrameRateKey: Int(fps)]
        var codec = AVVideoCodecType.h264
        var pixelFormat = kCVPixelFormatType_32BGRA
        switch source.colour {
        case .bt709:
            primaries = AVVideoColorPrimaries_ITU_R_709_2
            transfer = AVVideoTransferFunction_ITU_R_709_2
            matrix = AVVideoYCbCrMatrix_ITU_R_709_2
        case .displayP3:
            primaries = AVVideoColorPrimaries_P3_D65
            transfer = AVVideoTransferFunction_ITU_R_709_2
            matrix = AVVideoYCbCrMatrix_ITU_R_709_2
        case .hlg:
            primaries = AVVideoColorPrimaries_ITU_R_2020
            transfer = AVVideoTransferFunction_ITU_R_2100_HLG
            matrix = AVVideoYCbCrMatrix_ITU_R_2020
            codec = .hevc
            pixelFormat = kCVPixelFormatType_ARGB2101010LEPacked
            compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String
        }
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: primaries,
                AVVideoTransferFunctionKey: transfer,
                AVVideoYCbCrMatrixKey: matrix],
            AVVideoCompressionPropertiesKey: compression])
        video.expectsMediaDataInRealTime = false
        if source.isRotated { video.transform = CGAffineTransform(rotationAngle: .pi / 2) }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])

        let rate = 44_100
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000])
        audio.expectsMediaDataInRealTime = false

        guard writer.canAdd(video), writer.canAdd(audio) else { throw Failure.writer("inputs refused") }
        writer.add(video)
        writer.add(audio)
        guard writer.startWriting() else {
            throw Failure.writer(writer.error?.localizedDescription ?? "could not start")
        }
        writer.startSession(atSourceTime: .zero)

        // The picture without the block, as BGRA rows; each frame copies it and paints the block.
        let background = StudioGoldenPattern.background(width: w, height: h, palette: source.palette)
        // The pattern's colours are sRGB; a BT.709 buffer holds what a BT.709 video stores for
        // them and is tagged BT.709, so nothing converts it on the way into the file and a
        // decoded frame, shown as sRGB, has the pattern's own numbers. (The wide-colour and HDR
        // sources reuse the same numbers under their own tags; only their pass-through matters.)
        let stored = (0 ... 255).map { StudioGoldenPattern.videoValue(forSRGB: UInt8($0)) }
        var bgra = background.rgba
        for i in stride(from: 0, to: bgra.count, by: 4) {
            let r = bgra[i], g = bgra[i + 1], b = bgra[i + 2]
            if source.colour == .hlg {
                // 2 bits of alpha, then 10 each of red, green, blue; little-endian.
                let word = UInt32(3) << 30 | (UInt32(r) * 1023 / 255) << 20
                    | (UInt32(g) * 1023 / 255) << 10 | (UInt32(b) * 1023 / 255)
                bgra[i] = UInt8(word & 0xFF); bgra[i + 1] = UInt8(word >> 8 & 0xFF)
                bgra[i + 2] = UInt8(word >> 16 & 0xFF); bgra[i + 3] = UInt8(word >> 24 & 0xFF)
            } else {
                bgra[i] = stored[Int(b)]; bgra[i + 1] = stored[Int(g)]; bgra[i + 2] = stored[Int(r)]; bgra[i + 3] = 255
            }
        }
        let side = StudioGoldenPattern.blockSide(width: w, height: h)

        let frames = source.frameCount
        let totalSamples = Int(source.seconds * Double(rate))
        let chunk = rate / 10
        var frame = 0, sample = 0, idle = 0
        while frame < frames || sample < totalSamples {
            var progressed = false
            if frame < frames, video.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool {
                var made: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
                guard let buffer = made else { throw Failure.writer("no pixel buffer") }
                // The AVVideo… and kCVImageBuffer… tag names are the same strings.
                CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, primaries as CFString, .shouldPropagate)
                CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, transfer as CFString, .shouldPropagate)
                CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, matrix as CFString, .shouldPropagate)
                CVPixelBufferLockBaseAddress(buffer, [])
                if let base = CVPixelBufferGetBaseAddress(buffer) {
                    let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
                    let at = StudioGoldenPattern.blockOrigin(frame: frame, width: w, height: h)
                    bgra.withUnsafeBytes { src in
                        guard let from = src.baseAddress else { return }
                        for y in 0 ..< h {
                            let row = base + y * rowBytes
                            memcpy(row, from + y * w * 4, w * 4)
                            if y >= at.y, y < at.y + side { memset(row + at.x * 4, 255, side * 4) }
                        }
                    }
                }
                CVPixelBufferUnlockBaseAddress(buffer, [])
                guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps)) else {
                    throw Failure.writer(writer.error?.localizedDescription ?? "a frame was refused")
                }
                frame += 1
                progressed = true
                // Finished as soon as its last sample is in: a writer holds one input back until
                // the other catches up, and it cannot know an input is done until it is told.
                if frame == frames { video.markAsFinished() }
            }
            if sample < totalSamples, audio.isReadyForMoreMediaData {
                let count = min(chunk, totalSamples - sample)
                guard audio.append(try tone(from: sample, count: count, rate: rate)) else {
                    throw Failure.writer(writer.error?.localizedDescription ?? "sound was refused")
                }
                sample += count
                progressed = true
                if sample == totalSamples { audio.markAsFinished() }
            }
            if progressed {
                idle = 0
            } else {
                idle += 1
                guard idle < 20_000, writer.status == .writing else {       // 20 s with no progress
                    throw Failure.writer(writer.error?.localizedDescription ?? "the writer stopped taking data")
                }
                usleep(1_000)
            }
        }
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            throw Failure.writer(writer.error?.localizedDescription ?? "could not finish")
        }
    }

    /// `count` samples of a 440 Hz tone, 16-bit mono, starting at sample `start`.
    private static func tone(from start: Int, count: Int, rate: Int) throws -> CMSampleBuffer {
        var samples = [Int16](repeating: 0, count: count)
        for i in 0 ..< count {
            samples[i] = Int16(12_000 * sin(2 * Double.pi * 440 * Double(start + i) / Double(rate)))
        }
        var description = AudioStreamBasicDescription(
            mSampleRate: Double(rate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
            mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0,
                                       layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                       formatDescriptionOut: &format)
        let bytes = count * 2
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
                                           blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                                           offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block)
        guard let format, let block else { throw Failure.writer("no sound buffer") }
        let copied = samples.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: bytes)
        }
        var buffer: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: count, presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(rate)),
            packetDescriptions: nil, sampleBufferOut: &buffer)
        guard copied == kCMBlockBufferNoErr, let buffer else { throw Failure.writer("no sound buffer") }
        return buffer
    }

    // MARK: Rendering a scene

    /// The scene's frames, made the way `path` says. Export: `StudioComposer.assemble` with the
    /// overlay tool, `StudioComposer.export` to a file, frames read from the file. Preview: the
    /// same `assemble` call with `forPlayback`, frames drawn straight from its video composition
    /// (the one the editor hands to its `AVPlayerItem`).
    static func frames(of scene: StudioGoldenScene, fixture: Fixture,
                       path: StudioSelfCheck.RenderPath) async throws -> [StudioGoldenImage] {
        let composer = StudioComposer()
        let (composition, videoComposition, audioMix) = try await assemble(
            scene, fixture: fixture, composer: composer, forPlayback: path == .preview)
        return try await frames(scene.frames, composition: composition, videoComposition: videoComposition,
                                audioMix: audioMix, path: path, composer: composer)
    }

    /// Output frames of a composition that is already built: read from the exported file, or
    /// drawn straight from the video composition (the preview).
    static func frames(_ frames: [Int], composition: AVMutableComposition, videoComposition: AVVideoComposition?,
                       audioMix: AVAudioMix?, path: StudioSelfCheck.RenderPath,
                       composer: StudioComposer) async throws -> [StudioGoldenImage] {
        let generator: AVAssetImageGenerator
        var file: URL?
        switch path {
        case .preview:
            generator = AVAssetImageGenerator(asset: composition)
            generator.videoComposition = videoComposition
        case .export:
            let url = try await composer.export(composition: composition, videoComposition: videoComposition,
                                                audioMix: audioMix)
            file = url
            generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        }
        defer { if let file { try? FileManager.default.removeItem(at: file) } }
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.appliesPreferredTrackTransform = true
        var images: [StudioGoldenImage] = []
        for frame in frames {
            // 600 ticks a second: frame n starts at tick 20 n, exactly.
            let time = CMTime(value: CMTimeValue(frame) * 600 / CMTimeValue(StudioGoldenPattern.fps), timescale: 600)
            let cgImage = try await generator.image(at: time).image
            guard let image = image(cgImage) else { throw Failure.frame("frame \(frame)") }
            images.append(image)
        }
        return images
    }

    /// Frames of a finished video file (an export), by output frame number.
    static func frames(_ frames: [Int], ofFile url: URL) async throws -> [StudioGoldenImage] {
        var images: [StudioGoldenImage] = []
        for frame in frames { images.append(try await sourceFrame(url, frame: frame)) }
        return images
    }

    /// Fixture folders a run that was killed left in the temporary directory. The screen calls
    /// this when it opens; returns how many were removed.
    @discardableResult
    static func removeLeftovers(in directory: URL = FileManager.default.temporaryDirectory) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var removed = 0
        for name in names where name.hasPrefix(fixturePrefix) {
            if (try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))) != nil { removed += 1 }
        }
        return removed
    }

    /// Frame `frame` of a video file, decoded directly (no Studio code), turned upright.
    static func sourceFrame(_ url: URL, frame: Int) async throws -> StudioGoldenImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.appliesPreferredTrackTransform = true
        let time = CMTime(value: CMTimeValue(frame) * 600 / CMTimeValue(StudioGoldenPattern.fps), timescale: 600)
        let cgImage = try await generator.image(at: time).image
        guard let image = image(cgImage) else { throw Failure.frame("frame \(frame) of \(url.lastPathComponent)") }
        return image
    }

    /// `StudioComposer.assemble` for a scene. `loopPictureInPicture` repeats each
    /// picture-in-picture source that many times (the timed export needs one longer than 5 s).
    static func assemble(_ scene: StudioGoldenScene, fixture: Fixture, composer: StudioComposer,
                         forPlayback: Bool, loopPictureInPicture: Int = 1) async throws
        -> sending (AVMutableComposition, AVVideoComposition?, AVAudioMix?) {
        var resolved: [(clip: TimelineClip, asset: AVAsset)] = []
        var durations: [UUID: Double] = [:]
        for clip in scene.clips {
            guard let source = StudioGoldenSource(rawValue: clip.localIdentifier) else {
                throw Failure.unknownSource(clip.localIdentifier)
            }
            resolved.append((clip, AVURLAsset(url: fixture.url(source))))
            durations[clip.id] = source.seconds
        }
        var videoOverlays: [(overlay: OverlayItem, asset: AVAsset)] = []
        for overlay in scene.overlays where overlay.kind == .video {
            guard let source = StudioGoldenSource(rawValue: overlay.content) else {
                throw Failure.unknownSource(overlay.content)
            }
            let asset = try await looped(fixture.url(source), seconds: source.seconds, times: loopPictureInPicture)
            videoOverlays.append((overlay, asset))
        }
        var clipHR: [UUID: StudioClipHRContent] = [:]
        if let tile = scene.heartRateTile {
            for clip in scene.clips { clipHR[clip.id] = StudioClipHRContent(samples: StudioGoldenScene.heartRate, tile: tile) }
        }
        return try await composer.assemble(
            resolved: resolved, aspect: scene.aspect, sourceDurations: durations,
            transitions: scene.transitions, overlays: scene.overlays, videoOverlays: videoOverlays,
            clipHRByID: clipHR,
            baseFrame: scene.baseFrame, background: scene.background, forPlayback: forPlayback)
    }

    /// The file, or the file's picture played `times` times back to back.
    /// Not private: the heart-rate timing seed plays the fixture ten times (prompt 306).
    static func looped(_ url: URL, seconds: Double, times: Int) async throws -> AVAsset {
        let asset = AVURLAsset(url: url)
        guard times > 1, let video = try await asset.loadTracks(withMediaType: .video).first else { return asset }
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: seconds, preferredTimescale: 600))
        let movie = AVMutableComposition()
        guard let target = movie.addMutableTrack(withMediaType: .video,
                                                 preferredTrackID: kCMPersistentTrackID_Invalid) else { return asset }
        for index in 0 ..< times {
            try target.insertTimeRange(range, of: video,
                                       at: CMTime(seconds: seconds * Double(index), preferredTimescale: 600))
        }
        target.preferredTransform = try await video.load(.preferredTransform)
        return movie
    }

    // MARK: Checking a scene

    /// Render `scene` on both paths and compare every frame with its golden image. `golden`
    /// returns the stored image for a file name. A passing frame's pictures are kept only when
    /// `keepPassingImages` is set (the screen shows them; the tests do not need them).
    static func check(_ scene: StudioGoldenScene, fixture: Fixture, machine: StudioSelfCheck.Machine,
                      keepPassingImages: Bool = false,
                      golden: @Sendable (String) -> StudioGoldenImage?) async -> StudioSelfCheck.SceneResult {
        guard !scene.isPending else { return StudioSelfCheck.skipped(scene) }
        let clock = ContinuousClock()
        let started = clock.now
        var checks: [StudioSelfCheck.FrameCheck] = []
        var failure: String?
        do {
            for path in StudioSelfCheck.RenderPath.allCases {
                let tolerance = StudioSelfCheck.tolerance(for: path, on: machine)
                let images = try await frames(of: scene, fixture: fixture, path: path)
                for (frame, image) in zip(scene.frames, images) {
                    let name = scene.fileName(frame: frame)
                    guard let stored = golden(name) else {
                        checks.append(.init(frame: frame, path: path, goldenName: name, outcome: .missingGolden,
                                            actualPNG: pngData(image), diffPNG: nil))
                        continue
                    }
                    let result = StudioGoldenCompare.compare(actual: image, golden: stored, tolerance: tolerance)
                    var check = StudioSelfCheck.FrameCheck(frame: frame, path: path, goldenName: name,
                                                           outcome: .compared(result))
                    if keepPassingImages || !result.passed {
                        check.actualPNG = pngData(image)
                        check.diffPNG = StudioGoldenCompare.diffImage(actual: image, golden: stored, tolerance: tolerance)
                            .flatMap(pngData)
                    }
                    checks.append(check)
                }
            }
        } catch {
            failure = error.localizedDescription
        }
        let elapsed = clock.now - started
        return StudioSelfCheck.SceneResult(
            id: scene.id, title: scene.title,
            status: StudioSelfCheck.status(frames: checks, expectedFrames: scene.frames.count, error: failure),
            frames: checks,
            seconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
    }

    // MARK: The timed export

    /// Export `scene` (`StudioGoldenScene.timed` on the screen) and report how long the export
    /// session took and the most memory the app used while it ran (sampled every 50 ms). The
    /// fixture must hold the scene's source.
    ///
    /// `baselineBytes` is the app's memory before anything was done for the timed export. Pass
    /// the value read BEFORE the source video was written: the writer's buffers are still
    /// around when the export starts, and a baseline taken then hides them.
    static func timedExport(_ scene: StudioGoldenScene = .timed, fixture: Fixture,
                            baselineBytes: UInt64? = nil) async throws -> StudioSelfCheck.Timing {
        let composer = StudioComposer()
        let (composition, videoComposition, audioMix) = try await assemble(
            scene, fixture: fixture, composer: composer, forPlayback: false, loopPictureInPicture: 4)
        let size = videoComposition?.renderSize ?? .zero
        let outputSeconds = composition.duration.seconds

        let baseline = baselineBytes ?? memoryFootprint()
        let peak = OSAllocatedUnfairLock(initialState: baseline)
        let sampler = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                let now = memoryFootprint()
                peak.withLock { $0 = max($0, now) }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        defer { sampler.cancel() }
        let clock = ContinuousClock()
        let started = clock.now
        let url = try await composer.export(composition: composition, videoComposition: videoComposition,
                                            audioMix: audioMix)
        let elapsed = clock.now - started
        defer { try? FileManager.default.removeItem(at: url) }
        let last = memoryFootprint()
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
        return StudioSelfCheck.Timing(
            outputSeconds: outputSeconds, width: Int(size.width), height: Int(size.height),
            exportSeconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
            baselineBytes: baseline, peakBytes: peak.withLock { max($0, last) }, fileBytes: bytes)
    }

    /// The app's memory footprint in bytes (the number Xcode's memory gauge shows); 0 if unknown.
    static func memoryFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    // MARK: The overlay reference

    /// Render `StudioOverlayReference.scenes` through today's export (the Core Animation tool
    /// draws the text, stickers, climb tags and heart-rate tile) and save every frame as a PNG
    /// in `directory`, with a manifest. `directory` is emptied first. Returns the files written,
    /// the manifest last.
    static func captureOverlayReference(into directory: URL, machine: StudioSelfCheck.Machine,
                                        device: String, capturedAt: String) async throws -> [URL] {
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixtureDirectory = newFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        let fixture = try await Task.detached(priority: .userInitiated) {
            try makeFixture([.overlayBase], in: fixtureDirectory)
        }.value
        var files: [URL] = []
        var sizes: [String: (width: Int, height: Int)] = [:]
        for scene in StudioOverlayReference.scenes {
            let images = try await frames(of: scene, fixture: fixture, path: .export)
            for (frame, image) in zip(scene.frames, images) {
                guard let data = pngData(image) else { throw Failure.frame("frame \(frame) of \(scene.id)") }
                let url = directory.appendingPathComponent(scene.fileName(frame: frame))
                try data.write(to: url)
                files.append(url)
                sizes[scene.id] = (image.width, image.height)
            }
        }
        let manifest = StudioOverlayReference.manifest(machine: machine, device: device,
                                                       capturedAt: capturedAt, sizes: sizes)
        let manifestURL = directory.appendingPathComponent(StudioOverlayReference.manifestName)
        try StudioOverlayReference.encoded(manifest).write(to: manifestURL)
        files.append(manifestURL)
        return files
    }

    // MARK: Images

    /// A `CGImage` as sRGB bytes.
    static func image(_ cgImage: CGImage) -> StudioGoldenImage? {
        let w = cgImage.width, h = cgImage.height
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        for i in stride(from: 3, to: bytes.count, by: 4) { bytes[i] = 255 }
        return StudioGoldenImage(width: w, height: h, rgba: bytes)
    }

    static func cgImage(_ image: StudioGoldenImage) -> CGImage? {
        guard image.width > 0, image.height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(image.rgba) as CFData) else { return nil }
        return CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: image.width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    static func pngData(_ image: StudioGoldenImage) -> Data? {
        guard let cgImage = cgImage(image) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, cgImage, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    static func image(pngData data: Data) -> StudioGoldenImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return image(cgImage)
    }

    // MARK: Golden images in the app

    /// The folder the Debug build copies the golden images into (`project.yml`, "Copy Studio
    /// golden frames"). They are not in a Release build.
    static let bundleFolder = "StudioGoldenFrames"

    static func bundledGoldenURL(_ name: String) -> URL? {
        Bundle.main.resourceURL?.appendingPathComponent(bundleFolder).appendingPathComponent(name)
    }

    /// A golden image from the app bundle, or `nil` when it is not there.
    static func bundledGolden(_ name: String) -> StudioGoldenImage? {
        guard let url = bundledGoldenURL(name), let data = try? Data(contentsOf: url) else { return nil }
        return image(pngData: data)
    }
}
#endif
