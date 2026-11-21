import Foundation

// MARK: - The clip vault, PURE part (cloud-connect P4, prompt 269)
//
// Opt-in copies of session clips in a "Snappet Clips" folder of the person's Google Drive, so a clip
// outlives its Photos asset: it plays from Drive when the footage is no longer on the phone. Also
// the way OLD footage comes back without phone storage — picked in Google Photos, checked against
// the missing clip, and copied Google → Drive.
//
// No SwiftData field: a vault file CARRIES its `SessionMedia.id` (a private Drive property; the file
// name for copies made before prompt 270), and row ids survive backup/restore, so the index is
// rebuilt from a Drive listing on any phone.

struct MediaVaultSettings: Codable, Equatable, Sendable {
    /// Default OFF: no clip leaves the phone.
    var keepCopies = false
    /// Switching copies on only shows the choices (account, folders, Wi-Fi). Nothing is uploaded
    /// until the person taps "Start copying" (prompt 271). Asked once: switching copies off only
    /// pauses, and switching on again carries on.
    var started = false
    var wifiOnly = true
    /// How the copies are arranged inside "Snappet Clips" (prompt 270).
    var layout = MediaVaultLayout.bySession
    /// The time zone folder and file names are written in. Fixed the first time clips are copied, so
    /// travelling does not rename every folder.
    var timeZoneID: String? = nil
    /// Deleting a clip in Snappet also moves its copy to Drive's trash (prompt 274). On by default;
    /// only ever applies to clips THIS phone had and then deleted.
    var removeWithClip = true
}

extension MediaVaultSettings {
    /// Settings saved before a field existed still load; an unknown layout falls back to the default.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        keepCopies = try values.decodeIfPresent(Bool.self, forKey: .keepCopies) ?? false
        // Settings saved before the Start button: copies that were on were already running.
        started = try values.decodeIfPresent(Bool.self, forKey: .started) ?? keepCopies
        wifiOnly = try values.decodeIfPresent(Bool.self, forKey: .wifiOnly) ?? true
        layout = (try? values.decodeIfPresent(String.self, forKey: .layout)).flatMap { $0 }
            .flatMap(MediaVaultLayout.init(rawValue:)) ?? .bySession
        timeZoneID = try values.decodeIfPresent(String.self, forKey: .timeZoneID)
        removeWithClip = try values.decodeIfPresent(Bool.self, forKey: .removeWithClip) ?? true
    }

    var timeZone: TimeZone { timeZoneID.flatMap(TimeZone.init(identifier:)) ?? .current }
}

// MARK: - Folder layout (prompt 270, pure)

/// How clip copies are arranged in Drive. The person picks one; changing it moves the existing copies.
enum MediaVaultLayout: String, Codable, CaseIterable, Sendable, Identifiable {
    case bySession, byActivity, byMonth, flat

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bySession: "By session"
        case .byActivity: "By activity, then session"
        case .byMonth: "By month"
        case .flat: "One folder"
        }
    }

    /// A sample path, shown under the picker.
    var example: String {
        switch self {
        case .bySession: "Snappet Clips / 2026-11-14 18.42 Climbing"
        case .byActivity: "Snappet Clips / Climbing / 2026-11-14 18.42"
        case .byMonth: "Snappet Clips / 2026 / 11 November"
        case .flat: "Snappet Clips"
        }
    }
}

/// What a clip's place in Drive is made from. Plain values, read off the store at the edge.
struct MediaVaultClipInfo: Equatable, Sendable {
    var capturedAt: Date
    var sessionStartedAt: Date
    /// The SESSION's activity as the Clips tab names it ("Climbing", "Festival", "Other", …) — the
    /// whole session stays in one folder, whatever its individual clips are tagged as.
    var activity: String
    /// The festival's name, on a festival night.
    var festival: String? = nil
    /// The artist this clip is tagged to. In the FILE name, so a later tag renames one file.
    var artist: String? = nil
}

/// Where a clip's copy belongs: folders under "Snappet Clips", and its file name without extension.
struct MediaVaultPlacement: Equatable, Sendable {
    var folders: [String]
    var baseName: String

    func fileName(fileExtension: String) -> String {
        let ext = fileExtension.lowercased().filter { $0.isLetter || $0.isNumber }
        return baseName + "." + (ext.isEmpty ? "bin" : ext)
    }

    /// A short fingerprint of this place. Stored on the Drive file: the app moves a copy only when
    /// the place IT wants changes — never because the person renamed or moved the file themselves.
    var stamp: String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325   // FNV-1a, stable across launches and devices
        for byte in (folders + [baseName]).joined(separator: "/").utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}

enum MediaVaultPaths {
    static let monthNames = ["January", "February", "March", "April", "May", "June", "July", "August",
                             "September", "October", "November", "December"]

    /// Every clip's place. Names are written to the second, so two clips shot in one second in one
    /// folder would share a name (found on the phone: two photos 0.09 s apart). The later ones get
    /// " 2", " 3"… — in capture order, ties by id, so the answer is the same on every pass and phone.
    static func placements(_ infos: [UUID: MediaVaultClipInfo], layout: MediaVaultLayout,
                           timeZone: TimeZone) -> [UUID: MediaVaultPlacement] {
        var out = infos.mapValues { placement($0, layout: layout, timeZone: timeZone) }
        let sharing = Dictionary(grouping: out.keys) { out[$0]!.folders.joined(separator: "/") + "/" + out[$0]!.baseName }
        for ids in sharing.values where ids.count > 1 {
            let ordered = ids.sorted {
                let a = infos[$0]!.capturedAt, b = infos[$1]!.capturedAt
                return a != b ? a < b : $0.uuidString < $1.uuidString
            }
            for (n, id) in ordered.enumerated().dropFirst() { out[id]!.baseName += " \(n + 1)" }
        }
        return out
    }

