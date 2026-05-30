import SwiftUI
import HighlightEngine

/// The flagship screen: a finished reel by default, with one-tap Regenerate / Share
/// and a light edit list. Casual users never touch the list; power users curate it.
struct ReelView: View {
    let summary: WorkoutSummary
    @Environment(AppModel.self) private var model
    @State private var vm: ReelViewModel?

    var body: some View {
        Group {
            switch vm?.state {
            case .none, .loading:
                ProgressView("Building your reel…")
            case .empty:
                ContentUnavailableView("No clips for this workout",
                    systemImage: "video.slash",
                    description: Text("Snappet found no photos or videos shot during this session."))
            case .error(let msg):
                ContentUnavailableView("Couldn’t build the reel", systemImage: "exclamationmark.triangle",
                    description: Text(msg))
            case .exporting:
                ProgressView("Exporting…")
            case .exported(let url):
                ExportedView(url: url) { Task { await vm?.generate() } }
            case .ready:
                content
            }
        }
        .navigationTitle("\(summary.activity.rawValue.capitalized) reel")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if vm == nil {
                let v = ReelViewModel(summary: summary, model: model)
                vm = v
                await v.generate()
            }
        }
    }

    @ViewBuilder private var content: some View {
        if let vm {
            List {
                Section {
                    HStack(spacing: 12) {
                        Button { Task { await vm.export() } } label: {
                            Label("Share reel", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        Button { Task { await vm.regenerate() } } label: {
                            Label("Regenerate", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.bordered)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                Section {
                    ForEach(vm.keptHighlights) { h in
                        HighlightRow(highlight: h)
                            .swipeActions {
                                Button(role: .destructive) { vm.remove(h) } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                    }
                } header: {
                    Text("Highlights (\(vm.keptHighlights.count))")
                } footer: {
                    Text("Auto-selected from your heart rate. Swipe to remove; tap Regenerate for a fresh cut.")
                }
            }
        }
    }
}

private struct HighlightRow: View {
    let highlight: Highlight
    var body: some View {
        HStack {
            Image(systemName: highlight.kind == .high ? "flame.fill" : "leaf.fill")
                .foregroundStyle(highlight.kind == .high ? .orange : .green)
            VStack(alignment: .leading) {
                Text(timecode(highlight.atOffset)).font(.body.monospacedDigit())
                Text(String(format: "intensity %.0f%%", highlight.score * 100))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(String(format: "%.0fs", max(0, highlight.clipEnd - highlight.clipStart)))
                .font(.caption).foregroundStyle(.tertiary)
        }
    }
    private func timecode(_ s: Double) -> String {
        String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }
}

private struct ExportedView: View {
    let url: URL
    let onRegenerate: () -> Void
    @State private var showShare = false
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(.green)
            Text("Reel ready").font(.title2.bold())
            Button { showShare = true } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }.buttonStyle(.borderedProminent)
            Button("Make another cut", action: onRegenerate)
        }
        .padding()
        .sheet(isPresented: $showShare) { ShareSheet(items: [url]) }
    }
}

/// UIKit share sheet bridge.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
