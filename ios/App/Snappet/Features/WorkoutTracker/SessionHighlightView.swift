import SwiftUI
import AVKit

/// The B4 highlight-generation sheet: pick which tagged video clips to include (default = all),
/// **Generate** runs the existing `HighlightEngine` via `SessionHighlightViewModel`, and the
/// result previews inline in a `VideoPlayer` (the same composition export will use — B5 adds
/// share/save). Presented as a **sheet** so it owns its own `NavigationStack` (the WorkoutTracker
/// module rides the App Library's stack and must not nest one — decisions.md). The view is thin —
/// all bridge/engine/render logic is in the view model.
struct SessionHighlightView: View {
    @State var viewModel: SessionHighlightViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showShare = false

    private var videoClips: [SessionHighlightInput.Clip] { viewModel.clips.filter(\.isVideo) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(videoClips, id: \.localIdentifier) { clip in
                        Button {
                            viewModel.toggle(clip)
                        } label: {
                            HStack {
                                Label("Clip at +\(Int(clip.offsetSec.rounded()))s",
                                      systemImage: "video")
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: viewModel.isSelected(clip)
                                      ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(viewModel.isSelected(clip) ? Color.accentColor : Color.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Include clips")
                } footer: {
                    Text("Selected clips are always kept in the reel; the rest are filled in by heart-rate intensity.")
                }

                Section {
                    preview
                        .animation(snappetAnimation(SnappetMotion.standard, reduceMotion: reduceMotion),
                                   value: viewModel.state)
                }

                if viewModel.canExport || viewModel.exportState != .idle {
                    Section {
                        exportShare
                            .animation(snappetAnimation(SnappetMotion.standard, reduceMotion: reduceMotion),
                                       value: viewModel.exportState)
                    } footer: {
                        Text("Share your reel anywhere, or save it to your Photos library. Everything stays on your device.")
                    }
                }
            }
            .navigationTitle("Highlight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Generate") { Task { await viewModel.generate() } }
                        .disabled(viewModel.state == .generating)
                        .accessibilityIdentifier("generateHighlightRun")
                }
            }
        }
    }

    @ViewBuilder
    private var preview: some View {
        switch viewModel.state {
        case .idle:
            ContentUnavailableView {
                Label("No reel yet", systemImage: "sparkles.tv")
            } description: {
                Text("Tap Generate to build a highlight reel from your clips and heart rate.")
            }
        case .generating:
            ProgressView("Generating…").frame(maxWidth: .infinity, minHeight: 120)
        case .ready:
            if let player = viewModel.previewPlayer {
                VideoPlayer(player: player)
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: SnappetRadius.md))
                    .accessibilityIdentifier("highlightPreview")
                    // The freshly generated reel fades/scales in (gated by Reduce Motion).
                    .transition(reduceMotion ? .opacity
                                : .scale(scale: 0.96).combined(with: .opacity))
            }
        case .empty:
            ContentUnavailableView("No highlights found", systemImage: "video.slash",
                description: Text("The engine couldn't find moments to feature in these clips."))
        case .error(let msg):
            ContentUnavailableView("Couldn't generate", systemImage: "exclamationmark.triangle",
                description: Text(msg))
        }
    }

    /// B5: export the generated reel, then Share / Save to Photos. The view is thin — it reflects
    /// `viewModel.exportState` and routes taps to the VM; export/save I/O lives in the services.
    @ViewBuilder
    private var exportShare: some View {
        switch viewModel.exportState {
        case .idle, .failed:
            if case .failed(let message) = viewModel.exportState {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
            Button {
                Task { await viewModel.export() }
            } label: {
                Label("Export reel", systemImage: "film").frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("exportHighlight")

        case .exporting:
            ProgressView("Exporting…").frame(maxWidth: .infinity)

        case .exported(let url), .saving(let url), .saved(let url):
            if case .saved = viewModel.exportState {
                Label("Saved to Photos", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(SnappetColor.habits)
                    // Success label pops in once saved; degrades to a fade under Reduce Motion.
                    .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
            }
            Button {
                showShare = true
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .disabled(viewModel.exportState.isBusy)
            .accessibilityIdentifier("shareHighlight")

            Button {
                Task { await viewModel.saveToPhotos() }
            } label: {
                if viewModel.exportState.isBusy {
                    ProgressView()
                } else {
                    Label("Save to Photos", systemImage: "square.and.arrow.down")
                }
            }
            .disabled(viewModel.exportState.isBusy)
            .accessibilityIdentifier("saveHighlightToPhotos")
            .sheet(isPresented: $showShare) { ShareSheet(items: [url]) }
        }
    }
}
