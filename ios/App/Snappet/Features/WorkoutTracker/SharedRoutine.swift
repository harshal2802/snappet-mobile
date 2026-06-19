import Foundation
import Compression

/// A whole **routine** shared offline as a compact `snappet://routine/v1/<blob>` URL (workout-redesign
/// E6). Unlike a Kilter climb — which is a single REFERENCE into a catalog both phones already ship —
/// a user routine exists on no shared catalog, so we must carry the routine itself. We keep it small by
/// carrying **`exerciseId` references** (both devices ship the same 870-row exercise catalog + the same
/// timed/climb structures) rather than full `Exercise` definitions, then **deflate + base64url** the
/// terse JSON into the URL path.
///
/// Pure value type + codec (Foundation + Compression only — no SwiftUI/SwiftData/camera) so the whole
/// round-trip is unit-tested without a device. The version segment (`/v1/`) is in the wire form from day
/// one so a future schema change can add `/v2/` without breaking old codes.
///
/// **Custom exercises** (ids prefixed `custom-`) aren't in the shared catalog, so they'd resolve to a
/// de-slugged id on the other phone. We carry each block's `displayName` inline (it's already a terse
/// field) so an imported custom block still reads with its real name; the import-confirm preview flags
/// every id that doesn't resolve in the local library via `unresolvableExerciseIds(resolving:)` — the
/// `KilterDeepLinkRouting.explainMissing` analog — and the import proceeds anyway (never silent, never
/// dropping a block).
struct SharedRoutine: Equatable, Sendable {
    /// Wire-format version. Bumped only on an incompatible schema change; the URL also carries it as a
    /// path segment so the route table can reject an unknown version cleanly.
    static let version = 1

    var name: String
    var detail: String?
    var exercises: [Block]

    /// One exercise block in the shared routine — the wire mirror of a `RoutineExercise`, with only the
    /// fields a prescription needs (no per-set log, no live state). Every non-essential field is omitted
    /// when nil/default to keep the blob small (terse `CodingKeys` + `encodeIfPresent`).
    struct Block: Equatable, Sendable {
        var exerciseId: String
        var sets: Int
        var reps: String
        var restSeconds: Int
        var weight: Double?
        var weightUnitRaw: String?
        var notes: String?
        /// Inline label so a `custom-…` block (whose id won't resolve on the other phone) keeps its name.
        var displayName: String?
        var disciplineRaw: String?
        var targetDurationSec: Double?
        var targetDistanceMeters: Double?
        var targetRPE: Int?
        var climbTypeRaw: String?
        var climbGradeLabel: String?
        var climbGradeScaleRaw: String?
        var timedSpecData: Data?
        var timedCategory: String?
    }

    // MARK: - Bridge to/from RoutineExercise

    /// Build a shareable routine from a live `Routine` (drops per-session state; keeps the prescription).
    init(name: String, detail: String?, exercises: [RoutineExercise]) {
        self.name = name
        self.detail = (detail?.isEmpty == false) ? detail : nil
        self.exercises = exercises.map(Block.init(from:))
    }

    /// The blocks as fresh `RoutineExercise`s — each gets a NEW `id` so an import never collides with an
    /// existing routine's blocks. The caller wraps these in a NEW `Routine` (new UUID, never overwrite).
    func routineExercises() -> [RoutineExercise] {
        exercises.map { $0.routineExercise() }
    }

    // MARK: - Wire codec (deflate + base64url → snappet://routine/v1/<blob>)

    var url: URL? {
        guard let blob = SharedRoutine.encodeBlob(self) else { return nil }
        var c = URLComponents()
        c.scheme = "snappet"
        c.host = "routine"
        c.path = "/v\(SharedRoutine.version)/\(blob)"
        return c.url
    }

    /// The string actually encoded into the QR symbol (empty when the value is unrepresentable).
    var encoded: String { url?.absoluteString ?? "" }

    /// Encoded byte size — the number that decides QR vs link fallback (`fitsInScannableQR`).
    var encodedByteCount: Int { encoded.utf8.count }

    /// A version-`M` QR at this density should stay scannable below roughly this many URL bytes
    /// (alphanumeric-ish base64url at ECC-M lands well under a v40 symbol; we keep a conservative cap so
    /// a phone camera at arm's length reads it reliably). Past it, offer the `ShareLink` (link/file)
    /// instead — the honest size handling the design calls for (README §10 Q4, the QR size cliff).
    static let scannableURLByteCap = 900

    /// Whether this routine's encoded URL is small enough to render as a comfortably-scannable QR.
    var fitsInScannableQR: Bool {
        let n = encodedByteCount
        return n > 0 && n <= SharedRoutine.scannableURLByteCap
    }

