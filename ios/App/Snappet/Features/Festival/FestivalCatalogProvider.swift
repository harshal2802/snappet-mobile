import Foundation
import SwiftData

/// Default host for the festival lineup packs + `manifest.json` — the Snappet Pages site's
/// `music-festivals/` directory, sibling of the Kilter `board-data/` (same posture: static files on
/// a user-controlled host, ONE user-initiated GET per pack, nothing uploaded, offline forever after —
/// festivals have no signal).
let festivalDefaultCatalogHost = "https://harshal2802.github.io/Snappet/music-festivals/"

/// One festival in the host's `manifest.json` — everything the browse row shows without touching the
/// pack itself. `file` is relative to the host (or absolute via `url`, the Kilter manifest pattern).
struct FestivalLineupEntry: Codable, Sendable, Identifiable, Equatable {
    let id: String            // pack-author slug, matches FestivalPack.id
    let name: String
    let location: String
    let startDate: String     // yyyy-MM-dd
    let endDate: String
    let file: String
    var url: String?
    let stages: Int
    let sets: Int
    let sizeBytes: Int?
    let updatedAt: String?
}

struct FestivalLineupManifest: Codable, Sendable {
    let festivals: [FestivalLineupEntry]
}

// MARK: - Pure browse logic (unit-tested without a network or a store)

/// The state a browse row renders — the pure mapping from (manifest entry, installed packIDs,
/// in-flight install) the sheet's rows switch over.
enum FestivalBrowseRowState: Equatable {
    case get
    case installing(Double)
    case installed
}

enum FestivalBrowse {
    /// Which state a manifest entry's row shows. An entry mid-install shows progress; an installed
    /// one shows ✓ (and stays tappable — re-install replaces the row, how lineup revisions arrive).
    static func rowState(entry: FestivalLineupEntry, installedPackIDs: Set<String>,
                         installingPackID: String?, progress: Double) -> FestivalBrowseRowState {
        if entry.id == installingPackID { return .installing(progress) }
        return installedPackIDs.contains(entry.id) ? .installed : .get
    }

    /// Case/diacritic-insensitive substring search over name + location, plus an optional year chip
    /// (matched against the startDate's year). Order is preserved (the manifest is curated).
    static func filter(_ entries: [FestivalLineupEntry], query: String, year: String?) -> [FestivalLineupEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return entries.filter { entry in
            if let year, !entry.startDate.hasPrefix(year) { return false }
            guard !q.isEmpty else { return true }
            return entry.name.localizedCaseInsensitiveContains(q)
                || entry.location.localizedCaseInsensitiveContains(q)
        }
    }

    /// The year chips offered above the list — the distinct startDate years present, ascending.
    static func years(in entries: [FestivalLineupEntry]) -> [String] {
        Array(Set(entries.compactMap { $0.startDate.count >= 4 ? String($0.startDate.prefix(4)) : nil }))
            .sorted()
    }

    /// "Jun 24–28 · 9 stages · 412 sets" — the browse/lineup row's meta line, from poster dates.
    static func metaLine(startDate: String, endDate: String, stages: Int, sets: Int) -> String {
        "\(dateRange(startDate: startDate, endDate: endDate)) · \(stages) stages · \(sets) sets"
    }

    /// "Jun 24–28" (same month) / "Aug 30 – Sep 1" (across months) / the raw string when unparseable.
    static func dateRange(startDate: String, endDate: String) -> String {
        guard let s = posterDateComponents(startDate), let e = posterDateComponents(endDate) else {
            return startDate == endDate ? startDate : "\(startDate) – \(endDate)"
        }
        // Fixed English month labels: `Calendar.shortMonthSymbols` follows the process locale,
        // which is unset under XCTest ("M06") — and every other label in the app is English.
        var monthCal = Calendar(identifier: .gregorian)
        monthCal.locale = Locale(identifier: "en_US")
        let months = monthCal.shortMonthSymbols
        let sm = months[s.month - 1], em = months[e.month - 1]
        if s.month == e.month && s.year == e.year {
            return s.day == e.day ? "\(sm) \(s.day)" : "\(sm) \(s.day)–\(e.day)"
        }
        return "\(sm) \(s.day) – \(em) \(e.day)"
    }

