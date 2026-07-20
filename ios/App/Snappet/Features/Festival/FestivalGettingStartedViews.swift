import SwiftUI

// Thin SwiftUI renderers over the pure `FestivalGettingStarted` (festival prompt 07; wireframe
// `docs/ux-research/festival/getting-started/wireframes.html`). Three surfaces:
//   • `FestivalTourView`             — the 3-card value tour shown once on first open (frames 1–4)
//   • `FestivalSetupChecklistView`   — the guided checklist that replaces the empty state (frame 5)
//   • `FestivalGettingStartedBanner` — the collapsed nudge above the schedule (frame 6)
// All use `SnappetColor.festival` (UV orchid); coral appears only on nothing here — the festival
// accent carries the primary path, per the wireframe.

// MARK: - The value tour (frames 1–4)

/// The 20-second first-run tour: a welcome cover then three teaching cards on the value loop
/// (get the lineup · star your plan · capture the night). Rendered inline as the module root while
/// `showTour` is true — no sheet, so it dodges the suite's dismiss-then-present races; finishing or
/// skipping calls `onFinish`, which flips `festival.tourSeen`. The cards teach; they don't act (the
/// checklist does the doing).
struct FestivalTourView: View {
    /// Flip `festival.tourSeen` — the tour is done (finished or skipped), never shown twice.
    var onFinish: () -> Void

    @State private var page = 0
    private let lastPage = 3

