import AuthenticationServices
import SwiftData
import SwiftUI

// MARK: - Automatic cloud backup UI (cloud-connect P2, prompt 267)

/// The "Automatic backup" section of Cloud & Backup. Off by default; every control says literally
/// what it does (off = nothing leaves this iPhone).
struct CloudBackupSection: View {
    let storeIsFallback: Bool
    @Environment(AppModel.self) private var app

    private var backup: CloudBackupService { app.cloudBackup }

    var body: some View {
        Section {
            Picker("Back up to", selection: destination) {
                Text("Off").tag(CloudBackupDestination.off)
                Text("iCloud").tag(CloudBackupDestination.iCloud)
                // Only in a build that carries a Google client ID (prompt 268).
                if app.google.isConfigured || backup.settings.destination == .googleDrive {
                    Text("Google Drive").tag(CloudBackupDestination.googleDrive)
                }
            }
            .disabled(storeIsFallback)
            .accessibilityIdentifier("cloudBackup.destination")

            if backup.settings.destination == .googleDrive {
                GoogleAccountRow { Task { await app.runCloudBackup(manual: true) } }
            }
            if backup.settings.destination != .off {
                statusRow
                Toggle("Include heart-rate samples", isOn: includeHeartRate)
                    .accessibilityIdentifier("cloudBackup.includeHeartRate")
                Toggle("Wi-Fi only", isOn: wifiOnly)
                    .accessibilityIdentifier("cloudBackup.wifiOnly")
                Button {
                    Task { await app.runCloudBackup(manual: true) }
                } label: {
                    Label("Back up now", systemImage: "arrow.up.circle")
                }
                .disabled(backup.phase == .working || storeIsFallback)
                .accessibilityIdentifier("cloudBackup.now")
            }
            NavigationLink {
                CloudRestoreList(storeIsFallback: storeIsFallback)
            } label: {
                Label("Restore from a cloud backup…", systemImage: "icloud.and.arrow.down")
            }
            .accessibilityIdentifier("cloudBackup.restoreList")
        } header: {
            Text("Automatic backup")
        } footer: {
            Text(footer)
        }
    }

    private var footer: String {
        switch backup.settings.destination {
        case .off:
            "Off: everything stays on this iPhone. Turn it on and Snappet keeps an encrypted copy of your records in your own cloud storage, updated when things change."
        case .iCloud, .googleDrive:
            (backup.settings.destination == .googleDrive
                ? "Backups go to a private app folder in your Google Drive that only Snappet can open. " : "")
            + (backup.settings.includeHeartRate
                ? "Heart-rate samples are included in the encrypted copy. "
                : "Heart-rate samples are left out of the copy; after a restore Snappet re-reads what Apple Health still has. ")
            + "Backups are encrypted on this iPhone before they leave it, with a key kept in your keychain. Photos and videos are not part of the backup."
        }
    }

    @ViewBuilder private var statusRow: some View {
        switch backup.phase {
        case .working:
            HStack { ProgressView(); Text("Backing up…").foregroundStyle(.secondary) }
                .accessibilityIdentifier("cloudBackup.status")
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red).font(.footnote)
                .accessibilityIdentifier("cloudBackup.status")
        case .idle:
            if let note = backup.note {
                Label(note, systemImage: "clock").foregroundStyle(.secondary).font(.footnote)
                    .accessibilityIdentifier("cloudBackup.status")
            } else if let last = backup.lastManifest {
                LabeledContent("Last backup") {
                    Text("\(last.createdAt.formatted(.relative(presentation: .named))) · \(CloudBackupStatusText.size(last.byteCount))")
                }
                .accessibilityIdentifier("cloudBackup.status")
            } else {
                Label("No backup yet", systemImage: "icloud.slash").foregroundStyle(.secondary).font(.footnote)
                    .accessibilityIdentifier("cloudBackup.status")
            }
        }
    }

    private var destination: Binding<CloudBackupDestination> {
        Binding(get: { backup.settings.destination }, set: { new in
            backup.update { $0.destination = new }
            if new != .off { Task { await app.runCloudBackup(manual: true) } }
        })
    }
    private var includeHeartRate: Binding<Bool> {
        Binding(get: { backup.settings.includeHeartRate }, set: { new in backup.update { $0.includeHeartRate = new } })
    }
    private var wifiOnly: Binding<Bool> {
        Binding(get: { backup.settings.wifiOnly }, set: { new in backup.update { $0.wifiOnly = new } })
    }
}

/// The Google account row under "Back up to: Google Drive" (prompt 268): sign in through the system
/// browser sheet, or see who is signed in and sign out.
struct GoogleAccountRow: View {
    /// Run once sign-in succeeds (the first backup).
    var onSignedIn: () -> Void = {}
    @Environment(AppModel.self) private var app
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var working = false
    @State private var failure: String?

