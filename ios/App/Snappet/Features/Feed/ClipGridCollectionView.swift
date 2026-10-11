import SwiftUI
import UIKit

// MARK: - Clips grid on UICollectionView — Photos-style zoom (2026-10-10)
//
// Why UIKit: the SwiftUI LazyVGrid froze 370–620 ms on every 3 ⇄ 5 switch (measured on device — the whole grid
// re-laid out on main in one go), so no animation could hide it. Here a custom layout draws every cover from
// `ClipGridGeometry` (pure arithmetic), and a zoom interpolates each visible cover's frame between two levels
// while the scroll offset moves so the cover under the fingers stays put — only on-screen covers are touched
// per frame. Covers are plain UIKit views (cheap to resize every frame); the rich month header stays SwiftUI.

/// A handle the SwiftUI side uses to drive the collection (scrubber jumps, day-strip taps).
@MainActor
final class ClipGridController {
    fileprivate weak var coordinator: ClipGridCollection.Coordinator?

    /// Put a month's header at the top (instant — the scrubber calls this per month crossed).
    func jump(toMonth id: String) { coordinator?.jump(toMonth: id) }

    /// Bring a post's cover to the top, just under its month header.
    func scroll(toPost id: String) { coordinator?.scroll(toPost: id) }
}

struct ClipGridCollection: UIViewRepresentable {
    let months: [ClipGridModel.Month]
    let years: [String: ClipGridModel.Year]
    let level: ClipGridLevel
    /// Select mode's picks; nil = not selecting.
    let selection: Set<String>?
    let controller: ClipGridController
    let scrub: ClipGridScrubState
    let model: (ClipFeedPost) -> ClipGridCellModel
    let header: (ClipGridModel.Month) -> AnyView
    let onTap: (ClipFeedPost) -> Void
    let menu: (ClipFeedPost) -> [UIMenuElement]
    let preview: (ClipFeedPost) -> AnyView
    let onLevelChange: (ClipGridLevel) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UICollectionView {
        let layout = ClipGridZoomLayout(level: level)
        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        cv.backgroundColor = UIColor(SnappetColor.paper)
        cv.contentInsetAdjustmentBehavior = .never
        cv.alwaysBounceVertical = true
        cv.accessibilityIdentifier = "clips.grid"
        context.coordinator.attach(cv, layout: layout)
        controller.coordinator = context.coordinator
        return cv
    }

    func updateUIView(_ cv: UICollectionView, context: Context) {
        controller.coordinator = context.coordinator
        context.coordinator.update(from: self)
    }

