import SwiftUI
import SwiftData
import PhotosUI

// The multi-photo surfaces (wardrobe prompt 04): the detail hero's carousel, and the "Manage
// photos" sheet where reorder / re-role / set-cover / delete live.
//
// Management is deliberately NOT a long-press on the carousel — a swipe surface should only swipe.

/// The item detail hero. One photo renders exactly as it did before prompt 04: no dots, no role
/// caption, no new chrome. Chrome appears only once there is something to page through.
struct WardrobePhotoCarousel: View {
    let item: WardrobeItem
    var height: CGFloat = 240

    @Environment(\.modelContext) private var modelContext
    @Query private var allPhotos: [WardrobePhoto]
    @State private var page = 0

    private var extras: [WardrobePhoto] {
        allPhotos.filter { $0.itemID == item.id }
            .sorted { ($0.sortIndex, $0.createdAt) < ($1.sortIndex, $1.createdAt) }
    }

    private var showsChrome: Bool {
        WardrobePhotoSet.showsPagerChrome(photoCount: (item.imageData == nil ? 0 : 1) + extras.count)
    }

    var body: some View {
        Group {
            if showsChrome {
                TabView(selection: $page) {
                    WardrobeItemHeroImage(item: item, height: height)
                        .tag(0)
                    ForEach(Array(extras.enumerated()), id: \.element.id) { index, photo in
                        WardrobePhotoImage(photo: photo, height: height)
                            .tag(index + 1)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: height)
                .overlay(alignment: .bottomLeading) { roleCaption }
                .overlay(alignment: .bottom) { dots }
                .accessibilityIdentifier("wardrobe.item.carousel")
            } else {
                WardrobeItemHeroImage(item: item, height: height)
            }
        }
    }

    private var currentRole: GarmentPhotoRole {
        page == 0 ? item.coverPhotoRole
                  : (extras.indices.contains(page - 1) ? extras[page - 1].role : .detail)
    }

    private var roleCaption: some View {
        Text(currentRole.title.uppercased())
            .font(.system(size: 9, weight: .heavy))
            .foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.black.opacity(0.7), in: Capsule())
            .padding(10)
    }

    private var dots: some View {
        HStack(spacing: 5) {
            ForEach(0..<(extras.count + 1), id: \.self) { index in
                Capsule()
                    .fill(index == page ? SnappetColor.wardrobe : SnappetColor.hairline)
                    .frame(width: index == page ? 16 : 6, height: 6)
            }
        }
        .padding(.bottom, 8)
    }
}

/// One extra photo, decoded through the shared prompt-03 cache. Mirrors `WardrobeItemTile`:
/// prefer the thumbnail, fall back to the master, never `UIImage(data:)` on a full-size blob.
struct WardrobePhotoImage: View {
    let photo: WardrobePhoto
    var height: CGFloat = 240

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit().padding(6)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .task(id: "\(photo.id.uuidString)#\(photo.thumbnailData?.count ?? -1)#\(Int(height))") {
            image = nil
            // Big renders read the master; tiles read the thumbnail. Same rule as the cover:
            // the externalStorage touch happens HERE, never in the task's identity.
            if height > 120, let master = photo.imageData, !master.isEmpty {
                image = await WardrobeImageCache.image(itemID: photo.id, slot: .hero,
                                                       data: master, pointHeight: height)
                return
            }
            guard let thumb = photo.thumbnailData, !thumb.isEmpty else {
                if let master = photo.imageData, !master.isEmpty {
                    image = await WardrobeImageCache.image(itemID: photo.id, slot: .hero,
                                                           data: master, pointHeight: height)
                }
                return
            }
            image = await WardrobeImageCache.image(itemID: photo.id, slot: .thumbnail,
                                                   data: thumb, pointHeight: height)
        }
    }
}

/// Reorder, re-role, set cover, delete — and add more.
struct WardrobePhotosView: View {
    let item: WardrobeItem

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var allPhotos: [WardrobePhoto]

    @State private var selected: WardrobePhotoSet.Entry?
    @State private var photoSelection: PhotosPickerItem?
    @State private var showCamera = false
    @State private var showAdd = false
    @State private var addRole: GarmentPhotoRole = .back
    @State private var pendingCamera = false
    @State private var capMessage: String?
    @State private var isBusy = false

    private var extras: [WardrobePhoto] {
        allPhotos.filter { $0.itemID == item.id }
            .sorted { ($0.sortIndex, $0.createdAt) < ($1.sortIndex, $1.createdAt) }
    }

    private var entries: [WardrobePhotoSet.Entry] {
        WardrobePhotoSet.ordered(coverRole: item.imageData == nil ? nil : item.coverPhotoRole,
                                 extras: extras.map { ($0.id, $0.role) })
    }

    private let columns = [GridItem(.flexible(), spacing: 9),
                           GridItem(.flexible(), spacing: 9),
                           GridItem(.flexible())]

