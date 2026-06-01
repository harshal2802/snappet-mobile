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
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("highlightPreview")
            }
        case .empty:
            ContentUnavailableView("No highlights found", systemImage: "video.slash",
                description: Text("The engine couldn't find moments to feature in these clips."))
        case .error(let msg):
            ContentUnavailableView("Couldn't generate", systemImage: "exclamationmark.triangle",
                description: Text(msg))
        }
    }
}