    // MARK: Coordinator

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate,
                             UICollectionViewDataSourcePrefetching, UIGestureRecognizerDelegate {
        var parent: ClipGridCollection
        private weak var cv: UICollectionView?
        private var layout: ClipGridZoomLayout!
        private var structure: [[String]] = []
        private var monthRegistration: UICollectionView.SupplementaryRegistration<UICollectionViewCell>!
        private var yearRegistration: UICollectionView.SupplementaryRegistration<ClipGridYearLabelView>!

        // Zoom state
        private var pinchBase: CGFloat = 1
        private var pinching = false
        /// Whether the running zoom was the user's own gesture (pinch / year tap) — its result is reported back
        /// to SwiftUI. A segmented-control zoom already IS SwiftUI's level.
        private var zoomIsGesture = false
        private var link: CADisplayLink?
        private var settle: (from: CGFloat, to: CGFloat, start: CFTimeInterval, duration: Double)?

        init(parent: ClipGridCollection) { self.parent = parent }

        func attach(_ cv: UICollectionView, layout: ClipGridZoomLayout) {
            self.cv = cv
            self.layout = layout
            cv.register(ClipGridCoverCell.self, forCellWithReuseIdentifier: ClipGridCoverCell.reuse)
            monthRegistration = .init(elementKind: ClipGridZoomLayout.monthKind) { [weak self] view, _, ip in
                guard let self, ip.section < self.parent.months.count else { return }
                view.contentConfiguration = UIHostingConfiguration { self.parent.header(self.parent.months[ip.section]) }
                    .margins(.all, 0)
            }
            yearRegistration = .init(elementKind: ClipGridZoomLayout.yearKind) { [weak self] view, _, ip in
                self?.configureYearLabel(view, section: ip.section)
            }
            cv.dataSource = self
            cv.delegate = self
            cv.prefetchDataSource = self
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
            pinch.delegate = self
            cv.addGestureRecognizer(pinch)
            layout.measureMonthHeader = { [weak self] width in self?.measureMonthHeader(width: width) ?? 66 }
            reloadStructure()
        }

        func update(from parent: ClipGridCollection) {
            let oldSelection = self.parent.selection
            self.parent = parent
            let newStructure = parent.months.map { $0.posts.map(\.id) }
            if newStructure != structure {
                reloadStructure()
            } else {
                refreshVisible(selectionChanged: oldSelection != parent.selection)
            }
            if parent.level != layout.level, layout.zoom == nil, !pinching {
                animateZoom(to: parent.level, anchor: nil, gesture: false)
            }
        }

        private func reloadStructure() {
            structure = parent.months.map { $0.posts.map(\.id) }
            var seen = Set<String>()
            let firstOfYear = parent.months.map { seen.insert(String($0.id.prefix(4))).inserted }
            layout.setSections(counts: parent.months.map(\.posts.count), firstOfYear: firstOfYear)
            cv?.reloadData()
        }

        /// Same posts in the same places: refresh the on-screen covers (favourite, peak, select marks) and headers.
        private func refreshVisible(selectionChanged: Bool) {
            guard let cv else { return }
            for ip in cv.indexPathsForVisibleItems {
                guard let cell = cv.cellForItem(at: ip) as? ClipGridCoverCell, let post = post(at: ip) else { continue }
                cell.configure(parent.model(post), side: layout.settledSide, selection: selectionState(post))
            }
            for ip in cv.indexPathsForVisibleSupplementaryElements(ofKind: ClipGridZoomLayout.monthKind) {
                guard ip.section < parent.months.count,
                      let view = cv.supplementaryView(forElementKind: ClipGridZoomLayout.monthKind, at: ip)
                        as? UICollectionViewCell else { continue }
                let month = parent.months[ip.section]
                view.contentConfiguration = UIHostingConfiguration { self.parent.header(month) }.margins(.all, 0)
            }
            for ip in cv.indexPathsForVisibleSupplementaryElements(ofKind: ClipGridZoomLayout.yearKind) {
                if let v = cv.supplementaryView(forElementKind: ClipGridZoomLayout.yearKind, at: ip) as? ClipGridYearLabelView {
                    configureYearLabel(v, section: ip.section)
                }
            }
            _ = selectionChanged
        }

        private func post(at ip: IndexPath) -> ClipFeedPost? {
            guard ip.section < parent.months.count, ip.item < parent.months[ip.section].posts.count else { return nil }
            return parent.months[ip.section].posts[ip.item]
        }

        private func indexPath(ofPost id: String) -> IndexPath? {
            for (s, ids) in structure.enumerated() { if let i = ids.firstIndex(of: id) { return IndexPath(item: i, section: s) } }
            return nil
        }

        private func selectionState(_ post: ClipFeedPost) -> Bool? {
            parent.selection.map { $0.contains(post.id) }
        }

        private func configureYearLabel(_ view: ClipGridYearLabelView, section: Int) {
            guard section < parent.months.count else { return }
            let month = parent.months[section]
            let showsYear = layout.isFirstOfYear(section)
            view.configure(month: ClipGridModel.shortMonth(month),
                           year: showsYear ? parent.years[String(month.id.prefix(4))] : nil)
        }

        private func measureMonthHeader(width: CGFloat) -> CGFloat {
            guard let month = parent.months.first else { return 66 }
            let host = UIHostingController(rootView: parent.header(month))
            let h = host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
            return max(44, ceil(h))
        }

        // MARK: Data source

        func numberOfSections(in collectionView: UICollectionView) -> Int { parent.months.count }

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            parent.months[section].posts.count
        }

