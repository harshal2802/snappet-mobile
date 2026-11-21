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
    /// The Google permissions this row is for.
    var scopes: [String] = [GoogleScope.driveAppData]
    /// Hide "Sign out" where another row on the screen already offers it.
    var showsSignOut = true
    /// Run once sign-in succeeds (the first backup).
    var onSignedIn: () -> Void = {}
    @Environment(AppModel.self) private var app
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var working = false
    @State private var failure: String?

    var body: some View {
        if app.google.isSignedIn, scopes.allSatisfy(app.google.grants) {
            LabeledContent("Google account") {
                Text(app.google.email ?? "Signed in").lineLimit(1).truncationMode(.middle)
            }
            .accessibilityIdentifier("google.account")
            if showsSignOut {
                Button("Sign out of Google", role: .destructive) {
                    Task { await app.google.signOut() }
                }
                .accessibilityIdentifier("google.signOut")
            }
        } else {
            Button {
                signIn()
            } label: {
                HStack {
                    // Signed in already, but this feature needs one more permission from Google.
                    Label(app.google.isSignedIn ? "Allow access in Google" : "Sign in with Google",
                          systemImage: "person.crop.circle.badge.plus")
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
                let pending = try app.google.beginSignIn(scopes: scopes)
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

/// "Clip copies" in Cloud & Backup (prompt 269): keep a copy of each session clip in the person's
/// Google Drive, so a clip removed from this iPhone still plays. Only in a build with Google set up.
struct ClipVaultSection: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context

    private var vault: MediaVaultService { app.mediaVault }

    var body: some View {
        Section {
            Toggle("Keep clip copies in Google Drive", isOn: keepCopies)
                .accessibilityIdentifier("mediaVault.keepCopies")
            if vault.settings.keepCopies {
                GoogleAccountRow(scopes: [GoogleScope.driveFile],
                                 showsSignOut: app.cloudBackup.settings.destination != .googleDrive) {
                    Task { await app.runMediaVault() }
                }
                statusRow
                Picker("Folders", selection: layout) {
                    ForEach(MediaVaultLayout.allCases) { Text($0.label).tag($0) }
                }
                .accessibilityIdentifier("mediaVault.layout")
                Text(vault.settings.layout.example)
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("mediaVault.layout.example")
                Toggle("Wi-Fi only", isOn: wifiOnly)
                    .accessibilityIdentifier("mediaVault.wifiOnly")
                if vault.settings.started {
                    Button {
                        Task { await app.runMediaVault() }
                    } label: {
                        Label("Copy now", systemImage: "arrow.up.circle")
                    }
                    .disabled(isWorking)
                    .accessibilityIdentifier("mediaVault.now")
                } else {
                    Button {
                        vault.update { $0.started = true }
                        Task { await app.runMediaVault() }
                    } label: {
                        Label("Start copying", systemImage: "arrow.up.circle.fill").fontWeight(.semibold)
                    }
                    .disabled(!app.google.isSignedIn)
                    .accessibilityIdentifier("mediaVault.start")
                }
            }
            if vault.showsCopyState {
                NavigationLink {
                    ClipCopiesManageView()
                } label: {
                    HStack {
                        Text("Manage copies")
                        Spacer()
                        let waiting = vault.emptyFolderCount + vault.leftoverCount
                        if waiting > 0 { Text("\(waiting) to tidy").foregroundStyle(.secondary) }
                    }
                }
                .accessibilityIdentifier("mediaVault.manage")
            }
        } header: {
            Text("Clip copies")
        } footer: {
            Text(!vault.settings.keepCopies
                 ? "Off: clips exist only in this iPhone’s Photos. Turn it on and a clip removed from Photos still plays, from a copy in your Google Drive."
                 : !vault.settings.started
                 ? "Nothing is copied yet. Sign in, choose how the folders are arranged, then tap Start copying. After that, new clips are copied whenever you open Snappet."
                 : "Copies go to a “Snappet Clips” folder in your Google Drive as ordinary video and photo files, named by date and time — you can see them there, and they are not encrypted. Changing Folders moves the copies already there. A clip that is no longer on this iPhone plays from Drive.")
        }
        .task { await vault.refreshCoverage(context: context) }
    }

    private var isWorking: Bool {
        switch vault.phase {
        case .working, .organizing, .checking: true
        default: false
        }
    }

    @ViewBuilder private var statusRow: some View {
        switch vault.phase {
        case .working(let done, let total):
            HStack { ProgressView(); Text(MediaVaultText.copying(vault.coverage, done: done, total: total)).foregroundStyle(.secondary) }
                .accessibilityIdentifier("mediaVault.status")
        case .organizing(let done, let total):
            HStack { ProgressView(); Text("Organizing \(done) of \(total)…").foregroundStyle(.secondary) }
                .accessibilityIdentifier("mediaVault.status")
        case .checking(let done, let total):
            HStack { ProgressView(); Text("Checking copies \(done) of \(total)…").foregroundStyle(.secondary) }
                .accessibilityIdentifier("mediaVault.status")
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote)
                .accessibilityIdentifier("mediaVault.status")
        case .idle:
            if let note = vault.note {
                Label(note, systemImage: "clock").foregroundStyle(.secondary).font(.footnote)
                    .accessibilityIdentifier("mediaVault.status")
            } else {
                Text(MediaVaultText.coverage(vault.coverage, bytes: vault.index.totalBytes))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("mediaVault.status")
            }
        }
    }

    private var keepCopies: Binding<Bool> {
        Binding(get: { vault.settings.keepCopies }, set: { new in
            // Off pauses; on again carries on from what is already in Drive. Only the very first
            // time waits for "Start copying".
            vault.update { $0.keepCopies = new }
            if new { Task { await app.runMediaVault(); await vault.refreshCoverage(context: context) } }
        })
    }
    private var wifiOnly: Binding<Bool> {
        Binding(get: { vault.settings.wifiOnly }, set: { new in vault.update { $0.wifiOnly = new } })
    }
    private var layout: Binding<MediaVaultLayout> {
        Binding(get: { vault.settings.layout }, set: { new in
            vault.update { $0.layout = new }
            Task { await app.runMediaVault() }
        })
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
            } else if let problem = app.cloudBackup.remoteProblem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                    .accessibilityIdentifier("cloudBackup.restore.problem")
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
        // An alert, not a confirmation dialog: on current iOS a dialog can show as a popover without its Cancel button.
        .alert("Replace all data?", isPresented: confirming, presenting: pending) { manifest in
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

/// "Manage copies" (prompt 274): free up the phone, and remove copies from Google Drive. Every
/// removal goes to a trash that keeps it for 30 days, and every one is asked first.
struct ClipCopiesManageView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @State private var confirming: Confirm?

    private enum Confirm: String, Identifiable { case leftovers, folders, everything; var id: String { rawValue } }
    private var vault: MediaVaultService { app.mediaVault }

    private var isWorking: Bool {
        switch vault.phase {
        case .working, .organizing, .checking: true
        default: false
        }
    }

    var body: some View {
        List {
            if let statusLine {
                Section {
                    HStack { if isWorking { ProgressView() }; Text(statusLine).font(.footnote).foregroundStyle(.secondary) }
                        .accessibilityIdentifier("mediaVault.manage.status")
                }
            }
            Section {
                Text(!vault.libraryVisible
                     ? "Allow full access to Photos in Settings. With limited access Snappet can’t tell which clips are on this iPhone."
                     : vault.freeable.count > 0
                     ? MediaVaultText.freeUp(count: vault.freeable.count, bytes: vault.freeable.bytes)
                     : "No clip on this iPhone has a copy in Google Drive yet.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("mediaVault.freeUp.summary")
                if !vault.onlyInDrive.isEmpty {
                    Text(vault.onlyInDrive.count == 1 ? "1 clip is only in Google Drive and plays from there."
                                                      : "\(vault.onlyInDrive.count) clips are only in Google Drive and play from there.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                NavigationLink("Free up space on this iPhone…") { ClipFreeUpView() }
                    .disabled(isWorking || vault.freeable.count == 0)
                    .accessibilityIdentifier("mediaVault.freeUp")
            } header: {
                Text("On this iPhone")
            } footer: {
                Text("Choose which clips by age, activity or session. Originals leave Photos only once each copy has been checked in Google Drive. To edit a clip in the Studio afterwards, bring it back from its “…” menu.")
            }
            Section {
                Toggle("Remove a copy when its clip is deleted", isOn: removeWithClip)
                    .accessibilityIdentifier("mediaVault.removeWithClip")
                if vault.leftoverCount > 0 {
                    row(MediaVaultText.leftovers(vault.leftoverCount), button: "Remove these copies…", id: "mediaVault.leftovers") {
                        confirming = .leftovers
                    }
                }
                if vault.emptyFolderCount > 0 {
                    row(MediaVaultText.emptyFolders(vault.emptyFolderCount), button: "Remove empty folders…", id: "mediaVault.tidy") {
                        confirming = .folders
                    }
                }
            } header: {
                Text("In Google Drive")
            } footer: {
                Text("Deleting a clip in Snappet moves its copy to Google Drive’s trash the next time copies run. Drive keeps its trash for 30 days.")
            }
            Section {
                Button("Remove all copies from Google Drive…", role: .destructive) { confirming = .everything }
                    .disabled(isWorking || vault.index.count == 0)
                    .accessibilityIdentifier("mediaVault.removeAll")
            } footer: {
                Text(isWorking ? "Wait for copying to finish, or switch clip copies off to pause it."
                               : "Moves the “Snappet Clips” folder to Google Drive’s trash and switches clip copies off.")
            }
        }
        .navigationTitle("Manage copies")
        .navigationBarTitleDisplayMode(.inline)
        .task { await vault.refreshCoverage(context: context) }
        // An alert, not a confirmation dialog: on current iOS a dialog anchored in a list shows as a
        // popover WITHOUT its Cancel button, leaving one red button and no visible way out.
        .alert(title, isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
               presenting: confirming) { which in
            switch which {
            case .leftovers:
                Button("Move to trash", role: .destructive) { Task { await vault.removeLeftovers(context: context) } }
            case .folders:
                Button("Move to trash", role: .destructive) { Task { await vault.removeEmptyFolders() } }
            case .everything:
                Button("Move all copies to trash", role: .destructive) {
                    Task { await vault.removeAllCopies(); await app.reconcileMediaLinks() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { which in
            Text(message(which))
        }
    }

    private var statusLine: String? {
        switch vault.phase {
        case .working(let done, let total): MediaVaultText.copying(vault.coverage, done: done, total: total)
        case .organizing(let done, let total): "Working \(done) of \(total)…"
        case .checking(let done, let total): "Checking copies \(done) of \(total)…"
        case .failed(let message): message
        case .idle: vault.note
        }
    }

    private func row(_ text: String, button: String, id: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text).font(.footnote).foregroundStyle(.secondary)
            Button(button, action: action).disabled(isWorking).accessibilityIdentifier(id)
        }
    }

    private var removeWithClip: Binding<Bool> {
        Binding(get: { vault.settings.removeWithClip }, set: { new in vault.update { $0.removeWithClip = new } })
    }

    private var title: String {
        switch confirming {
        case .leftovers: "Move \(vault.leftoverCount) cop\(vault.leftoverCount == 1 ? "y" : "ies") to Google Drive’s trash?"
        case .folders: "Move \(vault.emptyFolderCount) empty folder\(vault.emptyFolderCount == 1 ? "" : "s") to Google Drive’s trash?"
        case .everything: "Move all \(vault.index.count) copies to Google Drive’s trash?"
        case nil: ""
        }
    }

    private func message(_ which: Confirm) -> String {
        switch which {
        case .leftovers:
            "These are copies of clips that are no longer in Snappet on this iPhone. Drive keeps its trash for 30 days."
        case .folders:
            "These folders hold none of your clip copies. Snappet can’t see files you put in them yourself; if there are any, they go to the trash too. Drive keeps its trash for 30 days."
        case .everything:
            (vault.onlyInDrive.isEmpty ? "" : "\(vault.onlyInDrive.count) of them \(vault.onlyInDrive.count == 1 ? "is" : "are") no longer on this iPhone and will stop playing. ")
            + "Clip copies are switched off. Drive keeps its trash for 30 days."
        }
    }
}
