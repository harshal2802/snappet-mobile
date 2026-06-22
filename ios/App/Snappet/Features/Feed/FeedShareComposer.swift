import SwiftUI
import SwiftData
import UIKit

// MARK: - Recap Feed — ShareComposer (F4)
//
// Renders a card to a shareable image on-device (ImageRenderer — works without a device, no Photos),
// at an exact aspect so there's no crop surprise, then hands it to the OS share sheet and appends a
// FeedShareEvent (channel "export:*"). The "Animate" HR-overlay CLIP path is iOS-device-only
// (ReelExporter + AVFoundation + Photos) and is surfaced honestly as a device-burn follow-on.

// `ShareAspect` and `ShareTemplateKind` now live in the pure `ShareTemplateModel` (R3) so the
// dimension math + template gating are unit-testable without a simulator.

private struct ShareImage: Identifiable { let id = UUID(); let image: UIImage }

/// The Animate (HR-overlay clip) render state machine — idle → rendering → done/failed.
private enum AnimateState: Equatable {
    case idle, rendering
    case done(ClipExportCoordinator.Outcome)
    case failed(String)
}

struct ShareComposerView: View {
    let card: FeedCard
    /// The session snapshot to render from — present only when this card targets a session with video
    /// clips (CardDetailView builds it). `nil` ⇒ the Animate offer is hidden (no dead button).
    var clipContext: ClipExportCoordinator.Context? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(AppModel.self) private var app
    /// The user's preferred weight unit → derived `DistanceUnit` (km/mi), threaded into the shared
    /// `ShareCardSpec`/`ShareCardView` so the exported run hero honors the user's choice (one source of
    /// truth with the list/wall/story).
    @AppStorage("workoutlog.preferredUnit") private var preferredUnitRaw = WeightUnit.kg.rawValue
    private var distanceUnit: DistanceUnit { SessionRecap.distanceUnit(WeightUnit(rawValue: preferredUnitRaw) ?? .kg) }
    @State private var aspect: ShareAspect = .r9x16
    @State private var template: ShareTemplateKind
    /// The metrics shown on the card — drives BOTH the live preview and the exported image (WYSIWYG).
    /// Seeded from the card's defaults (R5); the toggle chips edit it; a template switch re-seeds it.
    @State private var visibleMetrics: Set<ShareMetric>
    @State private var shareImage: ShareImage?
    @State private var animateState: AnimateState = .idle
    @State private var animateTask: Task<Void, Never>?

    /// Only the templates this card's payload supports — no dead thumbnails (R3 gating).
    private let templates: [ShareTemplateKind]

    init(card: FeedCard, clipContext: ClipExportCoordinator.Context? = nil) {
        self.card = card
        self.clipContext = clipContext
        let eligible = ShareTemplateModel.eligibleTemplates(for: card)
        self.templates = eligible
        // Pre-select the card's suggested template (F4 / F6 hand-off) when it's eligible, else the
        // first eligible template (always at least .card).
        let hinted = eligible.first { $0.shareTemplate == card.shareHint }
        _template = State(initialValue: hinted ?? eligible.first ?? .card)
        _visibleMetrics = State(initialValue: ShareTemplateModel.defaultVisibleMetrics(for: card))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                ScrollView {
                    // The live preview IS the exported view (WYSIWYG): same `ShareCardView`, same
                    // `visibleMetrics`, only the frame scale differs.
                    ShareCardView(card: card, template: template, aspect: aspect, visibleMetrics: visibleMetrics, unit: distanceUnit)
                        .frame(width: aspect.previewSize.width * 0.62, height: aspect.previewSize.height * 0.62)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .shadow(radius: 14, y: 6)
                        .padding(.vertical, 12)
                }

                if templates.count > 1 {
                    Picker("Template", selection: $template) {
                        ForEach(templates) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).padding(.horizontal)
                    // A new template re-seeds the metric set to that card's sensible defaults so the
                    // visible set always stays valid for what the template can render.
                    .onChange(of: template) { _, _ in
                        visibleMetrics = ShareTemplateModel.defaultVisibleMetrics(for: card)
                    }
                }

                metricChips

                Picker("Aspect", selection: $aspect) {
                    ForEach(ShareAspect.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).padding(.horizontal)

                Button(action: share) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 13)
                        .foregroundStyle(.black).background(SnappetColor.brand, in: RoundedRectangle(cornerRadius: 14))
                }
                .accessibilityIdentifier("share.button")
                .padding(.horizontal)

