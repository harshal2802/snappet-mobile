import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import HighlightEngine   // HighlightFeedbackEvent flows FeedbackStore → ModuleExports here

/// The suite's backup / export / restore surface (issue #68), presented as a sheet from
/// the App Library toolbar (and from `StoreHealthBanner` when the store fell back).
///
/// - **Back up my data**: every `SnappetSchema` model serialized into one versioned JSON
///   file (`SnappetBackup`) written wherever the user points the Files picker.
/// - **Restore from backup**: `.fileImporter` → decode-validate → an explicit
///   replace-everything confirmation → `SnappetBackup.restore`.
/// - **Per-module exports**: Journal → Markdown, Budget / Split Expenses → CSV, workout
///   history → JSON, highlight feedback → JSON (`ModuleExports` + `FeedbackStore`).
///
/// Nothing leaves the device except through these user-initiated Files writes.
struct BackupView: View {
    /// `true` when the live container is the in-memory fallback (presented from the
    /// corrupt-store banner, or from the App Library while `StoreHealth` is degraded):
    /// the store the codec would snapshot is EMPTY, so **every export path is gated
    /// off** (a "backup" made now would cover the user with 0 records), and a restore
    /// is previewable but won't survive a relaunch — both say so (#68 review fixes 1+3).
    var storeIsFallback = false

    @Environment(\.modelContext) private var context
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var exportDocument: BackupExportDocument?
    @State private var showingExporter = false
    @State private var showingImporter = false
    @State private var pendingRestore: SnappetBackup.File?
    @State private var status: Status?

