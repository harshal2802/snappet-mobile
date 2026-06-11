import SwiftUI

/// The visible face of the corrupt-store fallback (issue #68): when `SnappetApp` couldn't
/// open the persistent store and dropped to an empty in-memory container, this persistent
/// banner says so plainly — instead of the old silent blank app — and offers the two ways
/// out: restore a backup, or reset the unreadable store for a fresh start on next launch.
///
/// Mounted by `SnappetApp` as a top `safeAreaInset` over `RootShell` (deliberately not
/// inside the shell — the sibling #71 work owns `RootShell`). Renders nothing when the
/// store is healthy, so a normal launch pays no cost.
struct StoreHealthBanner: View {
    let health: StoreHealth

    @State private var showingRestore = false
    @State private var confirmingReset = false
    @State private var resetError: String?

    var body: some View {
        switch health.mode {
        case .ok:
            EmptyView()
        case .fallbackInMemory:
            fallbackBanner
        case .resetDone:
            resetDoneBanner
        }
    }

    // MARK: - States

    private var fallbackBanner: some View {
        VStack(alignment: .leading, spacing: SnappetSpacing.sm) {
            Label("Your data couldn't be opened", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.bold())
            Text("Snappet is running on temporary storage — changes made now won't be saved.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let resetError {
                Text("Reset failed: \(resetError)")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            HStack(spacing: SnappetSpacing.md) {
                Button("Restore from backup") { showingRestore = true }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("store.health.restore")
                Button("Reset storage…", role: .destructive) { confirmingReset = true }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("store.health.reset")
            }
            .font(.footnote.bold())
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.14))
        .overlay(alignment: .bottom) { Divider() }
        .foregroundStyle(.primary)
        .tint(.red)
        .accessibilityIdentifier("store.health.banner")
        .sheet(isPresented: $showingRestore) {
            BackupView(storeIsFallback: true)
        }
        .confirmationDialog("Reset stored data?",
                            isPresented: $confirmingReset,
                            titleVisibility: .visible) {
            Button("Reset storage", role: .destructive) { reset() }
                .accessibilityIdentifier("store.health.confirmReset")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the unreadable on-device store so the next launch starts "
                 + "fresh. Backup files you exported to Files are not affected.")
        }
    }

    private var resetDoneBanner: some View {
        VStack(alignment: .leading, spacing: SnappetSpacing.sm) {
            Label("Storage was reset", systemImage: "checkmark.circle.fill")
                .font(.subheadline.bold())
            Text("Quit and reopen Snappet to start fresh — then restore your backup from "
                 + "Apps → Back up & restore.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.green.opacity(0.14))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityIdentifier("store.health.resetDone")
    }

    // MARK: - Actions

    private func reset() {
        do {
            try StoreRecovery.resetPersistentStore()
            resetError = nil
            health.mode = .resetDone
        } catch {
            resetError = error.localizedDescription
        }
    }
}
