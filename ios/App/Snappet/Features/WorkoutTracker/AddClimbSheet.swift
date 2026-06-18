import SwiftUI

/// The **"Add a climb"** sheet (Quick Session redesign Phase 1): the climb-first entry point that
/// replaces dropping a bare `.climbAttempt` row. It captures the climb's identity ONCE — TYPE first
/// (because it drives the grade SCALE and the outcome relabels), a scale-aware DISCRETE grade rung
/// picker (never free-text — the exact-pyramid-math requirement), an optional NAME, and an optional
/// GYM under a "More" disclosure (inherited from the session's most recent climb) — then exits straight
/// into the running session where attempts log UNDERNEATH the new climb card.
///
/// Two CTAs: **"Add & log first attempt"** (prominent ember) creates the climb and asks the player to
/// auto-expand it onto its inline outcome strip; **"Add climb"** (bordered) just creates the card.
///
/// iOS-26 / XCUITest discipline (mirrors `FreeformPlayerView`): one `accessibilityIdentifier` per
/// interactive leaf — each rung pill, each recent/scale chip, the type Picker, the name/gym fields and
/// both CTAs carry their own id; the selected grade is mirrored on a queryable `addClimb.gradeValue`
/// element so a test can assert the picked rung without scraping the strip.
struct AddClimbSheet: View {
    /// The session's most recent climb gym, inherited as the default (free text, no catalog gate).
    let inheritedGym: String?
    /// Hand back the created climb's identity; `logFirstAttempt` true ⇒ auto-expand to the outcome strip.
    let onAdd: (_ params: AddClimbParams, _ logFirstAttempt: Bool) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var type: ClimbType = .boulder
    @State private var scale: GradeScale = .vScale
    @State private var grade: String = GradeScale.vScale.defaultGrade
    @State private var name: String = ""
    @State private var gym: String = ""
    @State private var showMore = false

    /// The last ~5 grades picked per scale, surfaced as a one-tap chip rail. Keyed per scale so the V
    /// rail and the YDS rail don't bleed into each other. Persisted in `UserDefaults` (the lightweight
    /// recents-store precedent), read on appear so the warm path is two taps (recent chip → CTA).
    @State private var recentGrades: [String] = []
    /// The last ~5 gyms entered, surfaced as a one-tap chip rail under "More · gym" (Phase 7) — so a gym
    /// is one tap, never re-typed. Persisted in `UserDefaults` like the recent grades; not scale-keyed.
    @State private var recentGyms: [String] = []
    /// One-shot guard so a double/triple-tapped CTA (a user mash, or XCUITest delivering the tap more
    /// than once as the sheet settles — the documented double-fire hazard) creates exactly ONE climb.
    @State private var committed = false

    /// The scale the user last toggled to **for this discipline** (boulder / route), so the V↔Font /
    /// YDS↔French choice sticks per type across sheet opens (Phase 7, task 5). One key per discipline.
    @AppStorage("addClimb.boulderScale") private var boulderScaleRaw = GradeScale.vScale.rawValue
    @AppStorage("addClimb.routeScale") private var routeScaleRaw = GradeScale.yds.rawValue

    private var resolvedName: String {
        // Empty NAME falls back to the TYPE label (e.g. "Boulder"), NOT the generic "Climbing", so a
        // mixed session reads honestly. `SetMeasure.climbName` still trims; we just supply a better blank.
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? type.label : trimmed
    }

