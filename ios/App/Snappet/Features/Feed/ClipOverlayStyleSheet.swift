import SwiftUI

// MARK: - Clips overlay style — the shared overlay view + the ✎ sheet (prompt 163)
//
// `ClipOverlayChrome` is the ONE SwiftUI drawing of a clip's title + HR tile at the user's style: the feed
// poster and the sheet's live preview both use it (and `ClipShareService` burns the same geometry from the
// pure `ClipOverlayStyle` rules), so the preview, the post and the shared video can't disagree.

/// Title + HR tile laid out on a card `width` points wide, per the style's edges (the poster's stack:
/// top = tile then title; bottom = title then tile).
struct ClipOverlayChrome: View {
    let style: ClipOverlayStyle
    let title: ClipOverlayStyle.TitleText?
    /// The tile + values to draw (nil → no tile: a photo, a reel, no HR in the window).
    let payload: ClipHROverlay.Payload?
    let fraction: Double
    let width: CGFloat
    /// Drives the BPM-dot glide into the live sweep at takeover (the poster's round-5 graft).
    var playing: Bool = false

    private var scale: CGFloat { max(0.5, width / ClipOverlayStyle.referenceWidth) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10 * scale) {
            if style.hrEdge == .top { tile }
            if style.titleEdge == .top { titleView }
            Spacer(minLength: 0)
            if style.titleEdge == .bottom { titleView }
            if style.hrEdge == .bottom { tile }
        }
        .padding(12 * scale)
    }

    /// Height the top edge's overlays occupy (incl. the inset) — the poster pushes its own top chrome
    /// (mute, page counter, EDITED chip) below it.
    static func topReserve(style: ClipOverlayStyle, title: ClipOverlayStyle.TitleText?,
                           tileTemplate: HRTileTemplate?, width: CGFloat) -> CGFloat {
        let s = max(0.5, width / ClipOverlayStyle.referenceWidth)
        var h: CGFloat = 0
        if style.hrEdge == .top, let t = tileTemplate {
            h += ClipOverlayStyle.posterSize(t, width: width).height + 10 * s
        }
        if style.titleEdge == .top, let title {
            let chipPad: CGFloat = style.titleLook == .chip ? 20 : 0
            h += (26 + (title.secondary != nil ? 20 : 0) + (title.chip != nil ? 22 : 0) + chipPad) * s + 10 * s
        }
        return h > 0 ? h + 12 * s : 0
    }

    @ViewBuilder private var tile: some View {
        if let payload {
            let size = ClipOverlayStyle.posterSize(payload.tile.template, width: width)
            let align: Alignment = ClipOverlayStyle.hAlign(payload.tile.template) == .trailing ? .trailing : .leading
            HRTileView(tile: payload.tile, values: payload.values, fraction: fraction,
                       liveBlur: false)   // flat scrim, not a live backdrop blur → cheap to slide (prompt 92)
                .frame(width: size.width, height: size.height)
                .frame(maxWidth: .infinity, alignment: align)
                .animation(.easeOut(duration: 0.18), value: playing)
                .allowsHitTesting(false)
                .accessibilityIdentifier("clips.post.hrTile")
        }
    }

    @ViewBuilder private var titleView: some View {
        if let title {
            let content = VStack(alignment: .leading, spacing: 3 * scale) {
                Text(title.primary).font(.system(size: 20 * scale, weight: .heavy)).foregroundStyle(.white).lineLimit(1)
                if let secondary = title.secondary {
                    Text(secondary).font(.system(size: 15 * scale, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                }
                if let chip = title.chip {
                    Text(chip).font(.system(size: 11 * scale, weight: .bold)).foregroundStyle(.black)
                        .padding(.horizontal, 7 * scale).padding(.vertical, 2 * scale)
                        .background(.white, in: RoundedRectangle(cornerRadius: 6 * scale, style: .continuous))
                        .padding(.top, 3 * scale)
                }
            }
            switch style.titleLook {
            case .chip:
                content.padding(10 * scale)
                    .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 10 * scale, style: .continuous))
                    .allowsHitTesting(false)
            case .plain:
                content.shadow(color: .black.opacity(0.9), radius: 5 * scale)
                    .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - The ✎ sheet

/// What the sheet previews: one of the user's own clips, or a sample when there's none (fresh install,
/// the simulator).
struct ClipOverlayPreviewInput {
    var media: MediaInput?
    var hr: ClipFeedHR
    var values: ClipOverlayStyle.TitleValues
    var aspect: Double
    var caption: String

    static let sample = ClipOverlayPreviewInput(
        media: nil,
        hr: ClipFeedHR(series: (0...60).map { HRPoint(t: Double($0), bpm: 128 + 30 * sin(Double($0) / 12)) },
                       maxHR: 190, restHR: 58),
        values: .init(name: "Black v6", outcome: "Sent", gradeAngle: "6c/V5 · 40°", attempt: "Attempt 3",
                      date: "Tue 30 Sep", session: "Tuesday Session"),
        aspect: 9.0 / 16.0, caption: "Sample clip")
}

struct ClipOverlayStyleSheet: View {
    let store: ClipOverlayStyleStore
    let preview: ClipOverlayPreviewInput

    @Environment(\.dismiss) private var dismiss
    @State private var draft: ClipOverlayStyle = .builtIn
    @State private var tab = 0
    @State private var confirmReset = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                previewCard
                Picker("Section", selection: $tab) {
                    Text("Heart rate").tag(0)
                    Text("Title").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, SnappetSpacing.lg).padding(.vertical, 10)
                .accessibilityIdentifier("clips.style.tabs")
                Form {
                    if tab == 0 { heartRateSections } else { titleSections }
                    Section {
                        Button("Reset to built-in", role: .destructive) { confirmReset = true }
                            .frame(maxWidth: .infinity)
                            .accessibilityIdentifier("clips.style.reset")
                    } footer: {
                        Text("Applies to every post, fullscreen, Share with heart rate and highlight reels. A session you styled in the Studio keeps its own look. Included in backups.")
                    }
                }
                // Title reordering is drag handles on the rows, always available (no Edit button).
                .environment(\.editMode, .constant(tab == 1 ? .active : .inactive))
            }
            .navigationTitle("Overlay style")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { store.save(draft); dismiss() }
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("clips.style.done")
                }
            }
            .confirmationDialog("Go back to the built-in look?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Reset", role: .destructive) { store.reset(); dismiss() }
            }
        }
        .onAppear { draft = store.style }
    }

    // MARK: Preview

    private var previewCard: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack {
                if let m = preview.media {
                    ClipThumbnail(localIdentifier: m.localIdentifier, kind: m.kind,
                                  size: CGSize(width: w, height: 230),
                                  posterTime: ClipHROverlay.playedRange(m).start)
                } else {
                    LinearGradient(colors: [Color(red: 0.23, green: 0.25, blue: 0.28), Color(red: 0.10, green: 0.11, blue: 0.13)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
                ClipOverlayChrome(style: draft, title: draft.titleText(preview.values), payload: previewPayload,
                                  fraction: ClipHROverlay.atEnd(for: previewPayload), width: w)
            }
            .frame(width: w, height: 230)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .frame(height: 230)
        .padding(.horizontal, SnappetSpacing.lg)
        .padding(.top, 4)
        .overlay(alignment: .bottom) {
            Text("Live preview · \(preview.caption)")
                .font(.caption2).foregroundStyle(SnappetColor.textSecondary)
                .offset(y: 16)
        }
        .padding(.bottom, 14)
        .accessibilityIdentifier("clips.style.preview")
    }

    /// The preview's tile + values from the DRAFT — the same `ClipHROverlay.make` the feed composes with.
    private var previewPayload: ClipHROverlay.Payload? {
        let media = preview.media ?? MediaInput(id: UUID(), kind: "video", offsetSec: 20, durationSec: 12,
                                                exerciseId: nil, setIndex: nil, climbUUID: nil, localIdentifier: "")
        return ClipHROverlay.make(clip: media, hrSeries: preview.hr.series, maxHR: preview.hr.maxHR,
                                  restHR: preview.hr.restHR,
                                  tile: draft.tile(sessionTile: nil, restHR: preview.hr.restHR))
    }

    // MARK: Heart rate

    @ViewBuilder private var heartRateSections: some View {
        Section("Design") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(HRTileTemplate.allCases) { t in
                        let on = draft.hrTile.template == t
                        Button { draft = draft.switching(to: t) } label: {
                            Text(t.label)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .foregroundStyle(on ? SnappetColor.brand : SnappetColor.textSecondary)
                                .background(on ? SnappetColor.brand.opacity(0.14) : SnappetColor.surfaceMuted,
                                            in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(on ? SnappetColor.brand : SnappetColor.hairline, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("clips.style.template.\(t.rawValue)")
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .padding(.vertical, 2)
            }
        }
        Section("Show") {
            ClipStyleMetricChips(items: draft.hrTile.entries.map { ($0.metric, $0.on) }) { metric in
                draft.hrTile.entries = draft.hrTile.entries.map {
                    var e = $0; if e.metric == metric { e.on.toggle() }; return e
                }
            }
            Toggle("Heart-rate chart", isOn: $draft.hrTile.showChart)
            Toggle("Colour by zone", isOn: $draft.hrTile.zoneColored)
        }
        Section {
            HStack {
                Text("Transparency")
                Slider(value: Binding(get: { 1 - draft.hrTile.opacity },
                                      set: { draft.hrTile.opacity = 1 - $0 }),
                       in: 0...(1 - HRTile.minOpacity))
                    .accessibilityIdentifier("clips.style.transparency")
            }
            Picker("Position", selection: $draft.hrEdge) {
                Text("Top").tag(ClipOverlayStyle.Edge.top)
                Text("Bottom").tag(ClipOverlayStyle.Edge.bottom)
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: Title

    @ViewBuilder private var titleSections: some View {
        Section { Toggle("Show title", isOn: $draft.showTitle).accessibilityIdentifier("clips.style.showTitle") }
        if draft.showTitle {
            Section {
                ForEach($draft.titleParts) { $p in
                    Toggle(p.part.label, isOn: $p.on)
                        .accessibilityIdentifier("clips.style.part.\(p.part.rawValue)")
                }
                .onMove { draft.titleParts.move(fromOffsets: $0, toOffset: $1) }
            } header: {
                Text("Include · drag to reorder")
            } footer: {
                Text("Name and outcome make the big line; the rest go on the line under it.")
            }
            Section {
                Picker("Position", selection: $draft.titleEdge) {
                    Text("Top").tag(ClipOverlayStyle.Edge.top)
                    Text("Bottom").tag(ClipOverlayStyle.Edge.bottom)
                }
                Picker("Style", selection: $draft.titleLook) {
                    Text("Chip").tag(ClipOverlayStyle.TitleLook.chip)
                    Text("Plain").tag(ClipOverlayStyle.TitleLook.plain)
                }
            }
        }
    }
}

/// The stat toggles as wrapping chips (on = brand-tinted).
private struct ClipStyleMetricChips: View {
    let items: [(HROverlayMetric, Bool)]
    let toggle: (HROverlayMetric) -> Void

    var body: some View {
        ClipStyleFlowLayout(spacing: 6) {
            ForEach(items, id: \.0) { metric, on in
                Button { toggle(metric) } label: {
                    Text(metric.label)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .foregroundStyle(on ? SnappetColor.brand : SnappetColor.textSecondary)
                        .background(on ? SnappetColor.brand.opacity(0.14) : SnappetColor.surfaceMuted, in: Capsule())
                        .overlay(Capsule().strokeBorder(on ? SnappetColor.brand : SnappetColor.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("clips.style.metric.\(metric.rawValue)")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }
}

/// Minimal wrapping layout for the stat chips.
private struct ClipStyleFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            x += size.width + spacing; rowH = max(rowH, size.height); maxX = max(maxX, x - spacing)
        }
        return CGSize(width: min(width, maxX), height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; rowH = max(rowH, size.height)
        }
    }
}
