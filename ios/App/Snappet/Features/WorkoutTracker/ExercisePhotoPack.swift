import Foundation

/// Pure logic for the **exercise guide-photo pack** (`.spack`) — the single container the app
/// downloads once from the static photo host and then slices photos out of on demand (no unzip
/// step, no thousands of loose files). Built by `tools/workout/build_photo_pack.py`; the two are
/// the only writers/readers of the format, versioned via the magic + the host manifest.
///
/// Layout: `magic "SPHOTOS1" (8B) | index length (4B little-endian) | index JSON | JPEG blobs`,
/// where index JSON is `{"exercises": {"<exerciseId>": [{"offset": n, "length": n}, ...]}}` and
/// offsets are relative to the first byte after the index. Photos are ordered start → end.
///
/// Everything here is platform-free and byte-in/value-out so it unit-tests without a simulator
/// (`ExercisePhotoPackTests`); the file I/O + networking edge is `ExercisePhotoStore`.
enum ExercisePhotoPack {
    static let magic = Data("SPHOTOS1".utf8)
    /// Bytes before the index JSON: 8-byte magic + 4-byte little-endian index length.
    static let headerLength = 12

    enum PackError: LocalizedError, Equatable {
        case truncated
        case badMagic
        case badIndex

        var errorDescription: String? {
            switch self {
            case .truncated: return "The photo pack file is incomplete. Download it again."
            case .badMagic: return "This isn't a Snappet photo pack. Check the host URL."
            case .badIndex: return "The photo pack index couldn't be read. Download it again."
            }
        }
    }

    /// Parse the fixed 12-byte header, returning the index JSON's byte length.
    static func indexLength(header: Data) throws -> Int {
        guard header.count >= headerLength else { throw PackError.truncated }
        guard header.prefix(8).elementsEqual(magic) else { throw PackError.badMagic }
        // Slice-index-safe (works on Data slices whose startIndex isn't 0).
        let raw = header.dropFirst(8).prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let length = UInt32(littleEndian: raw)
        guard length > 0 else { throw PackError.badIndex }
        return Int(length)
    }

    /// Decode the index JSON into absolute byte ranges within the pack file.
    /// `packSize` bounds-checks every slice so a truncated download can't yield garbage reads.
    static func parseIndex(_ json: Data, packSize: Int64) throws -> Index {
        struct RawSlice: Decodable { let offset: Int64; let length: Int64 }
        struct RawIndex: Decodable { let exercises: [String: [RawSlice]] }

        guard let raw = try? JSONDecoder().decode(RawIndex.self, from: json) else {
            throw PackError.badIndex
        }
        let blobStart = Int64(headerLength + json.count)
        var ranges: [String: [Range<Int64>]] = [:]
        ranges.reserveCapacity(raw.exercises.count)
        for (id, slices) in raw.exercises {
            var exercise: [Range<Int64>] = []
            for slice in slices {
                // Overflow-checked: offsets come from a downloaded file, so a hostile/corrupt
                // index near Int64.max must reject cleanly, not trap on the addition.
                let (start, overflow1) = blobStart.addingReportingOverflow(slice.offset)
                let (end, overflow2) = start.addingReportingOverflow(slice.length)
                guard slice.offset >= 0, slice.length > 0, !overflow1, !overflow2,
                      end <= packSize else {
                    throw PackError.truncated
                }
                exercise.append(start..<end)
            }
            ranges[id] = exercise
        }
        return Index(ranges: ranges)
    }

    /// The parsed pack index: exercise id → absolute byte ranges of its photos (start → end order).
    struct Index: Sendable, Equatable {
        let ranges: [String: [Range<Int64>]]

        var exerciseCount: Int { ranges.count }
        var photoCount: Int { ranges.values.reduce(0) { $0 + $1.count } }
        func photoRanges(for exerciseId: String) -> [Range<Int64>] { ranges[exerciseId] ?? [] }
    }
}

/// The host's `manifest.json` beside the pack — fetched (user-initiated) before the download so
/// the UI can show the real size, and stamped to disk after install for the Settings status row.
struct PhotoPackManifest: Codable, Sendable, Equatable {
    let version: Int
    let file: String
    let sizeBytes: Int64
    let photoCount: Int
    let exerciseCount: Int

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}
