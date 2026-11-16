import SwiftUI

// Racket on the Watch (prompt 245, issue #438 step 2): one view per board — XxWatchStart, Watch (game-by-game
// scoring), XxWatchMark, XxWatchBlock, XxWatchRest / WatchDrill, WatchBreak, WatchStillPlaying, and the stopped
// notice ("Your Watch tells you it stopped"). Thin glue: what to show comes from the phone's `RacketWatchState`,
// rings from the shared `Surface.ring(now:)`, taps go to `RacketWatchModel.tap`.

private enum RacketWatchStyle {
    /// The one accent (#8EA2FF).
    static let accent = Color(red: 0x8E / 255, green: 0xA2 / 255, blue: 0xFF / 255)
    /// "● Recording" (#FF8A7A on the boards).
    static let recording = Color(red: 1, green: 0x8A / 255, blue: 0x7A / 255)
    static let amber = Color(red: 1, green: 0.76, blue: 0.32)
    static let green = Color(red: 0.36, green: 0.84, blue: 0.55)

    /// Work accent, Rest / Break grey, Paused grey at 0.55, Done green (#438 design; the phone's `RacketTimerRing`).
    static func ring(_ tone: RacketTimerTone) -> Color {
        switch tone {
        case .work: return accent
        case .rest: return .gray
        case .restPaused: return .gray.opacity(0.55)
        case .done: return green
        }
    }
}

/// The racket face: the phone's current board, with Still playing? and the stopped notice on top.
struct RacketWatchRoot: View {
    let model: RacketWatchModel

    var body: some View {
        if let s = model.state {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                content(s, now: context.date)
            }
        }
    }

    @ViewBuilder private func content(_ s: RacketWatchState, now: Date) -> some View {
        if let notice = s.notice, model.showsNotice {
            RacketStoppedView(notice: notice) { model.dismissNotice() }
        } else if let still = s.stillPlaying {
            RacketStillPlayingView(still: still, now: now, tap: model.tap)
        } else {
            switch s.surface {
            case .start(let start): RacketStartView(state: s, start: start, deferred: model.startDeferred, tap: model.tap)
            case .scoring(let sc): RacketScoringView(state: s, scoring: sc, now: now, tap: model.tap)
            case .marks(let m): RacketMarksView(state: s, marks: m, now: now, tap: model.tap)
            case .countdown: RacketCountdownView(surface: s.surface, now: now, tap: model.tap)
            case .block(let b): RacketBlockView(surface: s.surface, block: b, now: now, tap: model.tap)
            case .rest(let r): RacketRestView(surface: s.surface, rest: r, now: now, tap: model.tap)
            case .matchBreak(let b): RacketBreakView(state: s, brk: b, now: now, tap: model.tap)
            case .ended(let e): RacketEndedView(surface: s.surface, ended: e, now: now)
            }
        }
    }
}

// MARK: - Pieces

private struct RacketRing: View {
    let display: RacketTimerDisplay
    var caption: String? = nil

    private var color: Color { RacketWatchStyle.ring(display.tone) }

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.14), lineWidth: 6)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, display.progress)))
                .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.9), value: display.progress)
            VStack(spacing: 0) {
                Text(display.word)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(color)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(RacketClock.mmss(display.seconds))
                    .font(.system(size: 34, weight: .light, design: .rounded).monospacedDigit())
                    .minimumScaleFactor(0.8)
                if let caption {
                    Text(caption).font(.system(size: 10)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
        }
        .frame(width: 124, height: 124)
        .accessibilityElement(children: .combine)
    }
}

private struct HeaderRow: View {
    let leading: String
    let trailing: String?
    var trailingColor: Color = .secondary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(leading).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 2)
            if let trailing {
                Text(trailing).font(.footnote.weight(.semibold).monospacedDigit()).foregroundStyle(trailingColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct WideButton: View {
    enum Kind { case primary, on, quiet }
    let title: String
    var kind: Kind = .primary
    var height: CGFloat = 44
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: height)
        }
        .buttonStyle(.plain)
        .foregroundStyle(kind == .primary ? Color.black : kind == .on ? RacketWatchStyle.accent : Color.white)
        .background(background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var background: Color {
        switch kind {
        case .primary: return RacketWatchStyle.accent
        case .on: return RacketWatchStyle.accent.opacity(0.2)
        case .quiet: return Color.white.opacity(0.12)
        }
    }
}

/// Stop as a red outline (#438 design). `hold` ⇒ "Hold to end match" (a long press, so a pocket brush can't end it).
private struct StopButton: View {
    let title: String
    var hold = false
    let action: () -> Void
    @State private var confirming = false

    var body: some View {
        let label = Text(title)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.red)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 40)
            .overlay(Capsule().strokeBorder(Color.red, lineWidth: 1.5))
            .contentShape(Capsule())
        if hold {
            label
                .onLongPressGesture(minimumDuration: 1.0) { action() }
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { action() }
        } else {
            Button { confirming = true } label: { label }
                .buttonStyle(.plain)
                .confirmationDialog(title + "?", isPresented: $confirming) {
                    Button(title, role: .destructive, action: action)
                } message: {
                    Text("Everything so far is saved on the phone.")
                }
        }
    }
}