    private static func posterDateComponents(_ date: String) -> (year: Int, month: Int, day: Int)? {
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        return (parts[0], parts[1], parts[2])
    }
}

// MARK: - Providers (the module's only network / file I/O)

enum FestivalCatalogError: LocalizedError {
    case http(Int)
    case emptyDownload
    case unreadableFile

    var errorDescription: String? {
        switch self {
        case .http(let code):
            return "Couldn't reach the lineup host (HTTP \(code)). Check your connection and try again."
        case .emptyDownload:
            return "The download was empty. Try again."
        case .unreadableFile:
            return "Couldn't read that file."
        }
    }
}

/// The I/O edge for getting a pack's BYTES onto the device — everything after (decode → validate →
/// store) is identical for every source, so the reader never learns where bytes came from (the
/// `KilterCatalogProvider` posture). Packs are tens of KB, so providers yield `Data` directly.
protocol FestivalPackProvider: Sendable {
    /// The `FestivalLineup.sourceLabel` for a pack installed through this provider.
    var sourceLabel: String { get }
    func fetch(progress: @escaping @Sendable (Double) -> Void) async throws -> Data
}

/// Fetches `manifest.json` + pack files from the hosted `music-festivals/` directory.
struct FestivalCatalogClient: Sendable {
    let baseURL: String
    private let session: URLSession

    init(baseURL: String = festivalDefaultCatalogHost) {
        self.baseURL = baseURL.hasSuffix("/") ? baseURL : baseURL + "/"
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    private func absolute(_ path: String) -> URL? {
        if let u = URL(string: path), u.scheme != nil { return u }
        return URL(string: baseURL + path)
    }

    func manifest() async throws -> [FestivalLineupEntry] {
        let data = try await get("manifest.json") { _ in }
        return try JSONDecoder().decode(FestivalLineupManifest.self, from: data).festivals
    }

    func get(_ path: String, progress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        guard let url = absolute(path) else { throw FestivalCatalogError.http(0) }
        let (bytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse else { throw FestivalCatalogError.http(0) }
        guard (200..<300).contains(http.statusCode) else {
            throw FestivalCatalogError.http(http.statusCode)
        }
        let total = http.expectedContentLength
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            // A pack is tiny; still cap what we'll buffer so a mispointed URL can't balloon memory.
            if data.count > FestivalPack.maxPackBytes { break }
            if total > 0, data.count % 4096 == 0 {
                progress(min(1, Double(data.count) / Double(total)))
            }
        }
        guard !data.isEmpty else { throw FestivalCatalogError.emptyDownload }
        progress(1)
        return data
    }
}

/// One GET of a hosted `.fpack` — the browse sheet's install path.
struct HostedFestivalPackProvider: FestivalPackProvider {
    let entry: FestivalLineupEntry
    var baseURL: String = festivalDefaultCatalogHost
    var sourceLabel: String { "Snappet Lineups" }

    func fetch(progress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        try await FestivalCatalogClient(baseURL: baseURL)
            .get(entry.url ?? entry.file, progress: progress)
    }
}

/// The power-user path: a `.fpack` the user already has (Files / AirDrop), exactly the Kilter
/// `.sqlite3` import posture — nothing is fetched from a network.
struct FestivalFilePackProvider: FestivalPackProvider {
    let pickedURL: URL
    var sourceLabel: String { "Imported file" }

    func fetch(progress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        let scoped = pickedURL.startAccessingSecurityScopedResource()
        defer { if scoped { pickedURL.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: pickedURL) else {
            throw FestivalCatalogError.unreadableFile
        }
        progress(1)
        return data
    }
}

// MARK: - Installer (fetch → decode → validate → store, one funnel)

/// Orchestrates provider → `FestivalPack.decode` → `FestivalPackValidator` → `FestivalLineup` row,
/// exposing a small `phase` the empty state and the browse sheet both observe (the
/// `KilterCatalogInstaller` shape). Every source funnels through here, so a malformed pack is
/// rejected with the validator's message verbatim and never half-installs.
@MainActor
@Observable
final class FestivalLineupInstaller {
    enum Phase: Equatable {
        case idle
        case working(Double)
        case failed(String)
        case installed(packID: String)
    }

