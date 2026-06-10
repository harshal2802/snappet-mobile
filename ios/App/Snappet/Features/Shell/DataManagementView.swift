import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Suite-level data backup, export, and restore screen. Accessible from the Workout Tracker
/// Settings → "Your data" section (and from the CorruptStoreBanner's "Restore backup…" button).
///
/// All I/O is user-initiated; nothing is transmitted. The `.fileExporter` modifier receives a
/// temp-file `URL` so the system Files picker controls the final save location.
struct DataManagementView: View {
    @Environment(\.modelContext) private var context

    // Backup / restore
    @State private var isBacking = false
    @State private var backupURL: URL?
    @State private var showingBackupExporter = false
    @State private var showingRestoreImporter = false

    // Per-module export URLs (written to a temp dir before the exporter sheet is presented)
    @State private var journalURL: URL?
    @State private var budgetURL: URL?
    @State private var expenseURL: URL?
    @State private var workoutURL: URL?
    @State private var showingJournalExporter = false
    @State private var showingBudgetExporter = false
    @State private var showingExpenseExporter = false
    @State private var showingWorkoutExporter = false

    @State private var alertMessage: String?
    @State private var showingAlert = false

    private let service = SnappetDataService()

    var body: some View {
        Form {
            backupSection
            restoreSection
            exportSection
        }
        .navigationTitle("Your data")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Data management", isPresented: $showingAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
        // Restore importer
        .fileImporter(
            isPresented: $showingRestoreImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            Task { await handleRestore(result) }
        }
        // Full-suite backup exporter
        .fileExporter(
            isPresented: $showingBackupExporter,
            item: backupURL,
            contentTypes: [.json],
            defaultFilename: backupFilename()
        ) { result in
            if case .failure(let error) = result { show(error) }
        }
        // Per-module exporters (each gets its own URL state + presenter)
        .fileExporter(
            isPresented: $showingJournalExporter,
            item: journalURL,
            contentTypes: [UTType(filenameExtension: "md") ?? .plainText],
            defaultFilename: "snappet-journal.md"
        ) { result in if case .failure(let error) = result { show(error) } }
        .fileExporter(
            isPresented: $showingBudgetExporter,
            item: budgetURL,
            contentTypes: [.commaSeparatedText],
            defaultFilename: "snappet-budget.csv"
        ) { result in if case .failure(let error) = result { show(error) } }
        .fileExporter(
            isPresented: $showingExpenseExporter,
            item: expenseURL,
            contentTypes: [.commaSeparatedText],
            defaultFilename: "snappet-expenses.csv"
        ) { result in if case .failure(let error) = result { show(error) } }
        .fileExporter(
            isPresented: $showingWorkoutExporter,
            item: workoutURL,
            contentTypes: [.json],
            defaultFilename: "snappet-workouts.json"
        ) { result in if case .failure(let error) = result { show(error) } }
    }

    // MARK: - Sections

    private var backupSection: some View {
        Section {
            Button {
                Task { await performBackup() }
            } label: {
                HStack {
                    Label("Back up my data", systemImage: "arrow.down.doc")
                    Spacer()
                    if isBacking {
                        ProgressView().progressViewStyle(.circular).scaleEffect(0.8)
                    }
                }
            }
            .disabled(isBacking)
            .accessibilityIdentifier("data.backup")
        } header: {
            Text("Backup")
        } footer: {
            Text("Creates a versioned JSON file of all your Snappet data — journal, budgets, expenses, habits, workouts, Kilter logs, and more. Save it to Files or share it.")
        }
    }

    private var restoreSection: some View {
        Section {
            Button {
                showingRestoreImporter = true
            } label: {
                Label("Restore from backup…", systemImage: "arrow.up.doc")
            }
            .foregroundStyle(.orange)
            .accessibilityIdentifier("data.restore")
        } header: {
            Text("Restore")
        } footer: {
            Text("Merges a .json backup into your current data. Existing records are kept — this is additive, not a replacement.")
        }
    }

    private var exportSection: some View {
        Section {
            Button {
                Task { await performModuleExport(.journal) }
            } label: {
                Label("Journal (Markdown)", systemImage: "doc.text")
            }
            .accessibilityIdentifier("data.export.journal")

            Button {
                Task { await performModuleExport(.budget) }
            } label: {
                Label("Budget (CSV)", systemImage: "tablecells")
            }
            .accessibilityIdentifier("data.export.budget")

            Button {
                Task { await performModuleExport(.expense) }
            } label: {
                Label("Expenses (CSV)", systemImage: "tablecells")
            }
            .accessibilityIdentifier("data.export.expense")

            Button {
                Task { await performModuleExport(.workout) }
            } label: {
                Label("Workout history (JSON)", systemImage: "figure.strengthtraining.traditional")
            }
            .accessibilityIdentifier("data.export.workout")
        } header: {
            Text("Per-module export")
        } footer: {
            Text("Export one module's data in a readable format. These are one-way exports; use the full backup above to restore.")
        }
    }

    // MARK: - Backup

    private func performBackup() async {
        isBacking = true
        do {
            let data = try service.backup(context: context)
            let url = tempURL(filename: backupFilename())
            try data.write(to: url)
            backupURL = url
            isBacking = false
            showingBackupExporter = true
        } catch {
            isBacking = false
            show(error)
        }
    }

    // MARK: - Restore

    private func handleRestore(_ result: Result<[URL], Error>) async {
        switch result {
        case .failure(let error):
            show(error)
        case .success(let urls):
            guard let url = urls.first else { return }
            let didStartAccess = url.startAccessingSecurityScopedResource()
            defer { if didStartAccess { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                try service.restore(data, into: context)
                alertMessage = "Restore complete. Your data has been merged in."
                showingAlert = true
            } catch let e as SnappetBackupError {
                alertMessage = e.errorDescription
                showingAlert = true
            } catch {
                show(error)
            }
        }
    }

    // MARK: - Per-module exports

    private enum ExportModule { case journal, budget, expense, workout }

    private func performModuleExport(_ module: ExportModule) async {
        do {
            let data: Data
            let filename: String
            switch module {
            case .journal:
                data = Data(service.exportJournalMarkdown(context: context).utf8)
                filename = "snappet-journal.md"
                journalURL = tempURL(filename: filename)
                try data.write(to: journalURL!)
                showingJournalExporter = true
            case .budget:
                data = Data(service.exportBudgetCSV(context: context).utf8)
                filename = "snappet-budget.csv"
                budgetURL = tempURL(filename: filename)
                try data.write(to: budgetURL!)
                showingBudgetExporter = true
            case .expense:
                data = Data(service.exportExpenseCSV(context: context).utf8)
                filename = "snappet-expenses.csv"
                expenseURL = tempURL(filename: filename)
                try data.write(to: expenseURL!)
                showingExpenseExporter = true
            case .workout:
                data = try service.exportWorkoutHistoryJSON(context: context)
                filename = "snappet-workouts.json"
                workoutURL = tempURL(filename: filename)
                try data.write(to: workoutURL!)
                showingWorkoutExporter = true
            }
        } catch {
            show(error)
        }
    }

    // MARK: - Helpers

    private func tempURL(filename: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(filename)
    }

    private func backupFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return "snappet-backup-\(formatter.string(from: Date())).json"
    }

    private func show(_ error: Error) {
        alertMessage = error.localizedDescription
        showingAlert = true
    }
}
