import SwiftUI
import SwiftData

/// Leaf components for the Quick Session **full-screen pager** (prompt 109): the Liquid-Glass
/// chrome (rail, glass panels), the plan segments + editor, the current-effort hero pieces
/// (steppers, outcome grid, rest ring), the ghost ledger + history drawer, and the exercise-scoped
/// media shelf. All stateless value views (plus two small self-seeded input cards) — the host
/// `FreeformPlayerView` owns session state and mutations and passes closures down.

// MARK: - Glass chrome

/// The pager's glass-panel treatment: ultra-thin material, continuous corners, hairline stroke.
/// One modifier so every panel reads as the same kit (the wireframes' `--glass` token).
struct PagerGlassPanel: ViewModifier {
    var cornerRadius: CGFloat = 22
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial,
                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }
}

extension View {
    func pagerGlass(cornerRadius: CGFloat = 22) -> some View {
        modifier(PagerGlassPanel(cornerRadius: cornerRadius))
    }
}

// MARK: - Exercise rail (the page indicator)

/// The tappable exercise rail under the glass nav — the pager's page indicator. Chips come from
/// the pure `QuickSessionPager.railChips`; the host supplies each chip's discipline tint. Scrolls
/// horizontally when the session outgrows the width, keeping the current chip visible.
struct PagerRailView: View {
    let chips: [QuickSessionPager.RailChip]
    let current: QuickSessionPager.Page
    /// Discipline accent per chip (wayfinding); the overview/add chips use the neutral default.
    let tint: (QuickSessionPager.RailChip) -> Color
    let onTap: (QuickSessionPager.Page) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(chips.enumerated()), id: \.element.id) { index, chip in
                        railChip(chip, index: index)
                    }
                }
                .padding(.horizontal, 16)
            }
            .onChange(of: current) { _, page in
                withAnimation { proxy.scrollTo(page, anchor: .center) }
            }
        }
    }

    @ViewBuilder
    private func railChip(_ chip: QuickSessionPager.RailChip, index: Int) -> some View {
        let isCurrent = chip.page == current
        let accent = tint(chip)
        Button { onTap(chip.page) } label: {
            HStack(spacing: 5) {
                Image(systemName: chip.done ? "checkmark" : chip.symbol)
                    .font(.system(size: 10, weight: .bold))
                Text(chip.title).font(.caption.weight(.bold)).lineLimit(1)
                if let detail = chip.detail {
                    Text(detail)
                        .font(.system(size: 9, weight: .heavy)).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 7)
            .foregroundStyle(chip.done ? SnappetColor.perfFresh
                             : isCurrent ? SnappetColor.ink : SnappetColor.textSecondary)
            .background(
                Capsule().fill(isCurrent ? accent.opacity(0.18) : Color.white.opacity(0.05)))
            .overlay(Capsule().strokeBorder(
                isCurrent ? accent.opacity(0.5) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .id(chip.page)
        .accessibilityIdentifier("freeform.rail.\(index)")
        .accessibilityLabel("\(chip.title) page")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

// MARK: - Plan segments + editor

/// The plan-progress segment bar: one capsule per planned set (done → filled, current → outlined).
/// Renders nothing without a plan (the label alone carries the open-ended count).
struct PlanSegmentsView: View {
    let done: Int
    let planned: Int
    var accent: Color = SnappetColor.workout

    var body: some View {
        HStack(spacing: 4) {
            // Cap the row at 12 segments so a silly plan can't wrap the header.
            ForEach(0..<min(planned, 12), id: \.self) { i in
                RoundedRectangle(cornerRadius: 3)
                    .fill(i < done ? accent : accent.opacity(i == done ? 0.45 : 0.15))
                    .frame(width: 20, height: 6)
                    .overlay(RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(i == done ? accent : .clear, lineWidth: 1))
            }
        }
        .accessibilityHidden(true)
    }
}

/// The tiny plan-editor sheet: a big ± stepper, quick chips (last time · no plan), one Save.
struct PlanEditorSheet: View {
    let noun: String
    let initial: Int?
    /// Last session's set count for this exercise — the suggested default chip. `nil` ⇒ no chip.
    let lastTime: Int?
    let onSave: (Int?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var count: Int

    init(noun: String, initial: Int?, lastTime: Int?, onSave: @escaping (Int?) -> Void) {
        self.noun = noun
        self.initial = initial
        self.lastTime = lastTime
        self.onSave = onSave
        _count = State(initialValue: initial ?? lastTime ?? 3)
    }

    var body: some View {
        VStack(spacing: 16) {
            Capsule().fill(.secondary.opacity(0.4)).frame(width: 38, height: 5).padding(.top, 8)
            Text("Planned \(noun)s").font(.headline)
            Text("Optional — drives the progress bar and the done nudge.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 24) {
                stepButton("minus") { count = max(1, count - 1) }
                    .accessibilityIdentifier("freeform.planMinus")
                Text("\(count)")
                    .font(.system(size: 54, weight: .bold, design: .rounded)).monospacedDigit()
                    .frame(minWidth: 80)
                    .accessibilityIdentifier("freeform.planValue")
                stepButton("plus") { count = min(30, count + 1) }
                    .accessibilityIdentifier("freeform.planPlus")
            }
            HStack(spacing: 8) {
                if let lastTime {
                    chip("\(lastTime) · last time", emphasized: true) { count = lastTime }
                }
                chip("No plan") { onSave(nil); dismiss() }
                    .accessibilityIdentifier("freeform.planNone")
            }
            Button {
                onSave(count)
                dismiss()
            } label: {
                Text("Set plan").font(.headline).frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .tint(SnappetColor.brand)
            .accessibilityIdentifier("freeform.planSave")
            .padding(.horizontal)
        }
        .padding(.bottom, 20)
        .presentationDetents([.height(320)])
    }

    private func stepButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "\(symbol).circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(SnappetColor.ink.opacity(0.85))
        }
        .buttonStyle(.plain)
    }

    private func chip(_ text: String, emphasized: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(.caption.weight(.bold))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(emphasized ? SnappetColor.workout.opacity(0.16) : SnappetColor.surfaceMuted,
                            in: Capsule())
                .foregroundStyle(emphasized ? SnappetColor.workout : SnappetColor.ink)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Hero steppers (strength / current set)

/// One glass stepper card: a big value with ± tap targets. Custom leaf buttons (not `Stepper`) so
/// each control keeps its queryable id — the pager successor of the list player's `QuickAddRow`.
struct HeroStepperCard: View {
    let caption: String
    let value: String
    let idBase: String
    let onMinus: () -> Void
    let onPlus: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(caption.uppercased())
                    .font(.system(size: 10, weight: .heavy)).tracking(1.2)
                    .foregroundStyle(SnappetColor.textSecondary)
                Text(value)
                    .font(.system(size: 32, weight: .bold, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
                    .accessibilityIdentifier(idBase)
            }
            Spacer()
            HStack(spacing: 10) {
                heroStepButton("minus", action: onMinus)
                    .accessibilityIdentifier("\(idBase).minus")
                    .accessibilityLabel("Decrease \(caption.lowercased())")
                heroStepButton("plus", action: onPlus)
                    .accessibilityIdentifier("\(idBase).plus")
                    .accessibilityLabel("Increase \(caption.lowercased())")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .pagerGlass()
    }

    private func heroStepButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 42, height: 42)
                .background(.white.opacity(0.08), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }
}

/// The strength page's current-set hero: reps + weight steppers seeded from the last set / the
/// cross-session prefill, the single coral Log CTA, and the orthogonal Time-this-set. Its own
/// `@State` (the host re-seeds by `.id(ex.id + sets.count)`) so tweak-and-log loops stay
/// keyboard-free — the pager successor of `QuickAddRow`, same accessibility ids.
struct StrengthHeroCard: View {
    let setLabel: String
    let hint: String?
    let onLog: (SetLog) -> Void
    let onTime: (Int, Double, WeightUnit) -> Void
    let onLogDifferent: () -> Void

    @State private var reps: Int
    @State private var weight: Double
    @State private var unitSel: WeightUnit

    init(setLabel: String, reps: Int, weight: Double, unit: WeightUnit, hint: String?,
         onLog: @escaping (SetLog) -> Void,
         onTime: @escaping (Int, Double, WeightUnit) -> Void,
         onLogDifferent: @escaping () -> Void) {
        self.setLabel = setLabel
        self.hint = hint
        self.onLog = onLog
        self.onTime = onTime
        self.onLogDifferent = onLogDifferent
        _reps = State(initialValue: max(0, reps))
        _weight = State(initialValue: max(0, weight))
        _unitSel = State(initialValue: unit)
    }

    var body: some View {
        VStack(spacing: 10) {
            Text(setLabel.uppercased())
                .font(.system(size: 11, weight: .heavy)).tracking(1.4)
                .foregroundStyle(SnappetColor.textSecondary)
            HeroStepperCard(caption: "Reps", value: "\(reps)", idBase: "freeform.quickReps",
                            onMinus: { reps = max(0, reps - 1) },
                            onPlus: { reps = min(999, reps + 1) })
            HeroStepperCard(caption: "Weight",
                            value: weight > 0
                                ? "\(SetMeasure.formatWeight(weight)) \(unitSel.display)" : "Body",
                            idBase: "freeform.quickWeight",
                            onMinus: { weight = max(0, weight - 2.5) },
                            onPlus: { weight = min(2000, weight + 2.5) })
            if let hint {
                Text(hint).font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("lastTimeHint")
            }
            Button {
                onLog(SetLog(actualReps: reps > 0 ? reps : nil,
                             actualWeight: weight > 0 ? weight : nil,
                             weightUnit: unitSel))
            } label: {
                Label("Log set", systemImage: "bolt.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            .tint(SnappetColor.brand)
            .accessibilityIdentifier("freeform.quickLog")
            HStack(spacing: 8) {
                ghostAction("Time this set", symbol: "stopwatch") { onTime(reps, weight, unitSel) }
                    .accessibilityIdentifier("freeform.timeThisSet")
                ghostAction("Log different", symbol: "plus.circle") { onLogDifferent() }
                    .accessibilityIdentifier("freeform.addSet")
            }
        }
    }

    private func ghostAction(_ title: String, symbol: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 42)
        }
        .buttonStyle(.plain)
        .pagerGlass(cornerRadius: 14)
    }
}

// MARK: - Climb outcome grid

/// The climb page's always-visible outcome buttons — the next attempt is one thumb-tap. Send is
/// the emphasized outcome (perfFresh = state, not wayfinding); the labels are type-aware via
/// `ClimbType.statusLabel`. Same `freeform.outcome.<status>` ids as the old inline strip.
struct OutcomeGridView: View {
    let type: ClimbType
    let onOutcome: (KilterAscentStatus) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(KilterAscentStatus.allCases, id: \.self) { status in
                Button { onOutcome(status) } label: {
                    Text(type.statusLabel(status))
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.plain)
                .foregroundStyle(status == .sent ? SnappetColor.perfFresh : SnappetColor.ink)
                .background(
                    (status == .sent ? SnappetColor.perfFresh.opacity(0.14) : Color.white.opacity(0.06)),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(status == .sent ? SnappetColor.perfFresh.opacity(0.4)
                                                  : .white.opacity(0.1)))
                .accessibilityIdentifier("freeform.outcome.\(status.rawValue)")
            }
        }
    }
}

// MARK: - Rest hero

/// After a log, the strength/timed hero morphs into the remembered rest count-down (the Phase-7
/// timer promoted from the command bar): a ring, ± nudges, Skip, and the prefilled next-set line.
struct RestHeroView: View {
    let remaining: TimeInterval
    let total: TimeInterval
    let done: Bool
    let nextUpText: String?
    let onMinus: () -> Void
    let onPlus: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().stroke(.white.opacity(0.1), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: total > 0 ? max(0, min(1, remaining / total)) : 0)
                    .stroke(SnappetColor.perfFresh, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.3), value: remaining)
                VStack(spacing: 2) {
                    Text(done ? "Done" : SetMeasure.formatDuration(remaining))
                        .font(.system(size: 38, weight: .bold, design: .rounded)).monospacedDigit()
                        .contentTransition(.numericText())
                        .accessibilityIdentifier("freeform.restTimer")
                    Text(done ? "GO" : "REST · of \(SetMeasure.formatDuration(total))")
                        .font(.system(size: 10, weight: .heavy)).tracking(1.2)
                        .foregroundStyle(SnappetColor.textSecondary)
                }
            }
            .frame(width: 150, height: 150)
            HStack(spacing: 8) {
                restAction("−30s") { onMinus() }
                    .accessibilityIdentifier("freeform.restMinus")
                restAction("Skip rest") { onSkip() }
                    .accessibilityIdentifier("freeform.restDismiss")
                restAction("+30s") { onPlus() }
                    .accessibilityIdentifier("freeform.restPlus")
            }
            if let nextUpText {
                Text(nextUpText).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func restAction(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 40)
        }
        .buttonStyle(.plain)
        .pagerGlass(cornerRadius: 13)
    }
}

// MARK: - Ghost ledger + history drawer

/// The quiet one-line record of this exercise's previous efforts: compact chips, oldest→newest,
/// never a table. Each chip keeps the `freeform.setRow` id (the tests' per-set anchor); tapping
/// the header's "History ›" opens the full drawer.
struct GhostLedgerView: View {
    struct Item: Identifiable {
        let id: Int
        let text: String
        let done: Bool
    }
    let title: String
    let items: [Item]
    let onHistory: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onHistory) {
                HStack {
                    Text(title.uppercased())
                        .font(.system(size: 10, weight: .heavy)).tracking(1.2)
                    Spacer()
                    Text("History ›").font(.caption.weight(.semibold))
                }
                .foregroundStyle(SnappetColor.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("freeform.history")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(items) { item in
                        HStack(spacing: 4) {
                            if item.done {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9, weight: .heavy))
                                    .foregroundStyle(SnappetColor.perfFresh)
                            }
                            Text(item.text)
                                .font(.caption.weight(.semibold)).monospacedDigit()
                                .foregroundStyle(SnappetColor.textSecondary)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.white.opacity(0.045),
                                    in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .accessibilityIdentifier("freeform.setRow")
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }
}

/// The pull-up history drawer: the full ledger with per-set deltas vs the previous session,
/// swipe-to-delete, and the aggregate line — all the density the expanding cards had, opt-in.
struct HistoryDrawerView: View {
    struct Row: Identifiable {
        let id: Int
        let summary: String
        let delta: QuickSessionPager.SetDelta?
    }
    let exerciseName: String
    let rows: [Row]
    let aggregate: String?
    let hasComparison: Bool
    let onDelete: (IndexSet) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if rows.isEmpty {
                    Text("Nothing logged yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(rows) { row in
                        HStack(spacing: 10) {
                            Text("\(row.id + 1)")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                .frame(width: 22, alignment: .leading)
                            Text(row.summary).font(.body.weight(.medium)).monospacedDigit()
                            Spacer()
                            if let delta = row.delta {
                                Text(delta.label)
                                    .font(.caption.weight(.bold)).monospacedDigit()
                                    .foregroundStyle(deltaColor(delta.direction))
                            }
                        }
                        .accessibilityIdentifier("freeform.historyRow")
                    }
                    .onDelete(perform: onDelete)
                }
                if let aggregate {
                    Text(aggregate).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(exerciseName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if hasComparison {
                    ToolbarItem(placement: .topBarLeading) {
                        Text("vs last time").font(.caption).foregroundStyle(.secondary)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("freeform.historyDone")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func deltaColor(_ direction: QuickSessionPager.DeltaDirection) -> Color {
        switch direction {
        case .up:   return SnappetColor.perfFresh
        case .down: return SnappetColor.perfHard
        case .same: return SnappetColor.textSecondary
        }
    }
}

// MARK: - Media shelf (exercise-scoped)

/// The page's media shelf: every clip/photo assigned to THIS exercise (any set, or the exercise
/// as a whole), one horizontal row of thumbnails tagged with the effort they belong to. The
/// exercise-scoped analogue of the per-set `SetMediaStrip` (same thumb, same deep-tap lifecycle
/// menu); renders nothing when the exercise has no media, so clean pages stay clean.
struct ExerciseMediaShelf: View {
    let session: WorkoutSession
    let exerciseID: UUID
    /// The effort noun for the set tag ("set 2" / "attempt 3" / "leg 1").
    let noun: String
    var onEdit: ((SessionMedia) -> Void)? = nil
    var moveTargets: [ClipMoveTarget] = []
    var moveTargetsLabel: String = "Move to attempt…"
    var onReassign: ((SessionMedia, UUID?, Int?) -> Void)? = nil
    var onRequestDelete: ((SessionMedia) -> Void)? = nil

    @Query private var media: [SessionMedia]

    init(session: WorkoutSession, exerciseID: UUID, noun: String,
         onEdit: ((SessionMedia) -> Void)? = nil,
         moveTargets: [ClipMoveTarget] = [],
         moveTargetsLabel: String = "Move to attempt…",
         onReassign: ((SessionMedia, UUID?, Int?) -> Void)? = nil,
         onRequestDelete: ((SessionMedia) -> Void)? = nil) {
        self.session = session
        self.exerciseID = exerciseID
        self.noun = noun
        self.onEdit = onEdit
        self.moveTargets = moveTargets
        self.moveTargetsLabel = moveTargetsLabel
        self.onReassign = onReassign
        self.onRequestDelete = onRequestDelete
        let sid = session.id
        let exID: UUID? = exerciseID
        _media = Query(filter: #Predicate<SessionMedia> {
            $0.sessionID == sid && $0.assignedExerciseID == exID
        }, sort: \SessionMedia.offsetSec, order: .forward)
    }

    var body: some View {
        if !media.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Media · \(media.count)")
                    .font(.system(size: 10, weight: .heavy)).tracking(1.2)
                    .foregroundStyle(SnappetColor.textSecondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(media) { clip in
                            VStack(spacing: 3) {
                                Group {
                                    if clip.kind == .video, let onEdit {
                                        Button { onEdit(clip) } label: { SessionMediaThumb(item: clip) }
                                            .buttonStyle(.plain)
                                            .accessibilityIdentifier("freeform.editClip")
                                    } else {
                                        SessionMediaThumb(item: clip)
                                    }
                                }
                                .modifier(ClipContextMenu(
                                    clip: clip, enabled: onReassign != nil || onRequestDelete != nil,
                                    moveTargets: moveTargets, moveTargetsLabel: moveTargetsLabel,
                                    onReassign: onReassign, onRequestDelete: onRequestDelete))
                                Text(clip.assignedSetIndex.map { "\(noun) \($0 + 1)" } ?? "general")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(SnappetColor.textSecondary)
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
        }
    }
}

// MARK: - Add-exercise page

/// The pager's last page: type-first entry, one card per discipline. The cards keep the
/// empty-state hero's `freeform.card*` ids and call the same mutators the add menu drives.
struct AddExercisePage: View {
    let onLifting: () -> Void
    let onClimbing: () -> Void
    let onRunning: () -> Void
    let onTimed: () -> Void
    let onDance: () -> Void
    let onOther: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Add to this session")
                    .font(.title2.bold())
                    .padding(.top, 12)
                typeCard("Lifting", subtitle: "Pick from library · reps × weight",
                         discipline: .strength, id: "freeform.cardLifting",
                         accLabel: "Start lifting", action: onLifting)
                typeCard("Climbing", subtitle: "Boulder / route · grade · gym",
                         discipline: .climb, id: "freeform.cardClimbing",
                         accLabel: "Start climbing", action: onClimbing)
                typeCard("Running", subtitle: "Distance + time legs",
                         discipline: .run, id: "freeform.cardRunning",
                         accLabel: "Start a run", action: onRunning)
                typeCard("Timed", subtitle: "Stopwatch · Tabata · EMOM",
                         discipline: .timed, id: "freeform.cardTimed",
                         accLabel: "Start a timed exercise", action: onTimed)
                typeCard("Dance", subtitle: "Open effort on the clock",
                         discipline: .dance, id: "freeform.cardDance",
                         accLabel: "Start a dance session", action: onDance)
                typeCard("Other", subtitle: "Anything else, timed",
                         discipline: .other, id: "freeform.cardOther",
                         accLabel: "Start another activity", action: onOther)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
    }

    private func typeCard(_ title: String, subtitle: String, discipline: WorkoutDiscipline,
                          id: String, accLabel: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: discipline.symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(discipline.accent)
                    .frame(width: 42, height: 42)
                    .background(discipline.accent.opacity(0.14),
                                in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.subheadline.weight(.bold)).foregroundStyle(SnappetColor.ink)
                    Text(subtitle).font(.caption).foregroundStyle(SnappetColor.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pagerGlass(cornerRadius: 20)
        .accessibilityIdentifier(id)
        .accessibilityLabel(accLabel)
    }
}

// MARK: - Guide drawer

/// The ⓘ drawer: the exercise's guide photos (prompt 108 pack — renders nothing when the pack
/// isn't installed or has no photos for this exercise) + the how-to steps, form check without
/// leaving the set.
struct GuideDrawer: View {
    let exercise: Exercise
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    GuidePhotoStrip(exerciseId: exercise.id)
                    if exercise.instructions.isEmpty {
                        Text("No guide steps for this exercise.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(exercise.instructions.enumerated()), id: \.offset) { idx, step in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("\(idx + 1)").font(.caption.bold())
                                    .foregroundStyle(SnappetColor.workout)
                                Text(step).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .navigationTitle(exercise.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("freeform.guideDone")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Plan-complete nudge

/// Shown in place of the input hero once the plan is met: the perfFresh summary + a coral
/// advance CTA, with the extra-set escape hatch one tap away.
struct PlanCompleteNudge: View {
    let headline: String
    let sublabel: String?
    /// "Next: Squat →" (advance) or "Finish workout" when nothing is left.
    let nextTitle: String
    let onNext: () -> Void
    let onExtraSet: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Label(headline, systemImage: "checkmark.seal.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(SnappetColor.perfFresh)
                if let sublabel {
                    Text(sublabel).font(.caption).foregroundStyle(SnappetColor.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(SnappetColor.perfFresh.opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(SnappetColor.perfFresh.opacity(0.3)))
            Button(action: onNext) {
                Text(nextTitle).font(.headline).frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .tint(SnappetColor.brand)
            .accessibilityIdentifier("freeform.nudgeNext")
            Button(action: onExtraSet) {
                Label("1 extra set", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 40)
            }
            .buttonStyle(.plain)
            .pagerGlass(cornerRadius: 13)
            .accessibilityIdentifier("freeform.nudgeExtra")
        }
    }
}