    /// Parse a scanned/opened string back into a routine, or nil if it isn't one of ours / wrong version.
    init?(decoding string: String) {
        guard let c = URLComponents(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme?.lowercased() == "snappet",
              c.host?.lowercased() == "routine" else { return nil }
        // path = "/v<version>/<blob>"
        let parts = c.path.split(separator: "/").map(String.init)
        guard parts.count == 2,
              parts[0].lowercased() == "v\(SharedRoutine.version)",
              !parts[1].isEmpty,
              let decoded = SharedRoutine.decodeBlob(parts[1]) else { return nil }
        self = decoded
    }

    // MARK: - blob = base64url(deflate(json))

    private static func encodeBlob(_ routine: SharedRoutine) -> String? {
        guard let json = try? JSONEncoder().encode(routine),
              let deflated = ZlibCodec.deflate(json) else { return nil }
        return Base64URL.encode(deflated)
    }

    private static func decodeBlob(_ blob: String) -> SharedRoutine? {
        guard let deflated = Base64URL.decode(blob),
              let json = ZlibCodec.inflate(deflated),
              let routine = try? JSONDecoder().decode(SharedRoutine.self, from: json) else { return nil }
        return routine
    }

    // MARK: - Missing-exercise landing (the explainMissing analog)

    /// The block exercise-ids that DON'T resolve in the local library — the graceful "these N exercises
    /// aren't in your library" line the import-confirm preview shows (the `KilterDeepLinkRouting`
    /// .explainMissing analog). Pure: takes a resolver closure so it's testable without a store.
    /// The import still proceeds — a missing id keeps its inline `displayName` (or a de-slugged label).
    func unresolvableExerciseIds(resolving exists: (String) -> Bool) -> [String] {
        exercises.map(\.exerciseId).filter { !exists($0) }
    }
}

extension SharedRoutine: SnappetShareable {}

extension SharedRoutine: Identifiable {
    /// Stable identity for SwiftUI `.sheet(item:)` presentation — the encoded URL string (a deterministic
    /// function of the content). Two scans of the same code present the same sheet; an edited routine is a
    /// different code.
    var id: String { encoded }
}

// MARK: - Block ↔ RoutineExercise

extension SharedRoutine.Block {
    init(from re: RoutineExercise) {
        exerciseId = re.exerciseId
        sets = re.sets
        reps = re.reps
        restSeconds = re.restSeconds
        weight = re.weight
        weightUnitRaw = re.weightUnit?.rawValue
        notes = re.notes
        displayName = re.displayName
        disciplineRaw = re.disciplineRaw
        targetDurationSec = re.targetDurationSec
        targetDistanceMeters = re.targetDistanceMeters
        targetRPE = re.targetRPE
        climbTypeRaw = re.climbTypeRaw
        climbGradeLabel = re.climbGradeLabel
        climbGradeScaleRaw = re.climbGradeScaleRaw
        timedSpecData = re.timedSpecData
        timedCategory = re.timedCategory
    }

