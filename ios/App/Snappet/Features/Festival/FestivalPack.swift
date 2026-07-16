import Foundation

// MARK: - Festival lineup domain — `.fpack` wire types + codec (festival prompt 01, pure)
//
// The lineup domain the Festival mini-app owns (festivals → days → stages → sets) and the `.fpack`
// wire codec the hosted-catalog install (prompt 02) will feed. PURE Foundation — no SwiftUI/SwiftData/
// UIKit — so the whole codec → validator → matcher chain unit-tests in `SnappetTests` without a
// simulator (decisions.md 2026-07-16: Kilter shape, hosted packs, time-window tagging).

/// One installed festival lineup: the decoded form of a `.fpack` file hosted at
/// `https://harshal2802.github.io/Snappet/music-festivals/` (the `board-data/` sibling; prompt 02 owns
/// the GET). Value type, `Codable`, no reference cycles — deliberately friendly to the prompt-05
/// deflate-blob QR codec (`SharedRoutine` pattern).
struct FestivalPack: Sendable, Equatable, Codable {
    /// Wire-format version, in the JSON *and* stamped as a byte in the `.fpack` header so an unknown
    /// future schema is rejected before JSON decoding is even attempted.
    static let currentFormatVersion = 1

    var formatVersion: Int
    /// Pack-author slug (e.g. `"glastonbury-2026"`) — the namespace every set's content id derives from,
    /// so a re-downloaded or friend-shared copy of the same lineup converges on the same set ids.
    var id: String
    var name: String
    var location: String
    /// Festival window as `yyyy-MM-dd` poster dates (inclusive); every day's `date` must fall inside.
    var startDate: String
    var endDate: String
    /// The festival's UTC offset in seconds (e.g. +3600 for Glastonbury under BST), captured in the pack
    /// so set times and day boundaries stay festival-local no matter what time zone the phone is in
    /// later. A fixed offset, not a zone id — a weekend doesn't cross DST often enough to carry tzdb.
    var utcOffsetSeconds: Int
    var days: [FestivalDay]

    init(id: String, name: String, location: String, startDate: String, endDate: String,
         utcOffsetSeconds: Int, days: [FestivalDay]) {
        self.formatVersion = Self.currentFormatVersion
        self.id = id
        self.name = name
        self.location = location
        self.startDate = startDate
        self.endDate = endDate
        self.utcOffsetSeconds = utcOffsetSeconds
        self.days = days
        stampContentIdentity()
    }

    // MARK: Content identity (the Kilter create-a-climb precedent)

    /// Fixed namespace for festival-set content ids. Constant forever — changing it would re-key every
    /// installed lineup's sets and orphan their tags. (A random v4 UUID, chosen once.)
    static let setIDNamespace = UUID(uuidString: "3B7A2E9C-6D14-4F0B-8C2A-5E9D71A4F3B6")!

    /// Stamp every set's derived `id` (UUIDv5 over normalized content) and denormalized `stage` label.
    /// Ids are a pure function of `(pack id, stage, artist, start, end)`, so two decodes of the same
    /// pack — or a friend's copy of it — agree on every set id (the dedupe/tag-stability contract).
    mutating func stampContentIdentity() {
        for d in days.indices {
            for s in days[d].stages.indices {
                let stage = days[d].stages[s].name
                for i in days[d].stages[s].sets.indices {
                    days[d].stages[s].sets[i].stage = stage
                    days[d].stages[s].sets[i].id = FestivalSet.contentID(
                        festivalID: id, stage: stage, set: days[d].stages[s].sets[i])
                }
            }
        }
    }

    // MARK: Lookup helpers the matcher / plan math share

    var allSets: [FestivalSet] { days.flatMap { $0.allSets } }

    var setsByID: [UUID: FestivalSet] {
        Dictionary(allSets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// The festival day whose window (rollover-to-rollover, festival-local) contains `date` — how a
    /// 01:00 clip lands on the *previous* poster day.
    func day(containing date: Date) -> FestivalDay? {
        days.first { $0.window(utcOffsetSeconds: utcOffsetSeconds)?.contains(date) == true }
    }

    // MARK: - `.fpack` codec  (magic + version byte + raw-DEFLATE JSON)

    /// 4-byte magic prefixing every `.fpack`, ahead of the 1-byte wire version — the file-format analog
    /// of `SharedRoutine`'s `/v1/` path segment, so tampered or future-versioned packs are rejected
    /// with a typed error before any decompression happens.
    static let magic = Data("FPAK".utf8)
    /// Sanity cap on the compressed file (a lineup is text — real packs are tens of KB; Kilter posture).
    static let maxPackBytes = 4 * 1_000_000
    /// Cap on the inflated JSON, so a hostile blob can't balloon memory after passing the size gate.
    static let maxJSONBytes = 16 * 1_000_000

    enum FPackError: LocalizedError, Equatable {
        case notAPack
        case unsupportedVersion(Int)
        case tooLarge(Int)
        case corrupted
        case undecodable

        var errorDescription: String? {
            switch self {
            case .notAPack:
                return "That file isn't a Snappet festival pack."
            case .unsupportedVersion(let v):
                return "That pack uses a newer format (v\(v)) — update Snappet to install it."
            case .tooLarge(let bytes):
                return "That file is too large (\(bytes / 1_000_000) MB) to be a festival pack."
            case .corrupted:
                return "That pack is damaged and couldn't be unpacked."
            case .undecodable:
                return "That pack's lineup data couldn't be read."
            }
        }
    }

    /// Encode to the `.fpack` wire form: `"FPAK"` + version byte + deflate(JSON). Reuses the shared
    /// `ZlibCodec` (raw DEFLATE via `compression_stream`, the `SharedRoutine` codec) — one compression
    /// story for every Snappet blob; the Pages pack builder mirrors it. Sorted keys → stable bytes.
    func fpackData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let offset = utcOffsetSeconds
        encoder.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(FestivalPack.isoString(date, utcOffsetSeconds: offset))
        }
        guard let json = try? encoder.encode(self),
              let deflated = ZlibCodec.deflate(json) else { throw FPackError.corrupted }
        var out = Self.magic
        out.append(UInt8(Self.currentFormatVersion))
        out.append(deflated)
        return out
    }

