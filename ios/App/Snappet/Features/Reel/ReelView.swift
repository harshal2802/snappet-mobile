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
    @State private var showLimitedPickConfirm = false
    @State private var limitedPickWarning = ""

    init(source: ReelSource) { self.source = source }

    var body: some View {
        Group {
            switch vm?.state {
            case .none, .loading:
                ProgressView("Building your reel…")
            case .empty:
                // Denied-aware: the spec (copy + actions) is the pure policy's pick via the VM,
                // so a denied user gets Open Settings — never the dead-end "Select clips" — a
                // limited user gets the grant-extending picker (the full-library PHPicker can't
                // widen what Snappet may read), and a pick that resolved to nothing explains
                // itself instead of looping back here silently.
                if let vm {
                    RecoveryUnavailableView(spec: vm.emptySpec,
                                            identifierPrefix: "reel") { action in
                        switch action {
                        case .selectClips: showPicker = true
                        case .extendLimitedSelection: presentLimitedLibraryPicker()
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
            // Edits-style chrome (reel editor redesign): the title carries the honest clip
            // count + duration, and EXPORT is the one prominent action. Reorder lives in the
            // edit-list sheet (☰) now; the limited-access pick moved into the tool row.
            if let vm, vm.state == .ready {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(source.title).font(.headline)
                        Text(editorSubtitle(vm)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await vm.export() } } label: {
                        Text("Export").font(.subheadline.weight(.bold))
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .tint(SnappetColor.reels)
                    .accessibilityIdentifier("reelExport")
                }
            }
        }
        .confirmationDialog("Start a new cut?", isPresented: $showLimitedPickConfirm,
                            titleVisibility: .visible) {
            Button("Select more clips", role: .destructive) { presentLimitedLibraryPicker() }
        } message: {
            Text(limitedPickWarning)
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

    /// "8 clips · 0:28" under the title — duration appears once a cut is planned.
    private func editorSubtitle(_ vm: ReelViewModel) -> String {
        let n = vm.keptHighlights.count
        let clips = "\(n) clip\(n == 1 ? "" : "s")"
        guard let total = vm.timelineMap?.totalDuration, total > 0 else { return clips }
        return "\(clips) · \(reelTimecode(total))"
    }

    /// The system limited-library management sheet — the ONLY surface that can EXTEND a
    /// `.limited` grant (PHPicker browses the full library but never widens what
    /// `PHAsset.fetchAssets` may resolve, so its picks outside the grant silently vanish —
    /// review fix). PhotoKit has no SwiftUI wrapper for it, so it's presented from the key
    /// window's top view controller; the completion regenerates so newly granted clips are
    /// auto-discovered by the session window.
    @MainActor private func presentLimitedLibraryPicker() {
        guard let presenter = Self.topViewController() else { return }
        let vm = vm
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: presenter) { _ in
            Task { @MainActor in await vm?.generate() }
        }
    }

    @MainActor private static func topViewController() -> UIViewController? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        guard var top = (windows.first(where: \.isKeyWindow) ?? windows.first)?.rootViewController
        else { return nil }
        while let presented = top.presentedViewController { top = presented }
        return top
    }

    @ViewBuilder private var content: some View {
        if let vm {
            ReelEditorView(vm: vm, onLimitedPick: model.photosLimited ? {
                // Picking new clips regenerates — wiping pins/removals/order — so it runs
                // through the same confirmation gate as Regenerate (review fix). The
                // `.empty`-state pick stays one-tap: curation is always empty there.
                if let warning = vm.regenerateConfirmation(exportedUnsaved: false) {
                    limitedPickWarning = warning
                    showLimitedPickConfirm = true
                } else {
                    presentLimitedLibraryPicker()
                }
            } : nil)
        }
    }
}

/// m:ss — the editor chrome's one timecode format.
private func reelTimecode(_ s: Double) -> String {
    String(format: "%d:%02d", Int(max(0, s)) / 60, Int(max(0, s)) % 60)
}

// MARK: - The editor (reel editor redesign — "the reel IS the screen")
//
// Edits/CapCut grammar over the SAME ViewModel: an auto-built looping preview fills the
// screen (no "Preview reel" button), one tool row (format · HR · pick · ↻ · ☰), and the
// highlight list is a filmstrip timeline — tap a frame for the clip sheet (trim/pin/remove),
// ☰ for the reorderable edit list. Export lives in the navigation bar (ReelView's toolbar).
private struct ReelEditorView: View {
    let vm: ReelViewModel
    /// Non-nil only under a limited Photos grant — the tool row then offers the pick chip.
    let onLimitedPick: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var transport = ClipPlaybackController()
    /// Loop observer for the preview player (an `AVPlayer`, not a queue+looper — the item is
    /// swapped on every rebuild, so a manual seek-to-zero loop is the simple correct thing).
    @State private var loopToken: NSObjectProtocol?
    @State private var selectedClip: Highlight?
    @State private var showEditList = false
    @State private var showRegenerateConfirm = false
    @State private var regenerateWarning = ""

    var body: some View {
        VStack(spacing: 10) {
            canvas
            toolRow
            filmstrip
        }
        .padding(.bottom, 8)
        .background(SnappetColor.paper)
        // Auto-(re)build the preview: the epoch bumps on every invalidation (edit/trim/format),
        // so the reel on screen is always the current cut. Composition-only — no export cost.
        .task(id: vm.previewEpoch) {
            guard vm.state == .ready, vm.previewPlayer == nil else { return }
            await vm.buildPreview()
            attachTransport()
            // A trim-triggered rebuild resumes AT the edited clip (device feedback: replaying
            // the whole reel from 0:00 buried the very cut you just made).
            if let id = vm.consumePendingSeek(), let map = vm.timelineMap,
               let start = map.start(of: id), map.totalDuration > 0 {
                transport.seek(toFraction: start / map.totalDuration)
            }
        }
        .onDisappear {
            vm.previewPlayer?.pause()
            detachTransport()
        }
        .sheet(item: $selectedClip) { clip in
            ReelClipSheet(vm: vm, highlightID: clip.id, transport: transport)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.hidden)
        }
        .sheet(isPresented: $showEditList) {
            ReelEditListSheet(vm: vm)
        }
        .confirmationDialog("Start a new cut?", isPresented: $showRegenerateConfirm,
                            titleVisibility: .visible) {
            Button("Regenerate", role: .destructive) { Task { await vm.regenerate() } }
        } message: {
            Text(regenerateWarning)
        }
    }

    // MARK: canvas — the preview player + its chrome

    private var canvas: some View {
        ZStack {
            RoundedRectangle(cornerRadius: SnappetRadius.md).fill(.black)
            if let player = vm.previewPlayer {
                StudioPlayerLayerView(player: player, backgroundColor: .black)
                    .clipShape(RoundedRectangle(cornerRadius: SnappetRadius.md))
                    .transition(.opacity)
            } else if let err = vm.previewError {
                VStack(spacing: 8) {
                    Text(err).font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Try again") { Task { await vm.buildPreview(); attachTransport() } }
                        .font(.caption.weight(.bold))
                }
                .padding()
            } else {
                ProgressView().tint(.white)
            }
        }
        .overlay(alignment: .topLeading) {
            if vm.previewPlayer != nil {
                Text("\(reelTimecode(transport.currentTime)) / \(reelTimecode(transport.duration))")
                    .font(.caption2.weight(.bold).monospacedDigit()).foregroundStyle(.white)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(.black.opacity(0.5), in: Capsule())
                    .padding(10)
            }
        }
        .overlay(alignment: .topTrailing) {
            Text(vm.format.label)
                .font(.caption2.weight(.bold)).foregroundStyle(SnappetColor.textSecondary)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(.black.opacity(0.5), in: Capsule())
                .padding(10)
        }
        // The burn, previewed: the SAME glass scorebug tile the export renders, swept by the
        // live playhead. (The CA burn itself can't draw in an in-app player — this SwiftUI
        // overlay is the WYSIWYG stand-in, and it replaces the old explanatory footer.)
        .overlay(alignment: .bottom) {
            if let hr = vm.previewHRTile, vm.previewPlayer != nil {
                HRTileView(tile: hr.tile, values: hr.values,
                           fraction: transport.fraction, liveBlur: false)
                    .frame(maxWidth: .infinity)
                    .frame(height: 88)
                    .allowsHitTesting(false)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 26)
            }
        }
        .overlay(alignment: .bottom) {
            if vm.previewPlayer != nil { scrubber.padding(.horizontal, 12).padding(.bottom, 10) }
        }
        .overlay {
            if vm.previewPlayer != nil, !transport.isPlaying {
                Image(systemName: "play.fill")
                    .font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(.black.opacity(0.4), in: Circle())
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { transport.togglePlay() }
        .padding(.horizontal, SnappetSpacing.lg)
        .accessibilityIdentifier("reelPreviewCanvas")
        .accessibilityLabel(transport.isPlaying ? "Pause preview" : "Play preview")
    }

    private var scrubber: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                Capsule().fill(SnappetColor.reels)
                    .frame(width: max(0, geo.size.width * transport.fraction))
                Circle().fill(.white)
                    .frame(width: 11, height: 11)
                    .offset(x: max(0, geo.size.width * transport.fraction - 5.5))
                    .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
            }
            .frame(height: 12)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    transport.isScrubbing = true
                    transport.seek(toFraction: v.location.x / max(1, geo.size.width), precise: false)
                }
                .onEnded { v in
                    transport.seek(toFraction: v.location.x / max(1, geo.size.width))
                    transport.isScrubbing = false
                })
        }
        .frame(height: 12)
        .accessibilityIdentifier("reelScrubber")
    }

    // MARK: tool row — format · HR · (pick) · ↻ · ☰

    private var toolRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ReelFormat.allCases) { fmt in
                    toolChip(fmt.label, on: vm.format == fmt) { vm.format = fmt }
                        .accessibilityIdentifier("reelFormat.\(fmt.rawValue)")
                }
                Divider().frame(height: 18)
                toolChip("HR", icon: "waveform.path.ecg", on: vm.overlayEnabled) {
                    vm.overlayEnabled.toggle()
                }
                .accessibilityIdentifier("reelOverlayToggle")
                .accessibilityLabel(vm.overlayEnabled ? "Heart-rate overlay on" : "Heart-rate overlay off")
                if let onLimitedPick {
                    toolChip(nil, icon: "photo.badge.plus", on: false, action: onLimitedPick)
                        .accessibilityLabel("Select more clips")
                }
                toolChip(nil, icon: "arrow.triangle.2.circlepath", on: false) {
                    // Regenerate silently discards pins/removals/order/trims — confirm when
                    // there's curation to lose (pure policy decides, unchanged).
                    if let warning = vm.regenerateConfirmation(exportedUnsaved: false) {
                        regenerateWarning = warning
                        showRegenerateConfirm = true
                    } else {
                        Task { await vm.regenerate() }
                    }
                }
                .accessibilityIdentifier("reelRegenerate")
                .accessibilityLabel("Regenerate")
                toolChip(nil, icon: "line.3.horizontal", on: false) { showEditList = true }
                    .accessibilityIdentifier("reelEditList")
                    .accessibilityLabel("Edit clips")
            }
            .padding(.horizontal, SnappetSpacing.lg)
        }
    }

    private func toolChip(_ label: String?, icon: String? = nil, on: Bool,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon { Image(systemName: icon).font(.caption.weight(.semibold)) }
                if let label { Text(label).font(.caption.weight(.bold)) }
            }
            .padding(.horizontal, label == nil ? 10 : 12).padding(.vertical, 8)
            .background(on ? SnappetColor.reels.opacity(0.14) : SnappetColor.surfaceMuted,
                        in: Capsule())
            .overlay(Capsule().strokeBorder(on ? SnappetColor.reels.opacity(0.5)
                                               : SnappetColor.hairline, lineWidth: 1))
            .foregroundStyle(on ? SnappetColor.reels : SnappetColor.textSecondary)
        }
        .buttonStyle(.plain)
    }

    // MARK: filmstrip — the highlight list as a timeline

    /// The clip currently under the playhead (the ring) — best-effort via the timeline map.
    private var currentClipID: String? {
        vm.timelineMap?.segmentID(at: transport.currentTime)
    }

    private var filmstrip: some View {
        VStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(vm.keptHighlights) { h in
                        filmFrame(h)
                    }
                    if !vm.removedHighlights.isEmpty {
                        Button { showEditList = true } label: {
                            VStack(spacing: 2) {
                                Text("+\(vm.removedHighlights.count)").font(.caption.weight(.bold))
                                Text("removed").font(.system(size: 8.5, weight: .bold))
                            }
                            .foregroundStyle(SnappetColor.textSecondary)
                            .frame(width: 56, height: 74)
                            .background(SnappetColor.surfaceMuted.opacity(0.4),
                                        in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(SnappetColor.hairline,
                                              style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("reelRemovedGhost")
                        .accessibilityLabel("\(vm.removedHighlights.count) removed clips")
                    }
                }
                .padding(.horizontal, SnappetSpacing.lg)
            }
            HStack {
                if let idx = vm.keptHighlights.firstIndex(where: { $0.id == currentClipID }) {
                    let h = vm.keptHighlights[idx]
                    Text("Clip \(idx + 1) of \(vm.keptHighlights.count)"
                         + (vm.peakBpm(for: h).map { " · PEAK \(Int($0))" } ?? ""))
                        .font(.caption2.weight(.bold)).foregroundStyle(SnappetColor.ink)
                }
                Spacer()
                Text("auto-cut from your heart rate")
                    .font(.caption2).foregroundStyle(SnappetColor.textSecondary)
            }
            .padding(.horizontal, SnappetSpacing.lg)
        }
        .accessibilityIdentifier("reelFilmstrip")
    }

    private func filmFrame(_ h: Highlight) -> some View {
        let window = vm.effectiveWindow(for: h)
        let peak = vm.peakBpm(for: h)
        let isCurrent = h.id == currentClipID
        return Button { selectedClip = h } label: {
            HighlightThumbnail(assetId: h.mediaItemId, kind: h.kind, width: 56, height: 74)
                .overlay(alignment: .bottomTrailing) {
                    Text("\(Int((window.upperBound - window.lowerBound).rounded()))s")
                        .font(.system(size: 8.5, weight: .heavy)).foregroundStyle(.white)
                        .padding(.horizontal, 4).padding(.vertical, 1.5)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
                        .padding(3)
                }
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 2) {
                        if vm.isPinned(h) {
                            Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(.yellow)
                        }
                        if vm.isTrimmed(h) {
                            Image(systemName: "scissors").font(.system(size: 8)).foregroundStyle(.white)
                        }
                    }
                    .padding(3)
                }
                // Peak-effort tint bar along the bottom — the HR ranking, visible per frame.
                .overlay(alignment: .bottom) {
                    if let peak {
                        Rectangle()
                            .fill(SnappetColor.performance(for: vm.intensityFraction(forPeak: peak)))
                            .frame(height: 3)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isCurrent ? SnappetColor.reels : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clip, \(Int((window.upperBound - window.lowerBound).rounded())) seconds"
                            + (peak.map { ", peak \(Int($0)) BPM" } ?? ""))
    }

    // MARK: transport plumbing

    private func attachTransport() {
        guard let player = vm.previewPlayer else { return }
        detachTransport()
        transport.attach(player, duration: vm.timelineMap?.totalDuration ?? 1)
        // Loop: the preview replays like a posted reel would. Item-scoped observer, re-made on
        // every rebuild (each rebuild is a fresh player + item).
        loopToken = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem, queue: .main) { [weak player] _ in
            Task { @MainActor in
                await player?.seek(to: .zero)
                player?.play()
            }
        }
        player.play()
    }

    private func detachTransport() {
        transport.detach()
        if let loopToken { NotificationCenter.default.removeObserver(loopToken) }
        loopToken = nil
    }
}

