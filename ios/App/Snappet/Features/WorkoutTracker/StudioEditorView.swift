import SwiftUI
import SwiftData
import AVKit
import UniformTypeIdentifiers

/// The full-studio **multi-clip editor** in an edits/CapCut-style layout: a custom top bar (title ·
/// export quality · Export), a preview canvas with the WYSIWYG overlay layer + a custom transport
/// (play/pause + live timecode), a horizontal clip timeline (select · trim · split · reorder), and a
/// **contextual bottom action bar** (Split · Speed · Filter · Transition · Delete, plus project-level
/// Text/Aspect). Editing is model-driven (works on the simulator); preview/export render through
/// PHAsset → AVFoundation and are device-only (the canvas shows a device-only placeholder on the sim).
struct StudioEditorView: View {
    @State private var vm: StudioEditorViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingShare = false
    @State private var addingText = false
    @State private var textDraft = ""
    @State private var renaming = false
    @State private var titleDraft = ""
    @State private var activeTool: StudioTool?
    @State private var importingMusic = false
    @State private var choosingPiP = false

    /// `SessionMedia.id` of a clip to pre-select when the studio opens (e.g. tapping one clip in a
    /// gallery jumps straight to editing it). `nil` keeps the default (no/first selection).
    private let focusClipMediaID: UUID?

