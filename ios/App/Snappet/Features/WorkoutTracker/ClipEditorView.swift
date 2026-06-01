import SwiftUI
import SwiftData
import AVKit

/// The CapCut-style **non-destructive** per-clip editor (B3), presented as a **sheet** so it
/// owns its own `NavigationStack` (the WorkoutTracker module rides the App Library's stack and
/// must not nest one — decisions.md). Reached from a tagged video in `SessionDetailView`'s B1
/// gallery.
///
/// An inline `VideoPlayer` previews the **live composition** (`VideoStudio` — the same
/// composition export uses, no render round-trip), with controls for the core CapCut ops: trim,
/// split, crop/aspect, text overlays, speed, mute. Every control writes to the `ClipEdit` and
/// invalidates the preview. The view is thin — all logic is in `ClipEditorViewModel`.
struct ClipEditorView: View {
    let media: SessionMedia

    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var vm: ClipEditorViewModel?
    @State private var editingOverlay: TextOverlay?

    var body: some View {
        NavigationStack {
            Group {
                if let vm {
                    editor(vm)
                } else {
                    ProgressView("Loading clip…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Edit Clip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("clipEditorDone")
                }
            }
            .sheet(item: $editingOverlay) { overlay in
                if let vm {
                    TextOverlayEditor(overlay: overlay) { updated in
                        if vm.edit.textOverlays.contains(where: { $0.id == updated.id }) {
                            vm.updateOverlay(updated)
                        } else {
                            vm.addOverlay(updated)
                        }
                    }
                }
            }
        }
        .task { await loadIfNeeded() }
    }

    private func loadIfNeeded() async {
        guard vm == nil else { return }
        let edit = existingEdit() ?? makeAndInsertEdit()
        let model = ClipEditorViewModel(
            edit: edit, studio: app.videoStudio,
            insert: { context.insert($0) },
            save: { try? context.save() })
        vm = model
        await model.load()
    }

    /// Reuse an existing primary (unsplit / first) edit for this clip if one exists.
    private func existingEdit() -> ClipEdit? {
        let mid = media.id
        let descriptor = FetchDescriptor<ClipEdit>(
            predicate: #Predicate { $0.sessionMediaID == mid },
            sortBy: [SortDescriptor(\.splitOrder, order: .forward)])
        return (try? context.fetch(descriptor))?.first
    }

    private func makeAndInsertEdit() -> ClipEdit {
        let edit = ClipEdit.makeDefault(for: media)
        context.insert(edit)
        try? context.save()
        return edit
    }

    // MARK: - Editor body

    @ViewBuilder
    private func editor(_ vm: ClipEditorViewModel) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                preview(vm)
                TrimControls(vm: vm)
                AspectControls(vm: vm)
                SpeedControls(vm: vm)
                OverlayControls(vm: vm, editingOverlay: $editingOverlay)
                AudioControls(vm: vm)
            }
            .padding()
        }
        .accessibilityIdentifier("clipEditor")
    }

    @ViewBuilder
    private func preview(_ vm: ClipEditorViewModel) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14).fill(.black)
            switch vm.state {
            case .building, .idle:
                ProgressView().tint(.white)
            case .ready:
                if let player = vm.previewPlayer {
                    VideoPlayer(player: player)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .accessibilityIdentifier("clipEditorPreview")
                }
            case .error(let message):
                VStack(spacing: 8) {
                    Image(systemName: "video.slash").font(.largeTitle)
                    Text(message).font(.footnote).multilineTextAlignment(.center)
                }
                .foregroundStyle(.white)
                .padding()
            }
        }
        .frame(height: 280)
    }
}

// MARK: - Trim + split

private struct TrimControls: View {
    @Bindable var vm: ClipEditorViewModel
    @State private var start: Double = 0
    @State private var end: Double = 0
    @State private var splitAt: Double = 0

    var body: some View {
        ControlCard(title: "Trim", systemImage: "scissors") {
            if vm.sourceDuration > 0 {
                labeledSlider("Start", value: $start, range: 0...vm.sourceDuration)
                labeledSlider("End", value: $end, range: 0...vm.sourceDuration)
                labeledSlider("Split at", value: $splitAt, range: 0...vm.sourceDuration)
                HStack {
                    Button {
                        vm.setTrim(start: min(start, end), end: max(start, end))
                    } label: { Label("Apply trim", systemImage: "checkmark") }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("applyTrim")
                    Spacer()
                    Button {
                        vm.split(at: splitAt)
                    } label: { Label("Split", systemImage: "rectangle.split.2x1") }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("splitClip")
                }
            } else {
                Text("Trim is available once the source video loads (needs a real clip — the simulator has none).")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            start = vm.edit.trimStart
            end = vm.effectiveTrimEnd
            splitAt = (vm.edit.trimStart + vm.effectiveTrimEnd) / 2
        }
    }

    private func labeledSlider(_ label: String, value: Binding<Double>,
                               range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(value.wrappedValue, specifier: "%.1f")s")
                    .font(.caption.monospacedDigit())
            }
            Slider(value: value, in: range)
        }
    }
}