private struct Footnote: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
    }
}

private struct ScoreButtons: View {
    let us: String
    let them: String
    let tap: (RacketWatchCommand) -> Void

    var body: some View {
        HStack(spacing: 8) {
            WideButton(title: "\(us) +1", height: 62) { tap(.pointUs) }
            WideButton(title: "\(them) +1", kind: .on, height: 62) { tap(.pointThem) }
        }
    }
}

// MARK: - Boards

/// XxWatchStart: "Start block 1?" / "Start game 2?".
private struct RacketStartView: View {
    let state: RacketWatchState
    let start: RacketWatchState.Start
    let deferred: Bool
    let tap: (RacketWatchCommand) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                HeaderRow(leading: state.sport, trailing: start.cameraReady ? "Camera ready" : nil,
                          trailingColor: RacketWatchStyle.green)
                Text(start.title)
                    .font(.system(size: 22, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if deferred {
                    WideButton(title: "Start", height: 52) { tap(.start) }
                    Footnote(text: "Ready when you are. You can also start on the phone.")
                } else {
                    HStack(spacing: 8) {
                        WideButton(title: "Start", height: 58) { tap(.start) }
                        WideButton(title: "Not yet", kind: .quiet, height: 58) { tap(.notYet) }
                    }
                    Footnote(text: start.footnote)
                }
            }
        }
    }
}

/// Watch / XxWatch: a game-by-game match, point by point.
private struct RacketScoringView: View {
    let state: RacketWatchState
    let scoring: RacketWatchState.Scoring
    let now: Date
    let tap: (RacketWatchCommand) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                HeaderRow(leading: scoring.score.header(unitNumber: scoring.unitNumber),
                          trailing: RacketClock.elapsed(scoring.clock.seconds(now: now)))
                if let line = scoring.matchLine { Footnote(text: line) }
                Text(scoring.score.display)
                    .font(.system(size: 44, weight: .light, design: .rounded).monospacedDigit())
                    .minimumScaleFactor(0.7)
                    .accessibilityLabel("Score \(scoring.score.display)")
                ScoreButtons(us: state.sideUs, them: state.sideThem, tap: tap)
                if let note = state.note { Footnote(text: note) }
                HStack(spacing: 8) {
                    WideButton(title: "Undo", kind: .quiet) { tap(.undo) }
                    WideButton(title: "End \(state.unitNoun)", kind: .quiet) { tap(.endUnit) }
                }
                StopButton(title: "Hold to end match", hold: true) { tap(.endMatch) }
            }
        }
    }
}

/// XxWatchMark: a match recording everything.
private struct RacketMarksView: View {
    let state: RacketWatchState
    let marks: RacketWatchState.Marks
    let now: Date
    let tap: (RacketWatchCommand) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                HeaderRow(leading: "Everything",
                          trailing: (marks.clock.running ? "● " : "Ⅱ ") + RacketClock.elapsed(marks.clock.seconds(now: now)),
                          trailingColor: marks.clock.running ? RacketWatchStyle.recording : RacketWatchStyle.amber)
                WideButton(title: "Mark", height: 64) { tap(.mark) }
                HStack(spacing: 8) {
                    WideButton(title: "New \(state.unitNoun)", kind: .quiet, height: 48) { tap(.newUnit) }
                    WideButton(title: "Break starts", kind: .quiet, height: 48) { tap(.breakStarts) }
                }
                VStack(spacing: 2) {
                    Text(marks.score.header(unitNumber: marks.unitNumber)).font(.footnote).foregroundStyle(.secondary)
                    Text(marks.score.display)
                        .font(.system(size: 30, weight: .light, design: .rounded).monospacedDigit())
                }
                ScoreButtons(us: state.sideUs, them: state.sideThem, tap: tap)
                if !marks.score.isEmpty { WideButton(title: "Undo", kind: .quiet, height: 38) { tap(.undo) } }
                StopButton(title: "Stop and split") { tap(.stopAndSplit) }
            }
        }
    }
}

/// The countdown before a block ("Your Watch taps you before it starts").
private struct RacketCountdownView: View {
    let surface: RacketWatchState.Surface
    let now: Date
    let tap: (RacketWatchCommand) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                HeaderRow(leading: "Starting soon", trailing: nil)
                if let d = surface.ring(now: now) { RacketRing(display: d) }
                WideButton(title: "+30 s", kind: .quiet) { tap(.add30) }
            }
        }
    }
}

