import SwiftUI
import UIKit

/// Invite someone (wireframe frame 4): a one-time QR that expires in five minutes. It carries a token,
/// never the household key; the key travels only over the encrypted channel once the token checks out.
struct HouseholdInviteSheet: View {
    let service: HouseholdPeerService
    let householdName: String

    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    private static let isUITest = ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("-uiTest") }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let joined = service.inviteJoinedBy {
                        joinedView(joined)
                    } else if let invite = service.invite {
                        code(invite)
                    } else {
                        expiredView
                    }
                    trustRows
                }
                .padding()
            }
            .background(SnappetColor.paper)
            .navigationTitle("Invite to \(householdName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("household.invite.done")
                }
            }
        }
        .onAppear { if service.invite == nil, service.inviteJoinedBy == nil { service.openInvite() } }
        .onDisappear { service.closeInvite() }
    }

    private func code(_ invite: HouseholdInvite) -> some View {
        VStack(spacing: 12) {
            Text("Scan with the camera, or in Snappet → Household → Join a household.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let image = QRCodeImage.make(for: invite.url.absoluteString) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable().scaledToFit()
                    .frame(maxWidth: 240, maxHeight: 240)
                    .padding(16)
                    .background(.white, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityLabel("Invite code for \(householdName)")
                    .accessibilityIdentifier("household.invite.qr")
                    // The two-simulator E2E test reads the link here (UI-test launches only).
                    .accessibilityValue(Self.isUITest ? invite.url.absoluteString : "")
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = max(0, Int(invite.expires.timeIntervalSince(context.date)))
                Text("Expires in \(left / 60):\(String(format: "%02d", left % 60)) · works once")
                    .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
            }
            Button {
                UIPasteboard.general.string = invite.url.absoluteString
                copied = true
            } label: {
                Label(copied ? "Link copied" : "Copy invite link", systemImage: copied ? "checkmark" : "link")
            }
            .buttonStyle(.bordered)
            .tint(SnappetColor.household)
            .accessibilityIdentifier("household.invite.copy")
            ProgressView().controlSize(.small).opacity(service.isSyncing ? 1 : 0)
        }
    }

    private func joinedView(_ name: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 54)).foregroundStyle(SnappetColor.household)
            Text("\(name) joined").font(.title3.weight(.bold))
                .accessibilityIdentifier("household.invite.joined")
            Text("Your phones now share one board. They catch up whenever they're on the same Wi-Fi with Snappet open.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Invite someone else") { service.openInvite() }
                .buttonStyle(.bordered).tint(SnappetColor.household)
        }
        .padding(.vertical, 20)
    }

    private var expiredView: some View {
        VStack(spacing: 10) {
            Text("This code has expired.").font(.headline)
            Button("Make a new code") { service.openInvite() }
                .buttonStyle(.borderedProminent).tint(SnappetColor.household)
        }
        .padding(.vertical, 30)
    }

    private var trustRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            trust("lock.fill", "Only phones that scan a code can read or change the board.")
            Divider()
            trust("wifi", "You both need to be on the same Wi-Fi.")
            Divider()
            trust("icloud.slash", "Nothing goes to a server. Chores travel phone to phone.")
        }
        .background(SnappetColor.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private func trust(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(SnappetColor.household).frame(width: 22)
            Text(text).font(.subheadline)
            Spacer(minLength: 0)
        }
        .padding(12)
    }
}
