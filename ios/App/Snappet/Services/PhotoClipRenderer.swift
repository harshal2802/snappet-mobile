import Foundation
import AVFoundation
import Photos
import UIKit
import CoreGraphics

/// Renders a still photo (a `PHAsset`) into a short **Ken-Burns** (slow zoom + pan)
/// H.264 clip so it can be stitched into the reel like any video segment. A still can't
/// be inserted into an `AVMutableCompositionTrack` directly, so we write a real clip
/// with `AVAssetWriter` + a pixel-buffer adaptor, drawing each frame with an
/// interpolated transform.
///
/// Stateless → `Sendable`. All the non-`Sendable` AVFoundation/CG objects live inside
/// the nonisolated async methods and never cross an actor boundary.
final class PhotoClipRenderer: Sendable {

    /// Wraps a non-Sendable value across a single continuation resume (produced/consumed once).
    private struct Box<T>: @unchecked Sendable { let value: T; init(_ v: T) { value = v } }

    private let fps: Int32 = 30

    /// Render `assetId` to a `duration`-second Ken-Burns clip at `size` (portrait by default).
    /// Returns `nil` if the image can't be loaded or the writer fails — the caller skips
    /// this photo rather than failing the whole reel.
    func renderClip(assetId: String,
                    duration: Double,
                    size: CGSize = CGSize(width: 1080, height: 1920)) async -> URL? {
        guard duration > 0, let cg = await loadImage(assetId: assetId, targetSize: size) else { return nil }
        return await write(image: cg, duration: duration, size: size)
    }

    // MARK: - Load the asset's image (oriented, sized to fill)

    private func loadImage(assetId: String, targetSize: CGSize) async -> CGImage? {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil)
        guard let asset = assets.firstObject else { return nil }
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .highQualityFormat
        opts.isNetworkAccessAllowed = true
        opts.resizeMode = .exact
        opts.isSynchronous = false
        let boxed: Box<CGImage?> = await withCheckedContinuation { cont in
            PHImageManager.default().requestImage(
                for: asset, targetSize: targetSize, contentMode: .aspectFill, options: opts
            ) { image, _ in
                cont.resume(returning: Box(image?.cgImageOriented))
            }
        }
        return boxed.value
    }

    // MARK: - Write the Ken-Burns clip

    private func write(image: CGImage, duration: Double, size: CGSize) async -> URL? {
        let w = Int(size.width), h = Int(size.height)
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("snappet-photo-\(UUID().uuidString).mp4")

        guard let writer = try? AVAssetWriter(outputURL: out, fileType: .mp4) else { return nil }
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
            ]
        )
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        guard writer.startWriting() else { return nil }
        writer.startSession(atSourceTime: .zero)

        let totalFrames = max(1, Int(duration * Double(fps)))
        for frame in 0..<totalFrames {
            // Back-pressure: wait until the input can take more data.
            while !input.isReadyForMoreMediaData { await Task.yield() }
            let t = Double(frame) / Double(max(1, totalFrames - 1))   // 0...1 progress
            guard let buffer = makeFrame(image: image, size: size, progress: t, pool: adaptor.pixelBufferPool)
            else { continue }
            let time = CMTime(value: CMTimeValue(frame), timescale: fps)
            adaptor.append(buffer, withPresentationTime: time)
        }
        input.markAsFinished()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writer.finishWriting { cont.resume() }
        }
        return writer.status == .completed ? out : nil
    }

    /// Draw one frame: black canvas, image aspect-filled, with a Ken-Burns zoom (1.0→1.1)
    /// and a gentle horizontal pan that grows with `progress` (0...1).
    private func makeFrame(image: CGImage, size: CGSize, progress: Double,
                           pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        guard let pool else { return nil }
        var pbOut: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut) == kCVReturnSuccess,
              let pb = pbOut else { return nil }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(pb),
            width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return nil }

        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))

        // Aspect-fill the image into the canvas, then zoom/pan over time.
        let imgW = CGFloat(image.width), imgH = CGFloat(image.height)
        let fill = max(size.width / imgW, size.height / imgH)
        let zoom = 1.0 + 0.10 * CGFloat(progress)            // 1.0 → 1.10
        let scale = fill * zoom
        let drawW = imgW * scale, drawH = imgH * scale
        // Center, then pan slightly right as it zooms.
        let pan = (drawW - size.width) * 0.15 * CGFloat(progress)
        let x = (size.width - drawW) / 2 - pan
        let y = (size.height - drawH) / 2
        ctx.draw(image, in: CGRect(x: x, y: y, width: drawW, height: drawH))
        return pb
    }
}

private extension UIImage {
    /// A correctly-oriented `CGImage` (PHImageManager hands back orientation metadata
    /// that a raw `cgImage` ignores). Renders once into an upright bitmap.
    var cgImageOriented: CGImage? {
        if imageOrientation == .up { return cgImage }
        let renderer = UIGraphicsImageRenderer(size: size)
        let upright = renderer.image { _ in draw(in: CGRect(origin: .zero, size: size)) }
        return upright.cgImage
    }
}
