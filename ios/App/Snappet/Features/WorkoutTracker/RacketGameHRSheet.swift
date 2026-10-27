import SwiftUI
import Charts
import HighlightEngine

/// Which game the sheet opens on (prompt 203 follow-up, 2026-10-26).
struct RacketGameTarget: Identifiable, Hashable {
    let exerciseID: UUID
    let index: Int
    var id: String { "\(exerciseID)-\(index)" }
}

/// **Heart rate for one game** (wireframe `docs/ux-research/racket-sports/game-hr/`): the game's HR line coloured by
/// zone with the peak marked, the previous game dashed behind it, avg / peak / time in Z5 (+ HRV with a chest
/// strap), the zone split, a one-line comparison, and an honest note when the readings are sparse (a Health
/// back-fill from a wrist band). Swipe between the match's games. Opened from the recap rows and the game tiles.
struct RacketGameHRSheet: View {
    let session: WorkoutSession
    let exerciseID: UUID
    let maxHR: Double
    @State var index: Int

    @Environment(\.dismiss) private var dismiss

    init(session: WorkoutSession, target: RacketGameTarget, maxHR: Double) {
        self.session = session
        self.exerciseID = target.exerciseID
        self.maxHR = maxHR
        _index = State(initialValue: target.index)
    }

    private var ex: SessionExercise? { session.exercises.first { $0.id == exerciseID } }

    var body: some View {
        NavigationStack {
            if let ex {
                let games = RacketStats.games(ex, series: session.hrSeries, sessionStart: session.startedAt, maxHR: maxHR)
                TabView(selection: $index) {
                    ForEach(Array(games.enumerated()), id: \.element.id) { pos, g in
                        page(ex, g, previous: pos > 0 ? games[pos - 1] : nil)
                            .tag(g.index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: games.count > 1 ? .always : .never))
                .indexViewStyle(.page(backgroundDisplayMode: .always))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }.accessibilityIdentifier("racket.gameHR.done")
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .presentationDetents([.large])
        .accessibilityIdentifier("racket.gameHR")
    }

    // MARK: - One page

    private func page(_ ex: SessionExercise, _ g: RacketStats.GameHR, previous: RacketStats.GameHR?) -> some View {
        let unit = ex.racketFormat.sport.unit
        let score = g.index < ex.sets.count ? ex.sets[g.index].racketScore?.label : nil
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(unit.noun.capitalized) \(g.index + 1)\(score.map { " · \($0)" } ?? "")")
                        .font(.title2.weight(.heavy))
                    Text([RacketStats.matchRowTitle(ex), Self.clock(g.duration)].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if g.points.isEmpty {
                    Label("No heart rate for this \(unit.noun)", systemImage: "heart.slash")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 160)
                } else {
                    chart(g, previous: previous)
                    if previous != nil, !(previous?.points.isEmpty ?? true) {
                        HStack(spacing: 14) {
                            legend(dashed: false, "this \(unit.noun)")
                            legend(dashed: true, "\(unit.noun) \(previous!.index + 1)")
                        }
                        .font(.caption2).foregroundStyle(.secondary)
                    }
                    kpis(g)
                    zoneBar(g.zoneSeconds)
                    if let line = RacketStats.comparison(g, previous: previous, unit: unit) {
                        callout(line, tint: .orange).accessibilityIdentifier("racket.gameHR.compare")
                    }
                    if g.isSparse {
                        callout("A reading about every \(Int((g.medianGap ?? 0).rounded())) s (from Apple Health) — each dot is a real reading, and a peak between two of them can be missed.",
                                tint: .blue)
                            .accessibilityIdentifier("racket.gameHR.sparse")
                    }
                }
                Spacer(minLength: 30)
            }
            .padding(.horizontal)
        }
    }

    // MARK: - Chart

