import Foundation
import CoreGraphics

// MARK: - Clips overlay style — the user's default HR tile + title (prompt 163, pure)
//
// One default for every clip's heart-rate tile and title, set from the Clips toolbar's ✎ sheet
// (wireframes: docs/ux-research/clips-overlay-style/). It applies to feed posts, the fullscreen viewer,
// "Share with heart rate" and highlight reels, so a post and the video shared from it match.
// Precedence: a session styled in the Studio (its saved tile) → this default → the built-in Broadcast
// scorebug. Persisted as one `ClipOverlayDefaults` row (in the backup envelope).
//
// Pure: value types + the rules the poster, the sheet preview and the share render all call — title
// text, per-design poster geometry, and tile placement on a render canvas. Unit-tested in
// `ClipOverlayStyleTests`.

struct ClipOverlayStyle: Codable, Equatable, Sendable {

    enum Edge: String, Codable, Sendable, CaseIterable { case top, bottom }
    /// Dark rounded chip (today's look) or plain text with a shadow.
    enum TitleLook: String, Codable, Sendable, CaseIterable { case chip, plain }

    enum TitlePart: String, Codable, Sendable, CaseIterable, Identifiable {
        case name, outcome, gradeAngle, attempt, date, session
        var id: String { rawValue }
        /// Headline parts form the big line; the rest form the small line under it.
        var isHeadline: Bool { self == .name || self == .outcome }
        var label: String {
            switch self {
            case .name: return "Climb / exercise name"
            case .outcome: return "Outcome (Sent, Flash)"
            case .gradeAngle: return "Grade · angle"
            case .attempt: return "Attempt / set"
            case .date: return "Date"
            case .session: return "Session name"
            }
        }
    }

    struct PartToggle: Codable, Equatable, Sendable, Identifiable {
        var part: TitlePart
        var on: Bool
        var id: String { part.rawValue }
    }

    /// The tile design + which stats + chart/zone colour + transparency (`HRTile.opacity`). Its stored
    /// geometry is unused on Clips surfaces — they place it per design (`posterSize` / `placed`).
    var hrTile: HRTile = HRTile.make(template: .scorebug)
    var hrEdge: Edge = .bottom
    var showTitle: Bool = true
    var titleParts: [PartToggle] = ClipOverlayStyle.defaultParts
    var titleEdge: Edge = .bottom
    var titleLook: TitleLook = .chip

    /// Today's look: Broadcast at the bottom, the name chip above it (name / grade·angle / attempt chip).
    static let builtIn = ClipOverlayStyle()
    static let defaultParts: [PartToggle] = [
        .init(part: .name, on: true), .init(part: .outcome, on: false),
        .init(part: .gradeAngle, on: true), .init(part: .attempt, on: true),
        .init(part: .date, on: false), .init(part: .session, on: false),
    ]

    init() {}