    static func placement(_ info: MediaVaultClipInfo, layout: MediaVaultLayout, timeZone: TimeZone) -> MediaVaultPlacement {
        let session = parts(info.sessionStartedAt, timeZone)
        let clip = parts(info.capturedAt, timeZone)
        let activity = clean(info.activity)
        let festival = info.festival.map(clean)
        let sessionStamp = "\(session.day) \(session.minute)"
        let folders: [String]
        switch layout {
        case .bySession: folders = ["\(sessionStamp) \(festival ?? activity)"]
        case .byActivity: folders = festival.map { [activity, $0, sessionStamp] } ?? [activity, sessionStamp]
        case .byMonth: folders = [session.year, session.month]
        case .flat: folders = []
        }
        let label = info.artist.map(clean) ?? activity
        return MediaVaultPlacement(folders: folders, baseName: "\(clip.day) \(clip.second) \(label)")
    }

    private static func parts(_ date: Date, _ timeZone: TimeZone)
        -> (year: String, month: String, day: String, minute: String, second: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let (y, m, d) = (c.year ?? 0, c.month ?? 1, c.day ?? 1)
        let (h, mi, s) = (c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        func two(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
        return (String(y), "\(two(m)) \(monthNames[max(1, min(12, m)) - 1])", "\(y)-\(two(m))-\(two(d))",
                "\(two(h)).\(two(mi))", "\(two(h)).\(two(mi)).\(two(s))")
    }

    /// A name safe to show as one Drive folder or file: no path separators or control characters,
    /// single spaces, bounded length.
    static func clean(_ text: String) -> String {
        let mapped = String(text.map { ch -> Character in
            if ch == "/" || ch == "\\" || ch == ":" { return "-" }
            return ch.isNewline || ch.unicodeScalars.allSatisfy({ $0.properties.generalCategory == .control }) ? " " : ch
        })
        let words = mapped.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        let short = String(words.prefix(80)).trimmingCharacters(in: .whitespaces)
        return short.isEmpty ? "Untitled" : short
    }
}

/// The private Drive properties that tie a file to its clip (only Snappet can read them).
enum MediaVaultTag {
    static let markerKey = "snappet", markerValue = "clip"
    static let clipKey = "clip", stampKey = "placed"

    /// How many bytes the phone sent — compared with what Drive says it holds before an original
    /// is ever removed from the phone (prompt 274).
    static let bytesKey = "bytes"
    /// The MD5 of what the phone sent — compared with the checksum Drive computes itself, so a copy
    /// of the right size and the wrong content is caught (prompt 276).
    static let md5Key = "md5"

    static func properties(rowID: UUID, stamp: String?, bytes: Int64? = nil, md5: String? = nil) -> [String: String] {
        var out = [markerKey: markerValue, clipKey: rowID.uuidString.lowercased()]
        if let stamp { out[stampKey] = stamp }
        if let bytes { out[bytesKey] = String(bytes) }
        if let md5 { out[md5Key] = md5.lowercased() }
        return out
    }

    static func clipID(from properties: [String: String]?) -> UUID? {
        guard let properties, properties[markerKey] == markerValue else { return nil }
        return properties[clipKey].flatMap(UUID.init(uuidString:))
    }
}

/// One file as Drive lists it.
struct MediaVaultFile: Equatable, Sendable {
    var id: String
    var name: String
    var byteCount: Int64
    var parentID: String? = nil
    /// From the private properties; nil for a copy made before prompt 270 (then the name says).
    var clipID: UUID? = nil
    var stamp: String? = nil
    var sentBytes: Int64? = nil
    /// Drive's own checksum of what it holds, and the one the phone recorded when it sent the file.
    var md5: String? = nil
    var sentMD5: String? = nil
}

/// A folder Snappet created in Drive.
struct MediaVaultFolder: Equatable, Sendable {
    var id: String
    var name: String
    var parentID: String?
}

/// The folders under "Snappet Clips", so a path is found before it is created (never twice).
struct MediaVaultFolderTree: Sendable {
    let rootID: String
    private var children: [String: [String: String]] = [:]   // parent id → name → folder id

    /// Two folders with one name under one parent: the lowest id wins, whatever the listing order.
    init(rootID: String, folders: [MediaVaultFolder] = []) {
        self.rootID = rootID
        for folder in folders.sorted(by: { $0.id < $1.id }) { insert(folder) }
    }

    mutating func insert(_ folder: MediaVaultFolder) {
        guard let parent = folder.parentID, folder.id != rootID, children[parent]?[folder.name] == nil else { return }
        children[parent, default: [:]][folder.name] = folder.id
    }

    /// Every known folder's names from the root down (the root itself is `[]`) — how the app says
    /// where a copy sits without asking Drive again (prompt 272).
    func paths() -> [String: [String]] {
        var out = [rootID: [String]()]
        var queue = [rootID]
        while let parent = queue.popLast() {
            for (name, id) in children[parent] ?? [:] where out[id] == nil {
                out[id] = (out[parent] ?? []) + [name]
                queue.append(id)
            }
        }
        return out
    }

    /// Folders that hold no clip copy, directly or further down (prompt 273) — what a layout change
    /// leaves behind. `occupied` = the folders copies sit in. `topmost` are the ones to remove
    /// (removing a folder takes the empty folders inside it along); `count` is all of them.
    func emptyFolders(occupied: Set<String>) -> (count: Int, topmost: [String]) {
        func size(_ id: String) -> Int { 1 + (children[id] ?? [:]).values.reduce(0) { $0 + size($1) } }
        func isEmpty(_ id: String) -> Bool {
            !occupied.contains(id) && (children[id] ?? [:]).values.allSatisfy(isEmpty)
        }
        var count = 0, topmost: [String] = []
        func walk(_ id: String) {
            for child in (children[id] ?? [:]).values.sorted() {
                if isEmpty(child) { topmost.append(child); count += size(child) } else { walk(child) }
            }
        }
        walk(rootID)
        return (count, topmost)
    }

    /// The deepest existing folder along `path`, and the names still to create below it.
    func resolve(_ path: [String]) -> (id: String, missing: [String]) {
        var id = rootID
        for (depth, name) in path.enumerated() {
            guard let next = children[id]?[name] else { return (id, Array(path[depth...])) }
            id = next
        }
        return (id, [])
    }
}

enum MediaVaultOrganizer {
    /// Put one existing copy where it belongs: its folders, its name, and the stamp that records it.
    struct Move: Equatable, Sendable {
        var rowID: UUID
        var fileID: String
        var folders: [String]
        var name: String
        var stamp: String
        var fromParentID: String?
    }

    /// Copies whose wanted place is not the one last recorded on the file — after a layout change, a
    /// retag, or for a copy made before prompt 270. A copy of a clip the app no longer has is left alone.
    static func moves(index: MediaVaultIndex, placements: [UUID: MediaVaultPlacement], limit: Int = .max) -> [Move] {
        let wanted = index.entries.values.compactMap { entry -> Move? in
            guard let placement = placements[entry.rowID], entry.stamp != placement.stamp else { return nil }
            return Move(rowID: entry.rowID, fileID: entry.fileID, folders: placement.folders,
                        name: placement.fileName(fileExtension: entry.fileExtension), stamp: placement.stamp,
                        fromParentID: entry.parentID)
        }
        return Array(wanted.sorted { $0.rowID.uuidString < $1.rowID.uuidString }.prefix(max(0, limit)))
    }
}

enum MediaVaultNaming {
    static let folderName = "Snappet Clips"

    static func fileName(rowID: UUID, fileExtension: String) -> String {
        let ext = fileExtension.lowercased().filter { $0.isLetter || $0.isNumber }
        return rowID.uuidString.lowercased() + "." + (ext.isEmpty ? "bin" : ext)
    }

    /// The clip a vault file belongs to; nil for anything Snappet did not name.
    static func rowID(fromFileName name: String) -> UUID? {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        return UUID(uuidString: String(name[..<dot]))
    }

    static func fileExtension(isVideo: Bool, mimeType: String?, fileName: String?) -> String {
        if let fileName, let dot = fileName.lastIndex(of: "."), fileName.index(after: dot) != fileName.endIndex {
            let ext = fileName[fileName.index(after: dot)...].lowercased()
            if ext.count <= 5, ext.allSatisfy({ $0.isLetter || $0.isNumber }) { return ext }
        }
        switch mimeType?.lowercased() {
        case "video/mp4": return "mp4"
        case "video/quicktime": return "mov"
        case "image/heic", "image/heif": return "heic"
        case "image/png": return "png"
        case "image/jpeg": return "jpg"
        default: return isVideo ? "mov" : "jpg"
        }
    }
}

struct MediaVaultEntry: Codable, Equatable, Sendable {
    var rowID: UUID
    var fileID: String
    var name: String
    var byteCount: Int64
    /// The Drive folder it sits in, as last listed.
    var parentID: String? = nil
    /// The place the app last put it (`MediaVaultPlacement.stamp`); nil = never placed.
    var stamp: String? = nil
    /// When THIS phone uploaded it — a listing taken moments later may not show it yet.
    var addedAt: Date? = nil
    /// Bytes the uploading phone sent, as recorded on the Drive file; nil for copies made before prompt 274.
    var sentBytes: Int64? = nil
    /// Drive's checksum of the file, as last listed; and the checksum of what was sent (prompt 276).
    var md5: String? = nil
    var sentMD5: String? = nil

    var fileExtension: String {
        guard let dot = name.lastIndex(of: "."), name.index(after: dot) != name.endIndex else { return "bin" }
        return String(name[name.index(after: dot)...]).lowercased()
    }

    /// The copy's page in Google Drive (opens the Drive app when installed).
    var driveURL: URL? { URL(string: "https://drive.google.com/file/d/\(fileID)/view") }

    /// The fetched file's name in Caches: by clip id, because Drive names are for people and may repeat.
    var cacheName: String { MediaVaultNaming.fileName(rowID: rowID, fileExtension: fileExtension) }
}

/// Which clips have a copy in the vault. Built from a Drive folder listing.
struct MediaVaultIndex: Codable, Equatable, Sendable {
    private(set) var entries: [UUID: MediaVaultEntry] = [:]

    init() {}

    /// Foreign files are ignored; if a clip was uploaded twice the first by file id wins (stable).
    /// A file says whose it is in its private properties, or — a copy from before prompt 270 — its name.
    init(files: [MediaVaultFile]) {
        for file in files.sorted(by: { $0.id < $1.id }) {
            guard let rowID = file.clipID ?? MediaVaultNaming.rowID(fromFileName: file.name), entries[rowID] == nil else { continue }
            entries[rowID] = MediaVaultEntry(rowID: rowID, fileID: file.id, name: file.name, byteCount: file.byteCount,
                                             parentID: file.parentID, stamp: file.clipID == nil ? nil : file.stamp,
                                             sentBytes: file.sentBytes, md5: file.md5, sentMD5: file.sentMD5)
        }
    }

    init(files: [(id: String, name: String, byteCount: Int64)]) {
        self.init(files: files.map { MediaVaultFile(id: $0.id, name: $0.name, byteCount: $0.byteCount) })
    }

    /// A fresh listing, plus what this phone uploaded in the last few minutes that the listing does
    /// not show yet (Drive search can lag) — so a clip is not uploaded twice.
    func keepingRecentUploads(from previous: MediaVaultIndex, now: Date, window: TimeInterval = 600) -> MediaVaultIndex {
        var out = self
        for entry in previous.entries.values where out.entries[entry.rowID] == nil {
            if let added = entry.addedAt, now.timeIntervalSince(added) < window, now >= added { out.entries[entry.rowID] = entry }
        }
        return out
    }

    func entry(for rowID: UUID) -> MediaVaultEntry? { entries[rowID] }
    func contains(_ rowID: UUID) -> Bool { entries[rowID] != nil }
    func copiedCount(of rowIDs: some Sequence<UUID>) -> Int { Set(rowIDs).filter { entries[$0] != nil }.count }
    mutating func insert(_ entry: MediaVaultEntry) { entries[entry.rowID] = entry }
    mutating func remove(_ rowID: UUID) { entries[rowID] = nil }
    var count: Int { entries.count }
    var totalBytes: Int64 { entries.values.reduce(0) { $0 + $1.byteCount } }
}

/// A clip as the vault planner sees it.
struct MediaVaultClip: Equatable, Sendable {
    var rowID: UUID
    var localIdentifier: String
    var isVideo: Bool
    /// The Photos asset still resolves on this phone.
    var isOnPhone: Bool
}

enum MediaVaultPlanner {
    /// Clips to copy now: on this phone, not in the vault yet. Rows sharing one asset upload once per
    /// row id (each row must resolve by its own name); order is stable.
    static func toUpload(_ clips: [MediaVaultClip], index: MediaVaultIndex, excluding: Set<UUID> = [],
                         limit: Int = .max) -> [MediaVaultClip] {
        Array(clips.filter { $0.isOnPhone && !index.contains($0.rowID) && !excluding.contains($0.rowID) }
            .sorted { $0.rowID.uuidString < $1.rowID.uuidString }.prefix(max(0, limit)))
    }

    struct Coverage: Equatable, Sendable {
        var copied: Int
        var total: Int
        /// In the vault but no longer on the phone — these play from Drive.
        var onlyInVault: Int
    }

    /// `excluding`: clips whose copy the person removed by hand — not copied again, not counted.
    static func coverage(_ clips: [MediaVaultClip], index: MediaVaultIndex, excluding: Set<UUID> = []) -> Coverage {
        let counted = clips.filter { !excluding.contains($0.rowID) || index.contains($0.rowID) }
        return Coverage(copied: counted.filter { index.contains($0.rowID) }.count, total: counted.count,
                        onlyInVault: counted.filter { !$0.isOnPhone && index.contains($0.rowID) }.count)
    }
}

// MARK: - Cleaning up (prompt 274)

/// Which copies no longer belong to a clip, and which originals could leave the phone.
enum MediaVaultCleanup {
    struct Plan: Equatable, Sendable {
        /// Copies of clips this phone had and deleted — removed without asking when the switch is on.
        var remove: [MediaVaultEntry] = []
        /// Copies whose clip is not in Snappet for any other reason — only ever offered.
        var leftovers: [MediaVaultEntry] = []
    }

    /// More deletions than this in one pass, and more than a quarter of what the phone knew, is not
    /// a person deleting clips — it is a restored, replaced or broken store. Then nothing is removed
    /// without asking.
    static let massDeletionFloor = 10

    /// - Parameters:
    ///   - storeIDs: every clip in Snappet right now.
    ///   - known: the clips Snappet had at the end of the previous pass on THIS phone.
    static func plan(index: MediaVaultIndex, storeIDs: Set<UUID>, known: Set<UUID>, followDeletions: Bool) -> Plan {
        // An empty store is a new or not-yet-restored phone: every copy would look abandoned.
        guard !storeIDs.isEmpty else { return Plan() }
        let orphans = index.entries.values.filter { !storeIDs.contains($0.rowID) }
            .sorted { $0.rowID.uuidString < $1.rowID.uuidString }
        let gone = known.subtracting(storeIDs)
        let massDeletion = gone.count > massDeletionFloor && gone.count * 4 > known.count
        guard followDeletions, !massDeletion else { return Plan(leftovers: orphans) }
        return Plan(remove: orphans.filter { known.contains($0.rowID) },
                    leftovers: orphans.filter { !known.contains($0.rowID) })
    }

    /// Whether Drive demonstrably holds the file: its size AND its checksum equal what was sent.
    /// `measured…` are the original's size and MD5 on the phone, used for copies made before those
    /// were recorded. Without a checksum from Drive nothing is proven.
    static func isVerified(_ entry: MediaVaultEntry, measured: Int64? = nil, measuredMD5: String? = nil) -> Bool {
        guard entry.byteCount > 0, let size = entry.sentBytes ?? measured, entry.byteCount == size else { return false }
        guard let held = entry.md5, !held.isEmpty, let expected = entry.sentMD5 ?? measuredMD5 else { return false }
        return held.lowercased() == expected.lowercased()
    }

    /// The copy was made before sizes or checksums were recorded: the original must be read now.
    static func needsMeasuring(_ entry: MediaVaultEntry) -> Bool { entry.sentBytes == nil || entry.sentMD5 == nil }

    /// Photos assets that may be removed from the phone: on the phone, and EVERY clip that uses the
    /// asset has a verified copy (two clips can share one asset).
    static func freeable(_ clips: [MediaVaultClip], verified: Set<UUID>) -> [String] {
        Dictionary(grouping: clips.filter(\.isOnPhone), by: \.localIdentifier)
            .filter { $0.value.allSatisfy { verified.contains($0.rowID) } }
            .keys.sorted()
    }
}

/// One clip that could leave this phone: it is in Photos here and has a copy in Drive (prompt 275).
struct MediaVaultFreeUpItem: Equatable, Sendable, Identifiable {
    var id: UUID
    /// The Photos asset. Two clips can share one.
    var asset: String
    var capturedAt: Date
    var activity: String
    var sessionID: UUID
    var sessionStartedAt: Date
    var bytes: Int64
}

/// What the person chose to free up. Every part narrows the others.
struct MediaVaultFreeUpChoice: Equatable, Sendable {
    enum Age: String, CaseIterable, Identifiable, Sendable {
        case any, days30, months6, year1
        var id: String { rawValue }

        var label: String {
            switch self {
            case .any: "Any age"
            case .days30: "Older than 30 days"
            case .months6: "Older than 6 months"
            case .year1: "Older than 1 year"
            }
        }

        /// Clips filmed before this moment qualify. `nil`: every clip does.
        func cutoff(now: Date, calendar: Calendar = .current) -> Date? {
            switch self {
            case .any: nil
            case .days30: calendar.date(byAdding: .day, value: -30, to: now)
            case .months6: calendar.date(byAdding: .month, value: -6, to: now)
            case .year1: calendar.date(byAdding: .year, value: -1, to: now)
            }
        }
    }

    var age: Age = .any
    /// `nil`: every activity.
    var activities: Set<String>? = nil
    /// `nil`: every session.
    var sessions: Set<UUID>? = nil
}

enum MediaVaultFreeUp {
    struct Group: Equatable, Sendable, Identifiable {
        var id: String
        var name: String
        var startedAt: Date? = nil
        var clips: Int
        var bytes: Int64
    }

    /// The clips the age and activity parts allow — what the session list is drawn from.
    static func narrowed(_ items: [MediaVaultFreeUpItem], choice: MediaVaultFreeUpChoice, now: Date,
                         calendar: Calendar = .current) -> [MediaVaultFreeUpItem] {
        let cutoff = choice.age.cutoff(now: now, calendar: calendar)
        return items.filter { item in
            if let cutoff, item.capturedAt >= cutoff { return false }
            if let activities = choice.activities, !activities.contains(item.activity) { return false }
            return true
        }
    }

    /// The clips to remove from the phone. An original used by two clips leaves only when BOTH are
    /// chosen: freeing one session never takes footage out from under another.
    static func selection(_ items: [MediaVaultFreeUpItem], choice: MediaVaultFreeUpChoice, now: Date,
                          calendar: Calendar = .current) -> [MediaVaultFreeUpItem] {
        let chosen = Set(narrowed(items, choice: choice, now: now, calendar: calendar)
            .filter { choice.sessions?.contains($0.sessionID) ?? true }.map(\.id))
        let whole = Dictionary(grouping: items, by: \.asset).filter { $0.value.allSatisfy { chosen.contains($0.id) } }
        return items.filter { whole[$0.asset] != nil }
    }

    /// Originals and bytes: an original shared by two clips counts once.
    static func total(_ items: [MediaVaultFreeUpItem]) -> (count: Int, bytes: Int64) {
        let assets = Dictionary(grouping: items, by: \.asset)
        return (assets.count, assets.values.reduce(Int64(0)) { $0 + ($1.first?.bytes ?? 0) })
    }

    static func activities(_ items: [MediaVaultFreeUpItem]) -> [Group] {
        Dictionary(grouping: items, by: \.activity).map { name, clips in
            let sum = total(clips)
            return Group(id: name, name: name, clips: sum.count, bytes: sum.bytes)
        }.sorted { $0.name < $1.name }
    }

    /// Newest session first.
    static func sessions(_ items: [MediaVaultFreeUpItem]) -> [Group] {
        Dictionary(grouping: items, by: \.sessionID).map { id, clips in
            let sum = total(clips)
            return Group(id: id.uuidString, name: clips[0].activity, startedAt: clips[0].sessionStartedAt,
                         clips: sum.count, bytes: sum.bytes)
        }.sorted { ($0.startedAt ?? .distantPast, $0.id) > ($1.startedAt ?? .distantPast, $1.id) }
    }
}

/// A clip brought back from Drive should sit in Photos at the time it was filmed (prompt 277).
/// Photos reads that from the file; a file that carries no date is filed under the moment it was
/// saved. Only then is the date Snappet knows put in its place — a date from the file is never
/// overruled.
enum MediaVaultRestoreDate {
    /// Slack around the save: clocks, and the seconds Photos takes to finish.
    static let window: TimeInterval = 120
    /// Anything earlier is a zeroed or broken date, not a capture time.
    static let earliestPlausible = Date(timeIntervalSince1970: 946_684_800)   // 2000-01-01

    /// The date to set on the new asset, or nil to leave it as Photos made it.
    /// - Parameters:
    ///   - assigned: the creation date Photos gave the saved asset.
    ///   - known: when Snappet believes the clip was filmed.
    static func correction(assigned: Date?, saveStarted: Date, saveEnded: Date, known: Date?) -> Date? {
        // A known date that is missing, absurd, in the future, or itself "just now" corrects nothing.
        guard let known, known >= earliestPlausible, known < saveStarted.addingTimeInterval(-window) else { return nil }
        guard let assigned else { return known }
        let stampedAtSave = assigned >= saveStarted.addingTimeInterval(-window) && assigned <= saveEnded.addingTimeInterval(window)
        return stampedAtSave ? known : nil
    }
}

/// Getting a clip that is only in Drive onto the screen (prompt 276): from the cache, by downloading
/// the whole file, or — a large video — by streaming just the parts the player asks for.
enum MediaVaultFetch {
    /// Videos larger than this stream; smaller ones download whole and replay from the cache.
    static let streamAbove: Int64 = 25 * 1024 * 1024
    /// One request to Drive while streaming.
    static let chunkBytes: Int64 = 1024 * 1024

    enum Mode: Equatable, Sendable { case cached, download, stream }

    static func mode(isVideo: Bool, byteCount: Int64, isCached: Bool, streamAbove: Int64 = streamAbove) -> Mode {
        if isCached { return .cached }
        return isVideo && byteCount > streamAbove ? .stream : .download
    }

    /// Why a clip cannot be fetched right now. Each has its own words and, for Wi-Fi, a way past.
    enum Blocked: Error, Equatable, Sendable {
        case signedOut, offline
        case wifiOnly(bytes: Int64)
        /// The copy is no longer in Drive.
        case gone
    }

    /// `allowed`: the person said "play anyway" for this clip. A cached file needs no network at all.
    static func blocked(mode: Mode, canUseDrive: Bool, wifiOnly: Bool, network: CloudBackupNetwork,
                        allowed: Bool, bytes: Int64) -> Blocked? {
        if mode == .cached { return nil }
        guard canUseDrive else { return .signedOut }
        switch network {
        case .offline: return .offline
        case .cellular where wifiOnly && !allowed: return .wifiOnly(bytes: bytes)
        default: return nil
        }
    }

    /// The pieces to ask Drive for, in order, to serve `length` bytes from `offset` of a file of `total`.
    static func chunks(offset: Int64, length: Int64, total: Int64, chunk: Int64 = chunkBytes) -> [Range<Int64>] {
        let end = min(total, offset + max(0, length))
        guard offset >= 0, offset < end, chunk > 0 else { return [] }
        return stride(from: offset, to: end, by: Int64.Stride(chunk)).map { $0..<min(end, $0 + chunk) }
    }

    /// HTTP's inclusive form: bytes 0..<1024 is "bytes=0-1023".
    static func rangeHeader(_ range: Range<Int64>) -> String { "bytes=\(range.lowerBound)-\(range.upperBound - 1)" }

    /// The uniform type the player is told, from the copy's file name.
    static func contentType(fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "mov", "qt": "com.apple.quicktime-movie"
        case "mp4": "public.mpeg-4"
        case "m4v": "com.apple.m4v-video"
        default: "public.movie"
        }
    }
}

enum MediaVaultPolicy {
    enum SkipReason: Equatable, Sendable { case off, notStarted, signedOut, needsPermission, offline, waitingForWiFi, needsPhotos, sessionRunning }
    enum Decision: Equatable, Sendable { case run, skip(SkipReason) }

