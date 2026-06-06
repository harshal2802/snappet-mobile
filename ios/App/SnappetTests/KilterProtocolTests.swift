import XCTest
@testable import Snappet

/// Unit tests for the **pure** Aurora/Kilter "API level 3" wire encoder `KilterProtocol`.
/// The byte layout is checked off-device here so a regression in the framing (the bug that left the
/// board "connected but unresponsive") is caught without hardware. Vectors follow the
/// `1-max-1/fake_kilter_board` reverse-engineering: frame = `[0x01, len, checksum, 0x02, <marker +
/// holds…>, 0x03]`, hold = position uint16-LE + R3G3B2 color byte, ≤ 20 bytes per BLE write.
final class KilterProtocolTests: XCTestCase {

    func testColorBytePacksR3G3B2() {
        XCTAssertEqual(KilterProtocol.colorByte("00FF00"), 0x1C)   // green: g=7<<2
        XCTAssertEqual(KilterProtocol.colorByte("FF0000"), 0xE0)   // red:   r=7<<5
        XCTAssertEqual(KilterProtocol.colorByte("0000FF"), 0x03)   // blue:  b=3
        XCTAssertEqual(KilterProtocol.colorByte("000000"), 0x00)
        XCTAssertEqual(KilterProtocol.colorByte("FFFFFF"), 0xFF)
    }

    func testSingleHoldFramesAsOnlyPacket() {
        // position 1096 = 0x0448 → LE 0x48 0x04; color 00FF00 → 0x1C; marker ONLY = 0x54.
        // checksum = ~(0x54+0x48+0x04+0x1C) & 0xFF = ~0xBC & 0xFF = 0x43.
        let messages = KilterProtocol.messages(for: [(1096, "00FF00")])
        XCTAssertEqual(messages, [[0x01, 0x04, 0x43, 0x02, 0x54, 0x48, 0x04, 0x1C, 0x03]])
    }

    func testEmptyHoldsClearsTheBoard() {
        // No holds → a single ONLY packet with empty body: checksum = ~0x54 & 0xFF = 0xAB.
        XCTAssertEqual(KilterProtocol.messages(for: []), [[0x01, 0x01, 0xAB, 0x02, 0x54, 0x03]])
    }

    func testFramingShapeAndChunkBoundaries() {
        // 5 holds = 15 body bytes > the 12-byte (4-hold) chunk → splits into FIRST(82)+LAST(83).
        let holds = (0..<5).map { (position: $0, colorHex: "00FF00") }
        let messages = KilterProtocol.messages(for: holds)

        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0][4], 0x52, "first packet marker")   // payload starts after 0x01 len cksum 0x02
        XCTAssertEqual(messages.last?[4], 0x53, "last packet marker")
        for message in messages {
            XCTAssertEqual(message.first, 0x01)
            XCTAssertEqual(message.last, 0x03)
            XCTAssertLessThanOrEqual(message.count, 20, "each write must fit the 20-byte BLE ATT payload")
            // length byte == the marker+holds payload it frames.
            XCTAssertEqual(Int(message[1]), message.count - 5)
        }
    }

    // MARK: - API level 2 (older boards: 2-byte holds, R2G2B2, markers 78/77/79/80)

    func testColorBitsV2PacksR2G2B2InHighSixBits() {
        XCTAssertEqual(KilterProtocol.colorBitsV2("00FF00"), 0x30)   // green: g=3<<4
        XCTAssertEqual(KilterProtocol.colorBitsV2("FF0000"), 0xC0)   // red:   r=3<<6
        XCTAssertEqual(KilterProtocol.colorBitsV2("0000FF"), 0x0C)   // blue:  b=3<<2
        XCTAssertEqual(KilterProtocol.colorBitsV2("FFFFFF"), 0xFC)   // low 2 bits stay clear for position
    }

    func testV2SingleHoldFramesAsOnlyPacket() {
        // position 1096 → byte0 0x48, high bits 0; color 00FF00 → 0x30; marker ONLY = 0x50.
        let messages = KilterProtocol.messages(for: [(1096, "00FF00")], level: .v2)
        XCTAssertEqual(messages, [[0x01, 0x03, 0x37, 0x02, 0x50, 0x48, 0x30, 0x03]])
    }

    func testV2PacksHighPositionBitsIntoColorByte() {
        // position 0x0300 → byte0 0x00, high 2 bits = 0b11 OR'd under red (FF0000 → 0xC0) = 0xC3.
        let messages = KilterProtocol.messages(for: [(0x0300, "FF0000")], level: .v2)
        XCTAssertEqual(messages, [[0x01, 0x03, 0xEC, 0x02, 0x50, 0x00, 0xC3, 0x03]])
    }

    func testV2ChunksOnTwoByteHoldsAndStaysWithinPayload() {
        // 7 holds = 14 body bytes > the 12-byte (6-hold) chunk → FIRST(78) + LAST(79).
        let holds = (0..<7).map { (position: $0, colorHex: "00FF00") }
        let messages = KilterProtocol.messages(for: holds, level: .v2)

        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0][4], 0x4E, "v2 first marker (78)")
        XCTAssertEqual(messages.last?[4], 0x4F, "v2 last marker (79)")
        for message in messages {
            XCTAssertEqual(message.first, 0x01)
            XCTAssertEqual(message.last, 0x03)
            XCTAssertLessThanOrEqual(message.count, 20)
        }
    }
}