    // Forward-compatible decode: a field added later falls back to its default instead of failing the
    // whole style (the HRTile/SetLog precedent).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hrTile = try c.decodeIfPresent(HRTile.self, forKey: .hrTile) ?? HRTile.make(template: .scorebug)
        hrEdge = try c.decodeIfPresent(Edge.self, forKey: .hrEdge) ?? .bottom
        showTitle = try c.decodeIfPresent(Bool.self, forKey: .showTitle) ?? true
        titleParts = Self.normalized(try c.decodeIfPresent([PartToggle].self, forKey: .titleParts) ?? Self.defaultParts)
        titleEdge = try c.decodeIfPresent(Edge.self, forKey: .titleEdge) ?? .bottom
        titleLook = try c.decodeIfPresent(TitleLook.self, forKey: .titleLook) ?? .chip
    }

    /// Every part exactly once, stored order kept, missing parts appended OFF (a part added in a later
    /// version shows up in the sheet without switching itself on).
    static func normalized(_ parts: [PartToggle]) -> [PartToggle] {
        var seen = Set<TitlePart>()
        var out = parts.filter { seen.insert($0.part).inserted }
        for p in TitlePart.allCases where !seen.contains(p) { out.append(.init(part: p, on: false)) }
        return out
    }

    // MARK: Tile

    /// The tile a clip draws: the session's own Studio tile wins; otherwise this default, with HRR
    /// switched off when there's no resting HR (the `.feedClipScorebug` rule — it would read nothing).
    func tile(sessionTile: HRTile?, restHR: Double?) -> HRTile {
        if let sessionTile { return sessionTile }
        var t = hrTile
        if (restHR ?? 0) <= 0 {
            t.entries = t.entries.map { var e = $0; if e.metric == .hrr { e.on = false }; return e }
        }
        return t
    }

    /// Switch design, keeping the user's stat choices where the new design has them.
    func switching(to template: HRTileTemplate) -> ClipOverlayStyle {
        var s = self
        var t = HRTile.make(template: template)
        let on = Dictionary(hrTile.entries.map { ($0.metric, $0.on) }, uniquingKeysWith: { a, _ in a })
        t.entries = t.entries.map { var e = $0; if let v = on[e.metric] { e.on = v }; return e }
        t.zoneColored = hrTile.zoneColored
        t.opacity = hrTile.opacity
        s.hrTile = t
        return s
    }

    // MARK: Title

    /// What a clip's title can say — filled by the poster / share from the post.
    struct TitleValues: Equatable, Sendable {
        var name: String
        var outcome: String?
        var gradeAngle: String
        var attempt: String?
        var date: String
        var session: String
    }

    /// The rendered title: a big line, a small line, and (chip look only) the attempt as its own white
    /// chip — today's look. Blank parts drop out; nil when there's nothing to say.
    struct TitleText: Equatable, Sendable {
        var primary: String
        var secondary: String?
        var chip: String?
    }

    func titleText(_ v: TitleValues) -> TitleText? {
        guard showTitle else { return nil }
        let outcomeOn = titleParts.contains { $0.part == .outcome && $0.on }
        // "Attempt 3 · Sent" + an Outcome part would say Sent twice — the attempt keeps just its number.
        var attempt = v.attempt
        if outcomeOn, let o = v.outcome, let a = attempt, a.hasSuffix(" · \(o)") {
            attempt = String(a.dropLast(o.count + 3))
        }
        func text(_ p: TitlePart) -> String? {
            let s: String?
            switch p {
            case .name: s = v.name
            case .outcome: s = v.outcome
            case .gradeAngle: s = v.gradeAngle
            case .attempt: s = attempt
            case .date: s = v.date
            case .session: s = v.session
            }
            guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return t
        }
        let on = titleParts.filter(\.on).map(\.part)
        // The chip look keeps the attempt as its own white chip (today's poster); plain folds it into the line.
        let chip = titleLook == .chip && on.contains(.attempt) ? text(.attempt) : nil
        let headline = on.filter { $0.isHeadline }.compactMap(text)
        let detail = on.filter { !$0.isHeadline && !(chip != nil && $0 == .attempt) }.compactMap(text)
        if !headline.isEmpty {
            return TitleText(primary: headline.joined(separator: " · "),
                             secondary: detail.isEmpty ? nil : detail.joined(separator: " · "), chip: chip)
        }
        if !detail.isEmpty {
            return TitleText(primary: detail.joined(separator: " · "), secondary: nil, chip: chip)
        }
        return chip.map { TitleText(primary: $0, secondary: nil, chip: nil) }
    }

    // MARK: Geometry (poster ⇄ render)

    /// The poster card the sizes are designed on (points). Everything scales with the card width, so a
    /// render canvas of any resolution gets the same proportions as the post.
    static let referenceWidth: CGFloat = 402
    /// The 12pt inset around the overlay stack on the poster, as a fraction of the card width.
    static let insetFraction: CGFloat = 12 / 402

    enum HAlign: Sendable, Equatable { case fill, leading, trailing }

    /// How wide a design sits on a post. Band designs span the card; the pill hugs the trailing edge.
    static func hAlign(_ t: HRTileTemplate) -> HAlign {
        switch t {
        case .scorebug, .chartBanner: return .fill
        case .hudPill: return .trailing
        case .hero, .ring, .list, .bento: return .leading
        }
    }

    /// A design's size on a post `width` points wide. Broadcast + HR Trace are the 4.2:1 band (#351); the
    /// card designs keep a readable box instead of the Studio's portrait-canvas defaults.
    static func posterSize(_ t: HRTileTemplate, width: CGFloat) -> CGSize {
        let inner = width * (1 - 2 * insetFraction)
        let k = width / referenceWidth
        switch t {
        case .scorebug, .chartBanner: return CGSize(width: inner, height: inner / 4.2)
        case .hudPill:                return CGSize(width: 0.50 * width, height: 44 * k)
        case .hero:                   return CGSize(width: 0.52 * width, height: 150 * k)
        case .bento:                  return CGSize(width: 0.52 * width, height: 150 * k)
        case .ring:                   return CGSize(width: 0.46 * width, height: 132 * k)
        case .list:                   return CGSize(width: 0.36 * width, height: 200 * k)
        }
    }

    /// `tile` re-placed on a `canvas`-sized render exactly where the poster draws it: the design's poster
    /// size and alignment, hugging `edge` with the poster's inset. (The title moves out of its way when
    /// they share an edge — `titleOrigin`.)
    static func placed(_ tile: ResolvedHRTile, edge: Edge, canvas: CGSize) -> ResolvedHRTile {
        guard canvas.width > 0, canvas.height > 0 else { return tile }
        let size = posterSize(tile.template, width: canvas.width)
        let inset = canvas.width * insetFraction
        let x = hAlign(tile.template) == .trailing ? canvas.width - inset - size.width : inset
        let y = edge == .top ? inset : canvas.height - inset - size.height
        var t = tile
        t.width = Double(min(1, size.width / canvas.width))
        t.height = Double(min(0.6, size.height / canvas.height))
        t.centerX = Double((x + size.width / 2) / canvas.width)
        t.centerY = Double((y + size.height / 2) / canvas.height)
        return t
    }

    /// Where the title block's top-left goes on a render (pixels, top-left origin), given its size and
    /// whether the tile shares its edge — the poster's VStack order (top: tile above title; bottom: title
    /// above tile).
    func titleOrigin(blockSize: CGSize, canvas: CGSize, tileHeight: CGFloat?) -> CGPoint {
        let inset = canvas.width * Self.insetFraction
        let spacing = inset * 0.8
        let shared = (tileHeight ?? 0) > 0 && hrEdge == titleEdge
        let push = shared ? (tileHeight ?? 0) + spacing : 0
        let y = titleEdge == .top ? inset + push : canvas.height - inset - push - blockSize.height
        return CGPoint(x: inset, y: y)
    }
}

extension ClipFeedPost {
    /// What this post's title can say for one of its clips (prompt 163).
    func titleValues(for item: ClipFeedItem) -> ClipOverlayStyle.TitleValues {
        ClipOverlayStyle.TitleValues(
            name: title,
            outcome: climbResult?.badge,
            gradeAngle: overlayDetail,
            attempt: item.attemptLabel,
            date: captureAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)),
            session: sessionTitle)
    }
}
