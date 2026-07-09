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
    @Environment(AppModel.self) private var app
    @State private var showingShare = false
    @State private var addingText = false
    @State private var textDraft = ""
    @State private var renaming = false
    @State private var titleDraft = ""
    @State private var activeTool: StudioTool?
    @State private var importingMusic = false
    @State private var choosingPiP = false
    @State private var editingOverlay = false
    @State private var overlayTextDraft = ""
    @State private var overlayTextTarget: UUID?
    @State private var stylingOverlay = false

    /// `SessionMedia.id` of a clip to pre-select when the studio opens (e.g. tapping one clip in a
    /// gallery jumps straight to editing it). `nil` keeps the default (no/first selection).
    private let focusClipMediaID: UUID?

    init(project: StudioProject, context: ModelContext, focusClipMediaID: UUID? = nil,
         visibleClipMediaIDs: Set<UUID>? = nil, suggestedClimbCaption: String? = nil,
         suggestedAttemptNumber: Int? = nil) {
        _vm = State(initialValue: StudioEditorViewModel(project: project, context: context,
                                                        visibleClipMediaIDs: visibleClipMediaIDs,
                                                        suggestedClimbCaption: suggestedClimbCaption,
                                                        suggestedAttemptNumber: suggestedAttemptNumber))
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
            // For a still-live session whose HR isn't flushed yet, supply the live coordinator buffer
            // (both transports merged) as the fallback so mid-session clips still show HR.
            await vm.onAppear {
                WorkoutHRStats.points(from: LiveHRMerge.merge(
                    app.liveWorkout.watch.samples, app.liveWorkout.ble.samples))
            }
            vm.loadOverlayContext(profile: app.userProfile.profile)   // overlay-builder bounds (prompt 28)
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
                .presentationDetents([(tool == .adjust || tool == .hr || tool == .grid) ? .height(380) : .height(260)])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $stylingOverlay) {
            StudioTextStyleControls(vm: vm)
                .presentationDetents([.height(420)])
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
        .alert("Edit text", isPresented: $editingOverlay) {
            TextField("Text", text: $overlayTextDraft)
            Button("Save") { if let id = overlayTextTarget { vm.editOverlayText(id, overlayTextDraft) } }
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
                .accessibilityLabel("Close studio")
            Button { titleDraft = vm.title; renaming = true } label: {
                HStack(spacing: 4) {
                    Text(vm.title).lineLimit(1).font(.subheadline.weight(.semibold))
                    Image(systemName: "chevron.down").font(.caption2)
                }
            }
            .foregroundStyle(.white)
            .accessibilityLabel("Project name, \(vm.title)")
            .accessibilityHint("Rename the project")
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
            StudioOverlayCanvas(overlays: vm.canvasOverlays, ratio: vm.previewRatio,
                                selectedID: vm.selectedOverlayID,
                                currentTime: vm.currentTime,
                                snapEnabled: vm.snapEnabled,
                                baseFrame: vm.baseFrame,
                                sourceAspects: vm.sourceAspects,
                                baseAspect: vm.baseSourceAspect,
                                onSelect: { vm.selectOverlay($0) },
                                onMove: { vm.setOverlayPosition($0, normalized: $1) },
                                onScale: { vm.setOverlayScale($0, $1) },
                                onFrame: { vm.setOverlayFrame($0, center: $1, size: $2) },
                                onBaseFrame: { vm.setBaseFrame(center: $0, size: $1) })
            // The unified HR stat tile (the overlay redesign): one draggable + corner-resizable tile,
            // rendered WYSIWYG with the per-clip export via the shared HRTileLayout. Any legacy
            // free-floating-badge overlay is folded into a tile by HRTileMigration on appear.
            if let tile = vm.hrTile {
                let preview = vm.previewTile
                HRTileEditorView(tile: tile, values: preview.values,
                                 fraction: preview.fraction, ratio: vm.previewRatio,
                                 onFrame: { vm.setTileFrame(center: $0, size: $1) })
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
            .accessibilityLabel(vm.isPlaying ? "Pause" : "Play")
            .disabled(vm.previewPlayer == nil)
            Button { vm.addOverlayKeyframeAtPlayhead() } label: { Image(systemName: "diamond.fill").font(.caption) }
                .accessibilityIdentifier("studioKeyframe")
                // diamond.fill carries no default label — without this VoiceOver reads nothing (#79).
                .accessibilityLabel("Add opacity keyframe")
                .accessibilityHint("Keyframes the selected overlay's opacity at the playhead")
                .disabled(vm.selectedOverlay == nil)
                .help("Add an opacity keyframe for the selected overlay at the playhead")
            Spacer()
            Text("\(timecode(vm.currentTime)) / \(timecode(vm.totalDuration))")
                .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.85))
                .accessibilityLabel("Playhead \(timecode(vm.currentTime)) of \(timecode(vm.totalDuration))")
            Spacer()
            Button { vm.undoEdit() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!vm.canUndo).accessibilityIdentifier("studioUndo")
                .accessibilityLabel("Undo")
            Button { vm.redoEdit() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!vm.canRedo).accessibilityIdentifier("studioRedo")
                .accessibilityLabel("Redo")
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
                barButton("Grid", "square.grid.2x2") { activeTool = .grid }
                    .accessibilityIdentifier("studioGridTool")
                barButton(vm.hasClimbOverlay ? "Climb ✓" : "Climb", "signpost.right",
                          enabled: vm.hasClimbInfo) { vm.addClimbNameOverlay() }
                    .accessibilityIdentifier("studioAddClimbName")
                barButton(vm.hrOverlay == nil ? "HR" : "HR ✓", "waveform.path.ecg",
                          enabled: vm.hasHRData) { activeTool = .hr }
                    .accessibilityIdentifier("studioHRTool")
                barButton("Canvas", "aspectratio") { activeTool = .aspect }
                barButton("Delete", "trash", enabled: hasClip, role: .destructive) { vm.deleteSelected() }
                    .accessibilityIdentifier("studioDelete")
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
        }
        .accessibilityIdentifier("studioActionBar")
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
                    Image(systemName: overlayIcon(ov))
                        .foregroundStyle(SnappetColor.workout)
                    Text(ov.content).lineLimit(1).font(.subheadline)
                    Spacer()
                    if !ov.opacityKeyframes.isEmpty {
                        Text("\(ov.opacityKeyframes.count) kf").font(.caption2).foregroundStyle(.secondary)
                    }
                    if ov.kind == .text || ov.kind == .climbName {
                        Button {
                            overlayTextTarget = ov.id; overlayTextDraft = ov.content; editingOverlay = true
                        } label: { Image(systemName: "pencil") }
                            .accessibilityIdentifier("studioEditOverlayText")
                        Button { stylingOverlay = true } label: { Image(systemName: "paintbrush") }
                            .accessibilityIdentifier("studioStyleOverlay")
                    }
                    Button(role: .destructive) { vm.deleteOverlay(ov.id) } label: { Image(systemName: "trash") }
                        .accessibilityIdentifier("studioDeleteOverlay")
                    Button { vm.selectOverlay(nil) } label: { Text("Done").font(.caption.weight(.semibold)) }
                }
                if ov.kind == .climbName {
                    // "Show setter" only for a Kilter climb (resolvedClimbUUID != nil) — hidden for
                    // freeform, where it would be a dead no-op (prompt 12 STEP 7b).
                    if vm.canShowClimbSetter {
                        Toggle("Show setter", isOn: Binding(get: { vm.selectedClimbShowsSetter },
                                                            set: { vm.setSelectedClimbShowsSetter($0) }))
                            .font(.caption)
                            .accessibilityIdentifier("studioClimbSetter")
                    }
                    // "Attempt #" (prompt 10): add/remove an "Attempt N" line on THIS climb-name tag for a
                    // clip attached to a specific attempt. Shown only when an attempt number was threaded in.
                    if vm.canShowClimbAttempt {
                        Toggle("Attempt #", isOn: Binding(get: { vm.selectedClimbShowsAttempt },
                                                          set: { vm.setSelectedClimbShowsAttempt($0) }))
                            .font(.caption)
                            .accessibilityIdentifier("studioClimbAttempt")
                    }
                }
                if ov.kind != .video {
                    HStack {
                        Image(systemName: "textformat.size").font(.caption)
                        Slider(value: Binding(get: { ov.scale },
                                              set: { vm.setOverlayScale(ov.id, $0) }), in: 0.5...3)
                            .accessibilityIdentifier("overlaySize")
                        Text("\(Int(ov.scale * 100))%").font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary).frame(width: 40)
                    }
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
                Text("Drag the overlay on the preview to position it; pinch or use Size to scale it. Set opacity at two playhead times (Keyframe) to fade it.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .foregroundStyle(.white)
            .background(Color(white: 0.05))
        }
    }

    private func overlayIcon(_ ov: OverlayItem) -> String {
        switch ov.kind {
        case .sticker: return "star.square"
        case .climbName: return "signpost.right"
        case .video: return "rectangle.on.rectangle"
        case .text: return "textformat"
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
enum StudioTool: String, Identifiable { case speed, volume, filter, adjust, transition, aspect, hr, grid; var id: String { rawValue } }

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
        case .hr: return "Heart-rate tile"
        case .grid: return "PiP grid"
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
        case .grid:
            StudioGridControls(vm: vm)
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

    var body: some View {
        // Scrollable: the tile builder (catalog + chart toggle + a row per metric) is taller than the
        // sheet, so every metric stays reachable.
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Enable the overlay (spawns the stat tile). The barButton shows "HR ✓" once on.
                Toggle("Show heart-rate tile", isOn: Binding(
                    get: { vm.hrOverlay != nil }, set: { _ in vm.toggleHROverlay() }))
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("hrTileEnable")
                if vm.hrTile != nil {
                    HRTileBuilder(vm: vm)
                } else {
                    Text("Turn on to overlay your heart rate and fitness metrics as a single resizable tile.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The HR stat tile builder: pick a design from the catalog, toggle the chart line, and turn each
/// metric on/off (all on by default). The tile itself is dragged/resized on the preview.
private struct HRTileBuilder: View {
    @Bindable var vm: StudioEditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Tile design").font(.subheadline.weight(.semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(HRTileTemplate.allCases) { template in
                        let selected = vm.hrTile?.template == template
                        Button { vm.selectTileTemplate(template) } label: {
                            VStack(spacing: 6) {
                                Image(systemName: template.systemImage).font(.title3)
                                Text(template.label).font(.caption2)
                            }
                            .frame(width: 78, height: 64)
                            .background(Color(white: selected ? 0.28 : 0.15), in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10)
                                .stroke(SnappetColor.workout, lineWidth: selected ? 2 : 0))
                            .foregroundStyle(.white)
                        }
                        .accessibilityIdentifier("studioTileTemplate.\(template.rawValue)")
                    }
                }
            }
            .accessibilityIdentifier("studioTileTemplatePicker")

            Toggle("Show chart line", isOn: Binding(
                get: { vm.hrTile?.showChart ?? false }, set: { vm.setTileShowChart($0) }))
                .accessibilityIdentifier("hrChartEnable")

            // Whole-tile transparency — drag left to let more of the video show through.
            HStack(spacing: 10) {
                Image(systemName: "circle.lefthalf.filled").font(.caption)
                Text("Opacity").font(.caption).frame(width: 64, alignment: .leading)
                Slider(value: Binding(get: { vm.hrTile?.opacity ?? 1 }, set: { vm.setTileOpacity($0) }),
                       in: HRTile.minOpacity...1)
                    .accessibilityIdentifier("hrTileOpacity")
                Text("\(Int((vm.hrTile?.opacity ?? 1) * 100))%")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary).frame(width: 40)
            }

            // Extended HR window (prompt 115) — per-clip lead-in/tail + metrics scope. Targets the
            // clip under the playhead (the same clip the preview tile shows). The info is resolved
            // ONCE here (it rebuilds the placed timeline) and pins the target clip id for the whole
            // control group, so a moving playhead can't retarget a slider drag.
            if let info = vm.hrWindowInfo {
                Divider().overlay(Color.white.opacity(0.1))
                HRWindowControls(vm: vm, info: info)
            }

            Divider().overlay(Color.white.opacity(0.1))
            Text("Metrics").font(.subheadline.weight(.semibold))
            Text("Toggle what to show — the caption under each explains what it means.")
                .font(.caption2).foregroundStyle(.secondary)
            ForEach(vm.tileEntries) { entry in
                HRTileMetricRow(vm: vm, entry: entry)
            }
            if vm.tileHiddenCount > 0 {
                Label("+\(vm.tileHiddenCount) more — drag a corner to enlarge the tile",
                      systemImage: "arrow.up.left.and.arrow.down.right")
                    .font(.caption2).foregroundStyle(SnappetColor.workout)
                    .accessibilityIdentifier("studioTileEnlargeHint")
            }
            Text("Drag the tile on the preview to move it; drag a corner to resize.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// The extended-HR-window controls (prompt 115): a mini-map of the window (lead | footage | tail),
/// the Lead-in / Tail sliders, the metrics-scope picker, and a Reset row. Per-clip — `info` is
/// resolved once by the parent and pins the target clip id, so a moving playhead can't retarget a
/// drag; sliders show the live value while dragging but COMMIT once on drag-end (one undo entry per
/// drag, the trim slider's house pattern). The mini-map shows the EFFECTIVE lead/tail (what the
/// chart's panes actually cover after session-start / recorded-HR clamping), with honest hints when
/// they differ from the requested values.
private struct HRWindowControls: View {
    @Bindable var vm: StudioEditorViewModel
    let info: StudioEditorViewModel.HRWindowEditorInfo
    /// In-flight slider values (nil = not dragging) — drives the label live, committed on drag-end.
    @State private var dragLead: Double?
    @State private var dragTail: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("HR window").font(.subheadline.weight(.semibold))
                Text("this clip").font(.caption2).foregroundStyle(.secondary)
            }
            // Mini-map: the window's three regions at their real (EFFECTIVE) proportions — the same
            // spans the chart's panes cover, so this strip mirrors the tile 1:1.
            GeometryReader { geo in
                let span = max(0.001, info.effectiveLead + info.footageSec + info.effectiveTail)
                HStack(spacing: 0) {
                    regionCell(seconds: info.effectiveLead, span: span, width: geo.size.width,
                               label: info.effectiveLead > 0 ? "−\(timecode(info.effectiveLead))" : nil,
                               hex: HRWindowRegionStyle.leadHex, alpha: 0.18)
                    regionCell(seconds: info.footageSec, span: span, width: geo.size.width,
                               label: "FOOTAGE \(timecode(info.footageSec))",
                               hex: HRWindowRegionStyle.footageHex, alpha: 0.22)
                    regionCell(seconds: info.effectiveTail, span: span, width: geo.size.width,
                               label: info.effectiveTail > 0 ? "+\(timecode(info.effectiveTail))" : nil,
                               hex: HRWindowRegionStyle.tailHex, alpha: 0.14)
                }
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(0.12)))
            }
            .frame(height: 26)
            .accessibilityIdentifier("hrWindowMiniMap")

            slider(label: "Lead-in", committed: info.lead, drag: $dragLead,
                   range: 0...HRClipWindow.maxLeadSec, id: "hrWindowLead") {
                vm.setHRWindowLead($0, clipID: info.clipID)
            }
            if info.effectiveLead < info.lead - 0.5 {
                // Honest clamp hint: the session starts inside the requested lead-in.
                Text("Only \(timecode(info.effectiveLead)) of session before this clip — the lead-in clamps there.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .accessibilityIdentifier("hrWindowLeadClampHint")
            }
            slider(label: "Tail", committed: info.tail, drag: $dragTail,
                   range: 0...HRClipWindow.maxTailSec, id: "hrWindowTail") {
                vm.setHRWindowTail($0, clipID: info.clipID)
            }
            if info.effectiveTail < info.tail - 0.5 {
                // Honest clamp hint: the session's recorded HR ends inside the requested tail.
                Text("Recorded HR covers \(timecode(info.effectiveTail)) of the \(timecode(info.tail)) tail — the chart stops at the data.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .accessibilityIdentifier("hrWindowClampHint")
            }
            Text("The chart shows HR beyond the footage; the live dot still tracks the video.")
                .font(.caption2).foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Text("Metrics over").font(.caption)
                Picker("Metrics over", selection: Binding(
                    get: { info.scope }, set: { vm.setHRWindowScope($0, clipID: info.clipID) })) {
                    ForEach(HRMetricsScope.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("hrWindowScope")
            }
            if info.isCustomized {
                HStack {
                    Text("Defaults: lead \(timecode(HRClipWindow.defaultLeadSec)) · tail \(timecode(HRClipWindow.defaultTailSec))")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset") { vm.resetHRWindow(clipID: info.clipID) }
                        .font(.caption.weight(.semibold)).foregroundStyle(SnappetColor.workout)
                        .accessibilityIdentifier("hrWindowReset")
                }
            }
        }
    }

    private func regionCell(seconds: Double, span: Double, width: CGFloat,
                            label: String?, hex: String, alpha: Double) -> some View {
        ZStack {
            Color(studioHex: hex).opacity(alpha)
            if let label {
                Text(label).font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(studioHex: hex))
                    .lineLimit(1).minimumScaleFactor(0.5).padding(.horizontal, 2)
            }
        }
        .frame(width: max(0, seconds / span) * width)
    }

    /// A stepped slider whose label tracks the drag LIVE but whose value commits once on drag-end —
    /// one undo entry + one save per drag, not one per 1-second step.
    private func slider(label: String, committed: Double, drag: Binding<Double?>,
                        range: ClosedRange<Double>, id: String,
                        commit: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.caption).frame(width: 64, alignment: .leading)
            Slider(value: Binding(get: { drag.wrappedValue ?? committed },
                                  set: { drag.wrappedValue = $0 }),
                   in: range, step: 1,
                   onEditingChanged: { editing in
                       guard !editing, let v = drag.wrappedValue else { return }
                       commit(v)
                       drag.wrappedValue = nil
                   })
                .accessibilityIdentifier(id)
            Text(timecode(drag.wrappedValue ?? committed))
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary).frame(width: 40)
        }
    }

    private func timecode(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// One metric row in the tile builder: the ON/OFF visibility toggle (all on by default), plus Live /
/// Animate for time-varying metrics (disabled for static aggregates, like the legacy row).
private struct HRTileMetricRow: View {
    @Bindable var vm: StudioEditorViewModel
    let entry: HRTileMetricEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { entry.on }, set: { _ in vm.toggleTileMetric(entry.id) })) {
                VStack(alignment: .leading, spacing: 1) {
                    Label(entry.metric.label, systemImage: entry.metric.systemImage).font(.subheadline)
                    Text(entry.metric.explanation)
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityIdentifier("studioTileMetric.\(entry.metric.rawValue)")
            if entry.on && entry.metric.supportsLive {
                HStack(spacing: 16) {
                    Toggle("Live", isOn: Binding(get: { entry.isLive },
                                                 set: { vm.setTileMetricLive(entry.id, $0) }))
                    Toggle("Animate", isOn: Binding(get: { entry.isAnimated },
                                                    set: { vm.setTileMetricAnimated(entry.id, $0) }))
                        .disabled(!entry.isLive)
                }
                .font(.caption).toggleStyle(.button)
            }
        }
        .padding(.vertical, 2)
    }
}