// MARK: - Clip sheet — trim / pin / remove one clip

/// Tap a filmstrip frame → this sheet. Resolved live from the VM by id so pin/trim state
/// can't go stale under it. The trimmer is the new capability: drag the auto-cut window
/// anywhere inside the clip's source video — the preview rebuilds with the trim, and the
/// export ships exactly that (both plan from `plannedHighlights`).
private struct ReelClipSheet: View {
    let vm: ReelViewModel
    let highlightID: String
    let transport: ClipPlaybackController
    @Environment(\.dismiss) private var dismiss
    /// The window while a handle is mid-drag (labels track live); committed on release.
    @State private var dragWindow: ClosedRange<Double>?

    private var highlight: Highlight? { vm.highlights.first { $0.id == highlightID } }

    var body: some View {
        if let h = highlight {
            let index = vm.keptHighlights.firstIndex(where: { $0.id == h.id })
            let window = dragWindow ?? vm.effectiveWindow(for: h)
            let isPhoto = vm.workout?.media.first(where: { $0.id == h.mediaItemId })?.kind == .photo
            VStack(alignment: .leading, spacing: 14) {
                Capsule().fill(SnappetColor.hairline)
                    .frame(width: 38, height: 4.5)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)

                HStack(spacing: 12) {
                    HighlightThumbnail(assetId: h.mediaItemId, kind: h.kind, width: 64, height: 84)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(index.map { "Clip \($0 + 1) of \(vm.keptHighlights.count)" } ?? "Clip")
                            .font(.headline)
                        Text(isPhoto ? "photo · shown \(Int(vm.lastPlan?.photoStill ?? 2))s"
                                     : "\(Int((window.upperBound - window.lowerBound).rounded()))s · video")
                            .font(.caption).foregroundStyle(SnappetColor.textSecondary)
                        if let peak = vm.peakBpm(for: h) {
                            peakPill(peak, tint: SnappetColor.performance(for: vm.intensityFraction(forPeak: peak)))
                        }
                    }
                    Spacer()
                }

                if let bounds = vm.trimBounds(for: h) {
                    trimSection(h, bounds: bounds, window: window)
                }

                VStack(spacing: 8) {
                    sheetAction("Play from here", icon: "play.fill") {
                        if let map = vm.timelineMap, let start = map.start(of: h.id), map.totalDuration > 0 {
                            transport.seek(toFraction: start / map.totalDuration)
                            vm.previewPlayer?.play()
                        }
                        dismiss()
                    }
                    .accessibilityIdentifier("reelClip.playFromHere")
                    sheetAction(vm.isPinned(h) ? "Unpin" : "Pin — always keep this moment",
                                icon: vm.isPinned(h) ? "pin.slash" : "pin") {
                        vm.togglePin(h)
                    }
                    .accessibilityIdentifier("reelClip.pin")
                    sheetAction("Remove from reel", icon: "trash", role: .destructive) {
                        vm.remove(h)
                        dismiss()
                    }
                    .accessibilityIdentifier("reelClip.remove")
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, SnappetSpacing.lg)
            .presentationBackground(SnappetColor.paper)
        }
    }

    @ViewBuilder private func trimSection(_ h: Highlight, bounds: ClosedRange<Double>,
                                          window: ClosedRange<Double>) -> some View {
        let kept = window.upperBound - window.lowerBound
        let sourceLen = bounds.upperBound - bounds.lowerBound
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("TRIM").font(.caption2.weight(.heavy)).tracking(0.5)
                    .foregroundStyle(SnappetColor.textSecondary)
                Spacer()
                Text("\(reelTimecode(window.lowerBound - bounds.lowerBound)) – \(reelTimecode(window.upperBound - bounds.lowerBound))")
                    .font(.caption2.weight(.bold).monospacedDigit()).foregroundStyle(SnappetColor.ink)
                + Text(" · \(Int(kept.rounded()))s kept of \(Int(sourceLen.rounded()))s")
                    .font(.caption2).foregroundStyle(SnappetColor.textSecondary)
            }
            ReelTrimBar(bounds: bounds, window: window,
                        onDrag: { dragWindow = $0 },
                        onCommit: { final in
                            dragWindow = nil
                            vm.setTrim(final, for: h)
                        })
            HStack {
                Text("Drag the handles — the clip can use any part of its source video.")
                    .font(.system(size: 10)).foregroundStyle(SnappetColor.textSecondary)
                Spacer()
                if vm.isTrimmed(h) {
                    Button("Reset trim") { vm.resetTrim(for: h) }
                        .font(.system(size: 10, weight: .bold)).foregroundStyle(SnappetColor.reels)
                        .accessibilityIdentifier("reelClip.resetTrim")
                }
            }
        }
        .accessibilityIdentifier("reelClip.trim")
    }

    private func peakPill(_ peak: Double, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "heart.fill").font(.system(size: 8, weight: .bold))
            Text("PEAK \(Int(peak)) BPM").font(.system(size: 10, weight: .heavy).monospacedDigit())
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(tint.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.45), lineWidth: 1))
    }

    private func sheetAction(_ title: String, icon: String, role: ButtonRole? = nil,
                             action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).frame(width: 22)
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(SnappetColor.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .foregroundStyle(role == .destructive ? Color.red : SnappetColor.ink)
    }
}

