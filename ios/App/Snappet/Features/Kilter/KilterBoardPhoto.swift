import SwiftUI
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Your own photo of your board, behind the hold shapes (prompt 215, option 1 — the user's pick; Aurora's board
/// images stay out, see decisions 2026-06). You photograph the wall once and tap its four corner holds; the photo
/// is straightened so those corners land on the board drawing's corners (the hole area `KilterBoardGeometry`
/// normalizes to 0…1), plus a small margin so edge holds aren't cropped. Stored on this device per layout + size,
/// preferring the board you're connected to.

// MARK: - Pure geometry

enum KilterBoardPhotoMath {
    /// Extra photo kept around the corner holds, as a fraction of the hole area on each side.
    static let margin = 0.06

    /// Bilinear point inside the quad (TL, TR, BR, BL) at (u, v); u, v outside 0…1 extrapolate.
    static func point(_ q: [CGPoint], u: Double, v: Double) -> CGPoint {
        let top = CGPoint(x: q[0].x + (q[1].x - q[0].x) * u, y: q[0].y + (q[1].y - q[0].y) * u)
        let bottom = CGPoint(x: q[3].x + (q[2].x - q[3].x) * u, y: q[3].y + (q[2].y - q[3].y) * u)
        return CGPoint(x: top.x + (bottom.x - top.x) * v, y: top.y + (bottom.y - top.y) * v)
    }

    /// The tapped corner quad grown by `margin` on every side (TL, TR, BR, BL).
    static func extended(_ q: [CGPoint], margin m: Double = margin) -> [CGPoint] {
        [point(q, u: -m, v: -m), point(q, u: 1 + m, v: -m), point(q, u: 1 + m, v: 1 + m), point(q, u: -m, v: 1 + m)]
    }

    /// Where the straightened photo goes in the board view: the hole-area rect grown by the same margin.
    static func photoRect(holeArea r: CGRect, margin m: Double = margin) -> CGRect {
        r.insetBy(dx: -r.width * m, dy: -r.height * m)
    }

    /// Output pixel size for a board of `aspect` (width / height), margin included (same aspect).
    static func outputSize(aspect: Double, longSide: Double = 1600) -> CGSize {
        let a = aspect > 0 ? aspect : 1
        return a >= 1 ? CGSize(width: longSide, height: (longSide / a).rounded())
                      : CGSize(width: (longSide * a).rounded(), height: longSide)
    }

    /// Starting markers for a fresh photo: a centred rectangle at 15–85 %, in normalized image coords.
    static let defaultCorners: [CGPoint] = [CGPoint(x: 0.15, y: 0.15), CGPoint(x: 0.85, y: 0.15),
                                            CGPoint(x: 0.85, y: 0.85), CGPoint(x: 0.15, y: 0.85)]
}

// MARK: - Which photo to show

struct KilterBoardPhotoEntry: Codable, Equatable, Sendable {
    var file: String
    var boardID: UUID?
    var layoutId: Int
    var sizeId: Int
    var savedAt: Date

    /// Two entries are the same slot when board + layout + size match (a re-take replaces it).
    func sameSlot(_ o: KilterBoardPhotoEntry) -> Bool {
        boardID == o.boardID && layoutId == o.layoutId && sizeId == o.sizeId
    }
}

enum KilterBoardPhotoPick {
    /// The photo for a layout + size: the given board's own photo first, else the newest one for that
    /// layout + size (any board — e.g. browsing at home with nothing connected).
    static func best(_ entries: [KilterBoardPhotoEntry], layoutId: Int, sizeId: Int, boardID: UUID?) -> KilterBoardPhotoEntry? {
        let fits = entries.filter { $0.layoutId == layoutId && $0.sizeId == sizeId }
        if let boardID, let own = fits.filter({ $0.boardID == boardID }).max(by: { $0.savedAt < $1.savedAt }) {
            return own
        }
        return fits.max { $0.savedAt < $1.savedAt }
    }
}

// MARK: - Store (index in UserDefaults, JPEGs in Application Support)

@MainActor @Observable
final class KilterBoardPhotoStore {
    /// UI-test launches use a scratch index + folder, emptied each launch, so a test run on a real phone never
    /// touches the user's board photos (the prompt-133 rule).
    static let shared: KilterBoardPhotoStore = {
        guard CommandLine.arguments.contains("-uiTestFreshStore"),
              let scratch = UserDefaults(suiteName: "snappet.uitest.boardPhotos") else { return KilterBoardPhotoStore() }
        scratch.removePersistentDomain(forName: "snappet.uitest.boardPhotos")
        try? FileManager.default.removeItem(at: folderURL(scratch: true))
        return KilterBoardPhotoStore(defaults: scratch, scratch: true)
    }()
    static let defaultsKey = "kilter.boardPhotos"

    private(set) var entries: [KilterBoardPhotoEntry] = []
    @ObservationIgnored private var cache: [String: UIImage] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let folder: URL

    init(defaults: UserDefaults = .standard, scratch: Bool = false) {
        self.defaults = defaults
        self.folder = Self.folderURL(scratch: scratch)
        if let data = defaults.data(forKey: Self.defaultsKey),
           let list = try? JSONDecoder().decode([KilterBoardPhotoEntry].self, from: data) {
            entries = list
        }
    }

    private static func folderURL(scratch: Bool) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent(scratch ? "KilterBoardPhotos-uitest" : "KilterBoardPhotos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func entry(layoutId: Int, sizeId: Int, boardID: UUID?) -> KilterBoardPhotoEntry? {
        KilterBoardPhotoPick.best(entries, layoutId: layoutId, sizeId: sizeId, boardID: boardID)
    }

    func image(layoutId: Int, sizeId: Int, boardID: UUID?) -> UIImage? {
        entry(layoutId: layoutId, sizeId: sizeId, boardID: boardID).flatMap(image(for:))
    }

    func image(for e: KilterBoardPhotoEntry) -> UIImage? {
        if let hit = cache[e.file] { return hit }
        guard let img = UIImage(contentsOfFile: folder.appendingPathComponent(e.file).path) else { return nil }
        cache[e.file] = img
        return img
    }

    func save(_ image: UIImage, layoutId: Int, sizeId: Int, boardID: UUID?) {
        guard let data = image.jpegData(compressionQuality: 0.85) else { return }
        let entry = KilterBoardPhotoEntry(file: "\(UUID().uuidString).jpg", boardID: boardID,
                                          layoutId: layoutId, sizeId: sizeId, savedAt: .now)
        do { try data.write(to: folder.appendingPathComponent(entry.file), options: .atomic) } catch { return }
        for old in entries where old.sameSlot(entry) { deleteFile(old) }
        entries.removeAll { $0.sameSlot(entry) }
        entries.append(entry)
        cache[entry.file] = image
        persist()
    }

    func remove(_ e: KilterBoardPhotoEntry) {
        deleteFile(e)
        entries.removeAll { $0 == e }
        persist()
    }

    private func deleteFile(_ e: KilterBoardPhotoEntry) {
        cache[e.file] = nil
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(e.file))
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(entries), forKey: Self.defaultsKey)
    }
}