    static func decide(settings: MediaVaultSettings, signedIn: Bool, hasDrivePermission: Bool,
                       network: CloudBackupNetwork, sessionRunning: Bool = false) -> Decision {
        guard settings.keepCopies else { return .skip(.off) }
        guard settings.started else { return .skip(.notStarted) }
        // Copying exports and uploads video: not while a session is running (prompt 279).
        guard !sessionRunning else { return .skip(.sessionRunning) }
        guard signedIn else { return .skip(.signedOut) }
        guard hasDrivePermission else { return .skip(.needsPermission) }
        switch network {
        case .offline: return .skip(.offline)
        case .cellular where settings.wifiOnly: return .skip(.waitingForWiFi)
        default: return .run
        }
    }
}

/// Where a clip's footage comes from, in order: the phone's Photos, a file already fetched from the
/// vault, the vault itself (a download), or nowhere.
enum MediaSource: Equatable, Sendable {
    case photos, cache, vault, missing

    static func resolve(isOnPhone: Bool, isCached: Bool, isInVault: Bool) -> MediaSource {
        if isOnPhone { return .photos }
        if isCached { return .cache }
        return isInVault ? .vault : .missing
    }
}

/// Fetched vault files live in Caches and are trimmed least-recently-used first.
enum MediaVaultCache {
    static let defaultLimitBytes: Int64 = 400 * 1024 * 1024