/// The two-handle trimmer: the kept window over the source video's span. Left/right handles
/// drag an edge (the far edge pushes back through `ReelTrim.clamp`, so it can't invert); the
/// coral window itself drags to slide the whole cut. Labels track `onDrag`; the trim commits
/// once, on release (`onCommit`) — so one drag = one preview rebuild, not a rebuild storm.
private struct ReelTrimBar: View {
    let bounds: ClosedRange<Double>
    let window: ClosedRange<Double>
    let onDrag: (ClosedRange<Double>) -> Void
    let onCommit: (ClosedRange<Double>) -> Void

    /// The window at the current gesture's start — the drag anchors to it, not to the
    /// continuously-updating `window` (which would compound the translation).
    @State private var anchor: ClosedRange<Double>?

    private let handleWidth: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            let span = max(0.001, bounds.upperBound - bounds.lowerBound)
            let width = geo.size.width
            let x0 = CGFloat((window.lowerBound - bounds.lowerBound) / span) * width
            let x1 = CGFloat((window.upperBound - bounds.lowerBound) / span) * width

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(LinearGradient(colors: [SnappetColor.surfaceMuted,
                                                  SnappetColor.hairline.opacity(0.6),
                                                  SnappetColor.surfaceMuted],
                                         startPoint: .leading, endPoint: .trailing))
                // The kept window — draggable as a whole (slide the cut).
                RoundedRectangle(cornerRadius: 8)
                    .fill(SnappetColor.reels.opacity(0.10))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(SnappetColor.reels, lineWidth: 2))
                    .frame(width: max(handleWidth * 2, x1 - x0))
                    .offset(x: x0)
                    .gesture(windowDrag(span: span, width: width))
                // Handles LAST (they win the overlap with the window body) and with a 44pt
                // hit zone each — the visual is 16pt, but a 16pt target meant most drags
                // landed on the window body and SLID the cut instead of resizing it (device
                // feedback: "it does not let me adjust how long I want the video").
                handle(visualLeftEdgeAt: x0, symbol: "chevron.compact.left")
                    .gesture(edgeDrag(isStart: true, span: span, width: width))
                handle(visualLeftEdgeAt: x1 - handleWidth, symbol: "chevron.compact.right")
                    .gesture(edgeDrag(isStart: false, span: span, width: width))
            }
        }
        .frame(height: 44)
    }

    /// Apple's 44pt minimum touch target — the resize handles must be grabbable.
    private let handleHitWidth: CGFloat = 44

    private func handle(visualLeftEdgeAt x: CGFloat, symbol: String) -> some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(SnappetColor.reels)
            .frame(width: handleWidth, height: 44)
            .overlay(Image(systemName: symbol)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(.black.opacity(0.7)))
            // The invisible hit zone extends the 16pt visual to 44pt, centred on it.
            .frame(width: handleHitWidth, height: 44)
            .contentShape(Rectangle())
            .offset(x: x - (handleHitWidth - handleWidth) / 2)
    }

    private func edgeDrag(isStart: Bool, span: Double, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                let a = anchor ?? window
                if anchor == nil { anchor = a }
                let delta = Double(v.translation.width / max(1, width)) * span
                let proposed = isStart ? safeRange(a.lowerBound + delta, a.upperBound)
                                       : safeRange(a.lowerBound, a.upperBound + delta)
                onDrag(ReelTrim.clamp(proposed, bounds: bounds))
            }
            .onEnded { _ in
                anchor = nil
                onCommit(window)
            }
    }

    private func windowDrag(span: Double, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                let a = anchor ?? window
                if anchor == nil { anchor = a }
                let length = a.upperBound - a.lowerBound
                let delta = Double(v.translation.width / max(1, width)) * span
                let start = min(max(bounds.lowerBound, a.lowerBound + delta),
                                bounds.upperBound - length)
                onDrag(start...(start + length))
            }
            .onEnded { _ in
                anchor = nil
                onCommit(window)
            }
    }

    /// A mid-drag proposal can momentarily invert (handle dragged past the far edge) —
    /// normalize before clamping so `ClosedRange` never traps.
    private func safeRange(_ lower: Double, _ upper: Double) -> ClosedRange<Double> {
        lower <= upper ? lower...upper : upper...lower
    }
}