    private enum Status: Equatable {
        case success(String)
        case failure(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                backupSection
                restoreSection
                moduleExportsSection
            }
            .navigationTitle("Back up & restore")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("backup.done")
                }
            }
            .fileExporter(isPresented: $showingExporter,
                          document: exportDocument,
                          contentType: exportDocument?.contentType ?? .json,
                          defaultFilename: exportDocument?.filename) { result in
                switch result {
                case .success:
                    if let message = exportDocument?.successMessage { finish(.success(message)) }
                case .failure(let error):
                    finish(.failure(error.localizedDescription))
                }
                exportDocument = nil
            }
            .fileImporter(isPresented: $showingImporter,
                          allowedContentTypes: [.json],
                          allowsMultipleSelection: false) { result in
                handlePickedBackup(result)
            }
            .confirmationDialog("Replace all data?",
                                isPresented: confirmingRestore,
                                titleVisibility: .visible,
                                presenting: pendingRestore) { _ in
                Button("Replace everything", role: .destructive) { runRestore() }
                    .accessibilityIdentifier("backup.confirmRestore")
                Button("Cancel", role: .cancel) { pendingRestore = nil }
            } message: { file in
                if storeIsFallback {
                    Text("Storage is in a temporary state, so this only previews the backup's "
                         + "\(file.recordCount) records (made \(file.exportedAt.formatted(date: .abbreviated, time: .shortened))) — "
                         + "everything restored now is lost when the app closes. To restore for "
                         + "good: reset storage from the banner, quit and reopen Snappet, then restore.")
                } else {
                    Text("This replaces everything in Snappet on this device with the backup's "
                         + "\(file.recordCount) records (made \(file.exportedAt.formatted(date: .abbreviated, time: .shortened))). "
                         + "This can't be undone.")
                }
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder private var backupSection: some View {
        Section {
            Button {
                backUpEverything()
            } label: {
                Label("Back up my data", systemImage: "externaldrive.badge.checkmark")
            }
            .disabled(storeIsFallback)
            .accessibilityIdentifier("backup.export")
            statusRow
        } header: {
            Text("Backup")
        } footer: {
            if storeIsFallback {
                Text("Storage is in a temporary state — a backup made now would not contain "
                     + "your saved data. Reset storage from the banner, quit and reopen "
                     + "Snappet, then back up.")
            } else {
                // Scoped to *records*: UserDefaults-resident settings (HR profile, expense
                // "me", band pairing) and the highlight-feedback log are NOT in the envelope.
                Text("Everything in Snappet's database in one file — workouts (full "
                     + "heart-rate series), climbing, festivals (installed lineups, your "
                     + "plan & tagged clips), wardrobe, journal, habits, finance, studio "
                     + "projects. Settings and the highlight-feedback log aren't included; "
                     + "export feedback separately below. It only goes where you save it in "
                     + "Files; nothing is uploaded by Snappet.")
            }
        }
    }

    @ViewBuilder private var restoreSection: some View {
        Section {
            Button {
                showingImporter = true
            } label: {
                Label("Restore from backup…", systemImage: "clock.arrow.circlepath")
            }
            .accessibilityIdentifier("backup.restore")
        } footer: {
            if storeIsFallback {
                Text("Storage is in a temporary state right now — anything restored here is "
                     + "lost when the app closes. Reset storage from the banner first, quit "
                     + "and reopen Snappet, then restore.")
            } else {
                Text("Restoring replaces everything currently in Snappet with the backup. "
                     + "You'll be asked to confirm.")
            }
        }
    }

    @ViewBuilder private var moduleExportsSection: some View {
        Section {
            exportRow("Journal", detail: "Markdown", id: "journal", systemImage: "book") {
                BackupExportDocument(
                    data: Data(ModuleExports.journalMarkdown(try fetchAll()).utf8),
                    contentType: BackupExportDocument.markdownOrPlainText, filename: "snappet-journal-\(dateStamp)",
                    successMessage: "Journal exported.")
            }
            exportRow("Budget", detail: "CSV", id: "budget", systemImage: "chart.pie") {
                BackupExportDocument(
                    data: Data(ModuleExports.budgetCSV(categories: try fetchAll(),
                                                       transactions: try fetchAll()).utf8),
                    contentType: .commaSeparatedText, filename: "snappet-budget-\(dateStamp)",
                    successMessage: "Budget exported.")
            }
            exportRow("Split Expenses", detail: "CSV", id: "expense", systemImage: "person.2") {
                BackupExportDocument(
                    data: Data(ModuleExports.expenseCSV(groups: try fetchAll(),
                                                        records: try fetchAll()).utf8),
                    contentType: .commaSeparatedText, filename: "snappet-expenses-\(dateStamp)",
                    successMessage: "Expenses exported.")
            }
            exportRow("Festival", detail: "CSV", id: "festival", systemImage: "music.mic") {
                BackupExportDocument(
                    data: Data(ModuleExports.festivalCSV(lineups: try fetchAll(), stars: try fetchAll(),
                                                         attendance: try fetchAll(), tags: try fetchAll()).utf8),
                    contentType: .commaSeparatedText, filename: "snappet-festival-\(dateStamp)",
                    successMessage: "Festival exported.")
            }
            exportRow("Workout history", detail: "JSON", id: "workouts", systemImage: "dumbbell") {
                BackupExportDocument(
                    data: try ModuleExports.workoutHistoryJSON(try fetchAll()),
                    contentType: .json, filename: "snappet-workouts-\(dateStamp)",
                    successMessage: "Workout history exported.")
            }
            exportRow("Highlight feedback", detail: "JSON", id: "feedback",
                      systemImage: "hand.thumbsup") {
                BackupExportDocument(
                    data: try ModuleExports.feedbackJSON(app.feedback.exportAll()),
                    contentType: .json, filename: "snappet-highlight-feedback-\(dateStamp)",
                    successMessage: "Highlight feedback exported.")
            }
        } header: {
            Text("Export one module")
        } footer: {
            if storeIsFallback {
                Text("Storage is in a temporary state — an export made now would not contain "
                     + "your saved data.")
            } else {
                Text("Readable single-module files — for spreadsheets, notes apps, or your own "
                     + "tools. The workout export includes each session's full heart-rate series, "
                     + "so it can be a few MB.")
            }
        }
        // The whole section gates on fallback with the suite button: every row reads the
        // (empty) live store — including the feedback row, kept uniform so the one rule in
        // this state is "reset first, then export" (its JSONL is disk-resident and intact).
        .disabled(storeIsFallback)
    }

    @ViewBuilder private var statusRow: some View {
        switch status {
        case .success(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.green)
                .accessibilityIdentifier("backup.status")
        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
                .accessibilityIdentifier("backup.status")
        case nil:
            EmptyView()
        }
    }

    private func exportRow(_ title: String, detail: String, id: String, systemImage: String,
                           _ build: @escaping () throws -> BackupExportDocument) -> some View {
        Button {
            do {
                exportDocument = try build()
                showingExporter = true
            } catch {
                finish(.failure(error.localizedDescription))
            }
        } label: {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                Text(detail).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("backup.export.\(id)")
    }

    // MARK: - Actions

    private func backUpEverything() {
        // Belt-and-braces behind the disabled button: the fallback container is EMPTY — a
        // "backup" snapshotted from it would cover the user with 0 records right before
        // they reset their real store believing they're safe (#68 review fix 1).
        guard !storeIsFallback else {
            finish(.failure("Storage is in a temporary state — a backup made now would not "
                            + "contain your saved data."))
            return
        }
        do {
            let file = try SnappetBackup.snapshot(of: context)
            exportDocument = BackupExportDocument(
                data: try SnappetBackup.encode(file),
                contentType: .json,
                filename: "snappet-backup-\(dateStamp)",
                successMessage: "Backed up \(file.recordCount) records.")
            showingExporter = true
        } catch {
            finish(.failure(error.localizedDescription))
        }
    }

    /// Read + decode the picked file OFF the main actor — an HR-heavy backup is multi-MB
    /// and a synchronous decode here froze the sheet (#68 review fix 7). The decoded
    /// `File` comes back once and backs BOTH the confirmation preview and `runRestore`;
    /// the security-scoped access brackets the read inside the task, where the read runs.
    private func handlePickedBackup(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            Task {
                do {
                    pendingRestore = try await Task.detached(priority: .userInitiated) {
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        return try SnappetBackup.decode(try Data(contentsOf: url))
                    }.value
                } catch {
                    finish(.failure(error.localizedDescription))
                }
            }
        } catch {
            finish(.failure(error.localizedDescription))
        }
    }

    /// Restore stays ON the main context — it has to coordinate with the live UI.
    private func runRestore() {
        guard let file = pendingRestore else { return }
        pendingRestore = nil
        // Restore deletes every row — including the live KilterSession the AppModel-owned
        // manager may hold. Detach it FIRST (no store writes; the rows are about to go) so
        // later manager writes can't trap on a deleted @Model or resurrect zombie rows, and
        // the Live Activity ends; `recover(in:)` re-adopts any open session from the
        // restored data on the next Kilter entry (#68 review fix 2). The manager is the only
        // AppModel-level @Model holder; the workout player's `playing` is view-local @State
        // on WorkoutHomeView, unreachable while this sheet is presented.
        app.kilterSessions.detachForStoreRestore()
        do {
            try SnappetBackup.restore(file, into: context)
            if storeIsFallback {
                // Honest about ephemerality: the in-memory preview vanishes on relaunch.
                finish(.success("Restored \(file.recordCount) records into temporary storage "
                                + "— they're lost when the app closes. To keep them: reset "
                                + "storage from the banner, quit and reopen Snappet, then "
                                + "restore again."))
            } else {
                finish(.success("Restored \(file.recordCount) records."))
            }
        } catch {
            finish(.failure("Restore failed: \(error.localizedDescription)"))
        }
    }

    /// Record the outcome inline + (on success) as a usage event. Inserted directly —
    /// not via `SnappetCore` — because the banner's presentation sits outside the shell
    /// that provides it in the environment.
    private func finish(_ outcome: Status) {
        status = outcome
        if case .success(let message) = outcome {
            context.insert(UsageRecord(module: "backup", action: "files", summary: message))
            try? context.save()
        }
    }

    private var confirmingRestore: Binding<Bool> {
        Binding(get: { pendingRestore != nil },
                set: { if !$0 { pendingRestore = nil } })
    }

    private func fetchAll<M: PersistentModel>() throws -> [M] {
        try context.fetch(FetchDescriptor<M>())
    }

    private var dateStamp: String {
        Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash))
    }
}

/// A one-shot, write-only `FileDocument` for `.fileExporter`: the bytes are prebuilt by
/// `SnappetBackup`/`ModuleExports`; this just hands them to the Files picker with the
/// right content type + suggested name.
struct BackupExportDocument: FileDocument {
    /// Markdown's UTType isn't a constant in the SDK — derive it once; fall back to
    /// plain text where the runtime doesn't know the extension.
    static let markdownOrPlainText = UTType(filenameExtension: "md", conformingTo: .text) ?? .plainText
    static let readableContentTypes: [UTType] = [.json, .commaSeparatedText, markdownOrPlainText, .plainText]

    let data: Data
    let contentType: UTType
    let filename: String
    let successMessage: String

    init(data: Data, contentType: UTType, filename: String, successMessage: String) {
        self.data = data
        self.contentType = contentType
        self.filename = filename
        self.successMessage = successMessage
    }

    init(configuration: ReadConfiguration) throws {
        // Export-only: the app never opens one of these as a document.
        throw CocoaError(.featureUnsupported)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
