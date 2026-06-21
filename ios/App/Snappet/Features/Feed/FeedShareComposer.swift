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
    @State private var aspect: ShareAspect = .r9x16
    @State private var template: ShareTemplateKind
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
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                ScrollView {
                    ShareCardView(card: card, template: template, aspect: aspect)
                        .frame(width: aspect.previewSize.width * 0.62, height: aspect.previewSize.height * 0.62)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .shadow(radius: 14, y: 6)
                        .padding(.vertical, 12)
                }

                if templates.count > 1 {
                    Picker("Template", selection: $template) {
                        ForEach(templates) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).padding(.horizontal)
                }

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
        // Render at the EXACT export pixel size (no Apple re-crop) via the thin renderer edge.
        let view = ShareCardView(card: card, template: template, aspect: aspect)
        guard let image = ShareImageRenderer.render(view, aspect: aspect) else { return }
        shareImage = ShareImage(image: image)
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

    var body: some View {
        let s = spec
        ZStack {
            RadialGradient(colors: [s.accent.opacity(0.85), Color.black], center: .top, startRadius: 0, endRadius: aspect.previewSize.height)
            VStack(alignment: .leading, spacing: 10) {
                Text(s.kick.uppercased()).font(.caption.weight(.heavy)).tracking(1.5).foregroundStyle(.white.opacity(0.85))
                Text(s.hero).font(.system(size: 64, weight: .heavy, design: .rounded)).foregroundStyle(.white)
                    .minimumScaleFactor(0.4).lineLimit(2)
                if template == .receipt {
                    ForEach(s.lines, id: \.self) { Text($0).font(.subheadline).foregroundStyle(.white.opacity(0.92)) }
                } else if let first = s.lines.first {
                    Text(first).font(.title3).foregroundStyle(.white.opacity(0.92))
                }
                Spacer(minLength: 0)
                Text("snappet · recap").font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.65))
            }
            .padding(22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var spec: (kick: String, hero: String, lines: [String], accent: Color) {
        switch card.payload {
        case .climbSession(let p):
            return ("Climb session", p.hardestSendGrade ?? "—",
                    ["\(p.totalClimbs) climbs", "\(p.sends) sends", "\(p.totalAttempts) tries"], SnappetColor.kilter)
        case .workoutSession(let p):
            return ("Workout", p.distanceMeters != nil ? "Run" : "\(p.setCount) sets",
                    ["\(p.exerciseCount) exercises", "\(p.setCount) sets"], SnappetColor.workout)
        case .gradePR(let p):
            return ("New hardest ever", p.newGrade, [p.previousGrade.map { "up from \($0)" } ?? "your first peak"], SnappetColor.brand)
        case .pyramid(let p):
            return ("Grade pyramid", p.maxGrade ?? "—", ["\(p.totalSends) sends"], SnappetColor.kilter)
        case .streak(let p):
            return ("Streak", "\(p.days)", ["days in a row"], SnappetColor.kilter)
        case .liftPR(let p):
            return ("Lift PR", "\(Int(p.oneRepMaxKg.rounded())) kg", [p.exerciseName, "est. 1RM"], SnappetColor.brand)
        case .effort(let p):
            return ("Session effort", "\(p.maxBpm)", ["peak BPM", "\(p.trimp) TRIMP"], SnappetColor.performance(forZone: .max))
        case .hardestEffort(let p):
            return ("Hardest-effort send", p.grade, ["\(p.peakBpm) bpm"], SnappetColor.performance(forZone: .max))
        case .mostClimbs(let p):
            return ("Biggest session", "\(p.count)", ["climbs in one go"], SnappetColor.kilter)
        case .weeklyVolume(let p):
            return ("Weekly volume", "\(p.buckets.last?.sends ?? 0)", ["sends this week"], SnappetColor.kilter)
        case .hrTrend(let p):
            return ("HR trend", "\(p.points.last?.avgBpm ?? 0)", ["recent avg BPM"], SnappetColor.workout)
        case .onTheBoard(let p):
            return ("On the board", "\(p.litCount)", ["climbs lit"], SnappetColor.kilter)
        case .pyramidHealth(let p):
            return ("Pyramid health", p.consolidateGrade, ["consolidate this row"], SnappetColor.kilter)
        case .progression(let p):
            return ("Progression", "\(p.fromGrade) → \(p.toGrade)", ["over \(p.points.count) months"], SnappetColor.kilter)
        case .climbingLevel(let p):
            return ("Climbing level", p.level, [p.maxGrade.map { "max \($0)" } ?? "working grade"], SnappetColor.kilter)
        case .angleDist(let p):
            return ("Angles", "\(p.topAngle)°", ["\(p.slices.count) angles"], SnappetColor.kilter)
        case .periodVsLast(let p):
            return ("This period", "\(p.current)", ["sends vs \(p.previous) last"], SnappetColor.kilter)
        case .consistency(let p):
            return ("Consistency", "\(p.activeDays)", ["active days"], SnappetColor.kilter)
        case .onThisDay(let p):
            return ("On this day", p.grade ?? "—", [p.summary], SnappetColor.kilter)
        case .firstAtGrade(let p):
            return ("First at grade", p.grade, [p.climbName], SnappetColor.kilter)
        case .projectSent(let p):
            return ("Project sent", p.grade, ["after \(p.sessions) sessions", p.climbName], SnappetColor.brand)
        case .disciplineSplit(let p):
            return ("Discipline split", p.topLabel, p.slices.prefix(3).map { "\($0.label): \($0.count)" }, SnappetColor.workout)
        case .trendArrows(let p):
            return ("90-day trends", p.arrows.first.map { "\($0.improving ? "▲" : "▼")\(abs($0.deltaPct))%" } ?? "—", p.arrows.map(\.label), SnappetColor.kilter)
        case .effortEfficiency(let p):
            return ("Fitness gain", "\(p.newAvgBpm)", ["avg BPM at \(p.gradeBand)", "was \(p.oldAvgBpm)"], SnappetColor.kilter)
        case .hrvRecovery(let p):
            return ("Recovery", "\(p.rmssd)", ["RMSSD", p.note], SnappetColor.kilter)
        case .restNudge(let p):
            return ("Go gentler", "\(p.hardDays)", ["hard days", p.note], SnappetColor.kilter)
        }
    }
}
