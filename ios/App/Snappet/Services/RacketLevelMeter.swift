import CoreMotion
import Foundation
import Observation

/// **The pro camera's level** (prompt 255, Options → Framing → Level): gravity from CoreMotion, turned into the tilt of
/// the picture's horizon by the pure `RacketLevel`. Device motion needs no permission. Runs only while the camera shows
/// the level. The fake camera (`-uiTestFakeCamera`, the simulator) has no motion: it reads `-uiTestCameraTilt N`
/// (degrees, DEBUG) or stands level.
@MainActor
@Observable
final class RacketLevelMeter {
    private(set) var tilt: Double?
    @ObservationIgnored private let motion = CMMotionManager()
    @ObservationIgnored private let fake: Bool

    init(fake: Bool) { self.fake = fake }

    func start() {
        if fake {
            #if DEBUG
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-uiTestCameraTilt"), i + 1 < args.count, let t = Double(args[i + 1]) {
                tilt = t
                return
            }
            #endif
            tilt = 0
            return
        }
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 15
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let g = data?.gravity else { return }
            MainActor.assumeIsolated { self?.tilt = RacketLevel.tilt(gx: g.x, gy: g.y, gz: g.z) }
        }
    }

    func stop() {
        if motion.isDeviceMotionActive { motion.stopDeviceMotionUpdates() }
    }
}
