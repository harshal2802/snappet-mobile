import SwiftUI

/// A persistent, non-dismissable warning shown when `SnappetApp` fell back to an in-memory
/// store because the on-disk SwiftData database failed to open. Data is still usable in this
/// session but nothing will survive a relaunch. Offers a link to the data management view
/// (restore from backup) and a secondary "reset" option.
struct CorruptStoreBanner: View {
    /// Presented modally so the user can restore from backup before deciding what to do.
    @State private var showDataManagement = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Your data couldn't be opened", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.bold())
                .foregroundStyle(.white)

            Text("Changes made now won't be saved when you close the app. Restore from a backup or reset to start fresh.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.9))

            HStack(spacing: 12) {
                Button("Restore backup…") {
                    showDataManagement = true
                }
                .font(.caption.bold())
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(.white)

                Spacer()
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.gradient)
        .accessibilityIdentifier("corrupt.store.banner")
        .sheet(isPresented: $showDataManagement) {
            NavigationStack {
                DataManagementView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showDataManagement = false }
                        }
                    }
            }
        }
    }
}
