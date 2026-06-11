import SwiftUI
import UIKit

/// Renders a pure `ReelFlowPolicy.RecoverySpec` as a `ContentUnavailableView` whose actions
/// actually work — the one surface behind every reel/workout dead end (issue #72), so the
/// copy/action *selection* stays in the unit-tested policy and this stays a dumb renderer.
///
/// `.openSettings` is handled here (the Settings deep-link is identical everywhere); every other
/// action is forwarded to the caller. The first action renders as the primary button.
struct RecoveryUnavailableView: View {
    let spec: ReelFlowPolicy.RecoverySpec
    /// Prefix for the action buttons' accessibility identifiers (e.g. "reel" → "reelOpenSettings").
    let identifierPrefix: String
    let onAction: (ReelFlowPolicy.RecoveryAction) -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        ContentUnavailableView {
            Label(spec.title, systemImage: spec.systemImage)
        } description: {
            Text(spec.message)
        } actions: {
            ForEach(Array(spec.actions.enumerated()), id: \.element) { index, action in
                button(for: action, isPrimary: index == 0)
            }
        }
    }

    @ViewBuilder
    private func button(for action: ReelFlowPolicy.RecoveryAction, isPrimary: Bool) -> some View {
        let button = Button(action.buttonTitle) { handle(action) }
            .accessibilityIdentifier(identifierPrefix + action.identifierSuffix)
        if isPrimary {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private func handle(_ action: ReelFlowPolicy.RecoveryAction) {
        if action == .openSettings {
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            return
        }
        onAction(action)
    }
}
