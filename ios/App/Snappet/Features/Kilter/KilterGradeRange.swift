import SwiftUI

/// Pure geometry/snapping rules for the grade-range slider — separated so they unit-test with no UI,
/// no device (`KilterGradeRangeTests`). The slider maps thumb positions onto the catalog's ordered
/// grade scale (indices, not raw difficulties — the scale isn't necessarily contiguous).
enum KilterGradeRange {
    enum Thumb { case lo, hi }

    /// The scale index nearest a slider fraction (0…1), clamped to the scale.
    static func index(forFraction f: Double, count: Int) -> Int {
        guard count > 1 else { return 0 }
        return min(count - 1, max(0, Int((f * Double(count - 1)).rounded())))
    }

    /// The fraction (0…1) where a scale index sits, clamped to the scale.
    static func fraction(forIndex i: Int, count: Int) -> Double {
        guard count > 1 else { return 0 }
        return Double(min(max(i, 0), count - 1)) / Double(count - 1)
    }

    /// Keep a dragged (lo, hi) index pair valid (lo ≤ hi): when the thumbs cross, the dragged end
    /// pushes the other along — never the old chips' surprise where picking a min silently moved the
    /// max out from under you *after* the fact; here the push is visible mid-drag.
    static func clamp(lo: Int, hi: Int, dragging: Thumb) -> (lo: Int, hi: Int) {
        guard lo > hi else { return (lo, hi) }
        return dragging == .lo ? (lo, lo) : (hi, hi)
    }
}

/// Bottom sheet behind the browse **Grade** chip: ONE two-thumb slider over the catalog's grade
/// scale (replacing the coupled Min/Max chip pair), with a live "Show N climbs" apply so narrowing
/// is felt before committing (UX feedback "filtering was not obvious").
struct KilterGradeRangeSheet: View {
    @Binding var minGrade: Int
    @Binding var maxGrade: Int
    /// The catalog's ordered grade scale (difficulty + combined label), from `KilterCatalog.gradeScale`.
    let scale: [(difficulty: Int, label: String)]
    let format: KilterGradeFormat
    /// Live match count from the root (the bindings are the browse state, so it recounts per move).
    let count: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if scale.count > 1 {
                    GradeRangeSlider(minGrade: $minGrade, maxGrade: $maxGrade, scale: scale, format: format)
                        .padding(.top, 30)
                } else {
                    ContentUnavailableView("No grade scale", systemImage: "questionmark.circle",
                                           description: Text("The installed catalog has no grade table."))
                }
                Button { dismiss() } label: {
                    Text(count == 1 ? "Show 1 climb" : "Show \(count) climbs")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(SnappetColor.moduleAccent("kilter"))
                .accessibilityIdentifier("kilter.grade.show")
                Spacer(minLength: 0)
            }
            .padding(.horizontal)
            .navigationTitle("Grade range")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") {
                        if let lo = scale.first?.difficulty, let hi = scale.last?.difficulty {
                            minGrade = lo
                            maxGrade = hi
                        }
                    }
                    .accessibilityIdentifier("kilter.grade.reset")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("kilter.grade.done")
                }
            }
            .presentationDetents([.height(300), .medium])
        }
    }
}

/// The two-thumb slider itself: thumbs snap to grade-scale entries, their labels ride above them,
/// and the scale's ends anchor below. VoiceOver gets one adjustable element per thumb (swipe
/// up/down steps a grade) — the drag is never the only way.
struct GradeRangeSlider: View {
    @Binding var minGrade: Int
    @Binding var maxGrade: Int
    let scale: [(difficulty: Int, label: String)]
    let format: KilterGradeFormat

    private static let thumbSize: CGFloat = 26

    private var loIndex: Int { scale.firstIndex { $0.difficulty >= minGrade } ?? 0 }
    private var hiIndex: Int { scale.lastIndex { $0.difficulty <= maxGrade } ?? scale.count - 1 }

    private func displayLabel(_ index: Int) -> String {
        kilterDisplayGrade(scale[index].label, format)
    }

    var body: some View {
        GeometryReader { geo in
            let usable = max(1, geo.size.width - Self.thumbSize)
            let loX = KilterGradeRange.fraction(forIndex: loIndex, count: scale.count) * usable
            let hiX = max(loX, KilterGradeRange.fraction(forIndex: hiIndex, count: scale.count) * usable)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(.tertiarySystemFill))
                    .frame(height: 5)
                    .padding(.horizontal, Self.thumbSize / 2)
                Capsule()
                    .fill(SnappetColor.moduleAccent("kilter"))
                    .frame(width: hiX - loX + Self.thumbSize, height: 5)
                    .offset(x: loX)
                thumb(at: loX, index: loIndex, dragging: .lo, usable: usable)
                thumb(at: hiX, index: hiIndex, dragging: .hi, usable: usable)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 72)
        .overlay(alignment: .bottom) {
            HStack {
                Text(displayLabel(0))
                Spacer()
                Text(displayLabel(scale.count - 1))
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("kilter.grade.slider")
    }

    private func thumb(at x: CGFloat, index: Int, dragging: KilterGradeRange.Thumb, usable: CGFloat) -> some View {
        Circle()
            .fill(.white)
            .frame(width: Self.thumbSize, height: Self.thumbSize)
            .shadow(color: .black.opacity(0.3), radius: 4, y: 1)
            .overlay(alignment: .top) {
                Text(displayLabel(index))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(SnappetColor.moduleAccent("kilter"))
                    .fixedSize()
                    .offset(y: -22)
            }
            .offset(x: x)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let picked = KilterGradeRange.index(
                            forFraction: (value.location.x - Self.thumbSize / 2) / usable,
                            count: scale.count)
                        apply(index: picked, dragging: dragging)
                    }
            )
            .accessibilityElement()
            .accessibilityLabel(dragging == .lo ? "Minimum grade" : "Maximum grade")
            .accessibilityValue(displayLabel(index))
            .accessibilityAdjustableAction { direction in
                let step = direction == .increment ? 1 : -1
                apply(index: index + step, dragging: dragging)
            }
            .accessibilityIdentifier(dragging == .lo ? "kilter.grade.min" : "kilter.grade.max")
    }

    /// Route every thumb move (drag or VoiceOver step) through the pure clamp so lo ≤ hi always holds.
    private func apply(index raw: Int, dragging: KilterGradeRange.Thumb) {
        let bounded = min(scale.count - 1, max(0, raw))
        let pair = dragging == .lo
            ? KilterGradeRange.clamp(lo: bounded, hi: hiIndex, dragging: .lo)
            : KilterGradeRange.clamp(lo: loIndex, hi: bounded, dragging: .hi)
        let newMin = scale[pair.lo].difficulty
        let newMax = scale[pair.hi].difficulty
        if newMin != minGrade { minGrade = newMin }
        if newMax != maxGrade { maxGrade = newMax }
    }
}