    struct File: Equatable, Sendable {
        var name: String
        var byteCount: Int64
        var lastUsed: Date
    }

    /// Files to delete so the cache fits `limit`; `keeping` (the one about to play) is never evicted.
    static func toEvict(_ files: [File], limit: Int64 = defaultLimitBytes, keeping: String? = nil) -> [String] {
        var total = files.reduce(Int64(0)) { $0 + $1.byteCount }
        var out: [String] = []
        for file in files.sorted(by: { ($0.lastUsed, $0.name) < ($1.lastUsed, $1.name) }) where total > limit {
            guard file.name != keeping else { continue }
            out.append(file.name)
            total -= file.byteCount
        }
        return out
    }
}

enum MediaVaultText {
    static func coverage(_ coverage: MediaVaultPlanner.Coverage, bytes: Int64) -> String {
        guard coverage.total > 0 else { return "No clips yet" }
        var line = "\(coverage.copied.formatted()) of \(coverage.total.formatted()) clips copied"
        if bytes > 0 { line += " · " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
        return line
    }

    /// Where a copy sits, for the clip's menu: "Snappet Clips / Climbing / 2026-11-14 18.42". A folder
    /// the app does not know (the person moved the file) reads just "Google Drive".
    static func location(folders: [String]?) -> String {
        guard let folders else { return "Google Drive" }
        return (["Snappet Clips"] + folders).joined(separator: " / ")
    }

    static func leftovers(_ count: Int) -> String {
        count == 1 ? "1 copy of a clip that is no longer in Snappet" : "\(count) copies of clips that are no longer in Snappet"
    }
    static func removedCopies(_ count: Int) -> String {
        count == 1 ? "1 copy moved to Drive’s trash." : "\(count) copies moved to Drive’s trash."
    }
    static func freeUp(count: Int, bytes: Int64) -> String {
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return count == 1 ? "1 clip on this iPhone has a copy in Google Drive · \(size)"
                          : "\(count.formatted()) clips on this iPhone have a copy in Google Drive · \(size)"
    }
    /// What the clip's surface says when its copy cannot be fetched, and the button that gets past it.
    static func blocked(_ why: MediaVaultFetch.Blocked) -> (line: String, detail: String?, action: String?) {
        switch why {
        case .signedOut: ("In Google Drive", "Sign in to Google in Cloud & Backup to play it.", nil)
        case .offline: ("In Google Drive", "You’re offline. It plays when you’re connected.", nil)
        case .wifiOnly(let bytes):
            ("In Google Drive · " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file),
             "Clip copies are set to Wi-Fi only.", "Play anyway")
        case .gone: ("Not on this phone", "Its copy is no longer in Google Drive.", nil)
        }
    }

