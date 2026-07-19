import Foundation

/// A festival lineup — or the user's starred-set **plan** — shared offline as a compact `snappet://`
/// URL (festival prompt 05). Generalizes the exact payload-vs-link cliff `SharedRoutine` ships: a
/// small subject (a day plan, a hand-built lineup) is **deflated into the code itself** so it scans in
/// a field with zero signal; a subject too dense for a comfortably-scannable QR (a whole multi-day
/// festival) falls back to an **install-link QR** that points at the hosted pack on
/// `festivalDefaultCatalogHost` (`music-festivals/`), which the receiver fetches once.
///
/// Two wire forms, one type, one `SnappetShareable` conformance (so the shell's route table + the
/// shared scanner treat it like a climb link or a routine):
///
///   • **payload** — `snappet://festival/v1/<blob>`, `blob = base64url(deflate(terse JSON))`, reusing
///     the shared `ZlibCodec` / `Base64URL` codec (NOT a second compression story). The carried
///     `FestivalPack` IS the source of truth: because a plan is just the same pack with its set list
///     filtered to the stars, the receiver's set **content ids line up byte-for-byte** (UUIDv5, prompt
///     01), so a shared plan stars the very sets the friend starred.
///   • **installLink** — `snappet://festival/install/<packID>?h=<host>&t=<title>&k=<0|1>` — the
///     fallback: the pack is fetched from `<host>/<packID>.fpack` (the Pages builder's naming
///     convention) through the existing `FestivalLineupInstaller`.
///
/// Pure value + codec (Foundation + the shared codec only — no SwiftUI/SwiftData/camera) so the whole
/// round-trip and the size-cliff decision are unit-tested without a device; the camera scan and the
/// share sheet stay the thin device edges.
struct SharedLineup: Equatable, Sendable, Identifiable {
    /// Wire-format version — carried as the `/v1/` path segment so the route table rejects an unknown
    /// future version cleanly (the `SharedRoutine` posture).
    static let version = 1

    /// What travels in the code.
    enum Content: Equatable, Sendable {
        /// The lineup (or plan subset) carried IN the code — offline-scannable.
        case payload(FestivalPack)
        /// A pointer to a hosted pack — the fallback when the payload won't fit a scannable QR.
        case installLink(packID: String, host: String)
    }

    var content: Content
    /// Human title the receiver's import-confirm shows ("My plan" / "Glastonbury 2026").
    var title: String
    /// Whether this shares a starred-set PLAN (star these on your copy) vs a whole LINEUP (install it).
    var isPlan: Bool

    init(content: Content, title: String, isPlan: Bool) {
        self.content = content
        self.title = title
        self.isPlan = isPlan
    }

    // MARK: - Builders (the pure share-site decisions)

    /// Share the user's starred sets as a plan: the same pack, its set list filtered to the stars, so
    /// content ids (and therefore the receiver's stars) line up. Titled for the import-confirm.
    static func plan(from pack: FestivalPack, starredSetIDs: Set<UUID>, title: String) -> SharedLineup {
        SharedLineup(content: .payload(subsetPack(pack, starredSetIDs: starredSetIDs)),
                     title: title, isPlan: true)
    }

    /// Share the whole lineup as a payload (the caller falls back to the link via `scannableForm`).
    static func lineup(from pack: FestivalPack, title: String) -> SharedLineup {
        SharedLineup(content: .payload(pack), title: title, isPlan: false)
    }

    /// The pure payload-vs-link cliff (the `SharedRoutine.fitsInScannableQR` boundary): keep the offline
    /// payload QR when it's dense enough to scan; otherwise fall back to the tiny install-link QR
    /// pointing at the hosted pack. A no-op for a value that's already an install link.
    func scannableForm(host: String = festivalDefaultCatalogHost) -> SharedLineup {
        guard case .payload(let pack) = content, !fitsInScannableQR else { return self }
        return SharedLineup(content: .installLink(packID: pack.id, host: host),
                            title: title, isPlan: isPlan)
    }

    /// A pack containing only the starred sets (empty stages/days dropped). Re-stamps content ids under
    /// the SAME pack id, so every kept set's UUIDv5 id equals its id in the full pack.
    static func subsetPack(_ pack: FestivalPack, starredSetIDs: Set<UUID>) -> FestivalPack {
        let days: [FestivalDay] = pack.days.compactMap { day in
            let stages: [FestivalStage] = day.stages.compactMap { stage in
                let sets = stage.sets.filter { starredSetIDs.contains($0.id) }
                return sets.isEmpty ? nil : FestivalStage(name: stage.name, sets: sets)
            }
            return stages.isEmpty ? nil : FestivalDay(date: day.date, stages: stages)
        }
        return FestivalPack(id: pack.id, name: pack.name, location: pack.location,
                            startDate: pack.startDate, endDate: pack.endDate,
                            utcOffsetSeconds: pack.utcOffsetSeconds, days: days)
    }

    // MARK: - Wire codec

    var url: URL? {
        var c = URLComponents()
        c.scheme = "snappet"
        c.host = "festival"
        switch content {
        case .payload(let pack):
            guard let blob = SharedLineup.encodeBlob(pack: pack, title: title, isPlan: isPlan) else {
                return nil
            }
            c.path = "/v\(SharedLineup.version)/\(blob)"
        case .installLink(let packID, let host):
            guard !packID.isEmpty else { return nil }
            c.path = "/install/\(packID)"
            c.queryItems = [URLQueryItem(name: "h", value: host),
                            URLQueryItem(name: "t", value: title),
                            URLQueryItem(name: "k", value: isPlan ? "1" : "0")]
        }
        return c.url
    }

