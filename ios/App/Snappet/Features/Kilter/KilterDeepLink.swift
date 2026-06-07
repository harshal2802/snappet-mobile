import Foundation

/// A shareable reference to a catalog climb, encoded as a compact `snappet://` URL. Both phones ship
/// the *same* read-only catalog (same `climb_uuid`s), so a scanned link resolves fully **offline** —
/// no account, no network. Kept a pure value type + codec so it's unit-testable without a camera.
///
/// Wire form: `snappet://kilter/climb/<uuid>?angle=<n>` (the angle is optional — the scanner opens
/// the climb at that angle when present).
struct KilterClimbLink: Equatable, Sendable {
    let uuid: String
    /// The angle the sharer was viewing, if any.
    var angle: Int?

    init(uuid: String, angle: Int? = nil) {
        self.uuid = uuid
        self.angle = angle
    }

    var url: URL? {
        var c = URLComponents()
        c.scheme = "snappet"
        c.host = "kilter"
        c.path = "/climb/\(uuid)"
        if let angle { c.queryItems = [URLQueryItem(name: "angle", value: String(angle))] }
        return c.url
    }

    /// The string actually encoded into the QR symbol (empty only if the uuid is unrepresentable).
    var encoded: String { url?.absoluteString ?? "" }

    /// Parse a scanned/opened string back into a climb link, or nil if it isn't one of ours.
    init?(decoding string: String) {
        guard let c = URLComponents(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme?.lowercased() == "snappet",
              c.host?.lowercased() == "kilter" else { return nil }
        // path = "/climb/<uuid>"
        let parts = c.path.split(separator: "/").map(String.init)
        guard parts.count == 2, parts[0] == "climb", !parts[1].isEmpty else { return nil }
        self.uuid = parts[1]
        self.angle = c.queryItems?.first { $0.name == "angle" }?.value.flatMap { Int($0) }
    }
}