    /// A fresh `RoutineExercise` (new id) reconstructed from the wire block. `disciplineRaw` is passed via
    /// the `discipline:` init param so a strength block keeps `disciplineRaw == nil` (byte-stable), exactly
    /// like a locally-authored one.
    func routineExercise() -> RoutineExercise {
        RoutineExercise(
            exerciseId: exerciseId,
            sets: sets,
            reps: reps,
            restSeconds: restSeconds,
            weight: weight,
            weightUnit: weightUnitRaw.flatMap(WeightUnit.init),
            notes: notes,
            displayName: displayName,
            discipline: disciplineRaw.flatMap(WorkoutDiscipline.init(rawValue:)),
            targetDurationSec: targetDurationSec,
            targetDistanceMeters: targetDistanceMeters,
            targetRPE: targetRPE,
            climbTypeRaw: climbTypeRaw,
            climbGradeLabel: climbGradeLabel,
            climbGradeScaleRaw: climbGradeScaleRaw,
            timedSpecData: timedSpecData,
            timedCategory: timedCategory)
    }
}

// MARK: - Terse Codable (short keys + omit-nil to keep the blob small)

extension SharedRoutine: Codable {
    private enum CodingKeys: String, CodingKey {
        case name = "n", detail = "d", exercises = "e"
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        exercises = try c.decodeIfPresent([Block].self, forKey: .exercises) ?? []
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(detail, forKey: .detail)
        try c.encode(exercises, forKey: .exercises)
    }
}

extension SharedRoutine.Block: Codable {
    private enum CodingKeys: String, CodingKey {
        case exerciseId = "x", sets = "s", reps = "r", restSeconds = "t"
        case weight = "w", weightUnitRaw = "u", notes = "o", displayName = "m"
        case disciplineRaw = "p", targetDurationSec = "dur", targetDistanceMeters = "dis"
        case targetRPE = "rpe", climbTypeRaw = "ct", climbGradeLabel = "cg", climbGradeScaleRaw = "cs"
        case timedSpecData = "ts", timedCategory = "tc"
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exerciseId = try c.decode(String.self, forKey: .exerciseId)
        sets = try c.decodeIfPresent(Int.self, forKey: .sets) ?? 1
        reps = try c.decodeIfPresent(String.self, forKey: .reps) ?? ""
        restSeconds = try c.decodeIfPresent(Int.self, forKey: .restSeconds) ?? 0
        weight = try c.decodeIfPresent(Double.self, forKey: .weight)
        weightUnitRaw = try c.decodeIfPresent(String.self, forKey: .weightUnitRaw)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        disciplineRaw = try c.decodeIfPresent(String.self, forKey: .disciplineRaw)
        targetDurationSec = try c.decodeIfPresent(Double.self, forKey: .targetDurationSec)
        targetDistanceMeters = try c.decodeIfPresent(Double.self, forKey: .targetDistanceMeters)
        targetRPE = try c.decodeIfPresent(Int.self, forKey: .targetRPE)
        climbTypeRaw = try c.decodeIfPresent(String.self, forKey: .climbTypeRaw)
        climbGradeLabel = try c.decodeIfPresent(String.self, forKey: .climbGradeLabel)
        climbGradeScaleRaw = try c.decodeIfPresent(String.self, forKey: .climbGradeScaleRaw)
        timedSpecData = try c.decodeIfPresent(Data.self, forKey: .timedSpecData)
        timedCategory = try c.decodeIfPresent(String.self, forKey: .timedCategory)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(exerciseId, forKey: .exerciseId)
        if sets != 1 { try c.encode(sets, forKey: .sets) }
        if !reps.isEmpty { try c.encode(reps, forKey: .reps) }
        if restSeconds != 0 { try c.encode(restSeconds, forKey: .restSeconds) }
        try c.encodeIfPresent(weight, forKey: .weight)
        try c.encodeIfPresent(weightUnitRaw, forKey: .weightUnitRaw)
        try c.encodeIfPresent(notes, forKey: .notes)
        try c.encodeIfPresent(displayName, forKey: .displayName)
        try c.encodeIfPresent(disciplineRaw, forKey: .disciplineRaw)
        try c.encodeIfPresent(targetDurationSec, forKey: .targetDurationSec)
        try c.encodeIfPresent(targetDistanceMeters, forKey: .targetDistanceMeters)
        try c.encodeIfPresent(targetRPE, forKey: .targetRPE)
        try c.encodeIfPresent(climbTypeRaw, forKey: .climbTypeRaw)
        try c.encodeIfPresent(climbGradeLabel, forKey: .climbGradeLabel)
        try c.encodeIfPresent(climbGradeScaleRaw, forKey: .climbGradeScaleRaw)
        try c.encodeIfPresent(timedSpecData, forKey: .timedSpecData)
        try c.encodeIfPresent(timedCategory, forKey: .timedCategory)
    }
}

// MARK: - base64url (RFC 4648 §5: URL-safe alphabet, no padding)

/// URL-safe base64 (`+`→`-`, `/`→`_`, no `=` padding) so the blob is a clean URL path segment and a
/// dense QR alphanumeric run. Pure → unit-tested.
enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ string: String) -> Data? {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Re-pad to a multiple of 4 (base64 decoding requires padding).
        let remainder = s.count % 4
        if remainder > 0 { s += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: s)
    }
}

// MARK: - raw DEFLATE (Apple `Compression`, COMPRESSION_ZLIB = raw deflate, no zlib/gzip header)

/// Raw-DEFLATE round-trip for the shared-routine blob. Uses Apple's `Compression` framework
/// (`COMPRESSION_ZLIB` = the raw DEFLATE stream, no header/checksum — the smallest form, which matters
/// for a QR), distinct from the gzip *inflate* the Kilter catalog download does via the `zlib` C lib.
/// Pure (no device) → unit-tested round-trip + a guard against a truncated blob.
enum ZlibCodec {
    static func deflate(_ input: Data) -> Data? {
        transcode(input, operation: COMPRESSION_STREAM_ENCODE)
    }

    static func inflate(_ input: Data) -> Data? {
        transcode(input, operation: COMPRESSION_STREAM_DECODE)
    }

    private static func transcode(_ input: Data, operation: compression_stream_operation) -> Data? {
        guard !input.isEmpty else { return Data() }
        // `compression_stream` has no zero-arg init in Swift — allocate it raw and let
        // `compression_stream_init` fill it (the documented pattern for the C API).
        let streamPtr = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPtr.deallocate() }
        guard compression_stream_init(streamPtr, operation, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            return nil
        }
        defer { compression_stream_destroy(streamPtr) }

        let bufferSize = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        var output = Data()
        let flags = Int32(COMPRESSION_STREAM_FINALIZE.rawValue)

        return input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            streamPtr.pointee.src_ptr = base
            streamPtr.pointee.src_size = input.count
            streamPtr.pointee.dst_ptr = buffer
            streamPtr.pointee.dst_size = bufferSize

            while true {
                let status = compression_stream_process(streamPtr, flags)
                switch status {
                case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
                    let produced = bufferSize - streamPtr.pointee.dst_size
                    if produced > 0 { output.append(buffer, count: produced) }
                    if status == COMPRESSION_STATUS_END { return output }
                    // Buffer full mid-stream — drain and continue.
                    streamPtr.pointee.dst_ptr = buffer
                    streamPtr.pointee.dst_size = bufferSize
                case COMPRESSION_STATUS_ERROR:
                    return nil
                default:
                    return nil
                }
            }
        }
    }
}
