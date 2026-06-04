import SwiftUI
import SwiftData
import AVKit

/// The full-studio **multi-clip editor** (S1): a preview canvas over the live `StudioComposer`
/// composition, a horizontal **timeline** of clips (select · reorder · split · delete), per-clip
/// controls (speed · filter · transition-to-next), project aspect, text overlay, undo/redo, and
/// export → share. Presented as a sheet, so it owns its own `NavigationStack`.
///
/// Editing is model-driven and works on the simulator; the preview/export render through PHAsset →
/// AVFoundation and are **device-only**, so on the simulator the canvas shows a device-only
/// placeholder while the timeline + every edit still function.
struct StudioEditorView: View {
    @State private var vm: StudioEditorViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingShare = false
    @State private var addingText = false
    @State private var textDraft = ""

    init(project: StudioProject, context: ModelContext) {
        _vm = State(initialValue: StudioEditorViewModel(project: project, context: context))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                preview
                timeline
                Divider()
                controls
            }
            .navigationTitle("Studio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button { vm.undoEdit() } label: { Image(systemName: "arrow.uturn.backward") }
                        .disabled(!vm.canUndo).accessibilityIdentifier("studioUndo")
                    Button { vm.redoEdit() } label: { Image(systemName: "arrow.uturn.forward") }
                        .disabled(!vm.canRedo).accessibilityIdentifier("studioRedo")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Export") { Task { await vm.export() } }
                        .accessibilityIdentifier("studioExport")
                        .disabled(vm.clips.isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .task { await vm.onAppear() }
            .onChange(of: vm.exportState) { _, state in
                if case .exported = state { showingShare = true }
            }
            .sheet(isPresented: $showingShare) {
                if case let .exported(url) = vm.exportState { ShareSheet(items: [url]) }
            }
            .alert("Add text", isPresented: $addingText) {
                TextField("Text", text: $textDraft)
                Button("Add") { if !textDraft.isEmpty { vm.addText(textDraft) }; textDraft = "" }
                Button("Cancel", role: .cancel) { textDraft = "" }
            }
        }
    }

    // MARK: Preview

    @ViewBuilder private var preview: some View {
        ZStack {
            Color.black
            if let player = vm.previewPlayer {
                VideoPlayer(player: player)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "film.stack").font(.largeTitle).foregroundStyle(.white.opacity(0.7))
                    Text(vm.isBuildingPreview ? "Building preview…" : "Preview renders on a device")
                        .font(.caption).foregroundStyle(.white.opacity(0.7))
                }
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
                ProgressView("Exporting…").padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .frame(height: 240)
        .accessibilityIdentifier("studioPreview")
    }

    // MARK: Timeline

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
        .background(Color(.secondarySystemBackground))
    }

    // MARK: Controls

    @ViewBuilder private var controls: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let clip = vm.selectedClip {
                    selectedClipControls(clip)
                } else {
                    Text("Tap a clip to edit it").font(.subheadline).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.top, 8)
                }
                Divider()
                projectControls
            }
            .padding()
        }
    }

    private func selectedClipControls(_ clip: TimelineClip) -> some View {
        VStack(spacing: 14) {
            HStack {
                Button { vm.moveSelected(by: -1) } label: { Image(systemName: "chevron.left.2") }
                Button { vm.moveSelected(by: 1) } label: { Image(systemName: "chevron.right.2") }
                Spacer()
                if !clip.isPhoto {
                    Button { vm.splitSelected() } label: { Label("Split", systemImage: "scissors") }
                        .accessibilityIdentifier("studioSplit")
                }
                Button(role: .destructive) { vm.deleteSelected() } label: { Label("Delete", systemImage: "trash") }
                    .accessibilityIdentifier("studioDelete")
            }
            .buttonStyle(.bordered)

            if !clip.isPhoto {
                HStack {
                    Text("Speed").font(.subheadline)
                    Spacer()
                    Picker("Speed", selection: Binding(
                        get: { clip.speed },
                        set: { vm.setSelectedSpeed($0) })) {
                        ForEach([0.5, 1.0, 1.5, 2.0], id: \.self) { Text("\($0, specifier: "%g")×").tag($0) }
                    }.pickerStyle(.segmented).frame(width: 220)
                }
            }

            HStack {
                Text("Filter").font(.subheadline)
                Spacer()
                Menu(clip.filter.display) {
                    ForEach(StudioFilter.allCases, id: \.self) { f in
                        Button(f.display) { vm.setSelectedFilter(f) }
                    }
                }
            }

            HStack {
                Text("Transition →").font(.subheadline)
                Spacer()
                Menu(vm.transitionKind(afterClipID: clip.id).display) {
                    ForEach(StudioTransitionKind.allCases, id: \.self) { k in
                        Button(k.display) { vm.setTransitionAfterSelected(k) }
                    }
                }
            }
        }
    }

    private var projectControls: some View {
        VStack(spacing: 14) {
            HStack {
                Text("Canvas").font(.subheadline)
                Spacer()
                Menu(vm.aspect.label) {
                    ForEach(ClipEditGeometry.OutputAspect.allCases, id: \.self) { a in
                        Button(a.label) { vm.setAspect(a) }
                    }
                }
            }
            Button { addingText = true } label: { Label("Add text overlay", systemImage: "textformat") }
                .accessibilityIdentifier("studioAddText")
            if case let .failed(msg) = vm.exportState {
                Text(msg).font(.footnote).foregroundStyle(.red)
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
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary)
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
