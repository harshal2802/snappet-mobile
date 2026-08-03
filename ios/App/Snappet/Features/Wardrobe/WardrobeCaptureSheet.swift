import SwiftUI
import SwiftData
import PhotosUI

/// The add-item flow: pick (camera or Photos) → subject lift → editable AI tag sheet →
/// save. One garment per pass. Everything runs on-device; the tag draft is the Vision
/// heuristic floor, optionally sharpened by Apple Intelligence (badge shows which).
///
/// **Multi-photo (wardrobe prompt 04)**: the review stage's single preview is a strip. The first
/// photo is the cover and the only one that drives tagging; up to five more can be added with a
/// role each. One photo still saves exactly as it did before — nothing on the fast path is new.
struct WardrobeCaptureSheet: View {
    private enum Stage {
        case pick
        case processing
        case review
    }

    /// Where a picker's result should go when it comes back.
    private enum PickIntent: Equatable {
        /// The first photo: run tagging, become the cover.
        case cover
        /// An extra photo with this role: subject lift per the role, no tagging.
        case extra(GarmentPhotoRole)
    }

    private enum PickSource: Equatable { case camera, photos }

    /// One photo held in the sheet before anything is persisted.
    private struct DraftPhoto: Identifiable {
        let id = UUID()
        var role: GarmentPhotoRole
        var original: UIImage
        var cutout: UIImage?
        var useCutout: Bool
        /// What actually gets encoded on save.
        var chosen: UIImage { (useCutout ? cutout : nil) ?? original }
        var isCutout: Bool { useCutout && cutout != nil }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(SnappetCore.self) private var core

    @State private var stage: Stage = .pick
    @State private var photoSelection: PhotosPickerItem?
    @State private var showCamera = false
    @State private var photos: [DraftPhoto] = []
    @State private var draft = WardrobeVision.DraftTags()
    @State private var costText = ""
    @State private var isSaving = false

    // Add-photo flow.
    @State private var showAddPhoto = false
    @State private var addRole: GarmentPhotoRole = .back
    @State private var intent: PickIntent = .cover
    /// Stashed while the add sheet is closing — see `onDismiss` below.
    @State private var pendingSource: PickSource?
    @State private var capMessage: String?