/// The PiP grid tool: one-tap collage layouts that tile the picture-in-picture clips into cells, plus
/// a snap-to-grid toggle for free placement. Presets map straight onto the PiP overlays in order.
private struct StudioGridControls: View {
    @Bindable var vm: StudioEditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Resize the main video", isOn: Binding(get: { vm.baseFramed },
                                                          set: { _ in vm.toggleBaseFrame() }))
                .font(.subheadline)
                .accessibilityIdentifier("baseFrameToggle")
            Text(vm.baseFramed
                 ? "Drag the \"Main\" frame's corners on the preview to resize the main video; drag its body to move it."
                 : "Turn on to make the main video a resizable cell instead of filling the whole frame.")
                .font(.caption2).foregroundStyle(.secondary)
            Divider().overlay(Color.white.opacity(0.1))
            Text("Arrange picture-in-picture clips into a grid.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                ForEach(StudioGridLayout.Preset.allCases) { preset in
                    Button { vm.applyPiPGrid(preset) } label: {
                        Text(preset.label).font(.caption.weight(.semibold))
                            .frame(minWidth: 44).padding(.vertical, 10).padding(.horizontal, 6)
                            .background(Color(white: 0.15), in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(vm.hasPiP ? .white : Color.white.opacity(0.35))
                    }
                    .disabled(!vm.hasPiP)
                    .accessibilityIdentifier("grid-\(preset.rawValue)")
                }
            }
            Toggle("Snap to grid", isOn: Binding(get: { vm.snapEnabled }, set: { vm.snapEnabled = $0 }))
                .font(.subheadline)
                .accessibilityIdentifier("gridSnap")
            Text("Drag a clip's corners on the preview to resize it; drag the body to move it.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// The text-styling sheet for the selected text / climb-name overlay: text colour, highlight (None +
/// colours), font preset, and bold / italic. Every control commits immediately — overlays render via
/// the export-only Core Animation tool, so there's no preview rebuild (just the WYSIWYG chip updating).
private struct StudioTextStyleControls: View {
    @Bindable var vm: StudioEditorViewModel
    private let swatches = ["#FFFFFF", "#000000", "#FF3B30", "#FF9F0A", "#FFD60A", "#30D158", "#0A84FF", "#BF5AF2"]

    var body: some View {
        if let ov = vm.selectedOverlay {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Text style").font(.headline)

                    caption("Colour")
                    swatchRow(selected: ov.colorHex) { vm.setOverlayColor(ov.id, $0) }

                    caption("Highlight")
                    HStack(spacing: 10) {
                        noneSwatch(selected: ov.highlightHex == nil) { vm.setOverlayHighlight(ov.id, nil) }
                        ForEach(swatches, id: \.self) { hex in
                            swatch(hex, selected: ov.highlightHex == hex) { vm.setOverlayHighlight(ov.id, hex) }
                        }
                    }

                    caption("Font")
                    Picker("Font", selection: Binding(get: { ov.font }, set: { vm.setOverlayFont(ov.id, $0) })) {
                        ForEach(StudioFont.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("overlayFont")

                    HStack(spacing: 12) {
                        Toggle(isOn: Binding(get: { ov.bold }, set: { vm.setOverlayBold(ov.id, $0) })) {
                            Image(systemName: "bold")
                        }
                        .toggleStyle(.button).accessibilityIdentifier("overlayBold")
                        Toggle(isOn: Binding(get: { ov.italic }, set: { vm.setOverlayItalic(ov.id, $0) })) {
                            Image(systemName: "italic")
                        }
                        .toggleStyle(.button).accessibilityIdentifier("overlayItalic")
                        Spacer()
                    }
                    .padding(.top, 2)
                }
                .padding()
            }
            .tint(SnappetColor.workout)
        } else {
            Text("Select a text overlay").foregroundStyle(.secondary).padding()
        }
    }

    private func caption(_ s: String) -> some View {
        Text(s).font(.caption).foregroundStyle(.secondary)
    }
    private func swatchRow(selected: String, _ set: @escaping (String) -> Void) -> some View {
        HStack(spacing: 10) {
            ForEach(swatches, id: \.self) { hex in swatch(hex, selected: selected == hex) { set(hex) } }
        }
    }
    private func swatch(_ hex: String, selected: Bool, _ tap: @escaping () -> Void) -> some View {
        Circle().fill(Color(studioHex: hex)).frame(width: 28, height: 28)
            .overlay(Circle().stroke(.gray.opacity(0.4), lineWidth: 1))
            .overlay(Circle().stroke(.white, lineWidth: selected ? 2.5 : 0))
            .onTapGesture { tap() }
    }
    private func noneSwatch(selected: Bool, _ tap: @escaping () -> Void) -> some View {
        Image(systemName: "slash.circle")
            .font(.system(size: 22)).foregroundStyle(.secondary)
            .frame(width: 28, height: 28)
            .overlay(Circle().stroke(.white, lineWidth: selected ? 2.5 : 0))
            .onTapGesture { tap() }
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

