import XCTest
import AVFoundation
import Photos
@testable import Snappet

/// Prompt 322: "Save to original" and "Replace original" quit the app on a phone. Photos runs a
/// change block on its own queue; the blocks were formed inside the main-actor `ClipBakeService`,
/// so Swift 6 made them main-actor closures and its runtime check stopped the app the moment
/// Photos ran one (`dispatch_assert_queue_fail` ← `swift_task_checkIsolated`).
///
/// These tests call the REAL bake writes against the simulator's Photos library, on a video each
/// test adds itself. Before the fix the test process stops in the change block (the same trap as
/// the phone); after it, the writes land. They need full Photos access for the app on the
/// simulator and are skipped without it; they never ask (an unanswered system dialog would stay
/// up and block the UI tests that run next). On the iOS 26.5 simulator `simctl privacy … grant
/// photos` is stored but not honoured, so access is given once by answering the app's Photos
/// dialog with "Allow Full Access"; it then lasts for that simulator (`PhotosAccessGrantUITests`
/// does that tap). Parallel testing runs on clones that do not carry the grant (skipped there):
/// run with `-parallel-testing-enabled NO`. CI does exactly this in the SnappetTests leg, with
/// `SNAPPET_REQUIRE_PHOTOS=1`, which turns the skip into a failure so a lost grant cannot pass
/// silently.
///
/// The test videos are NOT deleted afterwards: Photos asks the user before an app deletes
/// anything, and that dialog would also stay up. They are tiny grey videos in the simulator's
/// library (three per run), never on a phone.
@MainActor
final class ClipBakePhotosIsolationTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status != .authorized else { return }
        let why = "Full Photos access is not granted to the app on this simulator (status \(status.rawValue)): "
            + "run PhotosAccessGrantUITests with SNAPPET_GRANT_PHOTOS=1, or answer the app's Photos prompt "
            + "with \"Allow Full Access\""
        if ProcessInfo.processInfo.environment["SNAPPET_REQUIRE_PHOTOS"] == "1" {
            XCTFail(why)   // CI's Photos step: these tests must run, not skip
            throw XCTSkip(why)
        }
        throw XCTSkip(why)
    }

    /// The revertible bake: the rendered video becomes the asset's edited rendition.
    func testSaveToOriginalWritesTheRenditionWithoutStoppingTheApp() async throws {
        let original = try await addVideo(seconds: 2)
        let rendered = try Self.shortVideo(seconds: 1)
        defer { try? FileManager.default.removeItem(at: rendered) }

        try await ClipBakeService().saveToOriginal(renderedURL: rendered, localIdentifier: original,
                                                   projectID: UUID())

        XCTAssertEqual(ClipBakeService.hasEditedRendition(localIdentifier: original), true,
                       "the asset carries the baked rendition")
        let length = try XCTUnwrap(ClipBakeService.currentDuration(localIdentifier: original))
        XCTAssertEqual(length, 1, accuracy: 0.2, "the asset now plays the 1 s render, not the 2 s original")
    }

    /// The destructive bake's first change block (saving the render as a new asset). The original is
    /// an identifier that is not in the library, so the second block (the deletion, which shows the
    /// system's delete dialog that a unit test cannot answer) does not run; it is built the same way
    /// as the two blocks these tests run (`ClipBakeService.PhotosChange`).
    func testReplaceOriginalSavesTheRenderWithoutStoppingTheApp() async throws {
        let rendered = try Self.shortVideo(seconds: 1)
        defer { try? FileManager.default.removeItem(at: rendered) }

        let newID = try await ClipBakeService().replaceOriginal(renderedURL: rendered,
                                                                oldLocalIdentifier: "322-not-in-the-library/L0/001")

        let asset = try XCTUnwrap(PHAsset.fetchAssets(withLocalIdentifiers: [newID], options: nil).firstObject,
                                  "the render was saved as a new asset")
        XCTAssertEqual(asset.mediaType, .video)
    }

    // MARK: - Helpers

    /// Adds a fresh test video to Photos and returns its identifier.
    private func addVideo(seconds: Double) async throws -> String {
        let url = try Self.shortVideo(seconds: seconds)
        defer { try? FileManager.default.removeItem(at: url) }
        return try await Self.saveToPhotos(url)
    }

    /// `nonisolated`: the change block is then not a main-actor closure (the fix under test).
    nonisolated private static func saveToPhotos(_ url: URL) async throws -> String {
        let idBox = IDBox()
        try await PHPhotoLibrary.shared().performChanges {
            idBox.value = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)?
                .placeholderForCreatedAsset?.localIdentifier
        }
        return try XCTUnwrap(idBox.value)
    }

    private final class IDBox: @unchecked Sendable { var value: String? }

    /// A real, very small H.264 video of the given length.
    nonisolated private static func shortVideo(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bake322-\(UUID().uuidString).mp4")
        let side = 32, fps: Int32 = 30
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: side, AVVideoHeightKey: side])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: side, kCVPixelBufferHeightKey as String: side])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let frames = Int(seconds * Double(fps))
        var index = 0
        while index < frames {
            guard input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { usleep(1_000); continue }
            var made: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
            let buffer = try XCTUnwrap(made)
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, 128, CVPixelBufferGetBytesPerRow(buffer) * side)
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: fps))
            index += 1
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frames), timescale: fps))
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        XCTAssertEqual(writer.status, .completed)
        return url
    }
}