    var body: some View {
        if app.google.isSignedIn {
            LabeledContent("Google account") {
                Text(app.google.email ?? "Signed in").lineLimit(1).truncationMode(.middle)
            }
            .accessibilityIdentifier("google.account")
            Button("Sign out of Google", role: .destructive) {
                Task { await app.google.signOut() }
            }
            .accessibilityIdentifier("google.signOut")
        } else {
            Button {
                signIn()
            } label: {
                HStack {
                    Label("Sign in with Google", systemImage: "person.crop.circle.badge.plus")
                    if working { Spacer(); ProgressView() }
                }
            }
            .disabled(working || !app.google.isConfigured)
            .accessibilityIdentifier("google.signIn")
            if !app.google.isConfigured {
                Text("Google Drive isn’t set up in this build.").font(.footnote).foregroundStyle(.secondary)
            }
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote)
                    .accessibilityIdentifier("google.failure")
            }
        }
    }

    private func signIn() {
        working = true
        failure = nil
        Task {
            defer { working = false }
            do {
                let pending = try app.google.beginSignIn(scopes: [GoogleScope.driveAppData])
                let callback = try await webAuthenticationSession.authenticate(
                    using: pending.url, callback: .customScheme(pending.callbackScheme), additionalHeaderFields: [:])
                try await app.google.finishSignIn(pending, callback: callback)
                onSignedIn()
            } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
                // Closing the sheet is not an error worth showing.
            } catch GoogleAuthError.cancelled {
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

/// Backups found in the cloud, newest first. Picking one asks before replacing everything.
struct CloudRestoreList: View {
    let storeIsFallback: Bool
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @State private var loading = true
    @State private var pending: CloudBackupManifest?
    @State private var working = false
    @State private var result: String?
    @State private var failure: String?

    var body: some View {
        List {
            if loading {
                HStack { ProgressView(); Text("Looking in your cloud…").foregroundStyle(.secondary) }
            } else if app.cloudBackup.remote.isEmpty {
                Text("No cloud backups found. Backups appear here after automatic backup has run, on any of your devices signed into the same account.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("cloudBackup.restore.empty")
            }
            ForEach(app.cloudBackup.remote) { manifest in
                Button { pending = manifest } label: { CloudBackupRow(manifest: manifest) }
                    .disabled(working)
                    .accessibilityIdentifier("cloudBackup.restore.row")
            }
            if let result {
                Label(result, systemImage: "checkmark.circle").foregroundStyle(.green)
                    .accessibilityIdentifier("cloudBackup.restore.result")
            }
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    .accessibilityIdentifier("cloudBackup.restore.result")
            }
        }
        .navigationTitle("Cloud backups")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await app.cloudBackup.refreshRemote()
            loading = false
        }
        .confirmationDialog("Replace all data?", isPresented: confirming, titleVisibility: .visible,
                            presenting: pending) { manifest in
            Button("Replace everything", role: .destructive) { restore(manifest) }
                .accessibilityIdentifier("cloudBackup.restore.confirm")
            Button("Cancel", role: .cancel) { pending = nil }
        } message: { manifest in
            Text("This replaces everything in Snappet on this device with the backup from \(manifest.deviceName), made \(manifest.createdAt.formatted(date: .abbreviated, time: .shortened)) (\(manifest.recordCount.formatted()) records). This can’t be undone."
                 + (storeIsFallback ? " Storage is in a temporary state, so it is lost when the app closes." : ""))
        }
    }

    private var confirming: Binding<Bool> {
        Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })
    }

    private func restore(_ manifest: CloudBackupManifest) {
        pending = nil
        working = true
        result = nil
        failure = nil
        Task {
            do {
                let count = try await app.restoreFromCloud(manifest, into: context)
                result = "Restored \(count.formatted()) records."
            } catch {
                failure = "Restore failed: \(error.localizedDescription)"
            }
            working = false
        }
    }
}

struct CloudBackupRow: View {
    let manifest: CloudBackupManifest

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(manifest.createdAt.formatted(date: .abbreviated, time: .shortened))
                .foregroundStyle(SnappetColor.ink)
            Text("From \(manifest.deviceName) · \(CloudBackupStatusText.size(manifest.byteCount))")
                .font(.footnote).foregroundStyle(SnappetColor.textSecondary)
            Text(CloudBackupStatusText.contents(manifest))
                .font(.footnote).foregroundStyle(SnappetColor.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Shown once on a fresh install when a backup exists in the person's cloud ("Welcome back").
struct CloudRestoreOfferSheet: View {
    let manifest: CloudBackupManifest
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var working = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Text("Snappet found a backup in your \(app.cloudBackup.readDestination.label).")
                    .font(.title3.weight(.medium)).foregroundStyle(SnappetColor.ink)
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("From", value: manifest.deviceName)
                    LabeledContent("Last backed up",
                                   value: manifest.createdAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Contains", value: CloudBackupStatusText.contents(manifest))
                }
                .padding(14)
                .background(SnappetColor.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                Text("Clips that are in this iPhone’s Photos reconnect automatically. Others can be found later from Clips.")
                    .font(.footnote).foregroundStyle(SnappetColor.textSecondary)
                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote)
                        .accessibilityIdentifier("cloudBackup.offer.failure")
                }
                Spacer()
                Button {
                    working = true
                    failure = nil
                    Task {
                        do {
                            _ = try await app.restoreFromCloud(manifest, into: context)
                            app.cloudBackup.restoreOffer = nil
                            dismiss()
                        } catch {
                            failure = "Restore failed: \(error.localizedDescription)"
                        }
                        working = false
                    }
                } label: {
                    HStack { if working { ProgressView() }; Text("Restore this backup").fontWeight(.medium) }
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .disabled(working)
                .accessibilityIdentifier("cloudBackup.offer.restore")
                Button {
                    app.cloudBackup.declineOffer()
                    dismiss()
                } label: {
                    Text("Start fresh").frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .disabled(working)
                .accessibilityIdentifier("cloudBackup.offer.decline")
            }
            .padding(SnappetSpacing.lg)
            .background(SnappetColor.paper)
            .navigationTitle("Welcome back")
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled(working)
        .accessibilityIdentifier("cloudBackup.offer")
    }
}
