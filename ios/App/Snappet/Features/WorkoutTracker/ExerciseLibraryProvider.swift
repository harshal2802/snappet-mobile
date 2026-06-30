import Foundation

/// Default URL for the exercise library JSON in the Snappet web repo.
/// Override via the Advanced section of `ExerciseLibraryImportView`.
let exerciseLibraryDefaultURL =
    "https://raw.githubusercontent.com/harshal2802/Snappet/main/exercises-dataset/data/exercises.json"

// MARK: - Provider protocol

/// The network/IO edge for bringing the exercise library onto the device. The caller
/// (`ExerciseCatalogInstaller`) validates the result and hands it to `ExerciseLibraryStore`.
protocol ExerciseCatalogProvider: Sendable {
    var displayName: String { get }
    /// Produce a local JSON temp file. `progress` is 0…1 (best-effort).
    func fetch(progress: @escaping @Sendable (Double) -> Void) async throws -> URL
}

// MARK: - Network provider

/// Fetches the exercise catalog JSON from the Snappet web repo (or any configured URL),
/// validates it, and returns a local temp file — the **only** network egress for this feature.
/// User-initiated; no analytics; nothing uploaded; health + media never leave the device.
struct NetworkExerciseCatalogProvider: ExerciseCatalogProvider {
    let urlString: String
    var displayName: String { "Snappet exercise library" }

    func fetch(progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard let url = URL(string: urlString) else {
            throw ExerciseLibraryError.invalidURL(urlString)
        }

        let tempDir = FileManager.default.temporaryDirectory
        let tempURL = tempDir.appendingPathComponent("exercise-library-\(UUID().uuidString).json")

        let (fileURL, response) = try await URLSession.shared.download(from: url)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: fileURL)
            throw ExerciseLibraryError.httpError(http.statusCode)
        }

        if FileManager.default.fileExists(atPath: tempURL.path) {
            try FileManager.default.removeItem(at: tempURL)
        }
        try FileManager.default.moveItem(at: fileURL, to: tempURL)
        progress(1)
        return tempURL
    }
}

// MARK: - Installer

/// Orchestrates fetch → validate → install for any provider, exposing a `phase` the UI observes.
/// One place owns the "bring the exercise library onto the device" flow.
@MainActor
@Observable
final class ExerciseCatalogInstaller {
    enum Phase: Equatable {
        case idle
        case working(Double)
        case failed(String)
        case installed
    }

    private(set) var phase: Phase = .idle
    private let store = ExerciseLibraryStore.shared

    var isInstalled: Bool { store.isInstalled }
    var metadata: ExerciseLibraryMeta? { store.metadata() }

    func install(using provider: ExerciseCatalogProvider) async {
        phase = .working(0)
        var produced: URL?
        do {
            let url = try await provider.fetch { fraction in
                Task { @MainActor in
                    if case .working = self.phase { self.phase = .working(fraction) }
                }
            }
            produced = url
            let validated = try ExerciseLibraryValidator.validate(url)
            let meta = ExerciseLibraryMeta(
                exerciseCount: validated.count,
                sizeBytes: validated.sizeBytes,
                source: provider.displayName,
                installedAt: .now
            )
            try store.install(from: url, meta: meta)
            phase = .installed
            store.postDidChange()
        } catch {
            if let produced, FileManager.default.fileExists(atPath: produced.path) {
                try? FileManager.default.removeItem(at: produced)
            }
            phase = .failed(error.localizedDescription)
        }
    }

    func remove() {
        do {
            try store.clear()
            phase = .idle
            store.postDidChange()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

// MARK: - Validator

enum ExerciseLibraryValidator {
    struct ValidatedCatalog: Sendable {
        let count: Int
        let sizeBytes: Int64
    }

    /// Ensure the temp file is a valid JSON array of Exercise-shaped objects.
    /// Throws `ExerciseLibraryError.invalidCatalog` with a description on failure.
    static func validate(_ url: URL) throws -> ValidatedCatalog {
        let data = try Data(contentsOf: url)
        let sizeBytes = Int64(data.count)

        // Lenient decode — reuses Exercise's existing lenient decoder.
        let exercises: [Exercise]
        do {
            exercises = try JSONDecoder().decode([Exercise].self, from: data)
        } catch {
            throw ExerciseLibraryError.invalidCatalog("Not a valid exercise JSON array: \(error.localizedDescription)")
        }

        guard !exercises.isEmpty else {
            throw ExerciseLibraryError.invalidCatalog("The catalog contains no exercises.")
        }

        return ValidatedCatalog(count: exercises.count, sizeBytes: sizeBytes)
    }
}

// MARK: - Errors

enum ExerciseLibraryError: LocalizedError {
    case invalidURL(String)
    case httpError(Int)
    case invalidCatalog(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let s):   return "Invalid URL: \(s)"
        case .httpError(let code): return "Download failed (HTTP \(code))."
        case .invalidCatalog(let msg): return "Invalid catalog: \(msg)"
        }
    }
}