    private var cover: DraftPhoto? { photos.first }

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
                    await accept(image)
                }
                photoSelection = nil    // so re-picking the same asset fires again
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            WardrobeCameraPicker { image in
                showCamera = false
                if let image { Task { await accept(image) } }
            }
            .ignoresSafeArea()
        }
        // Presenting the camera/Photos picker straight from the add sheet's button would dismiss
        // one presentation and request another in a SINGLE state mutation — SwiftUI drops the
        // second, and the picker never appears (the same race that bit festival prompts 05 and 06).
        // Stash the choice, promote it here once the sheet has actually gone.
        .sheet(isPresented: $showAddPhoto, onDismiss: promotePendingSource) {
            addPhotoSheet
        }
        .alert("Photo limit reached", isPresented: .constant(capMessage != nil)) {
            Button("OK") { capMessage = nil }
        } message: {
            Text(capMessage ?? "")
        }
    }

    private func promotePendingSource() {
        guard let source = pendingSource else { return }
        pendingSource = nil
        switch source {
        case .camera: showCamera = true
        case .photos: break   // the PhotosPicker in the sheet handles its own presentation
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
                    if let cover {
                        Image(uiImage: cover.chosen)
                            .resizable()
                            .scaledToFit()
                            .frame(height: 180)
                            .frame(maxWidth: .infinity)
                    }
                    // The cut-out toggle applies to the COVER — the roles decide it for the rest.
                    if cover?.cutout != nil {
                        Picker("Image", selection: coverUsesCutout) {
                            Text("Cut-out").tag(true)
                            Text("Original").tag(false)
                        }
                        .pickerStyle(.segmented)
                    }
                    photoStrip
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

    /// Binding onto the cover's cut-out toggle (the cover is `photos[0]`).
    private var coverUsesCutout: Binding<Bool> {
        Binding(get: { photos.first?.useCutout ?? true },
                set: { if !photos.isEmpty { photos[0].useCutout = $0 } })
    }

    /// Cover · extras · "+". The whole multi-photo affordance, in one row.
    private var photoStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                    slot(photo, isCover: index == 0)
                }
                if WardrobePhotoSet.canAdd(currentCount: photos.count) {
                    Button {
                        addRole = WardrobePhotoSet.nextUnusedRole(used: photos.map(\.role))
                        // Set here (and kept in sync below) rather than on the picker's tap —
                        // a tap gesture on a PhotosPicker label is not reliably delivered.
                        intent = .extra(addRole)
                        showAddPhoto = true
                    } label: {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(SnappetColor.hairline, style: StrokeStyle(lineWidth: 1.5, dash: [4]))
                            .frame(width: 66, height: 80)
                            .overlay(Image(systemName: "plus")
                                .font(.system(size: 20, weight: .medium))
                                .foregroundStyle(SnappetColor.wardrobe))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("wardrobe.capture.addPhoto")
                }
            }
            .padding(.vertical, 2)
        }
        .overlay(alignment: .bottomLeading) {
            Text("\(photos.count) of \(WardrobePhotoSet.maxPhotos) photos")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(SnappetColor.textSecondary)
                .offset(y: 12)
        }
        .padding(.bottom, 12)
    }

    private func slot(_ photo: DraftPhoto, isCover: Bool) -> some View {
        Image(uiImage: photo.chosen)
            .resizable()
            .scaledToFill()
            .frame(width: 66, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .bottom) {
                Text(photo.role.title.uppercased())
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.72))
            }
            .overlay(alignment: .topLeading) {
                if isCover {
                    Text("COVER")
                        .font(.system(size: 7, weight: .black))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(SnappetColor.wardrobe, in: RoundedRectangle(cornerRadius: 4))
                        .padding(3)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contextMenu {
                if !isCover {
                    Button(role: .destructive) {
                        photos.removeAll { $0.id == photo.id }
                    } label: { Label("Remove photo", systemImage: "trash") }
                }
            }
    }

    /// Role first, source second — the role decides whether subject lift runs, so it has to be
    /// known before the picker returns.
    private var addPhotoSheet: some View {
        NavigationStack {
            Form {
                Section("What does this photo show?") {
                    Picker("Role", selection: $addRole) {
                        ForEach(GarmentPhotoRole.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: addRole) { _, role in intent = .extra(role) }
                    Text(addRole.hint)
                        .font(.caption)
                        .foregroundStyle(SnappetColor.textSecondary)
                    Label(addRole.shouldLiftSubject
                            ? "Background will be removed"
                            : "Background kept — you want the whole shot",
                          systemImage: addRole.shouldLiftSubject ? "scissors" : "photo")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(SnappetColor.wardrobe)
                }
                Section {
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button {
                            intent = .extra(addRole)
                            pendingSource = .camera      // promoted in the sheet's onDismiss
                            showAddPhoto = false
                        } label: {
                            Label("Take photo", systemImage: "camera.fill")
                        }
                        .accessibilityIdentifier("wardrobe.capture.add.camera")
                    }
                    // A PhotosPicker presents OVER this sheet, so it needs no dismiss dance.
                    PhotosPicker(selection: $photoSelection, matching: .images) {
                        Label("Import from Photos", systemImage: "photo.on.rectangle")
                    }
                    .accessibilityIdentifier("wardrobe.capture.add.photos")
                }
            }
            .navigationTitle("Add a photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showAddPhoto = false }
                }
            }
        }
        .presentationDetents([.medium])
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

    /// Route a freshly picked image by the current `intent`.
    private func accept(_ image: UIImage) async {
        switch intent {
        case .cover: await processCover(image)
        case .extra(let role): await appendExtra(image, role: role)
        }
    }

    /// The first photo: subject lift + the full tagging pass. This is the only photo that drives
    /// the garment's tags.
    private func processCover(_ image: UIImage) async {
        stage = .processing
        let lifted = await WardrobeVision.liftSubject(from: image)
        var tags = await WardrobeVision.draftTags(for: lifted ?? image)
        let labels = await WardrobeVision.classify(image)
        tags = await WardrobeIntelligence.sharpenTags(tags, labels: labels)
        photos = [DraftPhoto(role: .front, original: image, cutout: lifted,
                             useCutout: lifted != nil)]
        draft = tags
        stage = .review
    }

    /// An extra photo. Subject lift runs only when the ROLE calls for it, and **tagging does not
    /// re-run**: the tags came from the cover, and a worn shot would drag the dominant-color
    /// average toward skin and background.
    private func appendExtra(_ image: UIImage, role: GarmentPhotoRole) async {
        showAddPhoto = false
        guard WardrobePhotoSet.canAdd(currentCount: photos.count) else {
            capMessage = WardrobePhotoSet.addRefusalReason(currentCount: photos.count)
            intent = .cover
            return
        }
        let lifted = role.shouldLiftSubject ? await WardrobeVision.liftSubject(from: image) : nil
        photos.append(DraftPhoto(role: role, original: image, cutout: lifted,
                                 useCutout: lifted != nil))
        intent = .cover     // back to the default so a stray pick can't append silently
    }

    /// Encode through `WardrobeImageStore` so the stored master is capped at
    /// `WardrobeImagePolicy.displayMaxEdge` and a grid thumbnail is written alongside it
    /// (wardrobe prompt 03). Storing the raw cut-out here is what put 1.01 GB in a 100-item
    /// closet and made the grid decode a ~34 MB bitmap per 96pt tile.
    ///
    /// The resize/encode runs detached: a full-resolution capture takes long enough that doing
    /// it inline would freeze the sheet on the Save tap.
    private func save() async {
        // The cover rides the item itself (wardrobe prompt 04) — that's what keeps the closet
        // grid a single-table read and what let multi-photo ship without a migration.
        var prepared: WardrobeImageStore.Prepared?
        if let cover {
            let image = cover.chosen, isCutout = cover.isCutout
            prepared = await Task.detached(priority: .userInitiated) {
                WardrobeImageStore.prepare(image: image, isCutout: isCutout)
            }.value
        }

        let item = WardrobeItem(
            name: draft.suggestedName.isEmpty ? "\(draft.color.title) \(draft.category.title.lowercased())" : draft.suggestedName,
            category: draft.category, color: draft.color, pattern: draft.pattern,
            style: draft.style, material: draft.material, seasons: draft.seasons,
            cost: Double(costText.replacingOccurrences(of: ",", with: ".")),
            imageData: prepared?.display,
            thumbnailData: prepared?.thumbnail)
        item.coverPhotoRole = cover?.role ?? .front
        modelContext.insert(item)
        try? modelContext.save()

        // Extras become rows, encoded through the same pipeline.
        for extra in photos.dropFirst() {
            await WardrobePhotoStore.addExtra(extra.chosen, role: extra.role,
                                              isCutout: extra.isCutout,
                                              to: item, in: modelContext)
        }

        let photoNote = photos.count > 1 ? " (\(photos.count) photos)" : ""
        core.log(module: "wardrobe", action: "add",
                 summary: "Added \(item.name) to closet\(photoNote)")
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
