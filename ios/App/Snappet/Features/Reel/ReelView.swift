import SwiftUI
import AVKit
import Photos
import HighlightEngine

/// The flagship screen: a finished reel by default, with one-tap Regenerate / Share
/// and a light edit list. Casual users never touch the list; power users curate it.
struct ReelView: View {
    let source: ReelSource
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var vm: ReelViewModel?
    @State private var showPicker = false
    @State private var showRegenerateConfirm = false
    @State private var regenerateWarning = ""

    init(source: ReelSource) { self.source = source }
    /// Back-compat for the workout path (`WorkoutListView`).
    init(summary: WorkoutSummary) { self.source = .workout(summary) }

    var body: some View {
        Group {
            switch vm?.state {
            case .none, .loading:
                ProgressView("Building your reel…")
            case .empty:
                // Denied-aware: the spec (copy + actions) is the pure policy's pick, so a
                // denied user gets Open Settings — never the dead-end "Select clips".
                if let vm {
                    RecoveryUnavailableView(spec: ReelFlowPolicy.emptyReelSpec(access: vm.photoAccess),
                                            identifierPrefix: "reel") { action in
                        switch action {
                        case .selectClips: showPicker = true
                        case .allowPhotoAccess: Task { await vm.requestPhotoAccessAndGenerate() }
                        case .tryAgain: Task { await vm.generate() }
                        default: break
                        }
                    }
                }
            case .error(let msg):
                RecoveryUnavailableView(spec: ReelFlowPolicy.generateFailureSpec(message: msg),
                                        identifierPrefix: "reel") { action in
                    if action == .tryAgain { Task { await vm?.generate() } }
                }
            case .exportFailed(let msg):
                // Recoverable, not terminal: the curated edit is still in the VM.
                RecoveryUnavailableView(spec: ReelFlowPolicy.exportFailureSpec(message: msg),
                                        identifierPrefix: "reel") { action in
                    switch action {
                    case .retryExport: Task { await vm?.export() }
                    case .backToEdit: vm?.backToEdit()
                    default: break
                    }
                }
            case .exporting:
                ExportProgressView()
            case .exported(let url):
                if let vm { ExportedView(url: url, vm: vm) }
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
                        Button {
                            // Regenerate silently discards pins/removals/order — confirm
                            // when there's curation to lose (pure policy decides).
                            if let warning = vm.regenerateConfirmation(exportedUnsaved: false) {
                                regenerateWarning = warning
                                showRegenerateConfirm = true
                            } else {
                                Task { await vm.regenerate() }
                            }
                        } label: {
                            Label("Regenerate", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("reelRegenerate")
                        .confirmationDialog("Start a new cut?", isPresented: $showRegenerateConfirm,
                                            titleVisibility: .visible) {
                            Button("Regenerate", role: .destructive) { Task { await vm.regenerate() } }
                        } message: {
                            Text(regenerateWarning)
                        }
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
        HStack(spacing: 12) {
            HighlightThumbnail(assetId: highlight.mediaItemId, kind: highlight.kind)
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

/// Poster-frame thumbnail of a highlight's source asset (issue #72 §5), loaded through one
/// shared `PHCachingImageManager` so scrolling the edit list doesn't re-decode frames. Falls
/// back to the old kind icon when the asset can't be read (e.g. this id wasn't granted under
/// limited access) — the row stays informative either way.
private struct HighlightThumbnail: View {
    let assetId: String
    let kind: Highlight.Kind
    @State private var image: UIImage?

    private static let side: CGFloat = 52
    // MainActor-isolated via the View conformance, so the shared cache is concurrency-safe.
    private static let manager = PHCachingImageManager()

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    kindIcon
                }
            }
        }
        .frame(width: Self.side, height: Self.side)
        .clipShape(RoundedRectangle(cornerRadius: SnappetRadius.sm))
        .overlay(alignment: .bottomLeading) {
            if image != nil {
                kindIcon
                    .font(.caption2)
                    .padding(3)
                    .background(.black.opacity(0.55), in: Circle())
                    .padding(3)
            }
        }
        .accessibilityHidden(true)   // decorative; the row text carries the information
        .task(id: assetId) { await load() }
    }

    private var kindIcon: some View {
        Image(systemName: kind == .high ? "flame.fill" : "leaf.fill")
            .foregroundStyle(kind == .high ? SnappetColor.workout : SnappetColor.habits)
    }

    private func load() async {
        guard image == nil else { return }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil)
        guard let asset = assets.firstObject else { return }
        let target = CGSize(width: Self.side * 3, height: Self.side * 3)
        let options = PHImageRequestOptions()
        // One callback per request (continuation must resume exactly once) + on-device only.
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = false
        let manager = Self.manager
        let loaded: UIImage? = await withCheckedContinuation { continuation in
            manager.requestImage(for: asset, targetSize: target,
                                 contentMode: .aspectFill, options: options) { img, _ in
                continuation.resume(returning: img)
            }
        }
        if let loaded { image = loaded }
    }
}

/// The export payoff (issue #72 §3): the reel itself plays as the hero — auto-playing and
/// looped — with Save to Photos (add-only) and Share beneath it. The success haptic rides the
/// existing `.celebrates(on:)` landing (issue #80), so it isn't double-fired here. The file
/// now lives in `Application Support/Reels` (not tmp), so backing out keeps the artifact.
private struct ExportedView: View {
    let url: URL
    let vm: ReelViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL
    @State private var showShare = false
    @State private var landed = false
    /// Fires the celebration burst once per export landing (issue #80).
    @State private var celebrationTrigger = 0
    @State private var player: AVQueuePlayer?
    /// Retained for the player's lifetime — dropping it stops the loop.
    @State private var looper: AVPlayerLooper?
    @State private var showRegenerateConfirm = false
    @State private var regenerateWarning = ""

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(SnappetColor.habits)
                    // The success check springs in once the export lands; no-ops under Reduce Motion.
                    .scaleEffect(landed || reduceMotion ? 1 : 0.5)
                    .opacity(landed || reduceMotion ? 1 : 0)
                    .symbolEffect(.bounce, value: reduceMotion ? 0 : (landed ? 1 : 0))
                Text("Reel ready").bold()
            }
            .font(.title2)

            VideoPlayer(player: player)
                .frame(maxWidth: .infinity)
                .frame(height: 340)
                .clipShape(RoundedRectangle(cornerRadius: SnappetRadius.md))
                .accessibilityIdentifier("reelExportedPlayer")

            HStack(spacing: 12) {
                saveButton
                Button { showShare = true } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("reelShare")
            }

            if case .failed(let msg) = vm.saveState {
                VStack(spacing: 4) {
                    Text(msg).font(.caption).foregroundStyle(.secondary)
                    Button("Open Settings") {
                        if let settings = URL(string: UIApplication.openSettingsURLString) {
                            openURL(settings)
                        }
                    }
                    .font(.caption)
                    .accessibilityIdentifier("reelSaveOpenSettings")
                }
            }

            Button("Make another cut") {
                // A new cut wipes curation and replaces this screen — confirm when the pure
                // policy says something of the user's is at stake (unsaved cut counts).
                if let warning = vm.regenerateConfirmation(exportedUnsaved: vm.saveState != .saved) {
                    regenerateWarning = warning
                    showRegenerateConfirm = true
                } else {
                    Task { await vm.regenerate() }
                }
            }
            .accessibilityIdentifier("reelMakeAnotherCut")

            Text("Snappet keeps your latest exports on this device — save to Photos to keep this reel for good.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .animation(Snappet.snappetAnimation(SnappetMotion.expressive, reduceMotion: reduceMotion), value: landed)
        .animation(Snappet.snappetAnimation(SnappetMotion.standard, reduceMotion: reduceMotion), value: vm.saveState)
        // Full-size host: an overlay on the content-hugging card would clip the
        // confetti to ~220pt (Canvas clips to its bounds — review fix).
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .celebrates(on: celebrationTrigger)
        .confirmationDialog("Start a new cut?", isPresented: $showRegenerateConfirm,
                            titleVisibility: .visible) {
            Button("Make another cut", role: .destructive) { Task { await vm.regenerate() } }
        } message: {
            Text(regenerateWarning)
        }
        .onAppear {
            // Build the looping hero once; re-appearing (tab switch) just resumes playback.
            if player == nil {
                let queue = AVQueuePlayer()
                looper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(url: url))
                player = queue
            }
            player?.play()
            // Once per landing — onAppear re-fires on tab switches, and the landed
            // export shouldn't re-celebrate itself (review fix).
            guard !landed else { return }
            landed = true
            celebrationTrigger += 1   // burst + success haptic (haptic-only under Reduce Motion)
        }
        .onDisappear { player?.pause() }
        .sheet(isPresented: $showShare) { ShareSheet(items: [url]) }
    }

    @ViewBuilder private var saveButton: some View {
        switch vm.saveState {
        case .saved:
            Label("Saved to Photos", systemImage: "checkmark.circle.fill")
                .foregroundStyle(SnappetColor.habits)
        case .saving:
            ProgressView()
                .frame(minWidth: 140)
        case .idle, .failed:
            Button { Task { await vm.saveToPhotos() } } label: {
                Label("Save to Photos", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("reelSaveToPhotos")
        }
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
