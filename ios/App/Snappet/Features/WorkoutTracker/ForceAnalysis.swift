import Foundation

/// One force reading from a sensor: seconds since measuring started, and the load in kg.
struct ForceSample: Equatable, Sendable {
    var t: TimeInterval
    var kg: Double
}

/// The Tindeq Progressor's Bluetooth protocol (prompt 145), from Tindeq's published API: commands are
/// single bytes written to the control point; data arrives on the data point as tag-length-value
/// packets, little-endian. Pure → unit-tested against byte arrays, no device needed.
enum TindeqProtocol {
    static let serviceUUID = "7E4E1701-1EA6-40C9-9DCC-13D34FFEAD57"
    static let dataUUID = "7E4E1702-1EA6-40C9-9DCC-13D34FFEAD57"
    static let controlUUID = "7E4E1703-1EA6-40C9-9DCC-13D34FFEAD57"

    enum Command: UInt8 {
        case tare = 100
        case startWeight = 101
        case stopWeight = 102
        case sleep = 110
        case battery = 111
    }

    enum Packet: Equatable {
        /// Tag 1: a batch of (weight kg, microseconds since measuring started).
        case weights([(kg: Double, micros: UInt32)])
        /// Tag 0: a reply to the last command — the battery voltage when that was asked.
        case commandResponse(Data)
        /// Tag 4: the device is low on battery.
        case lowPower
        case unknown(tag: UInt8)

        static func == (a: Packet, b: Packet) -> Bool {
            switch (a, b) {
            case let (.weights(x), .weights(y)):
                return x.count == y.count && zip(x, y).allSatisfy { $0.kg == $1.kg && $0.micros == $1.micros }
            case let (.commandResponse(x), .commandResponse(y)): return x == y
            case (.lowPower, .lowPower): return true
            case let (.unknown(x), .unknown(y)): return x == y
            default: return false
            }
        }
    }

    static func parse(_ data: Data) -> Packet? {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { return nil }
        let tag = bytes[0]
        let length = Int(bytes[1])
        let payload = Array(bytes.dropFirst(2).prefix(length))
        switch tag {
        case 1:
            var out: [(Double, UInt32)] = []
            var i = 0
            while i + 8 <= payload.count {
                let kg = Float(bitPattern: le32(payload, i))
                let micros = le32(payload, i + 4)
                if kg.isFinite { out.append((Double(kg), micros)) }
                i += 8
            }
            return .weights(out)
        case 0: return .commandResponse(Data(payload))
        case 4: return .lowPower
        default: return .unknown(tag: tag)
        }
    }

    /// Battery voltage (mV) from a battery command response, if it is one.
    static func batteryMillivolts(_ payload: Data) -> UInt32? {
        let b = [UInt8](payload)
        return b.count >= 4 ? le32(b, 0) : nil
    }

    /// A rough Li-ion percentage for display (3.3 V empty → 4.2 V full).
    static func batteryPercent(millivolts mv: UInt32) -> Int {
        let pct = (Double(mv) - 3300) / (4200 - 3300) * 100
        return Int(min(100, max(0, pct)).rounded())
    }

    private static func le32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
}

/// Force analysis for hangs and pulls (prompt 145, wireframe frames 12–14). Pure → unit-tested on
/// recorded or synthetic samples; the sensor service only collects samples.
enum ForceAnalysis {
    /// One loaded stretch: hands on → hands off.
    struct Rep: Equatable, Sendable {
        var start: TimeInterval
        var end: TimeInterval
        var peakKg: Double
        var meanKg: Double
        /// Peak rate of force development over the first 0.3 s of loading, kg/s.
        var rfdKgPerSec: Double
        var duration: TimeInterval { end - start }
    }

    /// Hands-on detection with hysteresis: loaded above `onKg`, released below `offFraction × onKg`, so
    /// noise around the threshold can't flicker a rep on and off.
    struct Detector: Sendable {
        var onKg: Double = 5
        var offFraction: Double = 0.6
        private(set) var isLoaded = false

        init(onKg: Double = 5, offFraction: Double = 0.6) {
            self.onKg = onKg
            self.offFraction = offFraction
        }

        enum Edge: Equatable { case loaded, released }

        /// Feed one reading; returns an edge when the state changes.
        mutating func feed(_ kg: Double) -> Edge? {
            if !isLoaded, kg >= onKg { isLoaded = true; return .loaded }
            if isLoaded, kg < onKg * offFraction { isLoaded = false; return .released }
            return nil
        }
    }

    /// Every rep in a stream of samples.
    static func reps(in samples: [ForceSample], onKg: Double = 5, offFraction: Double = 0.6,
                     minDuration: TimeInterval = 0.2) -> [Rep] {
        var detector = Detector(onKg: onKg, offFraction: offFraction)
        var out: [Rep] = []
        var startIndex: Int?
        for (i, s) in samples.enumerated() {
            switch detector.feed(s.kg) {
            case .loaded?: startIndex = i
            case .released?:
                if let a = startIndex, let rep = summarize(Array(samples[a..<i])), rep.duration >= minDuration {
                    out.append(rep)
                }
                startIndex = nil
            case nil: break
            }
        }
        if let a = startIndex, let rep = summarize(Array(samples[a...])), rep.duration >= minDuration {
            out.append(rep)
        }
        return out
    }

    /// Peak, time-weighted mean and early RFD of one loaded stretch.
    static func summarize(_ s: [ForceSample]) -> Rep? {
        guard let first = s.first, let last = s.last else { return nil }
        let peak = s.map(\.kg).max() ?? 0
        var area = 0.0
        for (a, b) in zip(s, s.dropFirst()) { area += (a.kg + b.kg) / 2 * (b.t - a.t) }
        let span = last.t - first.t
        let mean = span > 0 ? area / span : first.kg
        var rfd = 0.0
        let early = s.filter { $0.t - first.t <= 0.3 }
        for (a, b) in zip(early, early.dropFirst()) where b.t > a.t {
            rfd = max(rfd, (b.kg - a.kg) / (b.t - a.t))
        }
        return Rep(start: first.t, end: last.t, peakKg: peak, meanKg: mean, rfdKgPerSec: rfd)
    }

    /// The target band for "x % of your max": ±3 % around the target, at least ±1 kg wide.
    static func targetBand(maxKg: Double, percent: Double) -> ClosedRange<Double> {
        let target = maxKg * percent / 100
        let half = max(1, target * 0.03)
        return (target - half)...(target + half)
    }

    /// Whether a reading is under the band by more than a small grace (so a wobble isn't a warning).
    static func isUnderTarget(_ kg: Double, band: ClosedRange<Double>) -> Bool {
        kg < band.lowerBound - max(0.5, band.lowerBound * 0.02)
    }

    /// Left-vs-right difference as a share of the stronger side (0.05 = 5 %), nil if either is missing.
    static func asymmetry(left: Double?, right: Double?) -> Double? {
        guard let l = left, let r = right, max(l, r) > 0 else { return nil }
        return abs(l - r) / max(l, r)
    }
}