    private func chart(_ g: RacketStats.GameHR, previous: RacketStats.GameHR?) -> some View {
        let ghost = previous?.points ?? []
        let all = g.points.map(\.bpm) + ghost.map(\.bpm)
        let lo = (all.min() ?? 100) - 6, hi = (all.max() ?? 180) + 12
        let peak = g.points.max { $0.bpm < $1.bpm }
        let duration = g.duration
        return Chart {
            ForEach([4, 5], id: \.self) { z in
                // Z4 = 80–90 % of max, Z5 = 90 %+ (`HeartRateZone.forBpm`).
                let a = max(lo, (z == 4 ? 0.8 : 0.9) * maxHR), b = min(hi, z == 4 ? 0.9 * maxHR : hi)
                if a < b {
                    RectangleMark(yStart: .value("lo", a), yEnd: .value("hi", b))
                        .foregroundStyle((HeartRateZone(rawValue: z)?.color ?? .gray).opacity(0.08))
                }
            }
            // The previous game, stretched to this game's length so the two read side by side.
            ForEach(Array(ghost.enumerated()), id: \.offset) { _, p in
                LineMark(x: .value("t", p.t / max(1, previous?.duration ?? 1) * duration), y: .value("bpm", p.bpm),
                         series: .value("game", "previous"))
                    .foregroundStyle(.gray.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1.3, dash: [3, 3]))
            }
            // This game: each segment takes the zone colour of its higher end.
            ForEach(Array(zip(g.points, g.points.dropFirst()).enumerated()), id: \.offset) { i, pair in
                let c = HeartRateZone.forBpm(max(pair.0.bpm, pair.1.bpm), maxHR: maxHR).color
                LineMark(x: .value("t", pair.0.t), y: .value("bpm", pair.0.bpm), series: .value("seg", i))
                    .foregroundStyle(c).lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round))
                LineMark(x: .value("t", pair.1.t), y: .value("bpm", pair.1.bpm), series: .value("seg", i))
                    .foregroundStyle(c).lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round))
            }
            if g.isSparse {
                ForEach(Array(g.points.enumerated()), id: \.offset) { _, p in
                    PointMark(x: .value("t", p.t), y: .value("bpm", p.bpm))
                        .foregroundStyle(HeartRateZone.forBpm(p.bpm, maxHR: maxHR).color).symbolSize(28)
                }
            }
            if let peak {
                PointMark(x: .value("t", peak.t), y: .value("bpm", peak.bpm))
                    .symbol(.circle).symbolSize(70).foregroundStyle(.clear)
                    .annotation(position: .top, spacing: 2) {
                        Text("\(Int(peak.bpm.rounded()))").font(.caption2.weight(.heavy))
                    }
            }
        }
        .chartYScale(domain: lo...hi)
        .chartXScale(domain: 0...duration)
        .chartXAxis {
            AxisMarks(values: [0, duration / 2, duration]) { v in
                AxisGridLine()
                AxisValueLabel { Text(Self.clock(v.as(Double.self) ?? 0)) }
            }
        }
        .frame(height: 190)
        .accessibilityIdentifier("racket.gameHR.chart")
    }

    private func legend(dashed: Bool, _ text: String) -> some View {
        HStack(spacing: 5) {
            Path { p in p.move(to: .init(x: 0, y: 1)); p.addLine(to: .init(x: 16, y: 1)) }
                .stroke(dashed ? Color.gray : .orange, style: StrokeStyle(lineWidth: dashed ? 1.4 : 2.4, dash: dashed ? [3, 3] : []))
                .frame(width: 16, height: 2)
            Text(text)
        }
    }

    // MARK: - Numbers

    private func kpis(_ g: RacketStats.GameHR) -> some View {
        HStack(spacing: 8) {
            kpi(g.avg.map { "\(Int($0.rounded()))" } ?? "—", "avg")
            kpi(g.peak.map { "\(Int($0.rounded()))" } ?? "—", "peak")
            kpi(Self.clock(g.zoneSeconds[4]), "in Z5 (max)")
            if let rmssd = g.hrv.rmssd {
                kpi("\(Int(rmssd.rounded())) ms", "HRV", tint: HRVBadge.recoveryColor(rmssd))
                    .accessibilityIdentifier("racket.gameHR.hrv")
            }
        }
    }

    private func kpi(_ value: String, _ label: String, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.title3.weight(.heavy).monospacedDigit()).foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private func zoneBar(_ seconds: [Double]) -> some View {
        let total = max(1, seconds.reduce(0, +))
        return GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(0..<5, id: \.self) { z in
                    Rectangle().fill(HeartRateZone(rawValue: z + 1)?.color ?? .gray)
                        .frame(width: geo.size.width * seconds[z] / total)
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 9)
    }

    private func callout(_ text: String, tint: Color) -> some View {
        Text(text).font(.footnote)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tint.opacity(0.3)))
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return "\(s / 60):\(String(format: "%02d", s % 60))"
    }
}
