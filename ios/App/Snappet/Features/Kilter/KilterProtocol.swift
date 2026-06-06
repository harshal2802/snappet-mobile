import Foundation

/// Encodes a climb's lit holds into the Aurora/Kilter board's BLE wire format.
///
/// ⚠️ This implements the **community-reverse-engineered** Aurora protocol (as used by the Kilter /
/// Tension apps and the `1-max-1/fake_kilter_board` simulator). It is **not yet validated against
/// physical hardware** — per the repo's device-only rule, illumination must be confirmed on a real
/// board before it's reported as working. The encoding is kept here as a pure, unit-testable
/// function so the byte layout can be checked independently of CoreBluetooth.
///
/// Wire format:
///  * Each lit hold → 2 bytes (API level 2) or 3 bytes (API level 3) — position + packed color.
///  * The concatenated body is split into ≤ `bodyChunk` chunks; each chunk is prefixed with a
///    packet-type marker (FIRST / MIDDLE / LAST, or ONLY when it all fits in one) and wrapped as
///    `[0x01, length, checksum, 0x02, <marker + chunk…>, 0x03]`, where `length`/`checksum` cover the
///    `<marker + chunk…>` packet data and `checksum = ~(Σ bytes) & 0xFF`.
///  * Each wrapped message is sent as one BLE write (≤ 20 bytes after framing).
enum KilterProtocol {
    /// Which Aurora payload dialect to speak. The BLE link + UUIDs are identical across the family;
    /// only the *payload* differs by board firmware generation, and it is **not negotiated** — the app
    /// picks. `v3` (3-byte holds, R3G3B2) is what current boards use and the default; `v2` (2-byte
    /// holds, R2G2B2) is for older controllers. A mismatch still connects fine but lights the wrong
    /// holds/colors — hence the user-facing toggle.
    enum APILevel: String, CaseIterable, Sendable {
        case v3, v2
        /// Short control label.
        var label: String { self == .v3 ? "Standard" : "Legacy" }
        /// Packet-type markers (first byte of packet data): (first, middle, last, only).
        var markers: (first: UInt8, middle: UInt8, last: UInt8, only: UInt8) {
            self == .v3 ? (82, 81, 83, 84) : (78, 77, 79, 80)
        }
    }

    // Body bytes per packet. 12 is a multiple of both hold widths (2 and 3), and framed —
    // 6 wrapper bytes (0x01 len cksum 0x02 … 0x03) + 1 marker + 12 body = 19 — fits the 20-byte BLE
    // ATT payload, so holds never straddle a packet boundary at either API level.
    static let bodyChunk = 12

    /// Pack a hex color (`"00DD00"`) into the v3 R3G3B2 byte (bits 7–5 R, 4–2 G, 1–0 B).
    static func colorByte(_ hex: String) -> UInt8 {
        let (r, g, b) = rgb(hex)
        return UInt8((Int(r) / 32) << 5 | (Int(g) / 32) << 2 | (Int(b) / 64))
    }

    /// Pack a hex color into the v2 R2G2B2 bits, positioned in byte1 bits 7–2 (R 7–6, G 5–4, B 3–2);
    /// bits 1–0 are left clear for the high position bits the caller ORs in.
    static func colorBitsV2(_ hex: String) -> UInt8 {
        let (r, g, b) = rgb(hex)
        return UInt8((Int(r) >> 6) << 6 | (Int(g) >> 6) << 4 | (Int(b) >> 6) << 2)
    }

    /// Body bytes for the lit holds (no framing), in the given API dialect.
    static func body(for holds: [(position: Int, colorHex: String)], level: APILevel = .v3) -> [UInt8] {
        var out: [UInt8] = []
        for hold in holds {
            switch level {
            case .v3:
                // 3 bytes: position uint16-LE + R3G3B2 color.
                out.append(UInt8(hold.position & 0xFF))
                out.append(UInt8((hold.position >> 8) & 0xFF))
                out.append(colorByte(hold.colorHex))
            case .v2:
                // 2 bytes: byte0 = position low 8 bits; byte1 = R2G2B2 color (bits 7–2) | high 2
                // position bits (bits 1–0).
                out.append(UInt8(hold.position & 0xFF))
                out.append(colorBitsV2(hold.colorHex) | UInt8((hold.position >> 8) & 0x03))
            }
        }
        return out
    }

    /// The full set of framed BLE messages to write, in order, to illuminate the holds.
    static func messages(for holds: [(position: Int, colorHex: String)], level: APILevel = .v3) -> [[UInt8]] {
        let m = level.markers
        let body = body(for: holds, level: level)
        if body.isEmpty { return [wrap([m.only])] }
        let chunks = stride(from: 0, to: body.count, by: bodyChunk).map {
            Array(body[$0 ..< min($0 + bodyChunk, body.count)])
        }
        if chunks.count == 1 { return [wrap([m.only] + chunks[0])] }
        return chunks.enumerated().map { index, chunk in
            let marker = index == 0 ? m.first : (index == chunks.count - 1 ? m.last : m.middle)
            return wrap([marker] + chunk)
        }
    }

    // MARK: - private

    private static func wrap(_ payload: [UInt8]) -> [UInt8] {
        [0x01, UInt8(payload.count), checksum(payload), 0x02] + payload + [0x03]
    }

    private static func checksum(_ bytes: [UInt8]) -> UInt8 {
        var sum = 0
        for b in bytes { sum = (sum + Int(b)) & 0xFF }
        return UInt8(~sum & 0xFF)
    }

    private static func rgb(_ hex: String) -> (UInt8, UInt8, UInt8) {
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        return (UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF))
    }
}
