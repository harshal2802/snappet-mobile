import SwiftUI
import SwiftData
import PhotosUI

/// The add-item flow: pick (camera or Photos) → subject lift → editable AI tag sheet →
/// save. One garment per pass. Everything runs on-device; the tag draft is the Vision
/// heuristic floor, optionally sharpened by Apple Intelligence (badge shows which).
struct WardrobeCaptureSheet: View {
    private enum Stage {
        case pick
        case processing
        case review
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(SnappetCore.self) private var core

    @State private var stage: Stage = .pick
    @State private var photoSelection: PhotosPickerItem?
    @State private var showCamera = false
    @State private var original: UIImage?
    @State private var cutout: UIImage?
    @State private var useCutout = true
    @State private var draft = WardrobeVision.DraftTags()
    @State private var costText = ""
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Group {
                switch stage {
                case .pick: pickStage
                case .processing: processingStage
                case .review: reviewStage
                }
            }
            .navigationTitle("Add to closet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .background(SnappetColor.paper)
        }
        .onChange(of: photoSelection) { _, selection in
            guard let selection else { return }
            Task {
                if let data = try? await selection.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    await process(image)
                }
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            WardrobeCameraPicker { image in
                showCamera = false
                if let image { Task { await process(image) } }
            }
            .ignoresSafeArea()
        }
    }

    // MARK: - Stages