    var body: some View {
        VStack(spacing: 0) {
            if page > 0 { navBar }
            Group {
                switch page {
                case 0: cover
                case 1: getLineupCard
                case 2: starPlanCard
                default: captureCard
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(SnappetColor.paper)
        // No identifier on this container — a container id flattens the child buttons (take / skip /
        // next) out of the XCUITest tree (the highlights-P5 / prompt-04 gotcha). Ids ride the
        // interactive children; tests assert cover presence via the headline static text.
    }

    private var navBar: some View {
        HStack {
            Button { withAnimation { page -= 1 } } label: {
                Image(systemName: "chevron.left").font(.headline)
                    .foregroundStyle(SnappetColor.festival)
            }
            .accessibilityIdentifier("festival.tour.back")
            Spacer()
            Text("How it works").font(.subheadline.weight(.bold))
            Spacer()
            Button("Skip") { onFinish() }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(SnappetColor.festival)
                .accessibilityIdentifier("festival.tour.skip")
        }
        .padding(.horizontal).padding(.vertical, 10)
    }

    // Frame 1 — the welcome cover.
    private var cover: some View {
        VStack(spacing: 14) {
            Spacer()
            Text("🎪").font(.system(size: 56))
                .shadow(color: SnappetColor.festival.opacity(0.5), radius: 18, y: 8)
            VStack(spacing: 6) {
                Text("Plan it. Dance it.").font(.largeTitle.weight(.heavy))
                Text("Keep it.").font(.largeTitle.weight(.heavy))
                    .foregroundStyle(SnappetColor.festival)
            }
            .multilineTextAlignment(.center)
            Text("Your festival weekend — the lineup, your plan, and every clip — all on this iPhone.")
                .font(.subheadline)
                .foregroundStyle(SnappetColor.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            VStack(spacing: 9) {
                postureChip("wifi.slash", bold: "Works with no signal.", "Offline once a lineup's in.")
                postureChip("lock.fill", bold: "On your phone only.", "Nothing about you is uploaded.")
                postureChip("applewatch", bold: "Your heart rate", "ranks the sets that moved you.")
            }
            .padding(.horizontal, 20).padding(.top, 4)
            Spacer()
            VStack(spacing: 8) {
                Button { withAnimation { page = 1 } } label: {
                    Text("Take a quick tour").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(SnappetColor.festival)
                .controlSize(.large)
                .accessibilityIdentifier("festival.tour.take")

                Button("Skip — I'll dive in") { onFinish() }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(SnappetColor.textSecondary)
                    .accessibilityIdentifier("festival.tour.skipCover")
            }
            .padding(.horizontal, 20).padding(.bottom, 12)
        }
    }

    private func postureChip(_ symbol: String, bold: String, _ rest: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(SnappetColor.festival).frame(width: 22)
            (Text(bold).font(.caption.weight(.bold)).foregroundColor(SnappetColor.ink)
             + Text(" " + rest).font(.caption).foregroundColor(SnappetColor.textSecondary))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SnappetRadius.sm))
    }

    // Frame 2 — get the lineup.
    private var getLineupCard: some View {
        tourCard(kicker: "STEP ONE", title: "Get the lineup in", page: 1,
                 blurb: "Three ways — pick whatever you've got. It installs once and lives on your phone.",
                 cta: "Next") {
            VStack(spacing: 11) {
                optionRow("square.and.arrow.down", "Download a festival",
                          "Curated lineups — Glastonbury, Tomorrowland…")
                optionRow("camera.viewfinder", "Scan a poster",
                          "Photograph the printed schedule — read on device")
                optionRow("qrcode.viewfinder", "Scan a friend's code",
                          "They share a lineup or a day plan by QR")
            }
        }
    }

    // Frame 3 — star your plan.
    private var starPlanCard: some View {
        tourCard(kicker: "STEP TWO", title: "Star your plan", page: 2,
                 blurb: "Tap ★ on the sets you can't miss. Your stars do the rest.",
                 cta: "Next") {
            VStack(spacing: 12) {
                VStack(spacing: 0) {
                    miniSetRow("22:15", "Fred again..", starred: true)
                    Divider().overlay(SnappetColor.hairline)
                    miniSetRow("23:00", "Eric Prydz", starred: true, clash: true)
                    Divider().overlay(SnappetColor.hairline)
                    miniSetRow("23:30", "Overmono", starred: false)
                }
                .padding(.horizontal, 12).padding(.vertical, 4)
                .background(SnappetColor.surface, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
                .overlay(RoundedRectangle(cornerRadius: SnappetRadius.md)
                    .strokeBorder(SnappetColor.hairline, lineWidth: 1))
                VStack(spacing: 10) {
                    featureLine("alarm", "Reminders", "before each starred set — with a walk-time hint.")
                    featureLine("exclamationmark.triangle", "Clash alerts", "when two stars overlap.")
                    featureLine("sparkles", "For You", "fills the gaps, ranked by your history.")
                }
            }
        }
    }

    // Frame 4 — capture the night.
    private var captureCard: some View {
        tourCard(kicker: "STEP THREE", title: "Capture the night", page: 3,
                 blurb: "Tap “I'm here” when a set grabs you — the rest is automatic.",
                 cta: "Get started") {
            VStack(spacing: 12) {
                VStack(spacing: 10) {
                    featureLine("smallcircle.filled.circle", "I'm here",
                                "starts a dance session — watch HR, live on your wrist.")
                    featureLine("play.rectangle", "Every clip you film",
                                "tags itself to the artist playing.")
                    featureLine("film.stack", "Set & festival reels",
                                "build themselves from the night.")
                    featureLine("chart.bar", "A recap",
                                "ranks the artists by the heart rate they earned.")
                }
                HStack(spacing: 9) {
                    Text("NOW").font(.caption2.weight(.bold)).foregroundStyle(SnappetColor.textSecondary)
                        .frame(width: 38, alignment: .leading)
                    Text("Fred again..").font(.subheadline.weight(.semibold))
                    Spacer(minLength: 6)
                    Text("♥ 148").font(.caption2.weight(.bold)).foregroundStyle(SnappetColor.perfHard)
                    Text("▶ 3").font(.caption2.weight(.bold)).foregroundStyle(SnappetColor.perfFresh)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(SnappetColor.surface, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
                .overlay(RoundedRectangle(cornerRadius: SnappetRadius.md)
                    .strokeBorder(SnappetColor.hairline, lineWidth: 1))
            }
        }
    }

    // A teaching card's chrome: kicker + title + blurb, the art, page dots, and the advance CTA.
    private func tourCard<Art: View>(kicker: String, title: String, page: Int, blurb: String,
                                     cta: String, @ViewBuilder art: () -> Art) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text(kicker).font(.caption2.weight(.heavy)).kerning(1.2)
                    .foregroundStyle(SnappetColor.festival)
                Text(title).font(.title.weight(.heavy))
                Text(blurb).font(.subheadline).foregroundStyle(SnappetColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20).padding(.top, 4)
            Spacer(minLength: 12)
            art().padding(.horizontal, 20)
            Spacer(minLength: 12)
            dots(active: page - 1).frame(maxWidth: .infinity)
            Button { advance() } label: { Text(cta).frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).tint(SnappetColor.festival)
                .controlSize(.large)
                .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 12)
                .accessibilityIdentifier(page == lastPage ? "festival.tour.getStarted" : "festival.tour.next")
        }
    }

    private func advance() {
        if page >= lastPage { onFinish() } else { withAnimation { page += 1 } }
    }

    private func dots(active: Int) -> some View {
        HStack(spacing: 7) {
            ForEach(0..<3, id: \.self) { i in
                Capsule()
                    .fill(i == active ? SnappetColor.festival : SnappetColor.hairline)
                    .frame(width: i == active ? 20 : 7, height: 7)
            }
        }
        .padding(.bottom, 2)
    }

    private func optionRow(_ symbol: String, _ name: String, _ detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(SnappetColor.festival)
                .frame(width: 40, height: 40)
                .background(SnappetColor.festival.opacity(0.14), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption2).foregroundStyle(SnappetColor.textSecondary)
            }
            Spacer(minLength: 6)
            Image(systemName: "chevron.right").font(.subheadline.weight(.bold))
                .foregroundStyle(SnappetColor.festival)
        }
        .padding(13)
        .background(SnappetColor.surface, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
        .overlay(RoundedRectangle(cornerRadius: SnappetRadius.md)
            .strokeBorder(SnappetColor.hairline, lineWidth: 1))
    }

    private func featureLine(_ symbol: String, _ bold: String, _ rest: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: symbol).font(.subheadline).foregroundStyle(SnappetColor.festival)
                .frame(width: 34, height: 34)
                .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SnappetRadius.sm))
            (Text(bold).font(.caption.weight(.bold)).foregroundColor(SnappetColor.ink)
             + Text(" " + rest).font(.caption).foregroundColor(SnappetColor.textSecondary))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func miniSetRow(_ time: String, _ artist: String, starred: Bool, clash: Bool = false) -> some View {
        HStack(spacing: 9) {
            Text(time).font(.caption2.weight(.semibold)).foregroundStyle(SnappetColor.textSecondary)
                .frame(width: 40, alignment: .leading)
            Text(artist).font(.subheadline.weight(.semibold))
            Spacer(minLength: 6)
            if clash {
                Text("⚠︎ clash").font(.caption2.weight(.bold))
                    .foregroundStyle(SnappetColor.perfModerate)
            }
            Image(systemName: starred ? "star.fill" : "star")
                .foregroundStyle(starred ? SnappetColor.festival : SnappetColor.hairline)
        }
        .padding(.vertical, 7)
    }
}

