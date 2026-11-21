import AVFoundation
import Foundation
import ObjectiveC

// Prompt 276: play a large clip straight from Google Drive. Drive serves a file in byte ranges; the
// player asks for the parts it needs and this hands them over, signed with the person's Google
// account. The range arithmetic is pure (`MediaVaultFetch`); this file is the thin edge.

/// Reads pieces of one Drive file.
struct MediaVaultRangeReader: Sendable {
    let google: GoogleAuthorizedHTTP
    let fileID: String
    let total: Int64

    /// Exactly the bytes of `range`. Throws when Drive answers with anything else, so a reply that
    /// ignored the range can never be played as if it were the right part of the file.
    func read(_ range: Range<Int64>) async throws -> Data {
        var request = GoogleDriveAPI.download(id: fileID)
        request.setValue(MediaVaultFetch.rangeHeader(range), forHTTPHeaderField: "Range")
        let (data, response) = try await google.send(request)
        let wanted = Int(range.upperBound - range.lowerBound)
        if response.statusCode == 206, data.count == wanted { return data }
        // A server may answer a range that covers the whole file with a plain 200.
        if response.statusCode == 200, Int64(data.count) == total, range.upperBound <= total {
            return data.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
        }
        throw MediaVaultFailure("Google Drive did not send the part of the clip that was asked for.")
    }
}

enum MediaVaultStream {
    static let scheme = "snappet-vault"
    private nonisolated(unsafe) static var loaderKey: UInt8 = 0

    /// An asset the player can open; its bytes come through `reader`.
    static func asset(reader: MediaVaultRangeReader, fileExtension: String) -> AVURLAsset {
        // The extension is what AVFoundation reads the container from on a custom scheme.
        let url = URL(string: "\(scheme)://clip/\(reader.fileID).\(fileExtension)")!
        let asset = AVURLAsset(url: url)
        let loader = MediaVaultStreamLoader(reader: reader, contentType: MediaVaultFetch.contentType(fileExtension: fileExtension))
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        // The resource loader holds its delegate weakly: tie the loader's life to the asset's.
        objc_setAssociatedObject(asset, &loaderKey, loader, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return asset
    }
}

/// Answers the player's requests for parts of the file. One task per request; cancelled with it.
final class MediaVaultStreamLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.snappet.app.vault-stream")
    private let reader: MediaVaultRangeReader
    private let contentType: String
    private let lock = NSLock()
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(reader: MediaVaultRangeReader, contentType: String) {
        self.reader = reader
        self.contentType = contentType
    }

    deinit { lock.withLock { tasks.values.forEach { $0.cancel() } } }

    private struct Request: @unchecked Sendable { let value: AVAssetResourceLoadingRequest }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        let request = Request(value: loadingRequest)
        let key = ObjectIdentifier(loadingRequest)
        let reader = reader, contentType = contentType
        let task = Task { [weak self] in
            await Self.serve(request, reader: reader, contentType: contentType)
            self?.lock.withLock { _ = self?.tasks.removeValue(forKey: key) }
        }
        lock.withLock { tasks[key] = task }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        lock.withLock { tasks.removeValue(forKey: ObjectIdentifier(loadingRequest)) }?.cancel()
    }

    private static func serve(_ request: Request, reader: MediaVaultRangeReader, contentType: String) async {
        let loading = request.value
        if let info = loading.contentInformationRequest {
            info.contentType = contentType
            info.contentLength = reader.total
            info.isByteRangeAccessSupported = true
        }
        guard let data = loading.dataRequest else { loading.finishLoading(); return }
        let offset = data.currentOffset
        let length = data.requestsAllDataToEndOfResource ? reader.total - offset : Int64(data.requestedLength)
        do {
            for piece in MediaVaultFetch.chunks(offset: offset, length: length, total: reader.total) {
                if Task.isCancelled || loading.isCancelled { return }
                let bytes = try await reader.read(piece)
                if Task.isCancelled || loading.isCancelled { return }
                data.respond(with: bytes)
            }
            loading.finishLoading()
        } catch {
            if !(Task.isCancelled || loading.isCancelled) { loading.finishLoading(with: error) }
        }
    }
}