    var body: some View {
        NavigationStack {
            ScrollView {
                Text("\(entries.count) of \(WardrobePhotoSet.maxPhotos)")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(SnappetColor.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.top, 8)

                LazyVGrid(columns: columns, spacing: 9) {
                    ForEach(entries) { entry in
                        cell(entry)
                    }
                    if WardrobePhotoSet.canAdd(currentCount: entries.count) {
                        Button {
                            addRole = WardrobePhotoSet.nextUnusedRole(used: entries.map(\.role))
                            showAdd = true
                        } label: {
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .strokeBorder(SnappetColor.hairline,
                                              style: StrokeStyle(lineWidth: 1.5, dash: [4]))
                                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                                .overlay(Image(systemName: "plus")
                                    .font(.system(size: 22, weight: .medium))
                                    .foregroundStyle(SnappetColor.wardrobe))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("wardrobe.photos.add")
                    }
                }
                .padding(.horizontal, 16)

                Text("The cover is what the closet grid, outfit boards and the For You carousel show.")
                    .font(.caption2)
                    .foregroundStyle(SnappetColor.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.top, 10)
            }
            .background(SnappetColor.paper)
            .navigationTitle("Photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .overlay { if isBusy { ProgressView().controlSize(.large) } }
        }
        .sheet(item: $selected) { entry in
            photoActions(entry)
        }
        .sheet(isPresented: $showAdd, onDismiss: {
            // Stash-and-promote: dismissing this sheet and presenting the camera in one state
            // mutation makes SwiftUI drop the camera (the festival prompt 05/06 race).
            if pendingCamera { pendingCamera = false; showCamera = true }
        }) {
            addSheet
        }
        .fullScreenCover(isPresented: $showCamera) {
            WardrobePhotoCameraPicker { image in
                showCamera = false
                if let image { Task { await add(image, role: addRole) } }
            }
            .ignoresSafeArea()
        }
        .onChange(of: photoSelection) { _, selection in
            guard let selection else { return }
            Task {
                if let data = try? await selection.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    showAdd = false
                    await add(image, role: addRole)
                }
                photoSelection = nil
            }
        }
        .alert("Photo limit reached", isPresented: .constant(capMessage != nil)) {
            Button("OK") { capMessage = nil }
        } message: { Text(capMessage ?? "") }
    }

    // MARK: - Pieces

    private func cell(_ entry: WardrobePhotoSet.Entry) -> some View {
        Button { selected = entry } label: {
            Group {
                if entry.isCover {
                    WardrobeItemTile(item: item, height: 108)
                } else if let photo = extras.first(where: { $0.id == entry.id }) {
                    WardrobePhotoImage(photo: photo, height: 108)
                }
            }
            .overlay(alignment: .bottom) {
                Text(entry.role.title.uppercased())
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.72))
            }
            .overlay(alignment: .topLeading) {
                if entry.isCover {
                    Text("COVER")
                        .font(.system(size: 7, weight: .black))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(SnappetColor.wardrobe, in: RoundedRectangle(cornerRadius: 5))
                        .padding(5)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(entry.isCover ? SnappetColor.wardrobe : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("wardrobe.photos.cell")
    }

    private func photoActions(_ entry: WardrobePhotoSet.Entry) -> some View {
        NavigationStack {
            Form {
                Section("What this photo shows") {
                    Picker("Role", selection: roleBinding(entry)) {
                        ForEach(GarmentPhotoRole.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                if !entry.isCover, let photo = extras.first(where: { $0.id == entry.id }) {
                    Section {
                        Button {
                            WardrobePhotoStore.makeCover(photo, of: item, in: modelContext)
                            selected = nil
                        } label: { Label("Make cover photo", systemImage: "star") }
                            .accessibilityIdentifier("wardrobe.photos.makeCover")
                    }
                }
                Section {
                    Button(role: .destructive) {
                        WardrobePhotoStore.delete(entry, from: item, in: modelContext)
                        selected = nil
                    } label: { Label("Delete photo", systemImage: "trash") }
                        .accessibilityIdentifier("wardrobe.photos.delete")
                }
            }
            .navigationTitle(entry.role.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { selected = nil }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func roleBinding(_ entry: WardrobePhotoSet.Entry) -> Binding<GarmentPhotoRole> {
        Binding(
            get: { entry.role },
            set: { role in
                if entry.isCover {
                    item.coverPhotoRole = role
                    try? modelContext.save()
                } else if let photo = extras.first(where: { $0.id == entry.id }) {
                    WardrobePhotoStore.setRole(role, on: photo, in: modelContext)
                }
                selected = nil
            })
    }

    private var addSheet: some View {
        NavigationStack {
            Form {
                Section("What does this photo show?") {
                    Picker("Role", selection: $addRole) {
                        ForEach(GarmentPhotoRole.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text(addRole.hint).font(.caption).foregroundStyle(SnappetColor.textSecondary)
                }
                Section {
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button {
                            pendingCamera = true
                            showAdd = false
                        } label: { Label("Take photo", systemImage: "camera.fill") }
                    }
                    PhotosPicker(selection: $photoSelection, matching: .images) {
                        Label("Import from Photos", systemImage: "photo.on.rectangle")
                    }
                }
            }
            .navigationTitle("Add a photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showAdd = false } }
            }
        }
        .presentationDetents([.medium])
    }

    private func add(_ image: UIImage, role: GarmentPhotoRole) async {
        isBusy = true
        defer { isBusy = false }
        let lifted = role.shouldLiftSubject ? await WardrobeVision.liftSubject(from: image) : nil
        let ok = await WardrobePhotoStore.addExtra(lifted ?? image, role: role,
                                                   isCutout: lifted != nil,
                                                   to: item, in: modelContext)
        if !ok {
            capMessage = WardrobePhotoSet.addRefusalReason(
                currentCount: WardrobePhotoStore.photoCount(for: item, in: modelContext))
        }
    }
}

/// Thin camera edge for the manage sheet (the capture sheet keeps its own private one).
struct WardrobePhotoCameraPicker: UIViewControllerRepresentable {
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
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onComplete(nil) }
    }
}