// MARK: - The guided setup checklist (frame 5, replaces the empty state)

/// The three-step checklist that stands in for the blank empty state: add a lineup → star a few
/// sets → turn on reminders, with a progress bar. Step 1 is active; 2–3 render locked (the full
/// checklist only shows with no lineup installed, so they're always pending here). The primary CTA
/// is still "Add a lineup" — a confirmationDialog onto the three real on-ramps the root already owns
/// — so this adds orientation, not friction. "I'll explore on my own" dismisses to the plain empty
/// state.
struct FestivalSetupChecklistView: View {
    let state: FestivalGettingStarted
    /// Present the browse / poster-scan / friend's-QR add-lineup on-ramps (owned by the root).
    var onBrowse: () -> Void
    var onScanPoster: () -> Void
    var onScan: () -> Void
    /// Set `festival.gettingStartedDismissed` — fall through to the plain empty state.
    var onDismiss: () -> Void

    @State private var showingAddOptions = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Let's get you set up").font(.title2.bold()).padding(.top, 8)
                    .accessibilityIdentifier("festival.gs.checklist.title")
                Text("Three quick steps and you're ready for the weekend.")
                    .font(.subheadline).foregroundStyle(SnappetColor.textSecondary)
                    .padding(.top, 2)

                progressBar.padding(.top, 14)

                VStack(spacing: 10) {
                    stepRow(.addLineup, title: "Add your first lineup",
                            detail: "Download one, scan a poster, or scan a friend's code")
                    stepRow(.starSets, title: "Star a few sets",
                            detail: "Tap ★ on the acts you can't miss")
                    stepRow(.enableReminders, title: "Turn on set reminders",
                            detail: "A nudge before each starred set begins")
                }
                .padding(.top, 14)

                VStack(spacing: 8) {
                    Button { showingAddOptions = true } label: {
                        Text("Add a lineup").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(SnappetColor.festival)
                    .controlSize(.large)
                    .accessibilityIdentifier("festival.gs.addLineup")

                    Button("I'll explore on my own") { onDismiss() }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(SnappetColor.textSecondary)
                        .accessibilityIdentifier("festival.gs.explore")

                    Label("One tap to download · nothing leaves your phone", systemImage: "lock.fill")
                        .font(.caption2).foregroundStyle(SnappetColor.textSecondary)
                        .padding(.top, 2)
                }
                .padding(.top, 18)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // No container id (it wraps the Add-a-lineup / explore buttons) — tests assert via the
        // title static text + the button ids (the container-id-flattens-children gotcha).
        .confirmationDialog("Add a lineup", isPresented: $showingAddOptions, titleVisibility: .visible) {
            Button("Download a festival") { onBrowse() }
            Button("Scan a poster") { onScanPoster() }
            Button("Scan a friend's code") { onScan() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var progressBar: some View {
        HStack(spacing: 10) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(SnappetColor.surfaceMuted)
                    Capsule().fill(SnappetColor.festival)
                        .frame(width: max(4, geo.size.width * state.progressFraction))
                }
            }
            .frame(height: 7)
            Text("\(state.completedCount) of \(FestivalGettingStarted.Step.allCases.count)")
                .font(.caption.weight(.semibold)).foregroundStyle(SnappetColor.textSecondary)
        }
        .accessibilityIdentifier("festival.gs.progress")
    }

