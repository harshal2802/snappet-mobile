import SwiftUI
import SwiftData
import UIKit

// MARK: - Recap Feed — ShareComposer (F4)
//
// Renders a card to a shareable image on-device (ImageRenderer — works without a device, no Photos),
// at an exact aspect so there's no crop surprise, then hands it to the OS share sheet and appends a
// FeedShareEvent (channel "export:*"). The "Animate" HR-overlay CLIP path is iOS-device-only
// (ReelExporter + AVFoundation + Photos) and is surfaced honestly as a device-burn follow-on.

enum ShareAspect: String, CaseIterable, Identifiable {
    case r916 = "9:16", r45 = "4:5", r11 = "1:1"
    var id: String { rawValue }
    var size: CGSize {
        switch self {
        case .r916: return CGSize(width: 360, height: 640)
        case .r45:  return CGSize(width: 360, height: 450)
        case .r11:  return CGSize(width: 360, height: 360)
        }
    }
}

enum ShareTemplateKind: String, CaseIterable, Identifiable {
    case card = "Send Card", receipt = "Receipt"
    var id: String { rawValue }
}

private struct ShareImage: Identifiable { let id = UUID(); let image: UIImage }

struct ShareComposerView: View {
    let card: FeedCard

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var aspect: ShareAspect = .r916
    @State private var template: ShareTemplateKind
    @State private var shareImage: ShareImage?

    init(card: FeedCard) {
        self.card = card
        // Pre-select the card's suggested template (F4 / F6 hand-off): sessionReceipt → Receipt, else Send Card.
        _template = State(initialValue: card.shareHint == .sessionReceipt ? .receipt : .card)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                ScrollView {
                    ShareCardView(card: card, template: template, aspect: aspect)
                        .frame(width: aspect.size.width * 0.62, height: aspect.size.height * 0.62)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .shadow(radius: 14, y: 6)
                        .padding(.vertical, 12)
                }

                Picker("Template", selection: $template) {
                    ForEach(ShareTemplateKind.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).padding(.horizontal)

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

                Label("Animate (HR-overlay clip) — needs a real device + Photos", systemImage: "wand.and.stars")
                    .font(.caption).foregroundStyle(SnappetColor.textSecondary).padding(.bottom, 8)
            }
            .background(SnappetColor.paper)
            .navigationTitle("Share")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .sheet(item: $shareImage) { ShareSheet(items: [$0.image]) }
        }
    }

    @MainActor private func share() {
        let view = ShareCardView(card: card, template: template, aspect: aspect)
            .frame(width: aspect.size.width, height: aspect.size.height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        guard let image = renderer.uiImage else { return }
        shareImage = ShareImage(image: image)
        if !card.contentId.isEmpty {
            context.insert(FeedShareEvent(activityContentId: card.contentId, channel: "export:share"))
            try? context.save()
        }
    }
}

// MARK: - The exported card layout

struct ShareCardView: View {
    let card: FeedCard
    var template: ShareTemplateKind = .card
    var aspect: ShareAspect = .r916

    var body: some View {
        let s = spec
        ZStack {
            RadialGradient(colors: [s.accent.opacity(0.85), Color.black], center: .top, startRadius: 0, endRadius: aspect.size.height)
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
        }
    }
}
