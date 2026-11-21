import SwiftUI

// Prompt 272: say on the clip itself whether it has a copy in Google Drive, and where.
// Each view is a small leaf that reads the vault on its own, so a copy finishing redraws the mark
// and not the whole post or session screen.

/// A small cloud on a clip that has a copy. Nothing at all when it has none.
struct ClipCopyMark: View {
    enum Style { case inline, onMedia }
    let clipID: UUID
    var style: Style = .inline
    @Environment(\.mediaVault) private var vault

    var body: some View {
        if let vault, vault.bringingBack.contains(clipID) {
            ProgressView().controlSize(.mini)
                .accessibilityLabel("Bringing back from Google Drive")
        } else if let vault, vault.bringBackFailure?.clip == clipID {
            Image(systemName: "exclamationmark.icloud")
                .font(.system(size: 12)).foregroundStyle(.red)
                .accessibilityLabel("Couldn’t bring this clip back")
        } else if let vault, vault.contains(clipID) {
            switch style {
            case .inline:
                Image(systemName: "checkmark.icloud")
                    .font(.system(size: 12))
                    .foregroundStyle(SnappetColor.textSecondary)
                    .accessibilityLabel("Copied to Google Drive")
                    .accessibilityIdentifier("clips.copyMark")
            case .onMedia:
                Image(systemName: "checkmark.icloud.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(3)
                    .background(.black.opacity(0.55), in: Circle())
                    .padding(4)
                    .accessibilityLabel("Copied to Google Drive")
                    .accessibilityIdentifier("clips.copyMark")
            }
        }
    }
}

/// The clip menu's lines: where the copy is and a way to open it, or that there is none yet.
struct ClipCopyMenuItems: View {
    let clipID: UUID
    @Environment(\.mediaVault) private var vault
    @Environment(\.openURL) private var openURL
    @Environment(AppModel.self) private var app: AppModel?
    @Environment(\.modelContext) private var context

    var body: some View {
        if let vault, vault.showsCopyState {
            if let place = vault.location(of: clipID) {
                Section(vault.bringBackFailure?.clip == clipID ? "Couldn’t bring it back: \(vault.bringBackFailure?.message ?? "")"
                                                                 : "Copied to \(place)") {
                    if let url = vault.index.entry(for: clipID)?.driveURL {
                        Button { openURL(url) } label: { Label("Open in Google Drive", systemImage: "arrow.up.forward.app") }
                            .accessibilityIdentifier("clips.post.openInDrive")
                    }
                    if vault.onlyInDrive.contains(clipID) {
                        // The only footage left is this copy: it can come back, it cannot be removed here.
                        Button { Task { await vault.bringBackNow(clipID, context: context) } } label: {
                            Label("Bring back to this iPhone", systemImage: "arrow.down.to.line")
                        }
                        .disabled(vault.bringingBack.contains(clipID))
                        .accessibilityIdentifier("clips.post.bringBack")
                    } else {
                        // iOS asks before anything leaves Photos, and keeps it 30 days.
                        Button {
                            Task { await vault.freeUpClip(clipID, context: context); await app?.reconcileMediaLinks() }
                        } label: { Label("Remove from this iPhone", systemImage: "iphone.slash") }
                        .disabled(vault.isBusy || !vault.libraryVisible)
                        .accessibilityIdentifier("clips.post.freeUp")
                        Button(role: .destructive) { Task { await vault.removeCopy(of: clipID) } } label: {
                            Label("Remove copy from Google Drive", systemImage: "icloud.slash")
                        }
                        .accessibilityIdentifier("clips.post.removeCopy")
                    }
                }
            } else if vault.excluded.contains(clipID) {
                Section("Copy removed — not copied again") {
                    Button { vault.copyAgain(clipID) } label: { Label("Copy to Google Drive again", systemImage: "icloud.and.arrow.up") }
                        .accessibilityIdentifier("clips.post.copyAgain")
                }
            } else {
                Button {} label: { Label("Not copied to Google Drive yet", systemImage: "icloud.slash") }
                    .disabled(true)
            }
        }
    }
}

/// One line for a session: how many of its clips have a copy.
struct SessionCopyLine: View {
    let clipIDs: [UUID]
    @Environment(\.mediaVault) private var vault

    var body: some View {
        if let vault, vault.showsCopyState,
           let line = MediaVaultText.sessionCopies(copied: vault.index.copiedCount(of: clipIDs), total: clipIDs.count) {
            Label(line, systemImage: vault.index.copiedCount(of: clipIDs) >= clipIDs.count ? "checkmark.icloud" : "icloud.and.arrow.up")
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("session.copyLine")
        }
    }
}

/// Editing needs the original in Photos. For a clip that lives only in Drive, offer to bring it
/// back instead of opening an empty editor. Set `clipID` to ask.
struct BringBackToEdit: ViewModifier {
    @Binding var clipID: UUID?
    @Environment(\.mediaVault) private var vault
    @Environment(\.modelContext) private var context

    func body(content: Content) -> some View {
        content.alert("This clip is in Google Drive", isPresented: Binding(get: { clipID != nil }, set: { if !$0 { clipID = nil } })) {
            Button("Bring back") {
                if let id = clipID, let vault { Task { await vault.bringBackNow(id, context: context) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It is no longer on this iPhone. Bring it back to edit it: it downloads from Google Drive and is saved to Photos. Open it again when the cloud mark stops spinning.")
        }
    }
}

extension View {
    func bringBackToEdit(_ clipID: Binding<UUID?>) -> some View { modifier(BringBackToEdit(clipID: clipID)) }
}
