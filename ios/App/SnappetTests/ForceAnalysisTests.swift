import XCTest
@testable import Snappet

/// Prompt 145 — the Tindeq Progressor packet format and force analysis, without a device.
final class ForceAnalysisTests: XCTestCase {

    private func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)] }
    private func weightsPacket(_ pairs: [(Float, UInt32)]) -> Data {
        var b: [UInt8] = [1, UInt8(pairs.count * 8)]
        for (kg, us) in pairs { b += le32(kg.bitPattern) + le32(us) }
        return Data(b)
    }

    // MARK: - Protocol

    func testParsesAWeightBatch() {
        let p = TindeqProtocol.parse(weightsPacket([(12.5, 1_000), (12.75, 13_500)]))
        XCTAssertEqual(p, .weights([(12.5, 1_000), (12.75, 13_500)]))
    }

    func testParsesBatteryAndLowPower() {
        let resp = TindeqProtocol.parse(Data([0, 4] + le32(3_960)))
        guard case .commandResponse(let payload)? = resp else { return XCTFail("\(String(describing: resp))") }
        XCTAssertEqual(TindeqProtocol.batteryMillivolts(payload), 3_960)
        XCTAssertEqual(TindeqProtocol.batteryPercent(millivolts: 3_960), 73)
        XCTAssertEqual(TindeqProtocol.parse(Data([4, 0])), .lowPower)
    }

    func testRejectsTruncatedAndIgnoresPartialPairs() {
        XCTAssertNil(TindeqProtocol.parse(Data([1])))
        let partial = Data([1, 12] + le32(Float(5).bitPattern) + le32(10) + [0, 0, 0, 0])
        XCTAssertEqual(TindeqProtocol.parse(partial), .weights([(5, 10)]))
    }

    func testCommandBytesMatchThePublishedAPI() {
        XCTAssertEqual(TindeqProtocol.Command.tare.rawValue, 100)
        XCTAssertEqual(TindeqProtocol.Command.startWeight.rawValue, 101)
        XCTAssertEqual(TindeqProtocol.Command.stopWeight.rawValue, 102)
        XCTAssertEqual(TindeqProtocol.Command.battery.rawValue, 111)
    }

    // MARK: - Analysis

    /// A 7 s hang at ~46 kg, sampled at 80 Hz, with a 0.2 s ramp and noise near zero either side.
    private func hang(start: Double, seconds: Double = 7, kg: Double = 46) -> [ForceSample] {
        stride(from: start - 1, through: start + seconds + 1, by: 1.0 / 80).map { t in
            let rel = t - start
            let v: Double
            if rel < 0 || rel > seconds { v = 0.3 }
            else if rel < 0.2 { v = kg * rel / 0.2 }
            else { v = kg + sin(t * 9) * 0.6 }
            return ForceSample(t: t, kg: v)
        }
    }

    func testDetectsOneRepWithPeakMeanAndDuration() {
        let reps = ForceAnalysis.reps(in: hang(start: 2))
        XCTAssertEqual(reps.count, 1)
        let r = reps[0]
        XCTAssertEqual(r.duration, 7, accuracy: 0.1)
        XCTAssertEqual(r.peakKg, 46.6, accuracy: 0.1)
        XCTAssertEqual(r.meanKg, 46, accuracy: 0.6)
        XCTAssertGreaterThan(r.rfdKgPerSec, 150)
    }

    func testHysteresisIgnoresNoiseAroundTheThreshold() {
        var d = ForceAnalysis.Detector(onKg: 5)
        XCTAssertEqual(d.feed(5.2), .loaded)
        XCTAssertNil(d.feed(4.4), "a dip to 4.4 kg is still loaded (release is below 3 kg)")
        XCTAssertNil(d.feed(5.5))
        XCTAssertEqual(d.feed(2.9), .released)
    }

    func testSeparatesRepsAndDropsBlips() {
        var s = hang(start: 2, seconds: 3) + hang(start: 10, seconds: 4)
        s.append(contentsOf: [ForceSample(t: 20, kg: 9), ForceSample(t: 20.05, kg: 0.1)])   // 50 ms blip
        let reps = ForceAnalysis.reps(in: s)
        XCTAssertEqual(reps.count, 2)
        XCTAssertEqual(reps.map { ($0.duration * 10).rounded() / 10 }, [3, 4])
    }

    func testTargetBandAndUnderTarget() {
        let band = ForceAnalysis.targetBand(maxKg: 52, percent: 90)
        XCTAssertEqual(band.lowerBound, 45.4, accuracy: 0.05)
        XCTAssertEqual(band.upperBound, 48.2, accuracy: 0.05)
        XCTAssertFalse(ForceAnalysis.isUnderTarget(45.0, band: band), "within grace")
        XCTAssertTrue(ForceAnalysis.isUnderTarget(43.0, band: band))
        XCTAssertEqual(ForceAnalysis.asymmetry(left: 52.4, right: 55.1)!, 0.049, accuracy: 0.001)
    }
}
