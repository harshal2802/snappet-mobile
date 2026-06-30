import SwiftUI

/// The opt-in gate + status view for the downloaded exercise library.
///
/// Shown as a sheet from the Library section when the user taps "Download exercise library".
/// The exercises-dataset (1,324 exercises with animated GIFs) is hosted on the Snappet web
/// repo and fetched on-device at the user's explicit request — no data leaves the device.
/// Mirrors the Kilter catalog pattern (decisions.md 2026-06-30).
struct ExerciseLibraryImportView: View {
    /// Called after a successful install so the host can re-merge the catalog.
    var onInstalled: () -> Void = {}

    @State private var installer = ExerciseCatalogInstaller()
    @AppStorage("exerciseLibrary.sourceURL") private var sourceURL = exerciseLibraryDefaultURL
    @AppStorage("exerciseLibrary.showAdvanced") private var showAdvanced = false
    @Environment(\.dismiss) private var dismiss

    private var isWorking: Bool {
        if case .working = installer.phase { return true } else { return false }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "figure.strengthtraining.traditional")
                        .font(.system(size: 52))
                        .foregroundStyle(SnappetColor.workout)
                        .padding(.top, 24)

                    Text("Download exercise library")
                        .font(.title2.bold())

                    Text("Snappet ships 873 bundled exercises. The full library adds 1,324 more "
                         + "with animated GIF demos, hosted on the Snappet web repo. "
                         + "Downloaded once, available offline.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    if installer.isInstalled, let meta = installer.metadata {
                        installedCard(meta)
                    } else {
                        infoCard
                        statusView
                        downloadButton
                    }

                    advancedSection
                }
                .padding()
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Exercise Library")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isWorking)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.disabled(isWorking)
                }
            }
        }
    }

    // MARK: - Sub-views

    private var infoCard: some View {
        VStack(spacing: 6) {
            Text("The exercise data comes from an open dataset hosted on the Snappet web repo. "
                 + "It stays on this device — nothing is ever uploaded.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
    }

    @ViewBuilder private var statusView: some View {
        switch installer.phase {
        case .working(let fraction):
            VStack(spacing: 6) {
                ProgressView(value: fraction).progressViewStyle(.linear)
                Text(fraction < 1 ? "Downloading…" : "Installing…")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("exerciseLibrary.error")
        case .idle, .installed:
            EmptyView()
        }
    }

    private var downloadButton: some View {
        Button {
            Task {
                let provider = NetworkExerciseCatalogProvider(urlString: sourceURL)
                await installer.install(using: provider)
                if case .installed = installer.phase {
                    onInstalled()
                }
            }
        } label: {
            Label("Download exercise library", systemImage: "arrow.down.circle.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(SnappetColor.workout)
        .disabled(isWorking)
        .accessibilityIdentifier("exerciseLibrary.download")
    }

    private func installedCard(_ meta: ExerciseLibraryMeta) -> some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("\(meta.exerciseCount.formatted()) exercises installed")
                    .font(.headline)
            }
            LabeledContent("Installed", value: meta.installedAt.formatted(date: .abbreviated, time: .omitted))
            LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: meta.sizeBytes, countStyle: .file))

            Divider()

            Button(role: .destructive) {
                installer.remove()
                dismiss()
            } label: {
                Label("Remove library", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("exerciseLibrary.remove")
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation { showAdvanced.toggle() }
            } label: {
                HStack {
                    Text("Advanced").font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: showAdvanced ? "chevron.up" : "chevron.down")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if showAdvanced {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Source URL").font(.caption).foregroundStyle(.tertiary)
                    TextField("Source URL", text: $sourceURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.footnote)
                        .accessibilityIdentifier("exerciseLibrary.sourceURL")
                }
                .padding()
                .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
            }
        }
    }
}

// MARK: - Download banner (inline, inside WorkoutLibraryView)

/// A compact banner row shown at the bottom of the Library section when the exercise
/// library has not yet been downloaded. Tapping it opens `ExerciseLibraryImportView`.
struct ExerciseLibraryDownloadBanner: View {
    @Binding var showingImport: Bool

    var body: some View {
        Button { showingImport = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle")
                    .font(.title3)
                    .foregroundStyle(SnappetColor.workout)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Download exercise library")
                        .font(.subheadline.bold())
                    Text("Add 1,324 exercises with animated GIF demos")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("exerciseLibrary.banner")
    }
}
