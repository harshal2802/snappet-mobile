import XCTest
import UIKit
@testable import Snappet

/// Prompt 138 — the schedule rides the routine QR code, and a QR can be imported from a photo.
final class RoutineQRScheduleTests: XCTestCase {

    private let blocks = [RoutineExercise(exerciseId: "Barbell_Bench_Press_-_Medium_Grip", sets: 4, reps: "8", restSeconds: 120),
                          RoutineExercise(exerciseId: "Pullups", sets: 3, reps: "10", restSeconds: 90)]

    private var schedule: RoutineSchedule {
        var s = RoutineSchedule(startDay: DayKey(value: 20260928))
        s.repeatRule = .weekly(weekdays: [2, 4, 6], everyWeeks: 1)
        s.reminder.leadMinutes = 30
        s.skippedDays = [DayKey(value: 20260930)]
        return s
    }

    // MARK: - Payload

    func testScheduleRoundTripsWithoutSkipHistory() throws {
        let shared = SharedRoutine(name: "Push Day", detail: nil, exercises: blocks, schedule: schedule)
        let back = try XCTUnwrap(SharedRoutine(decoding: shared.encoded))
        XCTAssertEqual(back.schedule?.repeatRule, schedule.repeatRule)
        XCTAssertEqual(back.schedule?.reminder.leadMinutes, 30)
        XCTAssertEqual(back.schedule?.skippedDays, [], "skips are device-local")
        XCTAssertEqual(back.exercises.count, 2)
    }

    func testNoScheduleStaysByteIdenticalToV1() {
        let before = SharedRoutine(name: "Push Day", detail: nil, exercises: blocks)
        XCTAssertFalse(before.encoded.isEmpty)
        let json = String(decoding: try! JSONEncoder().encode(before), as: UTF8.self)
        XCTAssertFalse(json.contains("\"sc\""), "no schedule → no new key, so existing codes don't change")
    }

    func testAScheduleCostsFewBytes() {
        let plain = SharedRoutine(name: "Push Day", detail: nil, exercises: blocks)
        let withSchedule = SharedRoutine(name: "Push Day", detail: nil, exercises: blocks, schedule: schedule)
        XCTAssertLessThan(withSchedule.encodedByteCount - plain.encodedByteCount, 80,
                          "\(plain.encodedByteCount) → \(withSchedule.encodedByteCount)")
    }

    /// An older build's decoder only knows n/d/e — it must still read a code that carries `sc`.
    func testOlderDecoderIgnoresTheScheduleKey() throws {
        struct V1: Decodable {
            let n: String
            let e: [SharedRoutine.Block]
        }
        let data = try JSONEncoder().encode(SharedRoutine(name: "Push Day", detail: nil, exercises: blocks,
                                                          schedule: schedule))
        let old = try JSONDecoder().decode(V1.self, from: data)
        XCTAssertEqual(old.n, "Push Day")
        XCTAssertEqual(old.e.count, 2)
    }

    func testMalformedScheduleDoesNotSinkTheRoutine() throws {
        let json = #"{"n":"Push Day","e":[{"x":"Pullups"}],"sc":{"garbage":true}}"#
        let decoded = try JSONDecoder().decode(SharedRoutine.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.name, "Push Day")
        XCTAssertNil(decoded.schedule)
    }

    // MARK: - Photo import

    private func png(_ image: UIImage) -> Data { image.pngData()! }

    /// A code sitting in a bigger, busier image — like a screenshot of a chat.
    private func screenshot(with qr: UIImage) -> Data {
        let size = CGSize(width: 1170, height: 2532)
        let renderer = UIGraphicsImageRenderer(size: size, format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
        return renderer.pngData { ctx in
            UIColor(white: 0.93, alpha: 1).setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            UIColor.systemBlue.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: size.width, height: 260))
            UIColor.white.setFill(); ctx.fill(CGRect(x: 180, y: 700, width: 810, height: 810))
            qr.draw(in: CGRect(x: 225, y: 745, width: 720, height: 720))
        }
    }

    /// Photo → payloads → the generic pick (prompt 201; routines since prompt 138).
    private func pick(_ data: Data) async -> SnappetCodeImport.Outcome<SharedRoutine> {
        SnappetCodeImport.pick(await QRImageDecoder.payloads(in: data), decode: { SharedRoutine(decoding: $0) })
    }

    func testDecodesARoutineFromAScreenshot() async throws {
        let shared = SharedRoutine(name: "Push Day", detail: nil, exercises: blocks, schedule: schedule)
        // The https form — what the share sheet's QR carries since prompt 200.
        let qr = try XCTUnwrap(QRCodeImage.make(for: SnappetWebLink.webForm(shared.encoded)))
        guard case .value(let routine) = await pick(screenshot(with: qr)) else { return XCTFail("no routine") }
        XCTAssertEqual(routine.name, "Push Day")
        XCTAssertEqual(routine.schedule?.repeatRule, schedule.repeatRule)
    }

    func testPhotoWithoutACodeSaysSo() async {
        let blank = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 400)).image { ctx in
            UIColor.gray.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 400))
        }
        guard case .failure(.noCode) = await pick(png(blank)) else { return XCTFail("expected noCode") }
    }

    func testForeignQRIsNotSnappet() async throws {
        let qr = try XCTUnwrap(QRCodeImage.make(for: "https://example.com/not-a-routine"))
        guard case .failure(.notSnappet) = await pick(png(qr)) else { return XCTFail("expected notSnappet") }
    }

    func testAnotherKindOfSnappetCodeIsHandedOn() async throws {
        let climb = KilterClimbLink(uuid: "11111111-1111-4111-8111-111111111111", angle: 40)
        let qr = try XCTUnwrap(QRCodeImage.make(for: SnappetWebLink.webForm(climb.encoded)))
        guard case .otherLink(let link) = await pick(png(qr)) else { return XCTFail("expected otherLink") }
        XCTAssertEqual(link, climb.encoded, "handed on in its snappet:// form")
    }

    func testFirstRoutineAmongSeveralPayloadsWins() {
        let shared = SharedRoutine(name: "Legs", detail: nil, exercises: blocks)
        let climb = KilterClimbLink(uuid: "11111111-1111-4111-8111-111111111111").encoded
        let outcome = SnappetCodeImport.pick(["https://example.com", climb, shared.encoded],
                                             decode: { SharedRoutine(decoding: $0) })
        guard case .value(let r) = outcome else { return XCTFail("the routine wins over another kind") }
        XCTAssertEqual(r.name, "Legs")
        guard case .failure(.noCode) = SnappetCodeImport.pick([], decode: { SharedRoutine(decoding: $0) }) else {
            return XCTFail("expected noCode")
        }
    }

    func testDescribesWhatALinkOpens() {
        XCTAssertEqual(SnappetCodeImport.describe("https://harshal2802.github.io/Snappet/open/kilter/climb/x"), "a Kilter climb")
        XCTAssertEqual(SnappetCodeImport.describe("snappet://routine/v1/abc"), "a workout routine")
        XCTAssertNil(SnappetCodeImport.snappetLink("https://example.com/x"))
    }
}