/// XxWatchBlock.
private struct RacketBlockView: View {
    let surface: RacketWatchState.Surface
    let block: RacketWatchState.Block
    let now: Date
    let tap: (RacketWatchCommand) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                HeaderRow(leading: "Block \(block.index + 1) of \(block.blocks)",
                          trailing: block.recording ? "● Recording" : nil, trailingColor: RacketWatchStyle.recording)
                if let d = surface.ring(now: now) { RacketRing(display: d, caption: "left in this block") }
                WideButton(title: "End block", kind: .quiet) { tap(.endBlock) }
                StopButton(title: "Stop drill") { tap(.stopDrill) }
            }
        }
    }
}

/// WatchDrill / XxWatchRest.
private struct RacketRestView: View {
    let surface: RacketWatchState.Surface
    let rest: RacketWatchState.Rest
    let now: Date
    let tap: (RacketWatchCommand) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                HeaderRow(leading: "Rest", trailing: rest.autoStart ? "Auto-start on" : "Auto-start off",
                          trailingColor: rest.autoStart ? RacketWatchStyle.green : .secondary)
                if let d = surface.ring(now: now) { RacketRing(display: d) }
                if !rest.done {
                    HStack(spacing: 8) {
                        WideButton(title: rest.paused ? "Resume" : "Pause", kind: .quiet) {
                            tap(rest.paused ? .resumeTimer : .pauseTimer)
                        }
                        WideButton(title: "+30 s", kind: .quiet) { tap(.add30) }
                    }
                }
                WideButton(title: rest.done ? "Start block \(rest.after + 2)" : "Skip rest", height: 50) { tap(.skip) }
                HStack(spacing: 8) {
                    if !rest.done { WideButton(title: "+1 min", kind: .quiet) { tap(.add60) } }
                    WideButton(title: "Finish", kind: .quiet) { tap(.finishDrill) }
                }
            }
        }
    }
}

/// WatchBreak / XxWatchBreak: between games of a game-by-game match.
private struct RacketBreakView: View {
    let state: RacketWatchState
    let brk: RacketWatchState.Break
    let now: Date
    let tap: (RacketWatchCommand) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                HeaderRow(leading: "\(state.unitNoun.capitalized) \(brk.unitNumber): \(brk.unitScore)",
                          trailing: brk.paused ? "Ⅱ Paused" : nil, trailingColor: RacketWatchStyle.amber)
                if let d = state.surface.ring(now: now) { RacketRing(display: d) }
                HStack(spacing: 8) {
                    WideButton(title: brk.paused ? "Resume" : "Pause", kind: .quiet) {
                        tap(brk.paused ? .resumeTimer : .pauseTimer)
                    }
                    WideButton(title: "+30 s", kind: .quiet) { tap(.add30) }
                }
                WideButton(title: "Skip break", height: 50) { tap(.skip) }
                StopButton(title: "Hold to end match", hold: true) { tap(.endMatch) }
                Footnote(text: "No phone tap needed. Confirm the score later.")
            }
        }
    }
}

/// Recording saved / drill done / match over.
private struct RacketEndedView: View {
    let surface: RacketWatchState.Surface
    let ended: RacketWatchState.Ended
    let now: Date

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text(ended.title).font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(RacketWatchStyle.green)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Footnote(text: ended.line)
            }
        }
    }
}

/// WatchStillPlaying / XxWatchStill — the configured threshold (review5 M4).
private struct RacketStillPlayingView: View {
    let still: RacketWatchState.StillPlaying
    let now: Date
    let tap: (RacketWatchCommand) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Text("Still playing?").font(.system(size: 24, weight: .semibold))
                    .multilineTextAlignment(.center)
                Footnote(text: still.reason)
                Text(still.stopsLine(now: now))
                    .font(.system(size: 22, weight: .light, design: .rounded).monospacedDigit())
                    .foregroundStyle(RacketWatchStyle.amber)
                HStack(spacing: 8) {
                    WideButton(title: "Keep", height: 60) { tap(.keepPlaying) }
                    Button { tap(.stopRecording) } label: {
                        Text("Stop").font(.system(size: 15, weight: .semibold)).foregroundStyle(.red)
                            .frame(maxWidth: .infinity, minHeight: 60)
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color.red, lineWidth: 1.5))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// "Your Watch tells you it stopped": storage full, too hot, a call, no answer to Still playing?.
private struct RacketStoppedView: View {
    let notice: RacketWatchState.Notice
    let dismiss: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text(notice.title).font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(notice.canResume ? RacketWatchStyle.amber : .red)
                    .multilineTextAlignment(.center)
                Text(notice.reason.headline).font(.system(size: 15, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Footnote(text: notice.line)
                WideButton(title: "OK", kind: .quiet) { dismiss() }
            }
        }
    }
}