    /// Decode a `.fpack` blob back into a pack, stamping content ids — the single entry point install
    /// (prompt 02) and share (prompt 05) both funnel through, so a pack in memory always has its ids.
    static func decode(fpack data: Data) throws -> FestivalPack {
        if data.count > maxPackBytes { throw FPackError.tooLarge(data.count) }
        guard data.count > magic.count + 1, data.prefix(magic.count) == magic else {
            throw FPackError.notAPack
        }
        let version = Int(data[data.startIndex + magic.count])
        guard version == currentFormatVersion else { throw FPackError.unsupportedVersion(version) }

        guard let json = ZlibCodec.inflate(data.dropFirst(magic.count + 1)) else {
            throw FPackError.corrupted
        }
        if json.count > maxJSONBytes { throw FPackError.tooLarge(json.count) }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            let s = try c.decode(String.self)
            guard let d = FestivalPack.parseISO(s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "not ISO-8601: \(s)")
            }
            return d
        }
        guard var pack = try? decoder.decode(FestivalPack.self, from: json),
              pack.formatVersion == version else { throw FPackError.undecodable }
        pack.stampContentIdentity()
        return pack
    }

    // MARK: ISO-8601 with the festival's offset (pure functions — nothing captured across threads)

    /// `2026-06-27T22:15:00+01:00` — the festival's own offset in the string, so the hosted JSON reads
    /// like the poster and any consumer decodes the same absolute instant.
    static func isoString(_ date: Date, utcOffsetSeconds: Int) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: utcOffsetSeconds) ?? TimeZone(secondsFromGMT: 0)!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let sign = utcOffsetSeconds < 0 ? "-" : "+"
        let a = abs(utcOffsetSeconds)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d%@%02d:%02d",
                      c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!,
                      sign, a / 3600, (a % 3600) / 60)
    }

    static func parseISO(_ string: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: string)
    }
}

/// One poster day. `date` is the *label* date (`yyyy-MM-dd`); the day's actual window runs from
/// `rolloverHour` festival-local to `rolloverHour` the next morning, because a 01:00 set belongs to the
/// night before — the explicit day-boundary model the matcher, validator, and plan math all share.
struct FestivalDay: Sendable, Equatable, Codable {
    /// Festival days roll over at 06:00 local, not midnight — late-night sets stay on their poster day.
    static let rolloverHour = 6

    var date: String
    var stages: [FestivalStage]

    var allSets: [FestivalSet] { stages.flatMap(\.sets) }

    /// The day's real interval: `rolloverHour` on `date` → 24 h later, in the festival's fixed offset.
    /// `nil` when `date` doesn't parse (the validator rejects that pack).
    func window(utcOffsetSeconds: Int) -> DateInterval? {
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: utcOffsetSeconds) ?? TimeZone(secondsFromGMT: 0)!
        let comps = DateComponents(year: parts[0], month: parts[1], day: parts[2],
                                   hour: Self.rolloverHour)
        guard let start = cal.date(from: comps) else { return nil }
        return DateInterval(start: start, duration: 24 * 3600)
    }
}

struct FestivalStage: Sendable, Equatable, Codable {
    var name: String
    var sets: [FestivalSet]
}

/// One set: an artist on a stage for an interval — the unit everything tags against. `id` and `stage`
/// are NOT on the wire (`sets (artist, start, end)`); both are stamped after decode, `id` as a UUIDv5
/// over normalized content so identity survives re-download and sharing.
struct FestivalSet: Sendable, Equatable, Codable, Identifiable {
    var id = UUID()
    var artist: String
    var start: Date
    var end: Date
    /// Denormalized stage label so matcher output ("Fred again.. · West Holts") is self-contained.
    var stage = ""

    private enum CodingKeys: String, CodingKey { case artist, start, end }

    init(artist: String, start: Date, end: Date) {
        self.artist = artist
        self.start = start
        self.end = end
    }

    var window: DateInterval { DateInterval(start: start, end: max(start, end)) }

    /// The deterministic content id: UUIDv5 (via the shared `KilterClimbIdentity.uuidV5` — reuse, don't
    /// copy) over `"fpack:v1|festival|stage|artist|startEpoch|endEpoch"` with labels normalized
    /// (lowercased, whitespace collapsed), so cosmetic pack edits don't re-key a set.
    static func contentID(festivalID: String, stage: String, set: FestivalSet) -> UUID {
        let name = ["fpack:v1", normalize(festivalID), normalize(stage), normalize(set.artist),
                    String(Int(set.start.timeIntervalSince1970)),
                    String(Int(set.end.timeIntervalSince1970))].joined(separator: "|")
        return UUID(uuidString: KilterClimbIdentity.uuidV5(namespace: FestivalPack.setIDNamespace,
                                                           name: name))!
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
