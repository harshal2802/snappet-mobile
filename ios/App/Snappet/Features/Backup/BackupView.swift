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
    /// `true` when presented from the corrupt-store banner: the live container is
    /// in-memory, so a restore is previewable but won't survive a relaunch — say so.
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
                Text("This replaces everything in Snappet on this device with the backup's "
                     + "\(file.recordCount) records (made \(file.exportedAt.formatted(date: .abbreviated, time: .shortened))). "
                     + "This can't be undone.")
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
            .accessibilityIdentifier("backup.export")
            statusRow
        } header: {
            Text("Backup")
        } footer: {
            Text("One file with every module's data — workouts (full heart-rate series), "
                 + "climbing, journal, habits, finance, studio projects. It only goes where "
                 + "you save it in Files; nothing is uploaded by Snappet.")
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
            Text("Readable single-module files — for spreadsheets, notes apps, or your own "
                 + "tools. The workout export includes each session's full heart-rate series, "
                 + "so it can be a few MB.")
        }
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

    private func handlePickedBackup(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            pendingRestore = try SnappetBackup.decode(try Data(contentsOf: url))
        } catch {
            finish(.failure(error.localizedDescription))
        }
    }

    private func runRestore() {
        guard let file = pendingRestore else { return }
        pendingRestore = nil
        do {
            try SnappetBackup.restore(file, into: context)
            finish(.success("Restored \(file.recordCount) records."))
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
