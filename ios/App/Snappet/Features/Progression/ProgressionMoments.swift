import SwiftUI

// Progression P3 (prompt 151; wireframe frames 2–3): the full-screen level-up and growing-up moments.

extension Progression {
    enum Moment: Identifiable, Equatable, Sendable {
        case levelUp(level: Int)
        case grewUp(from: BuddyStage, to: BuddyStage, level: Int)

        var id: String {
            switch self {
            case .levelUp(let l): "level-\(l)"
            case .grewUp(_, let to, let l): "grew-\(to.rawValue)-\(l)"
            }
        }
    }

    /// The moment to celebrate after a session took you from `before` to `after`, or nil. `celebrated`
    /// is the highest level already celebrated (nil = never: your backfilled history counts as seen),
    /// so each level is celebrated once and history never triggers one.
    nonisolated static func moment(before: LevelInfo, after: LevelInfo, celebrated: Int?) -> Moment? {
        let seen = max(before.level, celebrated ?? before.level)
        guard after.level > seen else { return nil }
        let from = stage(forLevel: seen)
        return from != after.stage ? .grewUp(from: from, to: after.stage, level: after.level)
                                   : .levelUp(level: after.level)
    }
}

extension BuddyStage {
    /// What growing into this stage adds (shown on the growing-up moment).
    var unlocks: [String] {
        switch self {
        case .egg: []
        case .hatchling: ["It's out — for now it still sits in its shell"]
        case .sprout: ["An antenna that glows brighter with your Form"]
        case .adult: ["A second antenna and arms — it throws them up when you cheer it",
                      "Sparks orbit it when your Form is above 70%"]
        case .legend: ["A golden halo and a new colour", "Three orbiting sparks when you're fired up"]
        }
    }
}

/// The highest level celebrated so far (BuddyDefaults — the UI-test scratch suite under tests).
enum MomentDefaults {
    static let celebratedKey = "buddy.celebratedLevel"
}

/// Full-screen celebration: either "Level 13" or "Your buddy grew up: Sprout → Adult". One tap away.
struct ProgressionMomentView: View {
    let moment: Progression.Moment
    let form: Double
    let sessions: Int
    let totalXP: Int
    let onDone: () -> Void

    @State private var cheer = 0
    /// Growing up: switches from the old stage to the new one shortly after the moment opens.
    @State private var grown = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.13, green: 0.11, blue: 0.17), .black], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 18) {
                Spacer(minLength: 8)
                switch moment {
                case .levelUp(let level): levelUp(level)
                case .grewUp(let from, let to, let level): grewUp(from, to, level)
                }
                Spacer(minLength: 8)
                Button(action: onDone) {
                    Text(buttonTitle).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent).tint(SnappetColor.workout)
                .accessibilityIdentifier("moment.done")
            }
            .padding(24)
        }
        .environment(\.colorScheme, .dark)
        .task {
            try? await Task.sleep(for: .milliseconds(350))
            if case .grewUp = moment { try? await Task.sleep(for: .milliseconds(900)) }
            cheer += 1
            Haptics.success()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("moment")
    }

    private var buttonTitle: String {
        if case .grewUp(_, let to, _) = moment { return "Meet your \(to.title)" }
        return "Nice"
    }

    private func kicker(_ text: String) -> some View {
        Text(text).font(.subheadline.weight(.heavy)).tracking(2).foregroundStyle(SnappetColor.workout)
    }

    @ViewBuilder private func levelUp(_ level: Int) -> some View {
        let stage = Progression.stage(forLevel: level)
        BuddyCreatureView(look: BuddyLook(stage: stage, form: form), cheerTrigger: cheer)
            .frame(height: 300)
        kicker("LEVEL UP")
        Text("Level \(level)").font(.system(size: 52, weight: .black, design: .rounded)).foregroundStyle(.white)
            .accessibilityIdentifier("moment.title")
        Text("\(sessions) sessions · \(totalXP.formatted()) XP all-time").font(.subheadline).foregroundStyle(.secondary)
        if let next = Progression.nextStageLevel(after: level) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Next growth: **\(Progression.stage(forLevel: next).title)** at Level \(next)").foregroundStyle(.white)
                let from = [1, 2, 5, 10, 20].last { $0 <= level } ?? 1
                ProgressView(value: Double(level - from), total: Double(max(1, next - from))).tint(SnappetColor.workout)
                Text("\(next - level) level\(next - level == 1 ? "" : "s") to go").font(.caption).foregroundStyle(.secondary)
            }
            .padding(14)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    @ViewBuilder private func grewUp(_ from: BuddyStage, _ to: BuddyStage, _ level: Int) -> some View {
        kicker("YOUR BUDDY GREW UP")
        // One buddy that grows in front of you: the old stage first, then the new one with a cheer.
        BuddyCreatureView(look: BuddyLook(stage: grown ? to : from, form: form), cheerTrigger: cheer)
            .frame(height: 280)
            .task {
                try? await Task.sleep(for: .milliseconds(1_100))
                withAnimation { grown = true }
            }
        HStack(spacing: 8) {
            Text(from.title).foregroundStyle(.secondary)
            Image(systemName: "arrow.right").foregroundStyle(SnappetColor.workout)
            Text(to.title).foregroundStyle(.white)
        }
        .font(.subheadline.weight(.bold))
        Text(to.title).font(.system(size: 44, weight: .black, design: .rounded)).foregroundStyle(.white)
            .accessibilityIdentifier("moment.title")
        Text("Reached at Level \(level) · \(sessions) sessions").font(.subheadline).foregroundStyle(.secondary)
        if !to.unlocks.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("New").font(.headline).foregroundStyle(.white)
                ForEach(to.unlocks, id: \.self) { Text("• \($0)").font(.subheadline).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
        }
    }
}