// MARK: - Edit list sheet (☰) — reorder / pin / remove / restore

/// The power-user surface: everything the old List did, re-skinned — rows lead with
/// "Clip n · ks · kind" + the PEAK badge, never raw timeline offsets or "intensity %".
private struct ReelEditListSheet: View {
    let vm: ReelViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(vm.keptHighlights.enumerated()), id: \.element.id) { idx, h in
                        ReelClipRow(vm: vm, highlight: h, index: idx + 1)
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
                    Text("In the reel · \(vm.keptHighlights.count)")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        // Honest shortfall: some picked clips weren't readable (review fix).
                        if let note = vm.pickShortfallNote { Text(note) }
                        Text("Swipe ▸ to remove, ◂ to pin (pinned clips always stay in). Drag ≡ to reorder.")
                    }
                }

                if !vm.removedHighlights.isEmpty {
                    Section {
                        ForEach(vm.removedHighlights) { h in
                            ReelClipRow(vm: vm, highlight: h, index: nil)
                                .foregroundStyle(.secondary)
                                .swipeActions {
                                    Button { vm.restore(h) } label: {
                                        Label("Restore", systemImage: "arrow.uturn.backward")
                                    }
                                    .tint(SnappetColor.budget)
                                }
                        }
                    } header: {
                        Text("Removed · \(vm.removedHighlights.count)")
                    } footer: {
                        Text("Swipe to restore a moment you removed.")
                    }
                }
            }
            .navigationTitle("Edit clips")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // EditButton toggles reorder handles; swipe pin/remove/restore work outside
                // edit mode (forcing .active would disable them).
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.font(.body.weight(.semibold))
                }
            }
        }
    }
}