    private(set) var phase: Phase = .idle
    /// The manifest entry currently downloading (drives the browse row's inline progress bar).
    private(set) var installingPackID: String?

    var isWorking: Bool { if case .working = phase { return true } else { return false } }
    var progress: Double { if case .working(let f) = phase { return f } else { return 0 } }

    /// Run a provider end-to-end. On success the lineup is inserted (or replaced, same `packID` —
    /// how lineup revisions arrive; stars/attendance survive because set ids are content-derived).
    /// Returns the installed row, or `nil` on failure (with `phase == .failed` carrying the message).
    @discardableResult
    func install(using provider: FestivalPackProvider, entryID: String? = nil,
                 into context: ModelContext) async -> FestivalLineup? {
        phase = .working(0)
        installingPackID = entryID
        defer { installingPackID = nil }
        do {
            let data = try await provider.fetch { fraction in
                Task { @MainActor in
                    if case .working = self.phase { self.phase = .working(fraction) }
                }
            }
            let pack = try FestivalPack.decode(fpack: data)
            let validated = try FestivalPackValidator.validate(pack)
            let lineup = FestivalLineup(packID: pack.id, name: pack.name, location: pack.location,
                                        startDate: pack.startDate, endDate: pack.endDate,
                                        utcOffsetSeconds: pack.utcOffsetSeconds,
                                        stageCount: validated.stageCount,
                                        setCount: validated.setCount,
                                        sourceLabel: provider.sourceLabel,
                                        fpackData: data)
            // Replace-on-reinstall: one row per festival, keyed by the pack-author slug.
            let packID = pack.id
            let existing = (try? context.fetch(FetchDescriptor<FestivalLineup>(
                predicate: #Predicate { $0.packID == packID }))) ?? []
            existing.forEach { context.delete($0) }
            context.insert(lineup)
            try context.save()
            phase = .installed(packID: pack.id)
            return lineup
        } catch {
            phase = .failed(error.localizedDescription)
            return nil
        }
    }

    /// Install an ALREADY-decoded pack — the festival-prompt-05 QR-payload path, where the pack rode in
    /// the code (no fetch, no re-decode). Validates, re-emits the verbatim `.fpack` bytes, and inserts
    /// (replace-on-reinstall by `packID`, exactly like `install(using:)`). Returns the row, or nil on a
    /// validation failure (with `phase == .failed`). Synchronous — there's no I/O.
    @discardableResult
    func install(pack: FestivalPack, sourceLabel: String, into context: ModelContext) -> FestivalLineup? {
        do {
            let validated = try FestivalPackValidator.validate(pack)
            let data = try pack.fpackData()
            let lineup = FestivalLineup(packID: pack.id, name: pack.name, location: pack.location,
                                        startDate: pack.startDate, endDate: pack.endDate,
                                        utcOffsetSeconds: pack.utcOffsetSeconds,
                                        stageCount: validated.stageCount,
                                        setCount: validated.setCount,
                                        sourceLabel: sourceLabel, fpackData: data)
            let packID = pack.id
            let existing = (try? context.fetch(FetchDescriptor<FestivalLineup>(
                predicate: #Predicate { $0.packID == packID }))) ?? []
            existing.forEach { context.delete($0) }
            context.insert(lineup)
            try context.save()
            phase = .installed(packID: pack.id)
            return lineup
        } catch {
            phase = .failed(error.localizedDescription)
            return nil
        }
    }

    /// Handle a Files-importer result by routing the picked URL through the file provider.
    func importPicked(_ result: Result<[URL], Error>, into context: ModelContext) async {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            await install(using: FestivalFilePackProvider(pickedURL: url), into: context)
        case .failure(let error):
            phase = .failed(error.localizedDescription)
        }
    }

    func resetPhase() { phase = .idle }
}
