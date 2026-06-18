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
    /// The route's hold/tape colour, picked next to the grade; optional (`nil` ⇒ untagged).
    @State private var color: ClimbColor?
    @State private var name: String = ""
    @State private var gym: String = ""
    /// The wall within the gym — free text, suggested per-gym (a gym has many walls).
    @State private var wall: String = ""
    @State private var showMore = false

    /// The last ~5 grades picked per scale, surfaced as a one-tap chip rail. Keyed per scale so the V
    /// rail and the YDS rail don't bleed into each other. Persisted in `UserDefaults` (the lightweight
    /// recents-store precedent), read on appear so the warm path is two taps (recent chip → CTA).
    @State private var recentGrades: [String] = []
    /// The last ~5 gyms entered, surfaced as a one-tap chip rail under "More · gym" (Phase 7) — so a gym
    /// is one tap, never re-typed. Persisted in `UserDefaults` like the recent grades; not scale-keyed.
    @State private var recentGyms: [String] = []
    /// The walls previously logged at the CURRENTLY-selected gym, surfaced as one-tap chips (a gym has
    /// many walls). Reloaded whenever the gym changes; empty until a gym is set. Persisted per-gym.
    @State private var recentWalls: [String] = []
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

    private var trimmedGym: String? { gym.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
    private var trimmedWall: String? { wall.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }

    private var params: AddClimbParams {
        AddClimbParams(type: type, scale: scale, grade: grade, name: resolvedName,
                       gym: trimmedGym, wall: trimmedWall, color: color)
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
            recentWalls = Self.loadWalls(forGym: trimmedGym)   // walls for the inherited gym, if any
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

            colorRow
        } header: {
            Text("Grade · \(scale.label)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("addClimb.grade")
    }

    /// The climb-colour picker — a horizontal swatch rail next to the grade (the gym sets routes by hold
    /// colour). Optional: a "None" chip clears it; tapping the selected colour again also clears. The
    /// chosen colour name is mirrored on a queryable `addClimb.colorValue` ("none" when unset).
    private var colorRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Colour").font(.subheadline.weight(.medium))
                Text(color?.label ?? "None")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .accessibilityIdentifier("addClimb.colorValue")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    // "None" clear chip.
                    Button { color = nil } label: {
                        Image(systemName: "slash.circle")
                            .font(.title3)
                            .foregroundStyle(color == nil ? SnappetColor.workout : .secondary)
                            .frame(width: 30, height: 30)
                            .overlay(Circle().stroke(color == nil ? SnappetColor.workout : Color.clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("addClimb.color.none")
                    .accessibilityLabel("No colour")

                    ForEach(ClimbColor.allCases) { c in
                        Button { color = (color == c) ? nil : c } label: {
                            Circle()
                                .fill(Color(hex: c.hexValue))
                                .frame(width: 30, height: 30)
                                .overlay(
                                    Circle().stroke(Color.primary.opacity(c.needsRing ? 0.3 : 0),
                                                    lineWidth: 1))
                                .overlay(
                                    Circle().stroke(SnappetColor.workout, lineWidth: color == c ? 3 : 0)
                                        .padding(-3))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("addClimb.color.\(c.rawValue)")
                        .accessibilityLabel(c.label)
                    }
                }
                .padding(.vertical, 4)
            }
        }
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
            DisclosureGroup("More · gym · wall", isExpanded: $showMore) {
                TextField("Gym / location", text: $gym)
                    .submitLabel(.done)
                    .accessibilityIdentifier("addClimb.gym")
                    // A gym has many walls, so the wall suggestions are scoped to the gym: whenever the gym
                    // changes (typed or chip-tapped), reload that gym's previously-logged walls.
                    .onChange(of: gym) { _, _ in recentWalls = Self.loadWalls(forGym: trimmedGym) }
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

                // Wall (within the gym). Free text + a chip rail of walls previously logged AT THE
                // SELECTED GYM — so once you pick a gym, its walls are one tap (and a new wall typed here
                // becomes a future suggestion for that gym).
                TextField("Wall (optional)", text: $wall)
                    .submitLabel(.done)
                    .accessibilityIdentifier("addClimb.wall")
                if !recentWalls.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(recentWalls, id: \.self) { w in
                                chip(w, selected: w == wall.trimmingCharacters(in: .whitespacesAndNewlines)) {
                                    wall = w
                                }
                                .accessibilityIdentifier("addClimb.recentWall.\(w)")
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } else if trimmedGym != nil {
                    Text("New walls you log at this gym will show up here.")
                        .font(.caption).foregroundStyle(.secondary)
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
        if let g = params.gym {
            Self.rememberRecentGym(g)                 // remember the gym for the one-tap rail (Phase 7)
            if let w = params.wall { Self.rememberWall(w, forGym: g) }   // remember the wall PER gym
        }
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
        UserDefaults.standard.set(mergedRecents(loadRecentGyms(), adding: gym, cap: 5), forKey: recentGymsKey)
    }

    // MARK: - Per-gym wall store (a gym has many walls; suggestions are scoped to the selected gym)

    private static let gymWallsKey = "freeform.gymWalls"

    /// Pure: most-recent-first, case-insensitively de-duplicated, capped — the recents-rail order. Shared
    /// by the wall (and gym) rails so the ordering rule is one tested definition.
    static func mergedRecents(_ existing: [String], adding value: String, cap: Int) -> [String] {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return existing }
        var out = existing.filter { $0.caseInsensitiveCompare(v) != .orderedSame }
        out.insert(v, at: 0)
        return Array(out.prefix(cap))
    }

    /// Map key for a gym (trim + lowercase) so "The Front" and "the front " share their wall list.
    private static func gymKey(_ gym: String) -> String {
        gym.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func loadGymWalls() -> [String: [String]] {
        guard let data = UserDefaults.standard.data(forKey: gymWallsKey),
              let map = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
        return map
    }

    /// The walls previously logged at `gym` (most-recent-first); empty when the gym is unset/unknown.
    static func loadWalls(forGym gym: String?) -> [String] {
        guard let gym, !gymKey(gym).isEmpty else { return [] }
        return loadGymWalls()[gymKey(gym)] ?? []
    }

    /// Record `wall` under `gym` — scoped per gym, so a wall suggested for one gym never bleeds to another.
    static func rememberWall(_ wall: String, forGym gym: String) {
        let key = gymKey(gym)
        guard !key.isEmpty, !wall.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var map = loadGymWalls()
        map[key] = mergedRecents(map[key] ?? [], adding: wall, cap: 6)
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: gymWallsKey)
        }
    }
}

/// The climb identity captured by `AddClimbSheet`, handed to the player to build a `SessionExercise`.
struct AddClimbParams {
    let type: ClimbType
    let scale: GradeScale
    let grade: String
    let name: String
    let gym: String?
    let wall: String?
    let color: ClimbColor?
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