    private var params: AddClimbParams {
        AddClimbParams(type: type, scale: scale, grade: grade, name: resolvedName,
                       gym: gym.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                typeSection
                gradeSection
                nameSection
                moreSection
                ctaSection
            }
            .navigationTitle("Add a climb")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .presentationDetents([.medium, .large])
        }
        .onAppear {
            gym = inheritedGym ?? ""
            // Restore the remembered scale for the opening discipline (boulder default), then snap the
            // grade to that scale's default so a route never opens on a V grade.
            scale = rememberedScale(for: type)
            grade = scale.defaultGrade
            recentGrades = Self.loadRecents(scale: scale)
            recentGyms = Self.loadRecentGyms()
            // Surface the gym affordance when there's a remembered gym to one-tap (recents OR inherited),
            // so the chip rail / prefilled gym is discoverable without hunting under the disclosure.
            if !recentGyms.isEmpty || (inheritedGym?.isEmpty == false) { showMore = true }
        }
    }

    /// The scale remembered for a discipline (Phase 7), falling back to the type's default if the stored
    /// raw is unknown or doesn't match the discipline (so a corrupt default can't open a boulder on YDS).
    private func rememberedScale(for type: ClimbType) -> GradeScale {
        let raw = type.isRoute ? routeScaleRaw : boulderScaleRaw
        let candidate = GradeScale(rawValue: raw) ?? type.defaultScale
        return candidate.isBoulderScale == !type.isRoute ? candidate : type.defaultScale
    }

    /// Remember the chosen scale for the current discipline so it sticks per type across opens.
    private func rememberScale(_ scale: GradeScale) {
        if type.isRoute { routeScaleRaw = scale.rawValue } else { boulderScaleRaw = scale.rawValue }
    }

    // MARK: - Sections

    private var typeSection: some View {
        Section("Type") {
            Picker("Type", selection: $type) {
                ForEach(ClimbType.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("addClimb.type")
            // Changing type restores the scale REMEMBERED for the new discipline (Phase 7) and snaps the
            // grade to that scale's default — a route can't carry a V grade. Recents re-load for the scale.
            .onChange(of: type) { _, newType in
                scale = rememberedScale(for: newType)
                grade = scale.defaultGrade
                recentGrades = Self.loadRecents(scale: scale)
            }
        }
    }

    private var gradeSection: some View {
        // Container id `addClimb.grade`; the selected label is mirrored on a queryable `addClimb.gradeValue`.
        Section {
            HStack {
                Text("Grade").font(.subheadline.weight(.medium))
                Text(grade)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(SnappetColor.workout)
                    .accessibilityIdentifier("addClimb.gradeValue")
                Spacer()
                // V/Font (or YDS/French) toggle — flips the rung labels to the companion notation and
                // re-snaps the selected grade to the same ordinal rung so the choice survives the toggle.
                Button {
                    toggleScale()
                } label: {
                    Text(scale.companion.shortLabel)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(SnappetColor.surfaceMuted, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("addClimb.scaleToggle")
                .accessibilityLabel("Switch to \(scale.companion.label)")
            }

            if !recentGrades.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(recentGrades, id: \.self) { g in
                            chip(g, selected: g == grade) { grade = g }
                                .accessibilityIdentifier("addClimb.recent.\(g)")
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            // The scale-aware rung rail: tap a rung to select it (filled when selected — a fill + bold,
            // not a hue-only cue, so it reads under Reduce Transparency / colour-blindness).
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(scale.rungs, id: \.self) { rung in
                            chip(rung, selected: rung == grade) { grade = rung }
                                .id(rung)
                                .accessibilityIdentifier("addClimb.rung.\(rung)")
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onAppear { proxy.scrollTo(grade, anchor: .center) }
                .onChange(of: grade) { _, g in withAnimation { proxy.scrollTo(g, anchor: .center) } }
            }
        } header: {
            Text("Grade · \(scale.label)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("addClimb.grade")
    }

    private var nameSection: some View {
        Section("Name (optional)") {
            TextField(type.label, text: $name)
                .submitLabel(.done)
                .accessibilityIdentifier("addClimb.name")
        }
    }

    private var moreSection: some View {
        Section {
            DisclosureGroup("More · gym", isExpanded: $showMore) {
                TextField("Gym / location", text: $gym)
                    .submitLabel(.done)
                    .accessibilityIdentifier("addClimb.gym")
                // Recent-gym chips (Phase 7): a one-tap rail of the last few gyms so a gym is never
                // re-typed. Same persisted-recents idiom as the grade rail.
                if !recentGyms.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(recentGyms, id: \.self) { g in
                                chip(g, selected: g == gym.trimmingCharacters(in: .whitespacesAndNewlines)) {
                                    gym = g
                                }
                                .accessibilityIdentifier("addClimb.recentGym.\(g)")
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    private var ctaSection: some View {
        Section {
            Button {
                commit(logFirstAttempt: true)
            } label: {
                Text("Add & log first attempt").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(SnappetColor.workout)
            .accessibilityIdentifier("addClimb.addAndLog")

            Button {
                commit(logFirstAttempt: false)
            } label: {
                Text("Add climb").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("addClimb.add")
        }
        .listRowBackground(Color.clear)
    }

    // MARK: - Controls

    private func chip(_ text: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.subheadline.weight(selected ? .bold : .regular))
                .foregroundStyle(selected ? Color.white : .primary)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(selected ? SnappetColor.workout : SnappetColor.surfaceMuted, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    /// Flip to the companion scale (V↔Font, YDS↔French) keeping the same ordinal rung so the user's
    /// pick survives the notation change (V4 → 6A+, not back to the default).
    private func toggleScale() {
        let ordinal = scale.difficulty(for: grade)
        let next = scale.companion
        scale = next
        if let i = ordinal.map({ Int($0) }), next.rungs.indices.contains(i) {
            grade = next.rungs[i]
        } else {
            grade = next.defaultGrade
        }
        recentGrades = Self.loadRecents(scale: next)
        rememberScale(next)   // the notation choice sticks per type (Phase 7)
    }

    private func commit(logFirstAttempt: Bool) {
        guard !committed else { return }   // ignore a double/triple-fired CTA → exactly one climb
        committed = true
        Self.rememberRecent(grade, scale: scale)
        if let g = params.gym { Self.rememberRecentGym(g) }   // remember the gym for the one-tap rail (Phase 7)
        onAdd(params, logFirstAttempt)
        dismiss()
    }

    // MARK: - Recent-grades store

    private static func recentsKey(_ scale: GradeScale) -> String { "freeform.recentGrades.\(scale.rawValue)" }

    private static func loadRecents(scale: GradeScale) -> [String] {
        UserDefaults.standard.stringArray(forKey: recentsKey(scale)) ?? []
    }

    /// Most-recent-first, de-duplicated, capped at 5 — the chip-rail order.
    private static func rememberRecent(_ grade: String, scale: GradeScale) {
        var recents = loadRecents(scale: scale)
        recents.removeAll { $0 == grade }
        recents.insert(grade, at: 0)
        UserDefaults.standard.set(Array(recents.prefix(5)), forKey: recentsKey(scale))
    }

    // MARK: - Recent-gyms store (Phase 7)

    private static let recentGymsKey = "freeform.recentGyms"

    private static func loadRecentGyms() -> [String] {
        UserDefaults.standard.stringArray(forKey: recentGymsKey) ?? []
    }

    /// Most-recent-first, de-duplicated (case-insensitively), capped at 5 — the gym chip-rail order.
    private static func rememberRecentGym(_ gym: String) {
        let trimmed = gym.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var recents = loadRecentGyms()
        recents.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        recents.insert(trimmed, at: 0)
        UserDefaults.standard.set(Array(recents.prefix(5)), forKey: recentGymsKey)
    }
}

/// The climb identity captured by `AddClimbSheet`, handed to the player to build a `SessionExercise`.
struct AddClimbParams {
    let type: ClimbType
    let scale: GradeScale
    let grade: String
    let name: String
    let gym: String?
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
