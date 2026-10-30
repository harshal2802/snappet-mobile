import SwiftUI
import PhotosUI

/// "Add a photo of this board" (prompt 215, mockup `docs/ux-research/design-system/kilter-climb.html`):
/// 1 take / choose a photo → 2 drag the four markers onto the corner holds → 3 check the line-up → Save.
struct KilterBoardPhotoSheet: View {
    let layoutId: Int
    let sizeId: Int
    let boardID: UUID?
    let boardName: String
    let geometry: KilterBoardGeometry
    /// A climb to draw on the preview (the open climb), if any — the grid always shows.
    var sampleHolds: [KilterHold] = []

    @Environment(\.dismiss) private var dismiss
    private var store: KilterBoardPhotoStore { .shared }

    private enum Step { case source, corners(UIImage), preview(UIImage, corners: [CGPoint], straight: UIImage) }
    @State private var step: Step = .source
    @State private var corners = KilterBoardPhotoMath.defaultCorners
    @State private var showingCamera = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var working = false

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .source: sourceStep
                case .corners(let img): cornersStep(img)
                case .preview(let img, let c, let straight): previewStep(img, corners: c, straight: straight)
                }
            }
            .padding()
            .frame(maxHeight: .infinity, alignment: .top)
            .background(SnappetColor.paper)
            .navigationTitle("Board photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .fullScreenCover(isPresented: $showingCamera) {
            WardrobePhotoCameraPicker { img in
                showingCamera = false
                if let img { start(img) }
            }
            .ignoresSafeArea()
        }
        .onChange(of: pickerItem) {
            guard let item = pickerItem else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                    start(img)
                }
                pickerItem = nil
            }
        }
    }

    private func start(_ img: UIImage) {
        corners = KilterBoardPhotoMath.defaultCorners
        step = .corners(KilterBoardPhotoRectifier.uprighted(img))
    }

    // MARK: Step 1

    private var sourceStep: some View {
        let current = store.entry(layoutId: layoutId, sizeId: sizeId, boardID: boardID)
        return VStack(alignment: .leading, spacing: 14) {
            Text("Show \(boardName) as your real wall").snappetTitle()
            Text("Take one straight-on photo of the whole board, then line up its four corner holds. It stays on this phone.")
                .snappetDetail()
            if let current, let img = store.image(for: current) {
                KilterBoardView(geometry: geometry, holds: sampleHolds, photo: img)
                    .frame(maxHeight: 260)
                Button(role: .destructive) { store.remove(current); dismiss() } label: {
                    Label("Remove photo", systemImage: "trash").font(SnappetType.detail)
                }
                .accessibilityIdentifier("kilter.boardPhoto.remove")
            }
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button { showingCamera = true } label: {
                    Label(current == nil ? "Take a photo" : "Take a new photo", systemImage: "camera")
                }
                .buttonStyle(SnappetWidePrimaryStyle())
                .accessibilityIdentifier("kilter.boardPhoto.camera")
            }
            PhotosPicker(selection: $pickerItem, matching: .images) {
                Label("Choose from Photos", systemImage: "photo.on.rectangle")
                    .font(.system(size: 15, weight: .medium)).frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .overlay(Capsule().strokeBorder(SnappetColor.hairline))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("kilter.boardPhoto.library")
        }
    }

    // MARK: Step 2

    private func cornersStep(_ img: UIImage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tap or drag the markers onto the corner holds: 1 top-left, 2 top-right, 3 bottom-right, 4 bottom-left.")
                .snappetDetail()
            KilterCornerPicker(image: img, corners: $corners)
                .frame(maxHeight: .infinity)
            Button {
                working = true
                let straight = KilterBoardPhotoRectifier.rectify(img, corners: corners, aspect: geometry.aspect)
                working = false
                if let straight { step = .preview(img, corners: corners, straight: straight) }
            } label: { Text(working ? "Straightening…" : "Next") }
                .buttonStyle(SnappetWidePrimaryStyle())
                .accessibilityIdentifier("kilter.boardPhoto.next")
        }
    }

    // MARK: Step 3

    private func previewStep(_ img: UIImage, corners c: [CGPoint], straight: UIImage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("The dots and shapes should sit on the holds. If they drift, go back and nudge a corner.")
                .snappetDetail()
            KilterBoardView(geometry: geometry, holds: sampleHolds, photo: straight, showsGridOverPhoto: true)
                .frame(maxHeight: .infinity)
            HStack(spacing: 10) {
                Button { corners = c; step = .corners(img) } label: {
                    Text("Adjust corners").font(.system(size: 15, weight: .medium)).frame(maxWidth: .infinity)
                        .kilterPill(selected: false, large: true)
                }
                .buttonStyle(.plain)
                Button("Save photo") {
                    store.save(straight, layoutId: layoutId, sizeId: sizeId, boardID: boardID)
                    Haptics.success()
                    dismiss()
                }
                .buttonStyle(SnappetWidePrimaryStyle())
                .accessibilityIdentifier("kilter.boardPhoto.save")
            }
        }
    }
}

/// The photo with four numbered, draggable corner markers (normalized image coords, TL TR BR BL). A tap moves
/// the nearest marker there; a drag moves the marker under the finger.
struct KilterCornerPicker: View {
    let image: UIImage
    @Binding var corners: [CGPoint]
    @State private var dragging: Int?

    var body: some View {
        GeometryReader { geo in
            let rect = fitted(image.size, in: geo.size)
            ZStack(alignment: .topLeading) {
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                Path { p in
                    let pts = corners.map { view($0, rect) }
                    p.addLines(pts); p.closeSubpath()
                }
                .stroke(SnappetColor.brand, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                ForEach(0..<4, id: \.self) { i in
                    Text("\(i + 1)")
                        .font(.system(size: 13, weight: .bold)).foregroundStyle(SnappetColor.onBrand)
                        .frame(width: 26, height: 26)
                        .background(SnappetColor.brand, in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1.5))
                        .position(view(corners[i], rect))
                        .accessibilityIdentifier("kilter.boardPhoto.corner\(i + 1)")
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let n = norm(g.location, rect)
                    let i = dragging ?? nearest(to: n)
                    dragging = i
                    corners[i] = n
                }
                .onEnded { _ in dragging = nil })
        }
    }

    private func nearest(to n: CGPoint) -> Int {
        corners.indices.min { hypot(corners[$0].x - n.x, corners[$0].y - n.y) < hypot(corners[$1].x - n.x, corners[$1].y - n.y) } ?? 0
    }
    private func view(_ n: CGPoint, _ r: CGRect) -> CGPoint { CGPoint(x: r.minX + n.x * r.width, y: r.minY + n.y * r.height) }
    private func norm(_ p: CGPoint, _ r: CGRect) -> CGPoint {
        CGPoint(x: min(1, max(0, (p.x - r.minX) / r.width)), y: min(1, max(0, (p.y - r.minY) / r.height)))
    }
    private func fitted(_ s: CGSize, in box: CGSize) -> CGRect {
        let k = min(box.width / max(s.width, 1), box.height / max(s.height, 1))
        let w = s.width * k, h = s.height * k
        return CGRect(x: (box.width - w) / 2, y: (box.height - h) / 2, width: w, height: h)
    }
}
