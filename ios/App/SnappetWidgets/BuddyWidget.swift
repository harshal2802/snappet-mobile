import SwiftUI
import WidgetKit

/// Your training buddy on the Home and Lock Screen (progression P4, prompt 152; wireframe frame 11).
/// Widgets can't run RealityKit, so the buddy is a pre-rendered still for its stage and mood
/// (`BuddyStills.xcassets`, rendered from the app's 3D buddy). Reads the App-Group snapshot the app
/// publishes on every foreground / background.
struct BuddyWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: BuddyWidgetStore.kind, provider: BuddyProvider()) { entry in
            BuddyWidgetView(entry: entry)
                .containerBackground(for: .widget) { BuddyWidgetView.ground }
        }
        .configurationDisplayName("Training buddy")
        .description("Your buddy's level, mood and streak — and what's up next.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular])
    }
}

struct BuddyEntry: TimelineEntry {
    let date: Date
    let snapshot: BuddyWidgetSnapshot
    /// No snapshot published yet (never trained / app not opened since install).
    let isEmpty: Bool
}

struct BuddyProvider: TimelineProvider {
    func placeholder(in context: Context) -> BuddyEntry {
        BuddyEntry(date: .now, snapshot: .placeholder, isEmpty: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (BuddyEntry) -> Void) {
        completion(entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BuddyEntry>) -> Void) {
        // The app reloads us on every change; refresh hourly too so "up next" times stay current.
        completion(Timeline(entries: [entry()], policy: .after(.now.addingTimeInterval(3_600))))
    }

    private func entry() -> BuddyEntry {
        if let s = BuddyWidgetStore.read() { return BuddyEntry(date: .now, snapshot: s, isEmpty: false) }
        return BuddyEntry(date: .now, snapshot: .placeholder, isEmpty: true)
    }
}

struct BuddyWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: BuddyEntry
    private var s: BuddyWidgetSnapshot { entry.snapshot }

    /// The stills are rendered on this exact colour, so the buddy sits seamlessly on the widget.
    static let ground = Color(red: 0.078, green: 0.075, blue: 0.09)
    private let ember = Color(red: 1.0, green: 0.59, blue: 0.27)

    var body: some View {
        switch family {
        case .systemSmall: small
        case .systemMedium: medium
        case .accessoryCircular: circular
        default: rectangular
        }
    }

    private var still: some View {
        Image(s.imageName).resizable().scaledToFit()
            .accessibilityLabel("Your training buddy, \(s.stageTitle), \(s.mood)")
    }

    private var title: String { s.hatched ? "\(s.stageTitle) · Lv \(s.level)" : "Ready to hatch" }
    private var moodLine: String { s.paused ? "Resting" : s.mood }

    private func bar(_ height: CGFloat) -> some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.15))
                Capsule().fill(ember).frame(width: g.size.width * s.fraction)
            }
        }
        .frame(height: height)
    }

    // MARK: Home Screen

    private var small: some View {
        VStack(alignment: .leading, spacing: 3) {
            still.frame(maxWidth: .infinity).frame(height: 92)
            if entry.isEmpty {
                Text("Train to meet your buddy").font(.caption.weight(.semibold)).foregroundStyle(.white)
            } else {
                Text(title).font(.caption.weight(.heavy)).foregroundStyle(.white).lineLimit(1)
                Text(moodLine + (s.streakWeeks >= 2 ? " · 🔥\(s.streakWeeks)" : ""))
                    .font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                bar(5)
            }
        }
        .environment(\.colorScheme, .dark)
    }

    private var medium: some View {
        HStack(spacing: 12) {
            still.frame(width: 128)
            VStack(alignment: .leading, spacing: 4) {
                Text("YOUR BUDDY").font(.caption2.weight(.heavy)).foregroundStyle(.white.opacity(0.55))
                Text(entry.isEmpty ? "Train to meet your buddy" : title)
                    .font(.headline.weight(.heavy)).foregroundStyle(.white).lineLimit(1)
                if !entry.isEmpty {
                    Text(s.paused ? "Resting\(s.pausedUntil.map { " · back \($0.formatted(.dateTime.weekday(.abbreviated)))" } ?? "")"
                         : "\(s.mood) · Form \(Int((s.form * 100).rounded()))%")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(s.paused ? .cyan : s.form >= 0.45 ? .green : .yellow)
                    bar(6).padding(.vertical, 2)
                    HStack(spacing: 8) {
                        if s.streakWeeks >= 1 { Text("🔥 \(s.streakWeeks) wk") }
                        if s.freezes > 0 { Text("❄︎ \(s.freezes)") }
                    }
                    .font(.caption2.weight(.bold)).foregroundStyle(.white.opacity(0.75))
                    if let name = s.upNextName, !s.paused {
                        Text("Up next: **\(name)**" + (s.upNextStart.map { " · \($0.formatted(.relative(presentation: .named)))" } ?? "")
                             + (s.upNextXP.map { " · ≈+\($0) XP" } ?? ""))
                            .font(.caption2).foregroundStyle(.white.opacity(0.7)).lineLimit(2)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .environment(\.colorScheme, .dark)
    }

    // MARK: Lock Screen

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.isEmpty ? "Training buddy" : title).font(.headline).widgetAccentable()
            Text(entry.isEmpty ? "Train to meet it" : "\(moodLine)\(s.streakWeeks >= 1 ? " · 🔥\(s.streakWeeks)" : "")")
                .font(.caption)
            Gauge(value: s.fraction) { EmptyView() }
                .gaugeStyle(.accessoryLinearCapacity)
        }
    }

    private var circular: some View {
        Gauge(value: s.fraction) {
            Text("Lv")
        } currentValueLabel: {
            Text("\(s.level)")
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .widgetAccentable()
    }
}