    /// The string actually encoded into the QR symbol (empty when the value is unrepresentable).
    var encoded: String { url?.absoluteString ?? "" }

    /// Encoded byte size — the number that decides the payload-vs-link fallback.
    var encodedByteCount: Int { encoded.utf8.count }

    /// A version-`M` QR at this density stays scannable below roughly this many URL bytes. Higher than
    /// `SharedRoutine`'s 900 because the wireframe wants a ~dozen-set day plan (~1.1 KB) in the code;
    /// past it (a whole festival is tens of KB) the install-link fallback carries it instead.
    static let scannableURLByteCap = 1400

    /// Whether this value renders as a comfortably-scannable QR: an install link is always tiny; a
    /// payload must fit under the cap.
    var fitsInScannableQR: Bool {
        switch content {
        case .installLink:
            return encodedByteCount > 0
        case .payload:
            let n = encodedByteCount
            return n > 0 && n <= SharedLineup.scannableURLByteCap
        }
    }

    /// Parse a scanned/opened string back into a shared lineup, or nil if it isn't one of ours / a
    /// wrong version.
    init?(decoding string: String) {
        guard let c = URLComponents(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme?.lowercased() == "snappet",
              c.host?.lowercased() == "festival" else { return nil }
        let parts = c.path.split(separator: "/").map(String.init)
        // payload: /v1/<blob>
        if parts.count == 2, parts[0].lowercased() == "v\(SharedLineup.version)", !parts[1].isEmpty,
           let decoded = SharedLineup.decodeBlob(parts[1]) {
            self.content = .payload(decoded.pack)
            self.title = decoded.title
            self.isPlan = decoded.isPlan
            return
        }
        // installLink: /install/<packID>?h=&t=&k=
        if parts.count == 2, parts[0].lowercased() == "install", !parts[1].isEmpty {
            let q = c.queryItems ?? []
            let host = q.first { $0.name == "h" }?.value ?? festivalDefaultCatalogHost
            self.content = .installLink(packID: parts[1], host: host)
            self.title = q.first { $0.name == "t" }?.value ?? parts[1]
            self.isPlan = q.first { $0.name == "k" }?.value == "1"
            return
        }
        return nil
    }

    // MARK: blob = base64url(deflate(json))

    /// The terse wire wrapper: the pack + its title + the plan flag, short keys to keep the blob small
    /// (the pack's Codable already omits derived set id/stage — they re-stamp on decode).
    private struct PayloadWire: Codable {
        var pack: FestivalPack
        var title: String
        var isPlan: Bool
        enum CodingKeys: String, CodingKey { case pack = "p", title = "t", isPlan = "k" }
    }

    private static func encodeBlob(pack: FestivalPack, title: String, isPlan: Bool) -> String? {
        let wire = PayloadWire(pack: pack, title: title, isPlan: isPlan)
        guard let json = try? JSONEncoder().encode(wire),
              let deflated = ZlibCodec.deflate(json) else { return nil }
        return Base64URL.encode(deflated)
    }

    private static func decodeBlob(_ blob: String) -> PayloadWire? {
        guard let deflated = Base64URL.decode(blob),
              let json = ZlibCodec.inflate(deflated),
              var wire = try? JSONDecoder().decode(PayloadWire.self, from: json) else { return nil }
        // Re-stamp derived set ids (off the wire) exactly as `FestivalPack.decode` does — so a shared
        // plan's set ids equal the receiver's installed-lineup set ids.
        wire.pack.stampContentIdentity()
        return wire
    }

    // MARK: - Receive decision (the pure brain the import edge executes)

    /// What installing this shared value should DO on a device with `installedPackIDs` already present.
    /// Pure so the never-silent import rules are unit-tested without a store (the `RoutineImportRoute`
    /// analog). The thin edge (`FestivalRootView`) runs the returned action after a user confirm.
    enum ReceiveAction: Equatable, Sendable {
        /// Install / replace a `FestivalLineup` from the carried bytes (a shared whole lineup).
        case installLineup(packID: String)
        /// Star these content set-ids on the already-installed lineup (a plan onto a lineup you have).
        case applyPlan(packID: String, setIDs: [UUID])
        /// Install the carried subset as a lineup, then star its sets (a plan for a lineup you lack).
        case installPlan(packID: String)
        /// Fetch the hosted pack, then install (the install-link fallback).
        case fetchInstall(packID: String, host: String)
    }

    func receiveAction(installedPackIDs: Set<String>) -> ReceiveAction {
        switch content {
        case .installLink(let packID, let host):
            return .fetchInstall(packID: packID, host: host)
        case .payload(let pack):
            guard isPlan else { return .installLineup(packID: pack.id) }
            if installedPackIDs.contains(pack.id) {
                return .applyPlan(packID: pack.id, setIDs: pack.allSets.map(\.id))
            }
            return .installPlan(packID: pack.id)
        }
    }

    /// The `FestivalPack` this value carries, if any (payload forms) — the import edge installs it.
    var carriedPack: FestivalPack? {
        if case .payload(let pack) = content { return pack }
        return nil
    }

    // MARK: Identifiable (stable `.sheet(item:)` identity — the encoded string)

    var id: String { encoded }
}

extension SharedLineup: SnappetShareable {}
