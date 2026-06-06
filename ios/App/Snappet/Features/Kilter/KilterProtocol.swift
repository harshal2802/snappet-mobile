import Foundation

/// Encodes a climb's lit holds into the Aurora/Kilter board's BLE wire format.
///
/// ⚠️ This implements the **community-reverse-engineered** Aurora protocol (as used by the Kilter /
/// Tension apps and the `1-max-1/fake_kilter_board` simulator). It is **not yet validated against
/// physical hardware** — per the repo's device-only rule, illumination must be confirmed on a real
/// board before it's reported as working. The encoding is kept here as a pure, unit-testable
/// function so the byte layout can be checked independently of CoreBluetooth.
///
/// Wire format (Aurora "API level 3"):
///  * Each lit hold → 3 bytes: `position` (uint16 little-endian) + `color` (R3 G3 B2 packed byte).
///  * The concatenated body is split into ≤ `bodyChunk` chunks; each chunk is prefixed with a
///    packet-type marker (FIRST / MIDDLE / LAST, or ONLY when it all fits in one) and wrapped as
///    `[0x01, length, checksum, 0x02, <marker + chunk…>, 0x03]`, where `length`/`checksum` cover the
///    `<marker + chunk…>` packet data and `checksum = ~(Σ bytes) & 0xFF`.
///  * Each wrapped message is sent as one BLE write (≤ 20 bytes after framing).
enum KilterProtocol {
    // 12 body bytes = 4 holds (3 bytes each) per packet. Framed: 6 wrapper bytes
    // (0x01 len cksum 0x02 … 0x03) + 1 marker + 12 body = 19 bytes ≤ the 20-byte BLE ATT payload,
    // and holds never straddle a packet boundary.
    static let bodyChunk = 12
    static let packetMiddle: UInt8 = 81
    static let packetFirst: UInt8 = 82
    static let packetLast: UInt8 = 83
    static let packetOnly: UInt8 = 84

    /// Pack a hex color (`"00DD00"`) into the board's single R3G3B2 byte.
    static func colorByte(_ hex: String) -> UInt8 {
        let (r, g, b) = rgb(hex)
        return UInt8((Int(r) / 32) << 5 | (Int(g) / 32) << 2 | (Int(b) / 64))
    }

    /// Body bytes for the lit holds (no framing).
    static func body(for holds: [(position: Int, colorHex: String)]) -> [UInt8] {
        var out: [UInt8] = []
        for hold in holds {
            out.append(UInt8(hold.position & 0xFF))
            out.append(UInt8((hold.position >> 8) & 0xFF))
            out.append(colorByte(hold.colorHex))
        }
        return out
    }

    /// The full set of framed BLE messages to write, in order, to illuminate the holds.
    static func messages(for holds: [(position: Int, colorHex: String)]) -> [[UInt8]] {
        let body = body(for: holds)
        if body.isEmpty { return [wrap([packetOnly])] }
        let chunks = stride(from: 0, to: body.count, by: bodyChunk).map {
            Array(body[$0 ..< min($0 + bodyChunk, body.count)])
        }
        if chunks.count == 1 { return [wrap([packetOnly] + chunks[0])] }
        return chunks.enumerated().map { index, chunk in
            let marker = index == 0 ? packetFirst : (index == chunks.count - 1 ? packetLast : packetMiddle)
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
