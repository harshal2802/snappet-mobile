import SwiftUI
import AVKit
import HighlightEngine

/// The flagship screen: a finished reel by default, with one-tap Regenerate / Share
/// and a light edit list. Casual users never touch the list; power users curate it.
struct ReelView: View {
    let source: ReelSource
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var vm: ReelViewModel?
    @State private var showPicker = false

    init(source: ReelSource) { self.source = source }
    /// Back-compat for the workout path (`WorkoutListView`).
    init(summary: WorkoutSummary) { self.source = .workout(summary) }

    var body: some View {
        Group {
            switch vm?.state {
            case .none, .loading:
                ProgressView("Building your reel…")
            case .empty:
                ContentUnavailableView {
                    Label("No clips for this workout", systemImage: "video.slash")
                } description: {
                    Text(model.photosLimited
                         ? "Snappet only has limited Photo access, so it can’t scan for the clips you shot. Select them manually."
                         : "Snappet found no photos or videos shot during this session.")
                } actions: {
                    Button("Select clips") { showPicker = true }
                        .buttonStyle(.borderedProminent)
                }
            case .error(let msg):
                ContentUnavailableView("Couldn’t build the reel", systemImage: "exclamationmark.triangle",
                    description: Text(msg))
            case .exporting:
                ExportProgressView()
            case .exported(let url):
                ExportedView(url: url) { Task { await vm?.generate() } }
            case .ready:
                content
            }
        }
        // Cross-fade between the major reel phases (build / ready / export / done), gated.
        .animation(Snappet.snappetAnimation(SnappetMotion.standard, reduceMotion: reduceMotion), value: vm?.state)
        .navigationTitle(source.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if vm?.state == .ready {
                EditButton()   // enables drag-to-reorder
                if model.photosLimited {
                    Button { showPicker = true } label: { Image(systemName: "photo.badge.plus") }
                }
            }
        }
        .sheet(isPresented: $showPicker) {
            MediaPicker { ids in
                guard !ids.isEmpty else { return }
                Task { await vm?.usePickedMedia(identifiers: ids) }
            }
            .ignoresSafeArea()
        }
        .task {
            if vm == nil {
                let v = ReelViewModel(source: source, model: model)
                vm = v
                await v.generate()
            }
        }
    }

    @ViewBuilder private var content: some View {
        if let vm {
            List {
                Section {
                    PreviewBlock(vm: vm)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

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
                        HighlightRow(highlight: h, pinned: vm.isPinned(h))
                            .swipeActions(edge: .leading) {
                                Button { vm.togglePin(h) } label: {
                                    Label(vm.isPinned(h) ? "Unpin" : "Pin",
                                          systemImage: vm.isPinned(h) ? "pin.slash" : "pin")
                                }
                                .tint(.yellow)
                            }
                            .swipeActions {
                                Button(role: .destructive) { vm.remove(h) } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                    }
                    .onMove { vm.move(from: $0, to: $1) }
                } header: {
                    Text("Highlights (\(vm.keptHighlights.count))")
                } footer: {
                    Text("Auto-selected from your heart rate. Swipe ▸ to remove, ◂ to pin (pinned clips always stay in). Tap Edit to reorder.")
                }

                if !vm.removedHighlights.isEmpty {
                    Section {
                        ForEach(vm.removedHighlights) { h in
                            HighlightRow(highlight: h, pinned: false)
                                .foregroundStyle(.secondary)
                                .swipeActions {
                                    Button { vm.restore(h) } label: {
                                        Label("Restore", systemImage: "arrow.uturn.backward")
                                    }
                                    .tint(SnappetColor.budget)
                                }
                        }
                    } header: {
                        Text("Removed (\(vm.removedHighlights.count))")
                    } footer: {
                        Text("Swipe to restore a moment you removed.")
                    }
                }
            }
        }
    }
}

/// In-app preview of the current cut — plays the composition directly (no export).
private struct PreviewBlock: View {
    let vm: ReelViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var building = false

    var body: some View {
        VStack(spacing: 10) {
            if let player = vm.previewPlayer {
                VideoPlayer(player: player)
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: SnappetRadius.md))
                    // The built preview eases in (gated by Reduce Motion).
                    .transition(reduceMotion ? .opacity
                                : .scale(scale: 0.96).combined(with: .opacity))
            } else {
                Button {
                    building = true
                    Task { await vm.buildPreview(); building = false }
                } label: {
                    if building {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 80)
                    } else {
                        Label("Preview reel", systemImage: "play.rectangle.fill")
                            .frame(maxWidth: .infinity, minHeight: 80)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(building)

                if let err = vm.previewError {
                    Text(err).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .animation(Snappet.snappetAnimation(SnappetMotion.standard, reduceMotion: reduceMotion),
                   value: vm.previewPlayer == nil)
    }
}

private struct HighlightRow: View {
    let highlight: Highlight
    let pinned: Bool
    var body: some View {
        HStack {
            Image(systemName: highlight.kind == .high ? "flame.fill" : "leaf.fill")
                .foregroundStyle(highlight.kind == .high ? SnappetColor.workout : SnappetColor.habits)
            VStack(alignment: .leading) {
                Text(timecode(highlight.atOffset)).font(.body.monospacedDigit())
                Text(String(format: "intensity %.0f%%", highlight.score * 100))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if pinned {
                Image(systemName: "pin.fill").font(.caption).foregroundStyle(.yellow)
            }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showShare = false
    @State private var landed = false
    /// Fires the celebration burst once per export landing (issue #80).
    @State private var celebrationTrigger = 0

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill").font(.largeTitle)
                .foregroundStyle(SnappetColor.habits)
                // The success check springs in once the export lands; no-ops under Reduce Motion.
                .scaleEffect(landed || reduceMotion ? 1 : 0.5)
                .opacity(landed || reduceMotion ? 1 : 0)
                .symbolEffect(.bounce, value: reduceMotion ? 0 : (landed ? 1 : 0))
            Text("Reel ready").font(.title2.bold())
            Button { showShare = true } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }.buttonStyle(.borderedProminent)
            Button("Make another cut", action: onRegenerate)
        }
        .padding()
        .animation(Snappet.snappetAnimation(SnappetMotion.expressive, reduceMotion: reduceMotion), value: landed)
        .celebrates(on: celebrationTrigger)
        .onAppear {
            landed = true
            celebrationTrigger += 1   // burst + success haptic (haptic-only under Reduce Motion)
        }
        .sheet(isPresented: $showShare) { ShareSheet(items: [url]) }
    }
}

/// A determinate-feel export progress that creeps toward (but never reaches) 100% while the
/// reel renders, then the parent swaps to `ExportedView`'s success check when `.exported` lands.
/// Purely presentational — it drives a perceived-progress bar, not the real export (whose
/// `ReelExporter` exposes no fraction). Honors Reduce Motion by snapping straight to a settled bar.
private struct ExportProgressView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var fraction: Double = 0

    var body: some View {
        VStack(spacing: 12) {
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .tint(SnappetColor.reels)
                .frame(maxWidth: 240)
            Text("Exporting…").font(.subheadline).foregroundStyle(.secondary)
        }
        .padding()
        .onAppear {
            guard !reduceMotion else { fraction = 0.9; return }
            withAnimation(.easeOut(duration: 6)) { fraction = 0.92 }
        }
    }
}