    private var pickStage: some View {
        VStack(spacing: 16) {
            Spacer()
            Text("🧺").font(.system(size: 56))
            Text("One piece per photo")
                .font(.title3.weight(.bold))
            Text("Lay the item flat and fill the frame — the background is removed automatically.")
                .font(.subheadline)
                .foregroundStyle(SnappetColor.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
            Spacer()
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button {
                    showCamera = true
                } label: {
                    Label("Take photo", systemImage: "camera.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(SnappetColor.brand)
                .accessibilityIdentifier("wardrobe.capture.camera")
            }
            PhotosPicker(selection: $photoSelection, matching: .images) {
                Label("Import from Photos", systemImage: "photo.on.rectangle")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.bordered)
            .tint(SnappetColor.wardrobe)
            .accessibilityIdentifier("wardrobe.capture.photos")
            Label("On-device — the photo never leaves this iPhone", systemImage: "lock.fill")
                .font(.caption2)
                .foregroundStyle(SnappetColor.textSecondary)
                .padding(.bottom, 8)
        }
        .padding(20)
    }

    private var processingStage: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("Cutting out & tagging…")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(SnappetColor.textSecondary)
            Label("Vision + Apple Intelligence · on-device", systemImage: "sparkles")
                .font(.caption2)
                .foregroundStyle(SnappetColor.wardrobe)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var reviewStage: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    if let shown = (useCutout ? cutout : original) ?? original {
                        Image(uiImage: shown)
                            .resizable()
                            .scaledToFit()
                            .frame(height: 180)
                            .frame(maxWidth: .infinity)
                    }
                    if cutout != nil {
                        Picker("Image", selection: $useCutout) {
                            Text("Cut-out").tag(true)
                            Text("Original").tag(false)
                        }
                        .pickerStyle(.segmented)
                    }
                    Label(draft.sharpenedByAI ? "Tagged on-device · Apple Intelligence"
                                              : "Tagged on-device",
                          systemImage: "sparkles")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(SnappetColor.wardrobe)
                }
                .listRowBackground(Color.clear)
            }
            Section("Details") {
                TextField("Name", text: $draft.suggestedName)
                    .accessibilityIdentifier("wardrobe.capture.name")
                Picker("Category", selection: $draft.category) {
                    ForEach(GarmentCategory.allCases) { Text($0.title).tag($0) }
                }
                Picker("Color", selection: $draft.color) {
                    ForEach(GarmentColorFamily.allCases) { Text($0.title).tag($0) }
                }
                Picker("Pattern", selection: $draft.pattern) {
                    ForEach(GarmentPattern.allCases) { Text($0.title).tag($0) }
                }
                Picker("Style", selection: $draft.style) {
                    ForEach(GarmentStyle.allCases) { Text($0.title).tag($0) }
                }
                TextField("Material (optional)", text: $draft.material)
                TextField("Cost (optional)", text: $costText)
                    .keyboardType(.decimalPad)
            }
            Section("Seasons — leave empty for all-season") {
                seasonToggles
            }
            Section {
                Button {
                    guard !isSaving else { return }
                    isSaving = true
                    Task { await save() }
                } label: {
                    Text(isSaving ? "Saving…" : "Save to closet")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(SnappetColor.brand)
                .disabled(isSaving)     // the encode is async now — a double tap would add twice
                .listRowBackground(Color.clear)
                .accessibilityIdentifier("wardrobe.capture.save")
            }
        }
    }

    private var seasonToggles: some View {
        HStack {
            ForEach(GarmentSeason.allCases) { season in
                let on = draft.seasons.contains(season)
                Button {
                    if on { draft.seasons.remove(season) } else { draft.seasons.insert(season) }
                } label: {
                    Text(season.title)
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(on ? SnappetColor.wardrobe : SnappetColor.surfaceMuted, in: Capsule())
                        .foregroundStyle(on ? .white : SnappetColor.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Pipeline

    private func process(_ image: UIImage) async {
        stage = .processing
        let lifted = await WardrobeVision.liftSubject(from: image)
        var tags = await WardrobeVision.draftTags(for: lifted ?? image)
        let labels = await WardrobeVision.classify(image)
        tags = await WardrobeIntelligence.sharpenTags(tags, labels: labels)
        original = image
        cutout = lifted
        useCutout = lifted != nil
        draft = tags
        stage = .review
    }

    /// Encode through `WardrobeImageStore` so the stored master is capped at
    /// `WardrobeImagePolicy.displayMaxEdge` and a grid thumbnail is written alongside it
    /// (wardrobe prompt 03). Storing the raw cut-out here is what put 1.01 GB in a 100-item
    /// closet and made the grid decode a ~34 MB bitmap per 96pt tile.
    ///
    /// The resize/encode runs detached: a full-resolution capture takes long enough that doing
    /// it inline would freeze the sheet on the Save tap.
    private func save() async {
        let usingCutout = useCutout && cutout != nil
        // `process()` always sets `original`, so this is normally non-nil; a nil source still
        // saves the item (photo-less, category-emoji tile) rather than silently doing nothing.
        var prepared: WardrobeImageStore.Prepared?
        if let source = usingCutout ? cutout : original {
            prepared = await Task.detached(priority: .userInitiated) {
                WardrobeImageStore.prepare(image: source, isCutout: usingCutout)
            }.value
        }

        let item = WardrobeItem(
            name: draft.suggestedName.isEmpty ? "\(draft.color.title) \(draft.category.title.lowercased())" : draft.suggestedName,
            category: draft.category, color: draft.color, pattern: draft.pattern,
            style: draft.style, material: draft.material, seasons: draft.seasons,
            cost: Double(costText.replacingOccurrences(of: ",", with: ".")),
            imageData: prepared?.display,
            thumbnailData: prepared?.thumbnail)
        modelContext.insert(item)
        try? modelContext.save()
        core.log(module: "wardrobe", action: "add", summary: "Added \(item.name) to closet")
        dismiss()
    }
}

/// Thin camera edge: `UIImagePickerController` in camera mode (photo only).
private struct WardrobeCameraPicker: UIViewControllerRepresentable {
    var onComplete: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onComplete: onComplete) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onComplete: (UIImage?) -> Void
        init(onComplete: @escaping (UIImage?) -> Void) { self.onComplete = onComplete }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onComplete(info[.originalImage] as? UIImage)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onComplete(nil)
        }
    }
}
