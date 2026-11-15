import CoreGraphics

// MARK: - Each part keeps its own orientation (prompt 250, device feedback round 2 split audit) — pure
//
// Parts are recorded level with the horizon (prompt 246 device round 1), so a phone turned between parts writes parts
// with different `preferredTransform`s. The split player used to put every part on one composition track with the FIRST
// part's transform, so a later part turned the other way played sideways and squashed. Now each orientation gets its
// own track, and when there is more than one, a video composition draws each part with its own transform, fitted
// (aspect-fit, centred) into one render size. The maths is here so it's tested without video.

enum RacketVideoOrientation {
    /// The size a track shows at after its transform (width / height swap for a quarter turn).
    static func orientedSize(natural: CGSize, transform: CGAffineTransform) -> CGSize {
        let r = CGRect(origin: .zero, size: natural).applying(transform)
        return CGSize(width: abs(r.width), height: abs(r.height))
    }

    /// The transform that turns a part upright and fits it, centred, into `render`.
    static func fit(natural: CGSize, transform: CGAffineTransform, render: CGSize) -> CGAffineTransform {
        let r = CGRect(origin: .zero, size: natural).applying(transform)
        guard r.width > 0, r.height > 0 else { return transform }
        let s = min(render.width / r.width, render.height / r.height)
        let dx = (render.width - r.width * s) / 2, dy = (render.height - r.height * s) / 2
        return transform
            .concatenating(CGAffineTransform(translationX: -r.minX, y: -r.minY))
            .concatenating(CGAffineTransform(scaleX: s, y: s))
            .concatenating(CGAffineTransform(translationX: dx, y: dy))
    }

    /// Where a picture of `aspect` (width / height) sits when aspect-fitted, centred, in `box` — the letterboxed video
    /// rect the court guide frames (round 3). nil aspect ⇒ the whole box.
    static func aspectFit(aspect: CGFloat?, in box: CGSize) -> CGRect {
        guard let aspect, aspect > 0, box.width > 0, box.height > 0 else { return CGRect(origin: .zero, size: box) }
        if box.width / box.height > aspect {
            let w = box.height * aspect
            return CGRect(x: (box.width - w) / 2, y: 0, width: w, height: box.height)
        }
        let h = box.width / aspect
        return CGRect(x: 0, y: (box.height - h) / 2, width: box.width, height: h)
    }

    /// A stable key per orientation (transforms differ by float noise only in theory; rounded to be safe).
    static func key(_ t: CGAffineTransform) -> String {
        [t.a, t.b, t.c, t.d, t.tx, t.ty].map { String(Int(($0 * 1000).rounded())) }.joined(separator: ",")
    }

    struct Placed: Equatable {
        var start: Double
        var duration: Double
        var key: String
    }

    struct Span: Equatable {
        var start: Double
        var end: Double
        /// The orientation drawn in this span; nil ⇒ a gap (black).
        var key: String?
    }

    /// Contiguous spans covering 0…`total` (a video composition's instructions must cover the whole timeline): each
    /// part's own span, gaps between them empty.
    static func spans(_ parts: [Placed], total: Double) -> [Span] {
        var out: [Span] = []
        var cursor = 0.0
        for p in parts.sorted(by: { $0.start < $1.start }) {
            let s = max(cursor, p.start), e = min(total, p.start + p.duration)
            guard e > s else { continue }
            if s > cursor { out.append(.init(start: cursor, end: s, key: nil)) }
            out.append(.init(start: s, end: e, key: p.key))
            cursor = e
        }
        if total > cursor { out.append(.init(start: cursor, end: total, key: nil)) }
        return out
    }
}

// MARK: - Turning a recording by hand, and the box a clip shows in (prompt 257) — pure
//
// Device feedback: a clip on the tag sheet was a portrait picture pillarboxed in a wide black box, and the scene inside it
// was sideways (stored with the wrong turn). The viewer can turn a recording a quarter at a time ("Rotate"); the turn is
// kept on the recording (`RacketRecordingLog.quarterTurns`) and every screen showing it through `RacketPlayback` draws
// it turned. The video box takes the picture's own shape (no side bars), capped in height.

enum RacketVideoTurn {
    /// 0…3 quarter turns clockwise (any integer folds into that range; nil ⇒ 0).
    static func normalized(_ turns: Int?) -> Int { (((turns ?? 0) % 4) + 4) % 4 }

    /// One more quarter turn clockwise (the Rotate button).
    static func next(_ turns: Int?) -> Int { normalized(normalized(turns) + 1) }

    /// The stored value: nil for upright, so an untouched recording stays as it was saved.
    static func stored(_ turns: Int) -> Int? { normalized(turns) == 0 ? nil : normalized(turns) }

    static func degrees(_ turns: Int?) -> Double { Double(normalized(turns)) * 90 }

    /// A quarter or three-quarter turn swaps width and height.
    static func swapsSides(_ turns: Int?) -> Bool { normalized(turns) % 2 == 1 }

    /// The size a picture shows at after `turns`.
    static func displayed(_ size: CGSize, turns: Int?) -> CGSize {
        swapsSides(turns) ? CGSize(width: size.height, height: size.width) : size
    }

    /// Width / height as shown after `turns`; nil without a usable size.
    static func aspect(_ size: CGSize?, turns: Int?) -> CGFloat? {
        guard let size, size.width > 0, size.height > 0 else { return nil }
        let d = displayed(size, turns: turns)
        return d.width / d.height
    }

    /// The shape a box has before the picture's size is known (a landscape guess, the common filming shape).
    static let placeholderAspect: CGFloat = 16.0 / 9.0

    /// The video box: the picture's own shape, full `width`; taller than `maxHeight` ⇒ that height and narrower (the
    /// caller centres it). nil aspect ⇒ the placeholder shape.
    static func box(aspect: CGFloat?, width: CGFloat, maxHeight: CGFloat) -> CGSize {
        let a = aspect.flatMap { $0 > 0 ? $0 : nil } ?? placeholderAspect
        guard width > 0 else { return .zero }
        let h = width / a
        let cap = max(1, maxHeight)
        if h <= cap { return CGSize(width: width, height: h) }
        return CGSize(width: min(width, cap * a), height: cap)
    }

    /// The tag sheet's height cap for the video: about 55 % of the screen, and never so tall that the controls under
    /// the picture and "Who won the point?" with its buttons (`reserve`) leave the first screen of the sheet.
    static func tagSheetCap(visibleHeight: CGFloat, reserve: CGFloat = 250) -> CGFloat {
        guard visibleHeight > 0 else { return 300 }
        return max(180, min(visibleHeight * 0.66, visibleHeight - reserve))
    }
}