                if let ctx = clipContext, ClipExportCoordinator.canAnimate(card) {
                    animateSection(ctx)
                }
                Color.clear.frame(height: 4)
            }
            .background(SnappetColor.paper)
            .navigationTitle("Share")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .sheet(item: $shareImage) { item in
                ShareSheet(items: [item.image]) { completed, activityType in
                    guard completed else { return }
                    appendShareEvent(activityType: activityType)
                }
            }
        }
    }

    @MainActor private func share() {
        // Render at the EXACT export pixel size (no Apple re-crop) via the thin renderer edge. Pass the
        // same `visibleMetrics` the preview used so the export is WYSIWYG.
        let view = ShareCardView(card: card, template: template, aspect: aspect, visibleMetrics: visibleMetrics, unit: distanceUnit)
        guard let image = ShareImageRenderer.render(view, aspect: aspect) else { return }
        shareImage = ShareImage(image: image)
    }

    // MARK: - Metric toggle chips (R5)

    /// A wrapping row of show/hide chips for every `ShareMetric`. Toggling a chip edits `visibleMetrics`,
    /// which drives the preview AND the export (WYSIWYG). `headline` is always kept (a card with no hero
    /// is empty), so its chip is shown selected but never removes the last anchor.
    @ViewBuilder private var metricChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ShareMetric.allCases) { metric in
                    let on = visibleMetrics.contains(metric)
                    Button {
                        toggle(metric)
                    } label: {
                        Text(metric.chipLabel)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 11).padding(.vertical, 6)
                            .foregroundStyle(on ? Color.white : SnappetColor.textSecondary)
                            .background(on ? SnappetColor.kilter : SnappetColor.surfaceMuted, in: Capsule())
                    }
                    .accessibilityIdentifier("share.metric.\(metric.rawValue)")
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.horizontal)
        }
    }

    /// Toggle a metric on/off, keeping `headline` as a non-removable anchor (a card needs its hero).
    private func toggle(_ metric: ShareMetric) {
        if metric == .headline { visibleMetrics.insert(.headline); return }
        if visibleMetrics.contains(metric) { visibleMetrics.remove(metric) }
        else { visibleMetrics.insert(metric) }
    }

    // MARK: - Animate (HR-overlay clip · R4)

    /// The Animate offer: a real render→Save button, a rendering ProgressView + Cancel, and an honest
    /// result line. Only shown when a `clipContext` is present (session with video clips).
    @ViewBuilder private func animateSection(_ ctx: ClipExportCoordinator.Context) -> some View {
        switch animateState {
        case .rendering:
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Rendering HR-overlay clip…").font(.subheadline).foregroundStyle(SnappetColor.ink)
                }
                Button("Cancel") {
                    animateTask?.cancel()
                    animateState = .idle
                }
                .font(.caption.weight(.semibold)).foregroundStyle(SnappetColor.textSecondary)
                .accessibilityIdentifier("share.animate.cancel")
            }
            .frame(maxWidth: .infinity).padding(.vertical, 11).padding(.horizontal)
        default:
            VStack(spacing: 8) {
                Button { runAnimate(ctx) } label: {
                    Label("Animate (HR-overlay clip)", systemImage: "wand.and.stars")
                        .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 11)
                        .foregroundStyle(SnappetColor.kilter)
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(SnappetColor.kilter, lineWidth: 1.2))
                }
                .accessibilityIdentifier("share.animate")
                if let result = animateResultText {
                    Text(result).font(.caption).foregroundStyle(SnappetColor.textSecondary)
                        .accessibilityIdentifier("share.animate.result")
                }
            }
            .padding(.horizontal)
        }
    }

    /// The result line for the current state (`nil` while idle / rendering).
    private var animateResultText: String? {
        switch animateState {
        case .idle, .rendering: return nil
        case .failed(let m): return m
        case .done(let outcome):
            switch outcome {
            case .saved: return "Saved to Photos"
            case .rendered(let url): return "Rendered \(url.lastPathComponent)"
            case .empty: return "No clips to animate yet."
            case .failed(let m): return m
            case .cancelled: return nil
            }
        }
    }

    private func runAnimate(_ ctx: ClipExportCoordinator.Context) {
        animateState = .rendering
        animateTask = Task {
            let outcome = await ClipExportCoordinator.animate(
                card: card, app: app, context: ctx, in: context)
            if Task.isCancelled || outcome == .cancelled {
                animateState = .idle
            } else {
                animateState = .done(outcome)
            }
        }
    }

    /// Append the F0b `FeedShareEvent` once the OS share actually completes, with the channel derived
    /// from the chosen destination (instagram / imessage / photos / generic share).
    private func appendShareEvent(activityType: String?) {
        guard !card.contentId.isEmpty else { return }
        let channel = ShareTemplateModel.shareChannel(forActivityType: activityType)
        context.insert(FeedShareEvent(activityContentId: card.contentId, channel: channel))
        try? context.save()
    }
}