        func collectionView(_ collectionView: UICollectionView, cellForItemAt ip: IndexPath) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ClipGridCoverCell.reuse, for: ip) as! ClipGridCoverCell
            if let post = post(at: ip) {
                cell.configure(parent.model(post), side: layout.settledSide, selection: selectionState(post))
            }
            return cell
        }

        func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String,
                            at ip: IndexPath) -> UICollectionReusableView {
            if kind == ClipGridZoomLayout.yearKind {
                return collectionView.dequeueConfiguredReusableSupplementary(using: yearRegistration, for: ip)
            }
            return collectionView.dequeueConfiguredReusableSupplementary(using: monthRegistration, for: ip)
        }

        func collectionView(_ collectionView: UICollectionView, prefetchItemsAt ips: [IndexPath]) {
            let ids = ips.compactMap { post(at: $0)?.clips.first?.media.localIdentifier }
            let side = layout.settledSide
            AssetPosterLoader.warmThumbnails(ids, pointSize: CGSize(width: side, height: side))
        }

        // MARK: Taps + long-press

        func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt ip: IndexPath) -> Bool {
            if layout.zoom == nil, let post = post(at: ip) {
                if layout.level == .year, parent.selection == nil {
                    // Year → tap zooms into the month around what you tapped, like Photos.
                    let f = layout.layoutAttributesForItem(at: ip)?.frame ?? .zero
                    animateZoom(to: .months, anchor: CGPoint(x: f.midX, y: f.midY), gesture: true)
                } else {
                    parent.onTap(post)
                }
            }
            return false
        }

        func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt ips: [IndexPath],
                            point: CGPoint) -> UIContextMenuConfiguration? {
            guard parent.selection == nil, layout.zoom == nil, let ip = ips.first, let post = post(at: ip) else { return nil }
            let elements = parent.menu(post)
            guard !elements.isEmpty else { return nil }
            let preview = parent.preview(post)
            return UIContextMenuConfiguration(identifier: nil, previewProvider: {
                let vc = UIHostingController(rootView: preview)
                vc.preferredContentSize = CGSize(width: 320, height: 320)
                return vc
            }, actionProvider: { _ in UIMenu(children: elements) })
        }

        // MARK: Scrolling → fast-scroll handle

        func scrollViewDidScroll(_ sv: UIScrollView) {
            guard layout.zoom == nil else { return }
            let range = sv.contentSize.height - sv.bounds.height
            parent.scrub.scrollFraction = range > 0 ? min(1, max(0, sv.contentOffset.y / range)) : 0
        }

        func scrollViewWillBeginDragging(_ sv: UIScrollView) { parent.scrub.show() }

        func scrollViewDidEndDragging(_ sv: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { parent.scrub.scheduleHide() }
        }

        func scrollViewDidEndDecelerating(_ sv: UIScrollView) { parent.scrub.scheduleHide() }

        func jump(toMonth id: String) {
            guard let cv, layout.zoom == nil, let s = parent.months.firstIndex(where: { $0.id == id }),
                  let g = layout.geometry else { return }
            cv.setContentOffset(CGPoint(x: 0, y: clampedOffset(g.tops[s], g)), animated: false)
        }

        func scroll(toPost id: String) {
            guard let cv, layout.zoom == nil, let ip = indexPath(ofPost: id), let g = layout.geometry else { return }
            let f = g.itemFrame(ip.section, ip.item)
            let header = layout.level.pinsHeaders ? g.sections[ip.section].headerHeight : 0
            cv.setContentOffset(CGPoint(x: 0, y: clampedOffset(f.minY - header - 4, g)), animated: true)
        }

        private func clampedOffset(_ y: CGFloat, _ g: ClipGridGeometry) -> CGFloat {
            min(max(0, g.contentHeight - (cv?.bounds.height ?? 0)), max(0, y))
        }

        // MARK: Zoom — pinch

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool { layout.zoom == nil || pinching }

        @objc private func pinched(_ g: UIPinchGestureRecognizer) {
            guard let cv else { return }
            switch g.state {
            case .began:
                stopSettle(commitTo: nil)
                pinching = true
                pinchBase = g.scale
                cv.panGestureRecognizer.isEnabled = false          // two fingers zoom, they don't also scroll
                cv.panGestureRecognizer.isEnabled = true
            case .changed:
                let rel = Double(g.scale / pinchBase)
                let at = g.location(in: cv)
                if layout.zoom == nil {
                    if rel < 0.98, let t = layout.level.denser { beginZoom(to: t, anchor: at, label: "pinch") }
                    else if rel > 1.02, let t = layout.level.bigger { beginZoom(to: t, anchor: at, label: "pinch") }
                }
                guard let z = layout.zoom else { return }
                let p = ClipGridZoom.progress(scale: rel, from: z.fromLevel, to: z.toLevel)
                let denser = z.toLevel.columns > z.fromLevel.columns
                if p == 0, (denser ? rel > 1.02 : rel < 0.98) {
                    // Reversed past where it started — zoom the other way instead.
                    commitZoom(finished: false)
                    pinchBase = g.scale
                    return
                }
                if p >= 1, let next = denser ? z.toLevel.denser : z.toLevel.bigger {
                    // Kept pinching past this level — carry on into the next one (All → Months → Year).
                    commitZoom(finished: true)
                    pinchBase = g.scale
                    beginZoom(to: next, anchor: at, label: "pinch")
                    return
                }
                setProgress(CGFloat(min(1, p)))
            case .ended, .cancelled, .failed:
                pinching = false
                guard let z = layout.zoom else { return }
                let denser = z.toLevel.columns > z.fromLevel.columns
                let toward = Double(g.velocity) * (denser ? -1 : 1)
                let finish = g.state == .ended && ClipGridZoom.settles(progress: Double(z.progress), towardVelocity: toward)
                runSettle(to: finish ? 1 : 0, duration: 0.12 + 0.18 * Double(finish ? 1 - z.progress : z.progress))
            default: break
            }
        }

        // MARK: Zoom — engine

        private func beginZoom(to target: ClipGridLevel, anchor: CGPoint?, label: String) {
            guard let cv, let g0 = layout.geometry, target != layout.level, !parent.months.isEmpty else { return }
            zoomIsGesture = label == "pinch" || zoomIsGesture
            let o0 = cv.contentOffset.y
            let viewport = cv.bounds.height
            let g1 = layout.makeGeometry(for: target, width: g0.width)
            // The anchor: the cover under the fingers (or, for a button, the cover at the top-left of the screen).
            let point = anchor ?? CGPoint(x: g0.spacing + 1, y: o0 + (layout.level.pinsHeaders ? 80 : 2))
            let item = g0.item(near: point) ?? (0, 0)
            let f0 = g0.itemFrame(item.section, item.item)
            let fraction = f0.height > 0 ? min(1, max(0, (point.y - f0.minY) / f0.height)) : 0.5
            let screenY = anchor == nil ? (f0.minY - o0) : (point.y - o0)
            let o1 = ClipGridZoom.anchoredOffset(item: item, fraction: anchor == nil ? 0 : fraction, screenY: screenY,
                                                 in: g1, viewport: viewport)
            layout.zoom = .init(from: g0, to: g1, fromLevel: layout.level, toLevel: target,
                                fromOffset: o0, toOffset: o1, progress: 0)
        }

        private func setProgress(_ p: CGFloat) {
            guard let cv, var z = layout.zoom else { return }
            z.progress = p
            layout.zoom = z
            cv.contentOffset = CGPoint(x: 0, y: ClipGridZoom.lerp(z.fromOffset, z.toOffset, p))
        }

        /// Land the zoom on its target (`finished`) or back where it started.
        private func commitZoom(finished: Bool) {
            guard let cv, let z = layout.zoom else { return }
            let level = finished ? z.toLevel : z.fromLevel
            layout.finishZoom(at: level)
            cv.contentOffset = CGPoint(x: 0, y: finished ? z.toOffset : z.fromOffset)
            cv.layoutIfNeeded()
            let gesture = zoomIsGesture
            zoomIsGesture = false
            if finished {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                // Sharpen covers that grew (they were drawn from the smaller level's thumbnails).
                for case let cell as ClipGridCoverCell in cv.visibleCells { cell.ensureImage(side: layout.settledSide) }
            }
            if gesture {
                if level != parent.level { parent.onLevelChange(level) }
            } else if level != parent.level, !pinching {
                // The segment changed again mid-zoom — carry on to where it points now.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.layout.zoom == nil, self.parent.level != self.layout.level else { return }
                    self.animateZoom(to: self.parent.level, anchor: nil, gesture: false)
                }
            }
        }

        /// A zoom nobody's pinching: the segmented control, or a tap in the year mosaic.
        private func animateZoom(to target: ClipGridLevel, anchor: CGPoint?, gesture: Bool) {
            stopSettle(commitTo: nil)
            zoomIsGesture = gesture
            beginZoom(to: target, anchor: anchor, label: "button")
            guard layout.zoom != nil else { return }
            runSettle(to: 1, duration: 0.34)
        }

        private func runSettle(to end: CGFloat, duration: Double) {
            guard let z = layout.zoom else { return }
            settle = (z.progress, end, CACurrentMediaTime(), max(0.08, duration))
            if link == nil {
                let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
                l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
                l.add(to: .main, forMode: .common)
                link = l
            }
        }

        @objc private func tick(_ l: CADisplayLink) {
            guard let s = settle else { stopSettle(commitTo: nil); return }
            let t = (CACurrentMediaTime() - s.start) / s.duration
            setProgress(ClipGridZoom.lerp(s.from, s.to, CGFloat(ClipGridZoom.ease(t))))
            if t >= 1 { stopSettle(commitTo: s.to >= 1) }
        }

        /// Stop the settle animation; `commitTo` lands the zoom (true = target, false = back, nil = leave as is).
        private func stopSettle(commitTo finished: Bool?) {
            link?.invalidate()
            link = nil
            let pending = settle
            settle = nil
            if let finished { commitZoom(finished: finished) }
            else if let pending, layout.zoom != nil { setProgress(pending.to); commitZoom(finished: pending.to >= 1) }
        }
    }
}