    init(project: StudioProject, context: ModelContext, focusClipMediaID: UUID? = nil,
         visibleClipMediaIDs: Set<UUID>? = nil) {
        _vm = State(initialValue: StudioEditorViewModel(project: project, context: context,
                                                        visibleClipMediaIDs: visibleClipMediaIDs))
        self.focusClipMediaID = focusClipMediaID
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            preview
            transportBar
            timeline
            Divider().overlay(Color.white.opacity(0.1))
            if vm.selectedOverlay != nil { overlayBar } else { actionBar }
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .tint(SnappetColor.workout)
        .task {
            await vm.onAppear()
            // Jump straight to the tapped clip (gallery → edit-this-clip), if one was requested.
            if let mid = focusClipMediaID, let clip = vm.clips.first(where: { $0.sessionMediaID == mid }) {
                vm.select(clip.id)
            }
        }
        .onChange(of: vm.exportState) { _, state in
            if case .exported = state { showingShare = true }
        }
        .sheet(isPresented: $showingShare) {
            if case let .exported(url) = vm.exportState { ShareSheet(items: [url]) }
        }
        .sheet(item: $activeTool) { tool in
            StudioToolSheet(tool: tool, vm: vm)
                .presentationDetents([(tool == .adjust || tool == .hr) ? .height(380) : .height(260)])
                .presentationDragIndicator(.visible)
        }
        .alert("Add text", isPresented: $addingText) {
            TextField("Text", text: $textDraft)
            Button("Add") { if !textDraft.isEmpty { vm.addText(textDraft) }; textDraft = "" }
            Button("Cancel", role: .cancel) { textDraft = "" }
        }
        .alert("Rename", isPresented: $renaming) {
            TextField("Title", text: $titleDraft)
            Button("Save") { vm.rename(titleDraft) }
            Button("Cancel", role: .cancel) {}
        }
        .fileImporter(isPresented: $importingMusic, allowedContentTypes: [.audio]) { result in
            if case let .success(url) = result { vm.addMusic(from: url) }
        }
        .confirmationDialog("Add picture-in-picture", isPresented: $choosingPiP, titleVisibility: .visible) {
            ForEach(vm.pipSources, id: \.id) { src in
                Button(src.label) { vm.addPiP(localIdentifier: src.localIdentifier) }
            }
        } message: { Text("Pick a clip to overlay on top of the video.") }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: { Image(systemName: "xmark").font(.headline) }
                .accessibilityIdentifier("studioClose")
            Button { titleDraft = vm.title; renaming = true } label: {
                HStack(spacing: 4) {
                    Text(vm.title).lineLimit(1).font(.subheadline.weight(.semibold))
                    Image(systemName: "chevron.down").font(.caption2)
                }
            }
            .foregroundStyle(.white)
            Spacer()
            Menu {
                Picker("Quality", selection: Binding(get: { vm.exportQuality }, set: { vm.exportQuality = $0 })) {
                    ForEach(StudioExportQuality.allCases) { q in Text(q.label).tag(q) }
                }
            } label: {
                Text(vm.exportQuality.label).font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.3)))
            }
            .accessibilityIdentifier("studioQuality")
            Button { Task { await vm.export() } } label: {
                Text("Export").font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(SnappetColor.workout, in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(.white)
            }
            .accessibilityIdentifier("studioExport")
            .disabled(vm.clips.isEmpty)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    // MARK: Preview

    @ViewBuilder private var preview: some View {
        ZStack {
            Color.black
            if let player = vm.previewPlayer {
                StudioPlayerLayerView(player: player)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "film.stack").font(.largeTitle).foregroundStyle(.white.opacity(0.7))
                    Text(vm.isBuildingPreview ? "Building preview…" : "Preview renders on a device")
                        .font(.caption).foregroundStyle(.white.opacity(0.7))
                }
            }
            // WYSIWYG overlay editing layer: text/sticker overlays are draggable here (they're not in
            // the live preview video — Core Animation overlays are export-only), and map to the same
            // normalized position export reads, so what you place is what renders.
            StudioOverlayCanvas(overlays: vm.overlays, ratio: vm.previewRatio,
                                selectedID: vm.selectedOverlayID,
                                onSelect: { vm.selectOverlay($0) },
                                onMove: { vm.setOverlayPosition($0, normalized: $1) },
                                onScale: { vm.setOverlayScale($0, $1) })
            // Live heart-rate chart overlay (moving-playhead line), draggable to reposition.
            if let hr = vm.hrOverlay {
                StudioHRChartView(samples: vm.hrSeries, config: hr, ratio: vm.previewRatio,
                                  currentTime: vm.currentTime, totalDuration: vm.totalDuration,
                                  onMove: { vm.setHRPosition($0) },
                                  onResize: { vm.setHRScale($0) })
                    .accessibilityIdentifier("studioHRChart")
            }
            if let err = vm.previewError {
                Text(err)
                    .font(.caption2).foregroundStyle(.yellow)
                    .multilineTextAlignment(.center).padding(8)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .accessibilityIdentifier("studioPreviewError")
            }
            if case .exporting = vm.exportState {
                ProgressView("Exporting…").padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .frame(maxHeight: .infinity)
        .accessibilityIdentifier("studioPreview")
    }

    // MARK: Transport (play/pause + live timecode + undo/redo)

    private var transportBar: some View {
        HStack(spacing: 16) {
            Button { vm.togglePlay() } label: {
                Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill").font(.title3)
            }
            .accessibilityIdentifier("studioPlayPause")
            .disabled(vm.previewPlayer == nil)
            Button { vm.addOverlayKeyframeAtPlayhead() } label: { Image(systemName: "diamond.fill").font(.caption) }
                .accessibilityIdentifier("studioKeyframe")
                .disabled(vm.selectedOverlay == nil)
                .help("Add an opacity keyframe for the selected overlay at the playhead")
            Spacer()
            Text("\(timecode(vm.currentTime)) / \(timecode(vm.totalDuration))")
                .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.85))
            Spacer()
            Button { vm.undoEdit() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!vm.canUndo).accessibilityIdentifier("studioUndo")
            Button { vm.redoEdit() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!vm.canRedo).accessibilityIdentifier("studioRedo")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private func timecode(_ s: Double) -> String {
        let total = Int(s.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    // MARK: Timeline (scrubbable, fixed centre playhead, trim handles)

    private var timeline: some View {
        StudioTimelineView(vm: vm)
            .accessibilityIdentifier("studioTimeline")
    }

    // MARK: Contextual action bar

    @ViewBuilder private var actionBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                let hasClip = vm.selectedClip != nil
                barButton("Split", "scissors", enabled: hasClip || vm.previewPlayer != nil) {
                    vm.splitAtPlayhead()
                }
                .accessibilityIdentifier("studioSplit")
                barButton("Speed", "speedometer", enabled: hasClip) { activeTool = .speed }
                barButton("Volume", "speaker.wave.2", enabled: hasClip) { activeTool = .volume }
                barButton("Filter", "camera.filters", enabled: hasClip) { activeTool = .filter }
                barButton("Adjust", "slider.horizontal.3", enabled: hasClip) { activeTool = .adjust }
                barButton("Transition", "arrow.left.arrow.right", enabled: hasClip) { activeTool = .transition }
                barButton("Text", "textformat") { addingText = true }
                    .accessibilityIdentifier("studioAddText")
                barButton(vm.musicTracks.isEmpty ? "Music" : "Music ✓", "music.note", action: { importingMusic = true })
                    .accessibilityIdentifier("studioAddMusic")
                barButton("PiP", "rectangle.on.rectangle", enabled: !vm.pipSources.isEmpty) { choosingPiP = true }
                    .accessibilityIdentifier("studioAddPiP")
                barButton(vm.hrOverlay == nil ? "HR" : "HR ✓", "waveform.path.ecg",
                          enabled: vm.hasHRData) { activeTool = .hr }
                    .accessibilityIdentifier("studioHRTool")
                barButton("Canvas", "aspectratio") { activeTool = .aspect }
                barButton("Delete", "trash", enabled: hasClip, role: .destructive) { vm.deleteSelected() }
                    .accessibilityIdentifier("studioDelete")
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
        }
        .background(Color(white: 0.05))
        .overlay(alignment: .top) {
            if vm.selectedClip == nil {
                Text("Tap a clip to edit it").font(.caption2).foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
        if case let .failed(msg) = vm.exportState {
            Text(msg).font(.footnote).foregroundStyle(.red).padding(6)
        }
    }

    // MARK: Overlay controls bar (shown when a text/sticker overlay is selected)

    @ViewBuilder private var overlayBar: some View {
        if let ov = vm.selectedOverlay {
            VStack(spacing: 8) {
                HStack {
                    Image(systemName: ov.kind == .sticker ? "star.square" : "textformat")
                        .foregroundStyle(SnappetColor.workout)
                    Text(ov.content).lineLimit(1).font(.subheadline)
                    Spacer()
                    if !ov.opacityKeyframes.isEmpty {
                        Text("\(ov.opacityKeyframes.count) kf").font(.caption2).foregroundStyle(.secondary)
                    }
                    Button(role: .destructive) { vm.deleteOverlay(ov.id) } label: { Image(systemName: "trash") }
                        .accessibilityIdentifier("studioDeleteOverlay")
                    Button { vm.selectOverlay(nil) } label: { Text("Done").font(.caption.weight(.semibold)) }
                }
                HStack {
                    Image(systemName: "circle.lefthalf.filled").font(.caption)
                    Slider(value: Binding(get: { ov.opacity },
                                          set: { vm.setOverlayOpacity(ov.id, $0) }), in: 0...1)
                        .accessibilityIdentifier("overlayOpacity")
                    Button { vm.addOverlayKeyframeAtPlayhead() } label: {
                        Label("Keyframe", systemImage: "diamond").font(.caption2)
                    }
                }
                Text("Drag the overlay on the preview to position it. Set opacity at two playhead times (Keyframe) to fade it.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .foregroundStyle(.white)
            .background(Color(white: 0.05))
        }
    }

    private func barButton(_ title: String, _ icon: String, enabled: Bool = true,
                           role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 18))
                Text(title).font(.caption2)
            }
            .frame(minWidth: 60)
            .foregroundStyle(enabled ? .white : Color.white.opacity(0.3))
        }
        .disabled(!enabled)
    }
}