// MARK: - Crop / aspect

private struct AspectControls: View {
    @Bindable var vm: ClipEditorViewModel

    var body: some View {
        ControlCard(title: "Aspect & crop", systemImage: "crop") {
            Picker("Aspect", selection: Binding(
                get: { vm.edit.aspect },
                set: { vm.setAspect($0) })) {
                ForEach(ClipEditGeometry.OutputAspect.allCases) { aspect in
                    Text(aspect.label).tag(aspect)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("aspectPicker")

            // A simple centered-zoom crop (a 1.0…1.0 range maps to a centered crop rect).
            let zoom = Binding(
                get: { 1.0 / max(0.2, vm.edit.cropRect.width) },
                set: { z in
                    let side = min(1.0, 1.0 / max(1.0, z))
                    let origin = (1.0 - side) / 2
                    vm.setCrop(CGRect(x: origin, y: origin, width: side, height: side))
                })
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Zoom crop").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(zoom.wrappedValue, specifier: "%.1f")×").font(.caption.monospacedDigit())
                }
                Slider(value: zoom, in: 1.0...3.0)
                    .accessibilityIdentifier("cropZoom")
            }
        }
    }
}

// MARK: - Speed

private struct SpeedControls: View {
    @Bindable var vm: ClipEditorViewModel

    var body: some View {
        ControlCard(title: "Speed", systemImage: "speedometer") {
            HStack {
                Text("\(vm.edit.speed, specifier: "%.2f")×").font(.body.monospacedDigit())
                Spacer()
            }
            Slider(value: Binding(get: { vm.edit.speed }, set: { vm.setSpeed($0) }),
                   in: 0.25...4.0)
                .accessibilityIdentifier("speedSlider")
            HStack(spacing: 8) {
                ForEach([0.5, 1.0, 2.0], id: \.self) { s in
                    Button("\(s, specifier: "%.1f")×") { vm.setSpeed(s) }
                        .buttonStyle(.bordered).font(.caption)
                }
            }
        }
    }
}

// MARK: - Text overlays

private struct OverlayControls: View {
    @Bindable var vm: ClipEditorViewModel
    @Binding var editingOverlay: TextOverlay?

    var body: some View {
        ControlCard(title: "Text", systemImage: "textformat") {
            ForEach(vm.edit.textOverlays) { overlay in
                HStack {
                    Text(overlay.string.isEmpty ? "(empty)" : overlay.string).lineLimit(1)
                    Spacer()
                    Button { editingOverlay = overlay } label: { Image(systemName: "pencil") }
                        .buttonStyle(.borderless)
                    Button(role: .destructive) { vm.removeOverlay(overlay) } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
                .font(.subheadline)
            }
            Button {
                editingOverlay = TextOverlay(string: "")
            } label: { Label("Add text", systemImage: "plus") }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("addTextOverlay")
        }
    }
}

/// Sheet to edit one overlay's string / position / size / color / timing.
private struct TextOverlayEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var overlay: TextOverlay
    let onSave: (TextOverlay) -> Void

    var body: some View {
        NavigationStack {
            Form {
                TextField("Text", text: $overlay.string)
                    .accessibilityIdentifier("overlayText")
                Section("Size") {
                    Slider(value: $overlay.fontSize, in: 16...120)
                    Text("\(Int(overlay.fontSize)) pt").font(.caption).foregroundStyle(.secondary)
                }
                Section("Position") {
                    LabeledContent("Horizontal") {
                        Slider(value: $overlay.normalizedPosition.x, in: 0...1)
                    }
                    LabeledContent("Vertical") {
                        Slider(value: $overlay.normalizedPosition.y, in: 0...1)
                    }
                }
                Section("Color") {
                    Picker("Color", selection: $overlay.colorHex) {
                        Text("White").tag("#FFFFFF")
                        Text("Black").tag("#000000")
                        Text("Yellow").tag("#FFD60A")
                        Text("Red").tag("#FF3B30")
                    }
                }
            }
            .navigationTitle("Text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(overlay); dismiss() }
                        .accessibilityIdentifier("saveOverlay")
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Audio

private struct AudioControls: View {
    @Bindable var vm: ClipEditorViewModel

    var body: some View {
        ControlCard(title: "Audio", systemImage: "speaker.wave.2") {
            Toggle("Mute original audio", isOn: Binding(
                get: { vm.edit.mutedOriginalAudio },
                set: { vm.setMuted($0) }))
                .accessibilityIdentifier("muteAudio")
        }
    }
}

// MARK: - Shared card chrome

private struct ControlCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage).font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