// MARK: - Layout

/// Settled: covers + (pinned) headers straight from one `ClipGridGeometry`. Zooming: every visible cover's frame
/// interpolated between two geometries; month headers ride along, the year mosaic's labels cross-fade in.
final class ClipGridZoomLayout: UICollectionViewLayout {
    static let monthKind = "clips.grid.monthHeader"
    static let yearKind = "clips.grid.yearLabel"
    static let monthLabelHeight: CGFloat = 20
    static let yearTitleHeight: CGFloat = 46

    struct Zoom {
        var from: ClipGridGeometry
        var to: ClipGridGeometry
        var fromLevel: ClipGridLevel
        var toLevel: ClipGridLevel
        var fromOffset: CGFloat
        var toOffset: CGFloat
        var progress: CGFloat
    }

    private(set) var level: ClipGridLevel
    private(set) var geometry: ClipGridGeometry?
    var zoom: Zoom? { didSet { invalidateLayout() } }
    var measureMonthHeader: ((CGFloat) -> CGFloat)?
    private var counts: [Int] = []
    private var firstOfYear: [Bool] = []
    private var monthHeaderHeight: CGFloat = 66
    private var measuredWidth: CGFloat = -1
    private var dirty = true

    init(level: ClipGridLevel) {
        self.level = level
        super.init()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var settledSide: CGFloat { geometry?.side ?? 100 }

    func isFirstOfYear(_ s: Int) -> Bool { s < firstOfYear.count && firstOfYear[s] }

    func setSections(counts: [Int], firstOfYear: [Bool]) {
        self.counts = counts
        self.firstOfYear = firstOfYear
        measuredWidth = -1                       // the header may have changed shape (e.g. a new month)
        dirty = true
        zoom = nil
        invalidateLayout()
    }

    func finishZoom(at level: ClipGridLevel) {
        self.level = level
        dirty = true
        zoom = nil
    }

    func makeGeometry(for level: ClipGridLevel, width: CGFloat) -> ClipGridGeometry {
        let sections = counts.indices.map { s in
            ClipGridGeometry.Section(count: counts[s], headerHeight: headerHeight(level, s))
        }
        return ClipGridGeometry(level: level, width: width, sections: sections)
    }

    private func headerHeight(_ level: ClipGridLevel, _ s: Int) -> CGFloat {
        guard level == .year else { return monthHeaderHeight }
        return Self.monthLabelHeight + (isFirstOfYear(s) ? Self.yearTitleHeight : 0)
    }

    private static func kind(_ level: ClipGridLevel) -> String { level == .year ? yearKind : monthKind }

    override func prepare() {
        super.prepare()
        guard let cv = collectionView else { return }
        let width = cv.bounds.width
        guard width > 0 else { return }
        if width != measuredWidth {
            measuredWidth = width
            monthHeaderHeight = measureMonthHeader?(width) ?? monthHeaderHeight
            dirty = true
        }
        if dirty || geometry?.width != width {
            geometry = makeGeometry(for: level, width: width)
            dirty = false
        }
    }

    override var collectionViewContentSize: CGSize {
        let width = collectionView?.bounds.width ?? 0
        if let z = zoom { return CGSize(width: width, height: max(z.from.contentHeight, z.to.contentHeight)) }
        return CGSize(width: width, height: geometry?.contentHeight ?? 0)
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        guard let cv = collectionView else { return false }
        if newBounds.width != cv.bounds.width { dirty = true; return true }
        return zoom == nil && level.pinsHeaders            // pinned headers follow the scroll
    }

    override func invalidationContext(forBoundsChange newBounds: CGRect) -> UICollectionViewLayoutInvalidationContext {
        let ctx = super.invalidationContext(forBoundsChange: newBounds)
        guard let cv = collectionView, newBounds.width == cv.bounds.width, let g = geometry else { return ctx }
        // Only the headers move while scrolling — re-place those, leave the covers alone.
        let range = g.sections(from: newBounds.minY - newBounds.height, to: newBounds.maxY + newBounds.height)
        ctx.invalidateSupplementaryElements(ofKind: Self.monthKind, at: range.map { IndexPath(item: 0, section: $0) })
        return ctx
    }

    // MARK: Attributes

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        if let z = zoom { return zoomAttributes(z, in: rect) }
        guard let g = geometry else { return nil }
        let offset = collectionView?.contentOffset.y ?? 0
        var out: [UICollectionViewLayoutAttributes] = []
        for s in g.sections(from: rect.minY, to: rect.maxY) {
            out.append(headerAttributes(s, g, level, offset: offset))
            if level == .year { out.append(dormantMonthHeader(s, g)) }
            for i in g.items(in: s, from: rect.minY, to: rect.maxY) {
                let a = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: i, section: s))
                a.frame = g.itemFrame(s, i)
                out.append(a)
            }
        }
        return out
    }

    override func layoutAttributesForItem(at ip: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard ip.section < counts.count, ip.item < counts[ip.section] else { return nil }
        let a = UICollectionViewLayoutAttributes(forCellWith: ip)
        if let z = zoom {
            a.frame = ClipGridZoom.lerp(z.from.itemFrame(ip.section, ip.item), z.to.itemFrame(ip.section, ip.item), z.progress)
        } else if let g = geometry {
            a.frame = g.itemFrame(ip.section, ip.item)
        }
        return a
    }

    override func layoutAttributesForSupplementaryView(ofKind kind: String,
                                                       at ip: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard ip.section < counts.count else { return nil }
        if let z = zoom {
            return zoomHeader(kind: kind, ip.section, z)
        }
        guard let g = geometry else { return nil }
        if kind == Self.kind(level) {
            return headerAttributes(ip.section, g, level, offset: collectionView?.contentOffset.y ?? 0)
        }
        if level == .year, kind == Self.monthKind { return dormantMonthHeader(ip.section, g) }
        let a = UICollectionViewLayoutAttributes(forSupplementaryViewOfKind: kind, with: ip)
        a.frame = g.headerFrame(ip.section)
        a.alpha = 0
        return a
    }

    /// In the year mosaic the (SwiftUI) month headers stay alive but invisible, so zooming back out doesn't build
    /// several hosting views in one frame — that was a 56–64 ms hitch, measured.
    private func dormantMonthHeader(_ s: Int, _ g: ClipGridGeometry) -> UICollectionViewLayoutAttributes {
        let a = UICollectionViewLayoutAttributes(forSupplementaryViewOfKind: Self.monthKind, with: IndexPath(item: 0, section: s))
        a.frame = CGRect(x: 0, y: g.tops[s], width: g.width, height: monthHeaderHeight)
        a.alpha = 0
        a.zIndex = -1
        return a
    }

    private func headerAttributes(_ s: Int, _ g: ClipGridGeometry, _ level: ClipGridLevel,
                                  offset: CGFloat) -> UICollectionViewLayoutAttributes {
        let a = UICollectionViewLayoutAttributes(forSupplementaryViewOfKind: Self.kind(level), with: IndexPath(item: 0, section: s))
        a.frame = level.pinsHeaders ? g.pinnedHeaderFrame(s, offset: offset) : g.headerFrame(s)
        a.zIndex = 10
        return a
    }

    /// The covers on screen at either end of the zoom (union) at their interpolated frames — only those inside
    /// `rect` NOW, so covers sliding in are created a few per frame rather than all on the zoom's first frame.
    private func zoomAttributes(_ z: Zoom, in rect: CGRect) -> [UICollectionViewLayoutAttributes] {
        let viewport = collectionView?.bounds.height ?? 0
        let margin = viewport * 0.25
        var paths = Set<IndexPath>()
        var sections = Set<Int>()
        for (g, o) in [(z.from, z.fromOffset), (z.to, z.toOffset)] {
            let lo = o - margin, hi = o + viewport + margin
            for s in g.sections(from: lo, to: hi) {
                sections.insert(s)
                for i in g.items(in: s, from: lo, to: hi) { paths.insert(IndexPath(item: i, section: s)) }
            }
        }
        var out: [UICollectionViewLayoutAttributes] = []
        out.reserveCapacity(paths.count + sections.count * 2)
        for ip in paths {
            let frame = ClipGridZoom.lerp(z.from.itemFrame(ip.section, ip.item), z.to.itemFrame(ip.section, ip.item), z.progress)
            guard frame.intersects(rect) else { continue }
            let a = UICollectionViewLayoutAttributes(forCellWith: ip)
            a.frame = frame
            out.append(a)
        }
        let kinds = Set([Self.kind(z.fromLevel), Self.kind(z.toLevel), Self.monthKind])
        for s in sections {
            for kind in kinds {
                if let a = zoomHeader(kind: kind, s, z), a.frame.intersects(rect) { out.append(a) }
            }
        }
        return out
    }

    /// Same header kind at both ends → it slides between its two (pinned) frames. Different kinds → each rides
    /// with its month's first cover, the outgoing one fading out quickly and the incoming one fading in.
    private func zoomHeader(kind: String, _ s: Int, _ z: Zoom) -> UICollectionViewLayoutAttributes? {
        let ip = IndexPath(item: 0, section: s)
        let a = UICollectionViewLayoutAttributes(forSupplementaryViewOfKind: kind, with: ip)
        a.zIndex = 10
        let fromKind = Self.kind(z.fromLevel), toKind = Self.kind(z.toLevel)
        func frame(_ g: ClipGridGeometry, _ lvl: ClipGridLevel, _ o: CGFloat) -> CGRect {
            lvl.pinsHeaders ? g.pinnedHeaderFrame(s, offset: o) : g.headerFrame(s)
        }
        if fromKind == toKind {
            guard kind == fromKind else { return nil }
            a.frame = ClipGridZoom.lerp(frame(z.from, z.fromLevel, z.fromOffset), frame(z.to, z.toLevel, z.toOffset), z.progress)
            return a
        }
        // Where the month's first cover is now, and how far it has moved from each end.
        let first = ClipGridZoom.lerp(z.from.itemFrame(s, 0), z.to.itemFrame(s, 0), z.progress)
        if kind == fromKind {
            let h = z.from.headerFrame(s)
            a.frame = CGRect(x: 0, y: first.minY - h.height, width: h.width, height: h.height)
            a.alpha = max(0, 1 - z.progress * 2.5)
        } else if kind == toKind {
            let h = z.to.headerFrame(s)
            a.frame = CGRect(x: 0, y: first.minY - h.height, width: h.width, height: h.height)
            a.alpha = max(0, min(1, (z.progress - 0.3) / 0.7))
        } else {
            return nil
        }
        return a
    }
}