    /// Shown when clips in a free-up selection are used in Studio projects.
    static func usedInStudio(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1 ? "1 of these is used in a Studio project. It still plays, but to edit or export that project you bring the clip back first."
                          : "\(count) of these are used in Studio projects. They still play, but to edit or export those projects you bring the clips back first."
    }

    /// The chooser's running total: "12 clips · 1.4 GB".
    static func freeUpTotal(count: Int, bytes: Int64) -> String {
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return count == 1 ? "1 clip · \(size)" : "\(count.formatted()) clips · \(size)"
    }
    static func freed(count: Int, bytes: Int64, unverified: Int) -> String {
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        var line = count == 1 ? "1 clip removed from this iPhone (\(size)). It plays from Google Drive."
                              : "\(count.formatted()) clips removed from this iPhone (\(size)). They play from Google Drive."
        if unverified > 0 {
            line += unverified == 1 ? " 1 was kept: its copy could not be confirmed."
                                    : " \(unverified) were kept: their copies could not be confirmed."
        }
        return line
    }

    static func emptyFolders(_ count: Int) -> String {
        count == 1 ? "1 empty folder left in Snappet Clips" : "\(count) empty folders left in Snappet Clips"
    }
    static func removedFolders(_ count: Int) -> String {
        count == 1 ? "1 empty folder moved to Drive’s trash." : "\(count) empty folders moved to Drive’s trash."
    }