/// One edit-list row: thumbnail · "Clip n" (+pin/trim marks) · "ks · kind" · PEAK badge.
private struct ReelClipRow: View {
    let vm: ReelViewModel
    let highlight: Highlight
    /// 1-based position in the reel; `nil` for a removed row.
    let index: Int?

    var body: some View {
        let window = vm.effectiveWindow(for: highlight)
        let isPhoto = vm.workout?.media.first(where: { $0.id == highlight.mediaItemId })?.kind == .photo
        HStack(spacing: 10) {
            HighlightThumbnail(assetId: highlight.mediaItemId, kind: highlight.kind,
                               width: 44, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(index.map { "Clip \($0)" } ?? "Clip").font(.subheadline.weight(.bold))
                    if vm.isPinned(highlight) {
                        Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.yellow)
                    }
                    if vm.isTrimmed(highlight) {
                        Image(systemName: "scissors").font(.caption2)
                            .foregroundStyle(SnappetColor.textSecondary)
                    }
                }
                Text(isPhoto ? "photo" : "\(Int((window.upperBound - window.lowerBound).rounded()))s · video")
                    .font(.caption).foregroundStyle(SnappetColor.textSecondary)
            }
            Spacer()
            if let peak = vm.peakBpm(for: highlight) {
                let tint = SnappetColor.performance(for: vm.intensityFraction(forPeak: peak))
                Text("PEAK \(Int(peak))")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(tint)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(tint.opacity(0.12), in: Capsule())
                    .overlay(Capsule().strokeBorder(tint.opacity(0.45), lineWidth: 1))
            }
        }
    }
}

