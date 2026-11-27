import Foundation
import Photos
import os

/// Reports where the Studio's Photos videos are, and downloads the ones that are only in iCloud
/// (prompt 302). The view model asks this BEFORE it asks `StudioComposer` for a preview, so the
/// composer is only handed clips that are on this phone and the user sees why a clip is not there.
/// A protocol, so the view model's tests pass a stand-in (the simulator has no real assets).
protocol StudioMediaAvailabilityChecking: Sendable {
    /// One status per given Photos identifier.
    func statuses(for localIdentifiers: [String]) async -> [String: StudioAssetStatus]
    /// Download an iCloud video so it can be opened without the network. `progress` reports 0…1.
    /// Cancelling the calling Task cancels the download and throws `CancellationError`.
    func download(localIdentifier: String,
                  progress: @escaping @MainActor @Sendable (Double) -> Void) async throws
}

/// The device edge: PhotoKit only, no decisions. What to show for a status is decided by the pure
/// `StudioMediaPlan`.
struct StudioMediaAvailabilityService: StudioMediaAvailabilityChecking {

    enum DownloadError: LocalizedError {
        case assetMissing
        case failed(String?)
        var errorDescription: String? {
            switch self {
            case .assetMissing: return "The clip is no longer in Photos."
            case .failed(let reason): return reason ?? "The clip couldn't be downloaded."
            }
        }
    }

    func statuses(for localIdentifiers: [String]) async -> [String: StudioAssetStatus] {
        let ids = Array(Set(localIdentifiers))
        #if targetEnvironment(simulator)
        // The simulator's sessions carry made-up identifiers. Reporting them all as deleted would
        // put the "can't be found" panel over every Studio there; the simulator keeps its own
        // placeholder ("Preview renders on a device") instead.
        return Dictionary(uniqueKeysWithValues: ids.map { ($0, StudioAssetStatus.available) })
        #else
        var found: [String: PHAsset] = [:]
        PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { asset, _, _ in
            found[asset.localIdentifier] = asset
        }
        var result: [String: StudioAssetStatus] = [:]
        // Not returned by Photos: deleted, or outside what the user lets Snappet see.
        for id in ids where found[id] == nil { result[id] = .missing }
        let probes = found.map { (id: $0.key, asset: $0.value) }
        await withTaskGroup(of: (String, StudioAssetStatus).self) { group in
            for probe in probes {
                group.addTask { (probe.id, await Self.localStatus(of: probe.asset)) }
            }
            for await (id, status) in group { result[id] = status }
        }
        return result
        #endif
    }

    func download(localIdentifier: String,
                  progress: @escaping @MainActor @Sendable (Double) -> Void) async throws {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject
        else { throw DownloadError.assetMissing }
        // The SAME request the composer makes (current version, high quality), with the network
        // allowed and progress reported — so what is downloaded is what the composer then opens.
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.progressHandler = { fraction, _, _, _ in
            Task { @MainActor in progress(fraction) }
        }
        let request = DownloadRequest()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard request.begin(continuation) else { return }   // cancelled before it started
                let id = PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                    let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                    let reason = (info?[PHImageErrorKey] as? NSError)?.localizedDescription
                    if avAsset != nil {
                        request.finish(.success(()))
                    } else if cancelled {
                        request.finish(.failure(CancellationError()))
                    } else {
                        request.finish(.failure(DownloadError.failed(reason)))
                    }
                }
                request.started(id)
            }
        } onCancel: {
            request.cancel()
        }
    }

    // MARK: Private

    #if !targetEnvironment(simulator)
    /// Ask for the video with the network OFF. An asset comes back → it is on this phone. Nothing
    /// comes back and Photos says it is in iCloud → it needs a download. Nothing comes back for
    /// any other reason → reported as available, so the composer tries it exactly as it did before
    /// this check existed (a wrong "missing" would block export of a good clip).
    private static func localStatus(of asset: PHAsset) async -> StudioAssetStatus {
        guard asset.mediaType == .video else { return .available }
        // Photos may never call back; after the limit the clip counts as available (prompt 303).
        let answer = await StudioFirstAnswer.wait(
            seconds: StudioAvailabilityProbe.timeoutSec,
            otherwise: StudioAvailabilityProbe.Answer.noAnswer) { answer in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = false
            options.deliveryMode = .highQualityFormat
            let id = PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                let inCloud = (info?[PHImageResultIsInCloudKey] as? Bool) ?? false
                answer(avAsset != nil ? .onPhone : (inCloud ? .inCloud : .noReason))
            }
            return { PHImageManager.default().cancelImageRequest(id) }
        }
        return StudioAvailabilityProbe.status(answer)
    }
    #endif

    /// One download's request id and continuation behind a lock, so the Photos callback and a
    /// cancel (which can arrive on any thread, before or after the request starts) resume the
    /// continuation exactly once. Photos may never call back for a cancelled request.
    private final class DownloadRequest: Sendable {
        private struct State {
            var requestID: PHImageRequestID?
            var cancelled = false
            var continuation: CheckedContinuation<Void, Error>?
        }
        private let state = OSAllocatedUnfairLock(initialState: State())

        /// Returns false (and resumes with a cancellation) if the task was already cancelled.
        func begin(_ continuation: CheckedContinuation<Void, Error>) -> Bool {
            let alreadyCancelled = state.withLock { s -> Bool in
                if s.cancelled { return true }
                s.continuation = continuation
                return false
            }
            if alreadyCancelled { continuation.resume(throwing: CancellationError()) }
            return !alreadyCancelled
        }

        func started(_ id: PHImageRequestID) {
            let cancelNow = state.withLock { s -> Bool in
                s.requestID = id
                return s.cancelled
            }
            if cancelNow { PHImageManager.default().cancelImageRequest(id) }
        }

        func finish(_ result: Result<Void, Error>) {
            let continuation = state.withLock { s -> CheckedContinuation<Void, Error>? in
                defer { s.continuation = nil }
                return s.continuation
            }
            continuation?.resume(with: result)
        }

        func cancel() {
            let (id, continuation) = state.withLock { s -> (PHImageRequestID?, CheckedContinuation<Void, Error>?) in
                s.cancelled = true
                defer { s.continuation = nil }
                return (s.requestID, s.continuation)
            }
            if let id { PHImageManager.default().cancelImageRequest(id) }
            continuation?.resume(throwing: CancellationError())
        }
    }
}

/// One answer from a callback API, or a fallback when it does not come in time (prompt 303).
/// The callback and the time limit can arrive on any thread and in any order; the caller is
/// resumed once, with whichever came first. No Photos here, so the unit tests run it.
enum StudioFirstAnswer {
    /// `start` begins the request and is given the function to call with its answer. It may
    /// return a way to cancel the request, which is called when the time limit wins.
    static func wait<T: Sendable>(
        seconds: Double, otherwise fallback: T,
        _ start: @Sendable (@escaping @Sendable (T) -> Void) -> (@Sendable () -> Void)?
    ) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            let pending = OSAllocatedUnfairLock<CheckedContinuation<T, Never>?>(initialState: continuation)
            let take: @Sendable () -> CheckedContinuation<T, Never>? = {
                pending.withLock { waiting in
                    defer { waiting = nil }
                    return waiting
                }
            }
            let cancel = start { answer in take()?.resume(returning: answer) }
            Task {
                try? await Task.sleep(for: .seconds(max(0, seconds)))
                guard let waiting = take() else { return }
                cancel?()
                waiting.resume(returning: fallback)
            }
        }
    }
}