    /// After a pass that skipped clips it could not export or upload; they are tried again next time.
    static func couldNotCopy(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1 ? "1 clip couldn’t be copied. It will be tried again."
                          : "\(count) clips couldn’t be copied. They will be tried again."
    }

    /// One session's clips: nil when it has none.
    static func sessionCopies(copied: Int, total: Int) -> String? {
        guard total > 0 else { return nil }
        if copied == 0 { return total == 1 ? "Clip not copied to Google Drive yet" : "None of \(total) clips copied to Google Drive yet" }
        if copied >= total { return total == 1 ? "Clip copied to Google Drive" : "All \(total) clips copied to Google Drive" }
        return "\(copied) of \(total) clips copied to Google Drive"
    }

    /// While a pass runs: the whole picture first (a pass is only a batch, so "1 of 20" alone reads
    /// as starting over).
    static func copying(_ coverage: MediaVaultPlanner.Coverage, done: Int, total: Int) -> String {
        guard coverage.total > 0 else { return "Copying \(done) of \(total)…" }
        return "Copying… \(coverage.copied.formatted()) of \(coverage.total.formatted()) clips copied"
    }

    static func skipped(_ reason: MediaVaultPolicy.SkipReason) -> String? {
        switch reason {
        case .off, .notStarted: nil
        case .signedOut: "Sign in to Google to copy clips."
        case .needsPermission: "Allow Snappet to save to Google Drive to copy clips."
        case .offline: "Waiting for a connection."
        case .waitingForWiFi: "Waiting for Wi-Fi."
        case .needsPhotos: "Allow full access to Photos to copy clips."
        case .sessionRunning: "Paused while a session is running."
        }
    }

