import Photos
import UIKit

/// A still from Photos, asked for from outside any actor (prompt 322 follow-up).
///
/// `requestImage`'s result handler is a plain, non-`Sendable` block. Written inside main-actor code
/// (a SwiftUI view, a `@MainActor` class) it becomes a main-actor closure, and Swift 6 stops the app
/// if Photos ever calls it off the main thread. Photos calls it on the main thread today for these
/// asynchronous high-quality requests, but nothing promises that; built here, the handler belongs to
/// no actor and only resumes a continuation.
enum PhotosImageRequest {
    /// One high-quality image (the handler is called once), or nil when Photos has none.
    /// `network: false` keeps it to what is on this phone.
    nonisolated static func image(for asset: PHAsset, targetSize: CGSize, contentMode: PHImageContentMode,
                                  network: Bool) async -> UIImage? {
        await withCheckedContinuation { cont in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = network
            options.isSynchronous = false
            PHImageManager.default().requestImage(for: asset, targetSize: targetSize,
                                                  contentMode: contentMode, options: options) { image, _ in
                cont.resume(returning: image)
            }
        }
    }
}
