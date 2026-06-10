import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Suite-level data management: full backup/restore (all SwiftData models → versioned JSON),
/// per-module exports (Journal → Markdown, Budget/Expense → CSV, Workouts → JSON),
/// and the restore-from-backup flow shown from the corrupt-store fallback banner.
struct DataBackupView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    // Per-module query access (passed to pure export methods — no device required).
    @Query private var journalEntries: [JournalEntry]
    @Query private var budgetCategories: [BudgetCategory]
    @Query private var budgetTransactions: [BudgetTransaction]
    @Query private var expenseGroups: [ExpenseGroup]
    @Query private var expenseRecords: [ExpenseRecord]
    @Query private var allWorkoutSessions: [WorkoutSession]

    private var completedWorkoutSessions: [WorkoutSession] {
        allWorkoutSessions.filter { $0.completedAt != nil }
    }

    @State private var phase: DataBackupPhase = .idle
    @State private var exportDocument: ExportDocument?
    @State private var exportContentType: UTType = .json
    @State private var exportFilename = "SnappetBackup.json"
    @State private var showingExporter = false
    @State private var showingImporter = false
    @State private var showingRestoreConfirm = false

    var body: some View {
        NavigationStack {
            Form {
                fullBackupSection
                perModuleSection
                statusSection
            }
            .navigationTitle("Data & Privacy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .disabled(phase == .busy)
            .overlay { if phase == .busy { ProgressView().padding() } }
            .fileExporter(
                isPresented: $showingExporter,
                document: exportDocument,
                contentType: exportContentType,
                defaultFilename: exportFilename
            ) { result in
                handleExportResult(result)
            }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [.json, .data],
                allowsMultipleSelection: false
            ) { result in
                handleImportResult(result)
            }
            .confirmationDialog(
                "Restore from backup?",
                isPresented: $showingRestoreConfirm,
                titleVisibility: .visible
            ) {
                Button("Restore — replace all data", role: .destructive) {
                    showingImporter = true
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will replace everything in the app with the contents of your backup file. This cannot be undone.")
            }
        }
    }

    // MARK: - Sections

    private var fullBackupSection: some View {
        Section {
            Button {
                startBackup()
            } label: {
                Label("Back up all data", systemImage: "archivebox")
            }
            .accessibilityIdentifier("backupAllData")

            Button(role: .destructive) {
                showingRestoreConfirm = true
            } label: {
                Label("Restore from backup", systemImage: "arrow.counterclockwise")
            }
            .accessibilityIdentifier("restoreFromBackup")
        } header: {
            Text("Full backup")
        } footer: {
            Text("Creates a single file with all your journal entries, workouts, budget, habits, climbing logs, and more. Nothing leaves your device except via the Files or Share actions you choose.")
        }
    }

    private var perModuleSection: some View {
        Section {
            exportRow(title: "Journal", subtitle: "Markdown", icon: "doc.text",
                      identifier: "exportJournal") { exportJournal() }
            exportRow(title: "Budget", subtitle: "CSV", icon: "chart.pie",
                      identifier: "exportBudget") { exportBudget() }
            exportRow(title: "Expenses", subtitle: "CSV", icon: "dollarsign.circle",
                      identifier: "exportExpenses") { exportExpenses() }
            exportRow(title: "Workouts", subtitle: "JSON", icon: "dumbbell",
                      identifier: "exportWorkouts") { exportWorkouts() }
        } header: {
            Text("Export by module")
        } footer: {
            Text("Human-readable formats for your own records or external tools.")
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        switch phase {
        case .done(let message):
            Section {
                Label(message, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        case .failed(let message):
            Section {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        default:
            EmptyView()
        }
    }

    private func exportRow(title: String, subtitle: String, icon: String,
                           identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: icon)
                Spacer()
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    // MARK: - Actions

    private func startBackup() {
        phase = .busy
        Task {
            do {
                let data = try DataBackupService.serialize(context: context)
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"
                let filename = "SnappetBackup_\(formatter.string(from: .now)).json"
                exportDocument = ExportDocument(data: data)
                exportContentType = .json
                exportFilename = filename
                showingExporter = true
                phase = .idle
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func exportJournal() {
        phase = .busy
        let data = DataBackupService.journalMarkdown(journalEntries)
        exportDocument = ExportDocument(data: data)
        exportContentType = .plainText
        exportFilename = "SnappetJournal.md"
        showingExporter = true
        phase = .idle
    }

    private func exportBudget() {
        phase = .busy
        let data = DataBackupService.budgetCSV(categories: budgetCategories,
                                               transactions: budgetTransactions)
        exportDocument = ExportDocument(data: data)
        exportContentType = .commaSeparatedText
        exportFilename = "SnappetBudget.csv"
        showingExporter = true
        phase = .idle
    }

    private func exportExpenses() {
        phase = .busy
        let data = DataBackupService.expenseCSV(groups: expenseGroups, records: expenseRecords)
        exportDocument = ExportDocument(data: data)
        exportContentType = .commaSeparatedText
        exportFilename = "SnappetExpenses.csv"
        showingExporter = true
        phase = .idle
    }

    private func exportWorkouts() {
        phase = .busy
        Task {
            do {
                let data = try DataBackupService.workoutJSON(completedWorkoutSessions)
                exportDocument = ExportDocument(data: data)
                exportContentType = .json
                exportFilename = "SnappetWorkouts.json"
                showingExporter = true
                phase = .idle
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func handleExportResult(_ result: Result<URL, Error>) {
        switch result {
        case .success:
            phase = .done("Saved successfully")
        case .failure(let error):
            // User cancellation is not a real error.
            if (error as NSError).code == NSUserCancelledError { phase = .idle } else {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func handleImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { phase = .idle; return }
            phase = .busy
            Task {
                do {
                    guard url.startAccessingSecurityScopedResource() else {
                        phase = .failed("Could not access the selected file.")
                        return
                    }
                    defer { url.stopAccessingSecurityScopedResource() }
                    let data = try Data(contentsOf: url)
                    try DataBackupService.restore(from: data, into: context)
                    phase = .done("Data restored successfully")
                } catch {
                    phase = .failed(error.localizedDescription)
                }
            }
        case .failure(let error):
            if (error as NSError).code == NSUserCancelledError { phase = .idle } else {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}

// MARK: - Phase

enum DataBackupPhase: Equatable {
    case idle
    case busy
    case done(String)
    case failed(String)
}

// MARK: - Fallback store banner

/// Persistent banner shown when the on-disk SwiftData store couldn't be opened and the app
/// is running on an empty in-memory container. Changes made in this session will be lost on
/// relaunch. The user can restore from a backup or dismiss to continue without saving.
struct FallbackStoreBanner: View {
    @State private var showingBackup = false
    @State private var dismissed = false

    var body: some View {
        if !dismissed {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your data couldn't be opened")
                        .font(.subheadline.bold())
                    Text("Changes made now won't be saved after you close the app")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 8) {
                    Button("Restore") {
                        showingBackup = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Button {
                        withAnimation { dismissed = true }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
            .transition(.move(edge: .top).combined(with: .opacity))
            .sheet(isPresented: $showingBackup) {
                DataBackupView()
            }
        }
    }
}