    /// The result of bringing picks in from Google Photos.
    static func importOutcome(saved: Int, unmatched: Int, failed: Int) -> String {
        var parts: [String] = []
        if saved > 0 { parts.append(saved == 1 ? "1 clip brought back" : "\(saved) clips brought back") }
        if unmatched > 0 {
            parts.append(unmatched == 1 ? "1 pick didn’t match a missing clip" : "\(unmatched) picks didn’t match a missing clip")
        }
        if failed > 0 { parts.append(failed == 1 ? "1 couldn’t be copied" : "\(failed) couldn’t be copied") }
        return parts.isEmpty ? "Nothing was picked" : parts.joined(separator: " · ")
    }
}

// MARK: - Drive requests for the visible clips folder (`drive.file`)

extension GoogleScope {
    /// Files and folders Snappet itself creates in the person's Drive — nothing else in it.
    static let driveFile = "https://www.googleapis.com/auth/drive.file"
    /// Read only the items the person hands over in Google's own picker.
    static let photosPicker = "https://www.googleapis.com/auth/photospicker.mediaitems.readonly"
}

extension GoogleDriveAPI {
    static let folderMimeType = "application/vnd.google-apps.folder"

    struct SizedFile: Decodable, Equatable, Sendable {
        var id: String
        var name: String
        /// Drive sends int64 as a string.
        var size: String?
        var parents: [String]?
        var appProperties: [String: String]?
        var md5Checksum: String?

        var vaultFile: MediaVaultFile {
            MediaVaultFile(id: id, name: name, byteCount: Int64(size ?? "") ?? 0, parentID: parents?.first,
                           clipID: MediaVaultTag.clipID(from: appProperties), stamp: appProperties?[MediaVaultTag.stampKey],
                           sentBytes: appProperties?[MediaVaultTag.bytesKey].flatMap { Int64($0) },
                           md5: md5Checksum, sentMD5: appProperties?[MediaVaultTag.md5Key])
        }
    }
    struct SizedPage: Decodable, Equatable, Sendable {
        var files: [SizedFile]
        var nextPageToken: String?
    }

    static func query(_ q: String, pageToken: String? = nil) -> URLRequest {
        var components = URLComponents(string: filesEndpoint)!
        components.queryItems = [URLQueryItem(name: "q", value: q),
                                 URLQueryItem(name: "spaces", value: "drive"),
                                 URLQueryItem(name: "fields", value: "nextPageToken,files(id,name,size,parents,appProperties,md5Checksum)"),
                                 URLQueryItem(name: "pageSize", value: "1000")]
        if let pageToken { components.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        return URLRequest(url: components.url!)
    }

    static func findFolder(named name: String) -> URLRequest {
        query("name = '\(escape(name))' and mimeType = '\(folderMimeType)' and trashed = false")
    }

    static func children(ofFolder id: String, pageToken: String? = nil) -> URLRequest {
        query("'\(escape(id))' in parents and trashed = false", pageToken: pageToken)
    }

    /// Every clip copy, wherever it sits (found by its private marker — prompt 270).
    static func clipFiles(pageToken: String? = nil) -> URLRequest {
        query("appProperties has { key='\(MediaVaultTag.markerKey)' and value='\(MediaVaultTag.markerValue)' } and trashed = false",
              pageToken: pageToken)
    }

    /// Every folder Snappet created (`drive.file` shows it no others).
    static func folders(pageToken: String? = nil) -> URLRequest {
        query("mimeType = '\(folderMimeType)' and trashed = false", pageToken: pageToken)
    }

    static func createFolder(named name: String, parent: String? = nil) -> URLRequest {
        var request = URLRequest(url: URL(string: filesEndpoint + "?fields=id,name")!)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        var metadata: [String: Any] = ["name": name, "mimeType": folderMimeType]
        if let parent { metadata["parents"] = [parent] }
        request.httpBody = try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys, .withoutEscapingSlashes])
        return request
    }

    /// Move a file or folder to Drive's trash (recoverable there for 30 days) — never a hard delete.
    static func trash(id: String) -> URLRequest {
        var request = URLRequest(url: URL(string: filesEndpoint + "/" + id + "?fields=id")!)
        request.httpMethod = "PATCH"
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"trashed":true}"#.utf8)
        return request
    }

    /// Rename a file, set its private properties, and (when the folders differ) move it — one call,
    /// no bytes re-sent.
    static func relocate(id: String, name: String, appProperties: [String: String],
                         addParent: String?, removeParent: String?) -> URLRequest {
        var components = URLComponents(string: filesEndpoint + "/" + id)!
        components.queryItems = [URLQueryItem(name: "fields", value: "id,name,parents")]
        if let addParent, addParent != removeParent {
            components.queryItems?.append(URLQueryItem(name: "addParents", value: addParent))
            if let removeParent { components.queryItems?.append(URLQueryItem(name: "removeParents", value: removeParent)) }
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = "PATCH"
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["name": name, "appProperties": appProperties], options: [.sortedKeys, .withoutEscapingSlashes])
        return request
    }

    static func sizedPage(from data: Data) throws -> SizedPage {
        guard let page = try? JSONDecoder().decode(SizedPage.self, from: data) else { throw GoogleAuthError.badResponse }
        return page
    }

    /// Drive query strings quote with `'`; a backslash escapes.
    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    }
}

