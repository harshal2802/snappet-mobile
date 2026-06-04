import SwiftUI
import SwiftData
import AVKit

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

    init(project: StudioProject, context: ModelContext) {
        _vm = State(initialValue: StudioEditorViewModel(project: project, context: context))
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            preview
            transportBar
            timeline
            Divider().overlay(Color.white.opacity(0.1))
            actionBar
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .tint(SnappetColor.workout)
        .task { await vm.onAppear() }
        .onChange(of: vm.exportState) { _, state in
            if case .exported = state { showingShare = true }
        }
        .sheet(isPresented: $showingShare) {
            if case let .exported(url) = vm.exportState { ShareSheet(items: [url]) }
        }
        .sheet(item: $activeTool) { tool in
            StudioToolSheet(tool: tool, vm: vm)
                .presentationDetents([.height(260)])
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
                                onMove: { vm.setOverlayPosition($0, normalized: $1) })
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

    // MARK: Timeline (clip strip — selectable; Phase 2 adds scrub/trim handles)

    private var timeline: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(vm.clips.enumerated()), id: \.element.id) { idx, clip in
                    Button { vm.select(clip.id) } label: {
                        StudioClipCard(index: idx + 1, clip: clip,
                                       duration: vm.outputDuration(of: clip),
                                       selected: clip.id == vm.selectedClipID,
                                       transition: vm.transitionKind(afterClipID: clip.id),
                                       isLast: idx == vm.clips.count - 1)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("studioClipCard")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
        }
        .frame(height: 96)
        .background(Color(white: 0.08))
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
                barButton("Filter", "camera.filters", enabled: hasClip) { activeTool = .filter }
                barButton("Transition", "arrow.left.arrow.right", enabled: hasClip) { activeTool = .transition }
                barButton("Text", "textformat") { addingText = true }
                    .accessibilityIdentifier("studioAddText")
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
enum StudioTool: String, Identifiable { case speed, filter, transition, aspect; var id: String { rawValue } }

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
        case .filter: return "Filter"
        case .transition: return "Transition"
        case .aspect: return "Canvas aspect"
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

/// One timeline clip card: index, a placeholder/icon, the output duration, the active filter, and a
/// transition badge to the next clip. Selected state is ringed. Thumbnails are device-only, so the
/// card uses an icon placeholder (the simulator has no Photos).
private struct StudioClipCard: View {
    let index: Int
    let clip: TimelineClip
    let duration: Double
    let selected: Bool
    let transition: StudioTransitionKind
    let isLast: Bool

    var body: some View {
        HStack(spacing: 4) {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(white: 0.18))
                    Image(systemName: clip.isPhoto ? "photo" : "video").foregroundStyle(.secondary)
                    if clip.filter != .none {
                        Text(clip.filter.display).font(.system(size: 8, weight: .bold))
                            .padding(2).background(.thinMaterial, in: Capsule())
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(3)
                    }
                }
                .frame(width: 64, height: 50)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(SnappetColor.workout,
                          lineWidth: selected ? 2.5 : 0))
                Text("\(index) · \(Int(duration.rounded()))s")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            if !isLast {
                Image(systemName: transition == .none ? "rectangle.split.2x1" : "arrow.left.arrow.right")
                    .font(.caption2)
                    .foregroundStyle(transition == .none ? AnyShapeStyle(.tertiary) : AnyShapeStyle(SnappetColor.workout))
            }
        }
    }
}
