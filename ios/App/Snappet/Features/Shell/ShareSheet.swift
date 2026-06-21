import SwiftUI
import UIKit

/// One shared UIKit `UIActivityViewController` bridge for the whole app (B5). Used by the flagship
/// Reels app and the WorkoutTracker video studio (the B3 clip editor + the B4 highlight reel) so
/// there is exactly one system-share component — no duplicated `UIViewControllerRepresentable`.
/// Originally `private` to `ReelView`; generalized here when WorkoutTracker gained share/save.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    /// Optional completion. `completed` is whether the user actually shared; `activityType` is the
    /// chosen `UIActivity.ActivityType.rawValue` (nil when cancelled / unknown) — the Recap feed
    /// (F4) maps it to a `FeedShareEvent.channel` via `ShareTemplateModel.shareChannel`.
    var onComplete: ((_ completed: Bool, _ activityType: String?) -> Void)? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        vc.completionWithItemsHandler = { activityType, completed, _, _ in
            onComplete?(completed, activityType?.rawValue)
        }
        return vc
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
