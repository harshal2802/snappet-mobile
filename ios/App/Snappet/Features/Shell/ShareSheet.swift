import SwiftUI
import UIKit

/// One shared UIKit `UIActivityViewController` bridge for the whole app (B5). Used by the flagship
/// Reels app and the WorkoutTracker video studio (the B3 clip editor + the B4 highlight reel) so
/// there is exactly one system-share component — no duplicated `UIViewControllerRepresentable`.
/// Originally `private` to `ReelView`; generalized here when WorkoutTracker gained share/save.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
