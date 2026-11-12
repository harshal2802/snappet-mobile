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