/// The bottom-sheet tool invoked from the action bar (Speed · Filter · Transition · Canvas) — keeps
/// the bar to one tap and the value-picking in a focused sheet (the edits pattern).
enum StudioTool: String, Identifiable { case speed, volume, filter, adjust, transition, aspect, hr; var id: String { rawValue } }

private struct StudioToolSheet: View {
    let tool: StudioTool
    @Bindable var vm: StudioEditorViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            content
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var title: String {
        switch tool {
        case .speed: return "Speed"
        case .volume: return "Volume"
        case .filter: return "Filter"
        case .adjust: return "Adjust"
        case .transition: return "Transition"
        case .aspect: return "Canvas aspect"
        case .hr: return "Heart-rate chart"
        }
    }

    @ViewBuilder private var content: some View {
        switch tool {
        case .speed:
            if let clip = vm.selectedClip {
                Picker("Speed", selection: Binding(get: { clip.speed }, set: { vm.setSelectedSpeed($0) })) {
                    ForEach([0.5, 1.0, 1.5, 2.0], id: \.self) { Text("\($0, specifier: "%g")×").tag($0) }
                }.pickerStyle(.segmented)
            }
        case .filter:
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(StudioFilter.allCases, id: \.self) { f in
                        Button { vm.setSelectedFilter(f); dismiss() } label: {
                            Text(f.display).font(.caption)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background((vm.selectedClip?.filter == f) ? SnappetColor.workout : Color(white: 0.15),
                                            in: Capsule())
                                .foregroundStyle(.white)
                        }
                    }
                }
            }
        case .volume:
            StudioVolumeControls(vm: vm)
        case .adjust:
            StudioAdjustControls(vm: vm)
        case .hr:
            StudioHRControls(vm: vm)
        case .transition:
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(StudioTransitionKind.allCases, id: \.self) { k in
                        Button { vm.setTransitionAfterSelected(k); dismiss() } label: {
                            Text(k.display).font(.caption)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(Color(white: 0.15), in: Capsule())
                                .foregroundStyle(.white)
                        }
                    }
                }
            }
        case .aspect:
            HStack(spacing: 10) {
                ForEach(ClipEditGeometry.OutputAspect.allCases, id: \.self) { a in
                    Button { vm.setAspect(a); dismiss() } label: {
                        Text(a.label).font(.caption)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background((vm.aspect == a) ? SnappetColor.workout : Color(white: 0.15), in: Capsule())
                            .foregroundStyle(.white)
                    }
                }
            }
        }
    }
}