    private func stepRow(_ step: FestivalGettingStarted.Step, title: String, detail: String) -> some View {
        let st = state.state(step)
        return HStack(spacing: 12) {
            checkBox(step: step, state: st)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .strikethrough(st == .done, color: SnappetColor.hairline)
                    .foregroundStyle(st == .done ? SnappetColor.textSecondary : SnappetColor.ink)
                Text(detail).font(.caption2).foregroundStyle(SnappetColor.textSecondary)
            }
            Spacer(minLength: 6)
            Image(systemName: "chevron.right").font(.subheadline.weight(.bold))
                .foregroundStyle(st == .locked ? SnappetColor.hairline : SnappetColor.festival)
        }
        .padding(13)
        .background(SnappetColor.surface, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
        .overlay(RoundedRectangle(cornerRadius: SnappetRadius.md)
            .strokeBorder(st == .activeNext ? SnappetColor.festival : SnappetColor.hairline,
                          lineWidth: st == .activeNext ? 1.5 : 1))
        .accessibilityIdentifier("festival.gs.step.\(step.rawValue)")
    }

    @ViewBuilder
    private func checkBox(step: FestivalGettingStarted.Step,
                          state st: FestivalGettingStarted.StepState) -> some View {
        ZStack {
            Circle().strokeBorder(borderColor(st), lineWidth: 2).frame(width: 26, height: 26)
            if st == .done {
                Circle().fill(SnappetColor.perfFresh).frame(width: 26, height: 26)
                Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white)
            } else {
                Text("\(step.rawValue)").font(.caption.weight(.bold))
                    .foregroundStyle(st == .activeNext ? SnappetColor.festival : SnappetColor.textSecondary)
            }
        }
    }

    private func borderColor(_ st: FestivalGettingStarted.StepState) -> Color {
        switch st {
        case .done: return SnappetColor.perfFresh
        case .activeNext: return SnappetColor.festival
        case .locked: return SnappetColor.hairline
        }
    }
}

// MARK: - The collapsed schedule banner (frame 6)

/// The dismissible banner the checklist collapses to once a lineup's installed: a progress ring, a
/// next-step nudge, and a ✕. Rides above the day schedule; tapping the body deep-links to the next
/// step (reminders → the For-You sheet; the star step is right below, so its tap is inert). Vanishes
/// for good on ✕ or once all three steps are done — non-blocking, never seen twice.
struct FestivalGettingStartedBanner: View {
    let state: FestivalGettingStarted
    /// Deep-link the current next step (`nil`-safe — the banner only shows when a step is pending).
    var onTapNudge: (FestivalGettingStarted.Step) -> Void
    /// Set `festival.gettingStartedDismissed`.
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            ring
            VStack(alignment: .leading, spacing: 1) {
                Text(nudge.title).font(.caption.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("festival.gs.banner.title")
                Text(nudge.detail).font(.caption2).foregroundStyle(SnappetColor.textSecondary)
            }
            Spacer(minLength: 6)
            Button { onDismiss() } label: {
                Image(systemName: "xmark").font(.caption.weight(.bold))
                    .foregroundStyle(SnappetColor.textSecondary)
                    .padding(6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss getting started")
            .accessibilityIdentifier("festival.gs.banner.dismiss")
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(SnappetColor.festival.opacity(0.12), in: RoundedRectangle(cornerRadius: SnappetRadius.md))
        .overlay(RoundedRectangle(cornerRadius: SnappetRadius.md)
            .strokeBorder(SnappetColor.festival.opacity(0.35), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { if let next = state.nextStep { onTapNudge(next) } }
        // No container id (it wraps the ✕ button) — tests assert via `festival.gs.banner.title` +
        // the dismiss button id (the container-id-flattens-children gotcha).
    }

    private var ring: some View {
        ZStack {
            Circle().stroke(SnappetColor.festival.opacity(0.2), lineWidth: 4)
            Circle().trim(from: 0, to: max(0.02, state.progressFraction))
                .stroke(SnappetColor.festival, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(state.completedCount)/\(FestivalGettingStarted.Step.allCases.count)")
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(SnappetColor.festival)
        }
        .frame(width: 38, height: 38)
    }

    private var nudge: (title: String, detail: String) {
        switch state.nextStep {
        case .addLineup:
            return ("Add your first lineup", "Download one, scan a poster, or a friend's code")
        case .starSets, .none:
            return ("Nice — lineup's in. Next: star a few sets", "Tap ★ on the acts you can't miss")
        case .enableReminders:
            return ("Last step: turn on set reminders", "A nudge before each starred set begins")
        }
    }
}