// MARK: - Cover cell (UIKit — cheap to resize every frame of a zoom)

final class ClipGridCoverCell: UICollectionViewCell {
    static let reuse = "clips.grid.cover"

    private let imageView = UIImageView()
    private let shade = CAGradientLayer()
    private let details = UIView()
    private let titleLabel = UILabel()
    private let durationLabel = ClipGridPill()
    private let reelBadge = ClipGridPill()
    private let sendBadge = ClipGridPill()
    private let peakBadge = ClipGridPill()
    private let heartView = UIImageView()
    private let multiView = UIImageView()
    private let mark = ClipGridSelectMark()
    private var model: ClipGridCellModel?
    private var loadedID: String?
    private var loadedSide: CGFloat = 0
    private var loading: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = UIColor(white: 0.08, alpha: 1)
        contentView.clipsToBounds = true
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        contentView.addSubview(imageView)
        shade.colors = [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.55).cgColor]
        details.layer.addSublayer(shade)
        details.isUserInteractionEnabled = false
        contentView.addSubview(details)
        titleLabel.font = .systemFont(ofSize: 11, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.accessibilityIdentifier = "clips.grid.cell.title"
        durationLabel.style(font: .systemFont(ofSize: 9, weight: .bold), fg: .white,
                            bg: UIColor.black.withAlphaComponent(0.5), radius: 4)
        reelBadge.style(font: .systemFont(ofSize: 8, weight: .heavy), fg: UIColor(red: 0.16, green: 0.04, blue: 0.02, alpha: 1),
                        bg: UIColor(SnappetColor.reels), radius: nil)
        reelBadge.text = "✦ REEL"
        sendBadge.style(font: .systemFont(ofSize: 8, weight: .heavy), fg: .white, bg: .clear, radius: nil)
        peakBadge.style(font: .systemFont(ofSize: 8, weight: .heavy), fg: UIColor(red: 1, green: 0.55, blue: 0.48, alpha: 1),
                        bg: UIColor.black.withAlphaComponent(0.55), radius: nil)
        let small = UIImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        heartView.image = UIImage(systemName: "heart.fill", withConfiguration: small)
        multiView.image = UIImage(systemName: "rectangle.stack.fill",
                                  withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        for v in [heartView, multiView] {
            v.tintColor = .white
            v.layer.shadowColor = UIColor.black.cgColor
            v.layer.shadowOpacity = 0.5
            v.layer.shadowRadius = 2
            v.layer.shadowOffset = .zero
        }
        for v in [titleLabel, durationLabel, reelBadge, sendBadge, peakBadge, heartView, multiView] as [UIView] {
            details.addSubview(v)
        }
        contentView.addSubview(mark)
        isAccessibilityElement = false
        accessibilityIdentifier = "clips.grid.cell"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func prepareForReuse() {
        super.prepareForReuse()
        loading?.cancel()
        loading = nil
    }

    func configure(_ m: ClipGridCellModel, side: CGFloat, selection: Bool?) {
        let changed = m != model
        model = m
        if changed {
            titleLabel.text = m.title
            durationLabel.text = m.duration
            durationLabel.isHidden = m.duration == nil
            reelBadge.isHidden = !m.isReel
            sendBadge.text = m.sendLabel
            sendBadge.backgroundColor = m.sendColor.map { UIColor($0) }
            sendBadge.isHidden = m.sendLabel == nil
            peakBadge.text = m.peak.map { "♥\($0)" }
            peakBadge.isHidden = m.peak == nil
            heartView.isHidden = !m.isFavorite
            multiView.isHidden = !m.isMulti
            accessibilityLabel = m.title
            setNeedsLayout()
        }
        mark.isHidden = selection == nil
        mark.isOn = selection == true
        ensureImage(side: side)
    }

    /// Load (or sharpen) the thumbnail for a cover `side` points wide. A smaller one already showing stays up
    /// until the sharper one lands, so a zoom never flashes blank.
    func ensureImage(side: CGFloat) {
        guard let id = model?.localIdentifier else {
            imageView.image = nil
            loadedID = nil
            return
        }
        if loadedID == id, loadedSide >= side * 0.95 { return }
        if loadedID != id { imageView.image = nil; loadedSide = 0 }
        loading?.cancel()
        loading = Task { @MainActor [weak self] in
            let raw = await AssetPosterLoader.poster(localIdentifier: id, pointSize: CGSize(width: side, height: side))
            // Decode off main before it's shown — otherwise the first frame that draws it decodes on main.
            let img = await raw?.byPreparingForDisplay() ?? raw
            guard let self, !Task.isCancelled, self.model?.localIdentifier == id, let img else { return }
            self.imageView.image = img
            self.loadedID = id
            self.loadedSide = side
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let b = contentView.bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageView.frame = b
        details.frame = b
        // Tiny covers (the year mosaic, or mid-zoom toward it) are just pictures.
        let detailed = b.width >= 60
        details.isHidden = !detailed
        if detailed {
            shade.frame = CGRect(x: 0, y: b.midY, width: b.width, height: b.height / 2)
            var x: CGFloat = 4
            for pill in [reelBadge, sendBadge, peakBadge] where !pill.isHidden {
                let s = pill.intrinsicContentSize
                pill.frame = CGRect(x: x, y: 4, width: min(s.width, b.width - x - 4), height: s.height)
                x += s.width + 3
            }
            var right = b.width - 5
            for icon in [multiView, heartView] where !icon.isHidden {
                let s = icon.intrinsicContentSize
                icon.frame = CGRect(x: right - s.width, y: 5, width: s.width, height: s.height)
                right -= s.width + 3
            }
            let ds = durationLabel.isHidden ? .zero : durationLabel.intrinsicContentSize
            durationLabel.frame = CGRect(x: b.width - 5 - ds.width, y: b.height - 5 - ds.height, width: ds.width, height: ds.height)
            let th = ceil(titleLabel.font.lineHeight)
            let tw = max(0, b.width - 10 - (ds.width > 0 ? ds.width + 4 : 0))
            titleLabel.frame = CGRect(x: 5, y: b.height - 5 - th, width: tw, height: th)
        }
        let m: CGFloat = b.width >= 60 ? 20 : 14
        mark.frame = CGRect(x: b.width - m - 4, y: b.height - m - 4, width: m, height: m)
        CATransaction.commit()
    }
}

/// A small capsule label (badges, video length).
final class ClipGridPill: UILabel {
    private var radius: CGFloat?

    func style(font: UIFont, fg: UIColor, bg: UIColor, radius: CGFloat?) {
        self.font = font
        textColor = fg
        backgroundColor = bg
        self.radius = radius
        layer.masksToBounds = true
        textAlignment = .center
    }

    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return text?.isEmpty == false ? CGSize(width: s.width + 8, height: s.height + 2) : .zero
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = radius ?? bounds.height / 2
    }
}

/// Select mode's circle: empty, or brand-filled with a check.
final class ClipGridSelectMark: UIView {
    private let check = UIImageView(image: UIImage(systemName: "checkmark",
                                                   withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .heavy)))
    var isOn = false {
        didSet {
            backgroundColor = isOn ? UIColor(SnappetColor.brand) : UIColor.black.withAlphaComponent(0.3)
            check.isHidden = !isOn
            accessibilityIdentifier = isOn ? "clips.grid.selected" : "clips.grid.unselected"
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.borderColor = UIColor.white.cgColor
        layer.borderWidth = 1.5
        check.tintColor = .white
        check.contentMode = .center
        addSubview(check)
        isUserInteractionEnabled = false
        isOn = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.width / 2
        check.frame = bounds
    }
}

// MARK: - Year mosaic labels

/// The year mosaic's header for a month: "2026 · 412 clips · 96 sessions" above the first month of each year,
/// then the small month label ("OCT").
final class ClipGridYearLabelView: UICollectionReusableView {
    private let yearLabel = UILabel()
    private let summaryLabel = UILabel()
    private let monthLabel = UILabel()
    private var showsYear = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(SnappetColor.paper)
        yearLabel.font = .systemFont(ofSize: 24, weight: .heavy)
        yearLabel.textColor = UIColor(SnappetColor.ink)
        yearLabel.accessibilityIdentifier = "clips.grid.year"
        summaryLabel.font = .systemFont(ofSize: 11, weight: .medium)
        summaryLabel.textColor = UIColor(SnappetColor.textSecondary)
        monthLabel.font = .systemFont(ofSize: 10, weight: .bold)
        monthLabel.textColor = UIColor(SnappetColor.textSecondary)
        for l in [yearLabel, summaryLabel, monthLabel] { addSubview(l) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(month: String, year: ClipGridModel.Year?) {
        monthLabel.attributedText = NSAttributedString(string: month, attributes: [.kern: 0.6])
        showsYear = year != nil
        yearLabel.text = year?.title
        summaryLabel.text = year?.summary
        yearLabel.isHidden = !showsYear
        summaryLabel.isHidden = !showsYear
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let b = bounds
        let labelH = ClipGridZoomLayout.monthLabelHeight
        monthLabel.frame = CGRect(x: 4, y: b.height - labelH + 4, width: b.width - 8, height: labelH - 6)
        if showsYear {
            let ys = yearLabel.intrinsicContentSize
            yearLabel.frame = CGRect(x: 10, y: 12, width: ys.width, height: ys.height)
            let ss = summaryLabel.intrinsicContentSize
            summaryLabel.frame = CGRect(x: yearLabel.frame.maxX + 8, y: yearLabel.frame.maxY - ss.height - 4,
                                        width: max(0, b.width - yearLabel.frame.maxX - 18), height: ss.height)
        }
    }
}