// MARK: - Straighten

enum KilterBoardPhotoRectifier {
    /// Straighten `image` so the tapped corners (normalized 0…1 in the upright image, TL TR BR BL) become the
    /// hole-area corners, with `KilterBoardPhotoMath.margin` kept around them, at the board's aspect.
    static func rectify(_ image: UIImage, corners: [CGPoint], aspect: Double) -> UIImage? {
        let upright = uprighted(image)
        guard let cg = upright.cgImage, corners.count == 4 else { return nil }
        let w = Double(cg.width), h = Double(cg.height)
        let px = KilterBoardPhotoMath.extended(corners.map { CGPoint(x: $0.x * w, y: $0.y * h) })
        // Core Image's origin is bottom-left.
        func ci(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: h - p.y) }
        let f = CIFilter.perspectiveCorrection()
        f.inputImage = CIImage(cgImage: cg)
        f.topLeft = ci(px[0]); f.topRight = ci(px[1]); f.bottomRight = ci(px[2]); f.bottomLeft = ci(px[3])
        guard let out = f.outputImage,
              let flat = CIContext().createCGImage(out, from: out.extent) else { return nil }
        let size = KilterBoardPhotoMath.outputSize(aspect: aspect)
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
        return UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            UIImage(cgImage: flat).draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// Bake EXIF orientation into the pixels so normalized taps match the pixel grid.
    static func uprighted(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = image.scale
        return UIGraphicsImageRenderer(size: image.size, format: fmt).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }
}