// MARK: - Google Photos Picker API

/// One item the person picked in Google Photos.
struct GooglePickedItem: Equatable, Sendable, Identifiable {
    var id: String
    var createTime: Date
    var isVideo: Bool
    var baseURL: String
    var mimeType: String?
    var fileName: String?
    var width: Int?
    var height: Int?

    /// The identifier a pick goes by in the relink planner (never collides with a Photos identifier).
    var pickIdentifier: String { "google:" + id }

    /// What Google tells us about it, as a fingerprint. No duration: the Picker API does not give one.
    var fingerprint: MediaFingerprint {
        MediaFingerprint(capturedAt: createTime, isVideo: isVideo, durationSec: nil,
                         pixelWidth: width, pixelHeight: height, originalFilename: fileName)
    }

    /// Original bytes: `=dv` for a video, `=d` for a photo.
    var downloadURL: URL? { URL(string: baseURL + (isVideo ? "=dv" : "=d")) }
}

enum GooglePhotosPickerAPI {
    static let base = "https://photospicker.googleapis.com/v1"

    struct Session: Equatable, Sendable {
        var id: String
        var pickerURL: URL
        var mediaItemsSet: Bool
        var pollInterval: TimeInterval
        var timeout: TimeInterval
    }

    static func createSession() -> URLRequest {
        var request = URLRequest(url: URL(string: base + "/sessions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        return request
    }

    static func getSession(id: String) -> URLRequest { URLRequest(url: URL(string: "\(base)/sessions/\(id)")!) }

    static func deleteSession(id: String) -> URLRequest {
        var request = getSession(id: id)
        request.httpMethod = "DELETE"
        return request
    }

    static func listItems(sessionID: String, pageToken: String? = nil) -> URLRequest {
        var components = URLComponents(string: base + "/mediaItems")!
        components.queryItems = [URLQueryItem(name: "sessionId", value: sessionID),
                                 URLQueryItem(name: "pageSize", value: "100")]
        if let pageToken { components.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        return URLRequest(url: components.url!)
    }

    /// A poll reply repeats only some fields; the rest carry over from `fallback`.
    static func session(from data: Data, fallback: Session) throws -> Session {
        struct Raw: Decodable { var mediaItemsSet: Bool? }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data) else { throw GoogleAuthError.badResponse }
        var next = fallback
        next.mediaItemsSet = raw.mediaItemsSet ?? false
        return next
    }

    static func session(from data: Data) throws -> Session {
        struct Raw: Decodable {
            struct Polling: Decodable { var pollInterval: String?; var timeoutIn: String? }
            var id: String
            var pickerUri: String?
            var mediaItemsSet: Bool?
            var pollingConfig: Polling?
        }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data),
              let url = raw.pickerUri.flatMap(URL.init(string:)) else { throw GoogleAuthError.badResponse }
        return Session(id: raw.id, pickerURL: url, mediaItemsSet: raw.mediaItemsSet ?? false,
                       pollInterval: min(max(seconds(raw.pollingConfig?.pollInterval) ?? 5, 2), 30),
                       timeout: seconds(raw.pollingConfig?.timeoutIn) ?? 1800)
    }

    static func items(from data: Data) throws -> (items: [GooglePickedItem], nextPageToken: String?) {
        struct Raw: Decodable {
            struct Item: Decodable {
                struct File: Decodable {
                    struct Metadata: Decodable { var width: Int?; var height: Int? }
                    var baseUrl: String?
                    var mimeType: String?
                    var filename: String?
                    var mediaFileMetadata: Metadata?
                }
                var id: String
                var createTime: String?
                var type: String?
                var mediaFile: File?
            }
            var mediaItems: [Item]?
            var nextPageToken: String?
        }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data) else { throw GoogleAuthError.badResponse }
        let items = (raw.mediaItems ?? []).compactMap { item -> GooglePickedItem? in
            guard let base = item.mediaFile?.baseUrl, let created = item.createTime.flatMap(date) else { return nil }
            let isVideo = item.type == "VIDEO" || (item.mediaFile?.mimeType?.hasPrefix("video/") ?? false)
            return GooglePickedItem(id: item.id, createTime: created, isVideo: isVideo, baseURL: base,
                                    mimeType: item.mediaFile?.mimeType, fileName: item.mediaFile?.filename,
                                    width: item.mediaFile?.mediaFileMetadata?.width,
                                    height: item.mediaFile?.mediaFileMetadata?.height)
        }
        return (items, raw.nextPageToken)
    }

    /// Google durations are strings like `"5s"` / `"1800.5s"`.
    static func seconds(_ text: String?) -> TimeInterval? {
        guard let text, text.hasSuffix("s") else { return nil }
        return TimeInterval(text.dropLast())
    }

    /// RFC 3339, with or without fractional seconds.
    static func date(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}

/// Match Google picks to missing clips with the SAME rules as a hand pick from Photos (prompt 266):
/// unique best score, a tie is no match, one asset is never attached to two different clips.
enum GoogleImportPlanner {
    struct Plan: Equatable, Sendable {
        /// Missing clip → the pick that is its footage.
        var matches: [UUID: GooglePickedItem] = [:]
        var unmatchedPickCount = 0
    }

    static func plan(missing: [MediaLinkRow], picks: [GooglePickedItem], alreadyInVault: Set<UUID>) -> Plan {
        let wanted = missing.filter { !alreadyInVault.contains($0.id) }
        let byPickID = Dictionary(picks.map { ($0.pickIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        let result = MediaRelinkPlanner.assign(
            missing: wanted,
            picks: byPickID.values.map { MediaLinkCandidate(localIdentifier: $0.pickIdentifier, fingerprint: $0.fingerprint) },
            owned: [])
        var plan = Plan()
        for (rowID, pickID) in result.relinks { plan.matches[rowID] = byPickID[pickID] }
        plan.unmatchedPickCount = byPickID.count - Set(result.relinks.values).count
        return plan
    }
}