/// The HR-chart tool: enable/disable the overlay + customize colour, size, live-BPM, and zone colour.
/// Position is set by dragging the chart on the preview. Sliders/toggles commit immediately (the HR
/// overlay isn't in the playback composition, so there's no preview rebuild).
private struct StudioHRControls: View {
    @Bindable var vm: StudioEditorViewModel
    private let swatches = ["#FF3B30", "#FF9F0A", "#FFD60A", "#30D158", "#0A84FF", "#FFFFFF"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Show heart-rate chart", isOn: Binding(
                get: { vm.hrOverlay != nil },
                set: { _ in vm.toggleHROverlay() }))
                .accessibilityIdentifier("hrEnable")
            if let cfg = vm.hrOverlay {
                HStack(spacing: 10) {
                    Text("Colour").font(.caption).frame(width: 60, alignment: .leading)
                    ForEach(swatches, id: \.self) { hex in
                        Circle().fill(Color(studioHex: hex)).frame(width: 24, height: 24)
                            .overlay(Circle().stroke(.white, lineWidth: cfg.colorHex == hex ? 2 : 0))
                            .onTapGesture { var c = cfg; c.colorHex = hex; c.zoneColored = false; vm.updateHROverlay(c) }
                    }
                }
                HStack {
                    Text("Size").font(.caption).frame(width: 60, alignment: .leading)
                    Slider(value: Binding(get: { cfg.scale },
                                          set: { var c = cfg; c.scale = $0; vm.updateHROverlay(c) }),
                           in: 0.4...1).accessibilityIdentifier("hrSize")
                }
                Toggle("Live BPM number", isOn: Binding(
                    get: { cfg.showBPM }, set: { var c = cfg; c.showBPM = $0; vm.updateHROverlay(c) }))
                Toggle("Colour by HR zone", isOn: Binding(
                    get: { cfg.zoneColored }, set: { var c = cfg; c.zoneColored = $0; vm.updateHROverlay(c) }))
                Text("Drag the chart on the preview to position it.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

/// The Volume tool: original-audio volume slider + mute for the selected clip. Commits on release
/// (one preview rebuild per drag). Maps to `TimelineClip.volume` → an `AVAudioMix` in the composer.
private struct StudioVolumeControls: View {
    @Bindable var vm: StudioEditorViewModel
    @State private var value: Double = 1

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Image(systemName: value == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 28)
                Slider(value: $value, in: 0...1, onEditingChanged: { editing in
                    if !editing { vm.setSelectedVolume(value) }
                })
                .accessibilityIdentifier("volumeSlider")
                Text("\(Int(value * 100))%").font(.caption.monospacedDigit()).frame(width: 44)
            }
            Button(value == 0 ? "Unmute" : "Mute") {
                value = value == 0 ? 1 : 0
                vm.setSelectedVolume(value)
            }
            .font(.caption).foregroundStyle(SnappetColor.workout)
        }
        .onAppear { value = vm.selectedClip?.volume ?? 1 }
    }
}

/// The Adjust tool: brightness/contrast/saturation sliders for the selected clip. Each slider holds a
/// local value and **commits on release** (`onEditingChanged`) so the preview rebuilds once per drag,
/// not per tick. Maps to `ClipAdjust` → `CIColorControls` in the composer.
private struct StudioAdjustControls: View {
    @Bindable var vm: StudioEditorViewModel
    @State private var value: ClipAdjust = .neutral

    var body: some View {
        VStack(spacing: 12) {
            slider("Brightness", $value.brightness, -0.5...0.5)
            slider("Contrast", $value.contrast, 0.5...1.5)
            slider("Saturation", $value.saturation, 0...2)
            Button("Reset") { value = .neutral; vm.setSelectedAdjust(.neutral) }
                .font(.caption).foregroundStyle(SnappetColor.workout)
        }
        .onAppear { value = vm.selectedClip?.adjust ?? .neutral }
    }

    private func slider(_ label: String, _ binding: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack {
            Text(label).font(.caption).frame(width: 80, alignment: .leading)
            Slider(value: binding, in: range, onEditingChanged: { editing in
                if !editing { vm.setSelectedAdjust(value) }
            })
            .accessibilityIdentifier("adjust-\(label)")
        }
    }
}