// MARK: - The exported card layout

struct ShareCardView: View {
    let card: FeedCard
    var template: ShareTemplateKind = .card
    var aspect: ShareAspect = .r9x16
    /// The metrics to show — drives BOTH the live preview and the exported image (WYSIWYG). Defaults to
    /// the card's full default set so direct (test/preview) callers render everything.
    var visibleMetrics: Set<ShareMetric> = Set(ShareMetric.allCases)
    /// The user's km/mi choice, threaded from `ShareComposerView` so the run hero honors it. Defaults
    /// `.km` for direct (test/preview) callers.
    var unit: DistanceUnit = .km

    var body: some View {
        // Route the three bespoke R5 templates to their dedicated views (each renders only the visible
        // metrics over PulsePro/.snappetCard()/SnappetColor); Send Card + Receipt render inline below.
        switch template {
        case .gradePRTicket: GradePRTicketTemplate(card: card, visibleMetrics: visibleMetrics, unit: unit)
        case .boardPolaroid: BoardPolaroidTemplate(card: card, visibleMetrics: visibleMetrics, unit: unit)
        case .pyramidCard:   PyramidCardTemplate(card: card, visibleMetrics: visibleMetrics, unit: unit)
        case .card, .receipt: heroCard
        }
    }

    /// The Send Card / Receipt hero layout (R3) — a discipline gradient with the hero numeral and either
    /// one supporting line (Send Card) or the full stacked set (Receipt), each metric individually gated.
    private var heroCard: some View {
        let s = ShareCardSpec(card: card, unit: unit)
        return ZStack {
            RadialGradient(colors: [s.accent.opacity(0.85), Color.black], center: .top, startRadius: 0, endRadius: aspect.previewSize.height)
            VStack(alignment: .leading, spacing: 10) {
                if visibleMetrics.contains(.subtitle) {
                    Text(s.kick.uppercased()).font(.caption.weight(.heavy)).tracking(1.5).foregroundStyle(.white.opacity(0.85))
                }
                if visibleMetrics.contains(.headline) {
                    Text(s.hero).font(.system(size: 64, weight: .heavy, design: .rounded)).foregroundStyle(.white)
                        .minimumScaleFactor(0.4).lineLimit(2)
                }
                // The lead supporting line falls back to the hero caption — the descriptor moves some cards'
                // lead fact (e.g. "over N months", "working grade") into heroCaption, which the share would
                // otherwise drop when primaryLine is nil.
                let lead = s.primaryLine ?? s.heroCaption
                if template == .receipt {
                    if visibleMetrics.contains(.primary), !lead.isEmpty {
                        Text(lead).font(.subheadline).foregroundStyle(.white.opacity(0.92))
                    }
                    if visibleMetrics.contains(.secondary) {
                        ForEach(s.secondaryLines, id: \.self) { Text($0).font(.subheadline).foregroundStyle(.white.opacity(0.92)) }
                    }
                } else if visibleMetrics.contains(.primary), !lead.isEmpty {
                    Text(lead).font(.title3).foregroundStyle(.white.opacity(0.92))
                }
                Spacer(minLength: 0)
                if visibleMetrics.contains(.branding) {
                    Text("snappet · recap").font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.65))
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}