/// Poster-frame thumbnail of a highlight's source asset (issue #72 §5), loaded through one
/// shared `PHCachingImageManager` so scrolling the edit list doesn't re-decode frames. Falls
/// back to the old kind icon when the asset can't be read (e.g. this id wasn't granted under
/// limited access) — the row stays informative either way.
private struct HighlightThumbnail: View {
    let assetId: String
    let kind: Highlight.Kind
    /// Frame size — the filmstrip (56×74), clip sheet (64×84), and edit rows (44×56) share
    /// this one loader (reel editor redesign; was a fixed 52pt square).
    var width: CGFloat = 52
    var height: CGFloat = 52
    @State private var image: UIImage?

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
        .frame(width: width, height: height)
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
        if let loaded = await AssetPosterLoader.poster(
            localIdentifier: assetId, pointSize: CGSize(width: width, height: height)
        ) {
            image = loaded
        }
    }
}

/// The export payoff (issue #72 §3): the reel itself plays as the hero — auto-playing and
/// looped — with Save to Photos (add-only) and Share beneath it. The success haptic rides the
/// existing `.celebrates(on:)` landing (issue #80), so it isn't double-fired here. The file
/// lives in `Application Support/Reels` (not tmp) so backing out mid-flow doesn't destroy it,
/// but that copy is an internal safety net — no UI lists past renders, so the caption below
/// promises only what's real: Save to Photos, or a new cut replaces this one (review fix).
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

            // Post to Clips is the primary payoff when the reel has a home session (highlights P2):
            // the reel lands in the feed as a ✦ REEL post. Save/Share demote to the secondary row.
            if vm.canPostToClips {
                postButton
                if case .failed(let msg) = vm.postState {
                    Text(msg).font(.caption).foregroundStyle(.secondary)
                }
            }

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

            Text(vm.canPostToClips
                 ? "Post to Clips saves the reel to Photos and shows it in your feed with a ✦ REEL badge — making a new cut replaces this one."
                 : "Save to Photos to keep this reel — making a new cut replaces it.")
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

    /// Post-to-Clips CTA (highlights P2). Prominent while available; collapses to its done state
    /// once posted (like the save button) so the payoff can't double-post by tap.
    @ViewBuilder private var postButton: some View {
        switch vm.postState {
        case .posted:
            Label("Posted to Clips", systemImage: "checkmark.circle.fill")
                .foregroundStyle(SnappetColor.habits)
        case .posting:
            ProgressView()
                .frame(minWidth: 160)
        case .idle, .failed:
            Button { Task { await vm.postToClips() } } label: {
                Label("Post to Clips", systemImage: "sparkles.tv")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("reelPostToClips")
        }
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
            // Secondary when Post-to-Clips leads (posting already saves to Photos); primary
            // when there's no session to post under (the pre-P2 payoff, e.g. a manual one-off).
            if vm.canPostToClips {
                Button { Task { await vm.saveToPhotos() } } label: {
                    Label("Save to Photos", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("reelSaveToPhotos")
            } else {
                Button { Task { await vm.saveToPhotos() } } label: {
                    Label("Save to Photos", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("reelSaveToPhotos")
            }
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
