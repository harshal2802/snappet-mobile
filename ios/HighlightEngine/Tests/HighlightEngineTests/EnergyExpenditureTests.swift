import XCTest
@testable import HighlightEngine

final class EnergyExpenditureTests: XCTestCase {

    func testPerMinuteRisesWithHeartRate() {
        let low = EnergyExpenditure.keytelKcalPerMinute(bpm: 90, ageYears: 30, weightKg: 75, male: true)
        let high = EnergyExpenditure.keytelKcalPerMinute(bpm: 160, ageYears: 30, weightKg: 75, male: true)
        XCTAssertGreaterThan(high, low)
        XCTAssertGreaterThan(low, 0)
    }

    func testPerMinuteSexDiffers() {
        let m = EnergyExpenditure.keytelKcalPerMinute(bpm: 150, ageYears: 30, weightKg: 75, male: true)
        let f = EnergyExpenditure.keytelKcalPerMinute(bpm: 150, ageYears: 30, weightKg: 75, male: false)
        XCTAssertGreaterThan(m, f)   // the male regression yields more at the same inputs/weight
    }

    func testPerMinuteClampsNonNegative() {
        // A very low HR can push the regression negative; it must clamp to 0, never subtract.
        let v = EnergyExpenditure.keytelKcalPerMinute(bpm: 40, ageYears: 20, weightKg: 50, male: false)
        XCTAssertGreaterThanOrEqual(v, 0)
    }

    func testTotalIntegratesOverDuration() {
        // 10 minutes at a steady 150 bpm ≈ 10 × per-minute, via left-edge dwell to durationSec.
        let perMin = EnergyExpenditure.keytelKcalPerMinute(bpm: 150, ageYears: 30, weightKg: 75, male: true)
        let samples = (0...600).filter { $0 % 60 == 0 }.map { HRSample(t: Double($0), bpm: 150) }
        let total = try! XCTUnwrap(EnergyExpenditure.keytelKcal(
            samples: samples, durationSec: 600, ageYears: 30, weightKg: 75, male: true))
        XCTAssertEqual(total, perMin * 10, accuracy: perMin * 0.05)
    }

    func testTotalCapsAtDuration() {
        // A trailing sample past `durationSec` must not bill beyond the session end.
        let capped = EnergyExpenditure.keytelKcal(
            samples: [HRSample(t: 0, bpm: 150), HRSample(t: 30, bpm: 150)],
            durationSec: 60, ageYears: 30, weightKg: 75, male: true)
        let perMin = EnergyExpenditure.keytelKcalPerMinute(bpm: 150, ageYears: 30, weightKg: 75, male: true)
        XCTAssertEqual(try! XCTUnwrap(capped), perMin, accuracy: perMin * 0.02)  // exactly ~1 minute
    }

    func testNilForEmptyOrZeroDuration() {
        XCTAssertNil(EnergyExpenditure.keytelKcal(samples: [], durationSec: 60, ageYears: 30, weightKg: 75, male: true))
        XCTAssertNil(EnergyExpenditure.keytelKcal(samples: [HRSample(t: 0, bpm: 150)], durationSec: 0,
                                                  ageYears: 30, weightKg: 75, male: true))
    }
}
