import SwiftUI
import UniformTypeIdentifiers

/// The opt-in empty state shown when no catalog is installed (issue #42). Snappet ships no Aurora data;
/// the user brings the climb catalog onto this device once — by importing a `.sqlite3` they built
/// themselves (Phase 1) — and from then on everything browse/detail/log/illuminate works offline.
///
/// Surfaces Aurora's Terms of Use + a link before any fetch, and makes clear the data stays on-device.
struct KilterCatalogSyncView: View {
    /// Called after a successful install so the host can reload the reader.
    var onInstalled: () -> Void = {}

    @State private var installer = KilterCatalogInstaller()
    @State private var showingImporter = false

    private let auroraTermsURL = URL(string: "https://kilterboardapp.com/terms-of-use")!

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 52))
                    .foregroundStyle(SnappetColor.moduleAccent("kilter"))
                    .padding(.top, 24)

                Text("Get the climb catalog")
                    .font(.title2.bold())

                Text("Snappet doesn't ship Kilter's climb catalog. Bring it onto this device once, then "
                     + "browse, log, and illuminate offline from then on.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                termsCard

                statusView

                VStack(spacing: 12) {
                    Button { showingImporter = true } label: {
                        Label("Import catalog file…", systemImage: "folder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isWorking)
                    .accessibilityIdentifier("kilter.catalog.import")

                    // Phase 2 (AuroraSyncProvider) — present but inert until the endpoint/account/ToU
                    // questions in issue #42 are answered.
                    Button {} label: {
                        Label("Sync from Kilter (coming soon)", systemImage: "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(true)
                    .accessibilityIdentifier("kilter.catalog.sync")
                }

                Text("No catalog file yet? Build one with the boardlib tool — see the Kilter tooling "
                     + "README (tools/kilter).")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("kilter.catalog.sync.empty")
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: [UTType(filenameExtension: "sqlite3") ?? .data, .data],
                      allowsMultipleSelection: false) { result in
            Task {
                await installer.importPicked(result)
                if case .installed = installer.phase { onInstalled() }
            }
        }
    }

    private var isWorking: Bool { if case .working = installer.phase { return true } else { return false } }

    private var termsCard: some View {
        VStack(spacing: 6) {
            Text("The catalog is Aurora Climbing's data, governed by their Terms of Use. It stays on "
                 + "this device — Snappet never uploads it.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Link(destination: auroraTermsURL) {
                Label("Aurora Climbing Terms of Use", systemImage: "link").font(.footnote)
            }
            .accessibilityIdentifier("kilter.catalog.terms")
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private var statusView: some View {
        switch installer.phase {
        case .working(let fraction):
            VStack(spacing: 6) {
                ProgressView(value: fraction).progressViewStyle(.linear)
                Text("Installing…").font(.footnote).foregroundStyle(.secondary)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("kilter.catalog.error")
        case .idle, .installed:
            EmptyView()
        }
    }
}
