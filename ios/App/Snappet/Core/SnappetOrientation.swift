import SwiftUI
import UIKit

/// **Per-screen orientation lock** (prompt 254). SwiftUI has no per-view lock, so the app delegate answers
/// `supportedInterfaceOrientationsFor` from `SnappetOrientation.mask`. A screen designed only for portrait (the racket
/// player's Edit mode and Share sheet) calls `lockPortrait()` while it shows and `unlock()` when it goes; everything else
/// keeps rotating as the Info.plist allows. iPhone only: on iPad the lock is ignored.
final class SnappetAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        MainActor.assumeIsolated { SnappetOrientation.mask }
    }
}

@MainActor
enum SnappetOrientation {
    /// What the app allows right now.
    static var mask: UIInterfaceOrientationMask = .allButUpsideDown
    /// Screens holding the lock (Edit over a Share sheet, say): it lifts when the last one goes.
    private static var holders = 0

    static var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    static func lockPortrait() {
        guard isPhone else { return }
        holders += 1
        apply(.portrait)
    }

    static func unlock() {
        guard isPhone, holders > 0 else { return }
        holders -= 1
        if holders == 0 { apply(.allButUpsideDown) }
    }

    private static func apply(_ m: UIInterfaceOrientationMask) {
        mask = m
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows {
                var vc = window.rootViewController
                while let v = vc {
                    v.setNeedsUpdateOfSupportedInterfaceOrientations()
                    vc = v.presentedViewController
                }
            }
            // Turn now when the lock asks for portrait (the phone may be held sideways); unlocking lets the device's
            // own orientation take over again.
            if m == .portrait { scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in } }
        }
    }
}

extension View {
    /// Keep this screen upright on iPhone while it shows.
    func portraitOnly() -> some View {
        onAppear { SnappetOrientation.lockPortrait() }
            .onDisappear { SnappetOrientation.unlock() }
    }
}
