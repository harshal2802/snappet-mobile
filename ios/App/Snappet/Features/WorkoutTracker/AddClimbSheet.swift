import SwiftUI
import Photos

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
    /// The user's distinct previously-logged climbs (derived in `FreeformPlayerView` from history + the live
    /// session), offered as a one-tap **re-log** above Type. Empty ⇒ the section is omitted (the first-ever
    /// session; edit mode never passes any). Selecting one prefills the form via `seed(from:)`.
    var previousClimbs: [PreviousClimb] = []
    /// EDIT mode (prompt 09): when non-nil, the sheet opens PREFILLED from an existing climb and the CTA
    /// becomes a single "Save" (no "Add & log first attempt"). `nil` ⇒ the original add-a-climb flow.
    var initial: AddClimbParams? = nil
    /// Hand back the created climb's identity; `logFirstAttempt` true ⇒ auto-expand to the outcome strip.
    /// In EDIT mode `logFirstAttempt` is always false (Save just overwrites the climb's fields in place).
    let onAdd: (_ params: AddClimbParams, _ logFirstAttempt: Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    /// Photos access for the optional photo-attach control (mirrors `SetMediaStrip.ensureAccessThenPick`).
    @Environment(AppModel.self) private var app

    @State private var type: ClimbType = .boulder
    @State private var scale: GradeScale = .vScale
    @State private var grade: String = GradeScale.vScale.defaultGrade
    /// The route's hold/tape colour, picked next to the grade; optional (`nil` ⇒ untagged).
    @State private var color: ClimbColor?
    @State private var name: String = ""
    @State private var gym: String = ""
    /// The wall within the gym — free text, suggested per-gym (a gym has many walls).
    @State private var wall: String = ""
    /// The route-setter (optional) — its own section under Name. Empty ⇒ `nil` on the params.
    @State private var setter: String = ""
    @State private var showMore = false

    // MARK: - Previous-climb picker (ADD mode) state
    /// Whether the "Log a previous climb" disclosure is expanded into its searchable / filterable list.
    @State private var showPrevious = false
    @State private var previousQuery = ""
    @State private var previousScope: PreviousClimb.Scope = .all
    /// The "This gym" toggle — restricts the list to the inherited gym (only offered when one exists).
    @State private var previousThisGym = false
    /// The "Sent" toggle — restricts to climbs whose best outcome is a send.
    @State private var previousSent = false
    /// The `id` of the previous climb the form was last prefilled from (the selected cue + a test handle).
    @State private var prefilledFromPreviousID: String?
    /// One-shot guard so a re-log selection's `type` change doesn't trigger the auto grade-snap that would
    /// clobber the prefilled scale/grade (the snap is for a manual type pick; a prefill sets them exactly).
    @State private var suppressTypeSnap = false

    // MARK: - Photo attach (ADD mode) state
    /// PHAsset `localIdentifier`s of photos picked for the NEW climb (photos only). Returned on the params;
    /// the player files them as climb-level `SessionMedia` once it mints the climb's id.
    @State private var photoIdentifiers: [String] = []
    @State private var showingPhotoPicker = false

    /// The sheet opens at `.large` (still draggable down to `.medium`): the form now carries the
    /// previous-climb picker, Setter, and Photos in addition to type/grade/colour/name/gym/wall, so the
    /// full capture surface is on-screen rather than below a half-sheet fold (the approved wireframe shape).
    @State private var detent: PresentationDetent = .large

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
    /// True once `.onAppear` has finished seeding state, so the `type` `.onChange` (which snaps the grade
    /// to the scale's default) doesn't clobber an EDIT-mode prefill when `seed(from:)` flips the type.
    @State private var didSeed = false

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
    private var trimmedSetter: String? { setter.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }

    private var params: AddClimbParams {
        AddClimbParams(type: type, scale: scale, grade: grade, name: resolvedName,
                       gym: trimmedGym, wall: trimmedWall, color: color,
                       setter: trimmedSetter, photoLocalIdentifiers: photoIdentifiers)
    }

    var body: some View {
        NavigationStack {
            Form {
                if initial == nil && !previousClimbs.isEmpty { previousSection }
                typeSection
                gradeSection
                nameSection
                setterSection
                moreSection
                if initial == nil { photosSection }
            }
            // Pin the primary action(s) to the bottom: the form now carries the previous-climb picker,
            // Setter, and Photos, so an in-form bottom CTA would sit below the fold — pinning keeps "commit"
            // always visible (and reliably reachable) regardless of scroll. (prompt 81)
            .safeAreaInset(edge: .bottom) { ctaBar }
            .navigationTitle(initial == nil ? "Add a climb" : "Edit climb")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .presentationDetents([.medium, .large], selection: $detent)
        }
        .onAppear {
            if let initial {
                seed(from: initial)        // EDIT mode: prefill every field from the existing climb
            } else {
                gym = inheritedGym ?? ""
                // Restore the remembered scale for the opening discipline (boulder default), then snap the
                // grade to that scale's default so a route never opens on a V grade.
                scale = rememberedScale(for: type)
                grade = scale.defaultGrade
            }
            recentGrades = Self.loadRecents(scale: scale)
            recentGyms = Self.loadRecentGyms()
            recentWalls = Self.loadWalls(forGym: trimmedGym)   // walls for the inherited gym, if any
            // Surface the gym affordance when there's a remembered gym to one-tap (recents OR inherited OR
            // a prefilled gym in edit mode), so the chip rail / prefilled gym is discoverable.
            if !recentGyms.isEmpty || (inheritedGym?.isEmpty == false) || (trimmedGym != nil) { showMore = true }
            didSeed = true
        }
    }

    /// Prefill the sheet's state from an existing climb (EDIT mode). The grade is shown verbatim; the
    /// stored NAME is shown raw (an empty/type-label-only name renders blank so the placeholder shows and
    /// `resolvedName` re-derives the fallback on Save).
    private func seed(from p: AddClimbParams) {
        type = p.type
        scale = p.scale
        grade = p.grade
        color = p.color
        // A name equal to the bare type label (the add-flow's blank fallback) shows as empty so the
        // placeholder reads and the user can clear it; any real name is shown verbatim.
        name = (p.name == p.type.label) ? "" : p.name
        gym = p.gym ?? ""
        wall = p.wall ?? ""
        setter = p.setter ?? ""
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
                guard didSeed else { return }   // don't clobber an EDIT-mode prefill as `seed` sets the type
                // A re-log prefill sets type+scale+grade together; skip the auto-snap once so the prefilled
                // scale/grade survive (the snap is only for a MANUAL discipline switch).
                if suppressTypeSnap { suppressTypeSnap = false; return }
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

    /// The primary action(s), pinned to the sheet bottom via `.safeAreaInset` so they stay visible above a
    /// long, scrollable form (and above the keyboard). Same identifiers/behaviour as the former in-form CTA
    /// section — only relocated. ADD mode shows the two original CTAs; EDIT mode a single "Save".
    @ViewBuilder private var ctaBar: some View {
        VStack(spacing: 10) {
            if initial == nil {
                // ADD mode: the two original CTAs (prominent "Add & log first attempt" · bordered "Add climb").
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
                .tint(SnappetColor.workout)
                .accessibilityIdentifier("addClimb.add")
            } else {
                // EDIT mode (prompt 09): a single "Save" that overwrites the climb's fields in place.
                Button {
                    commit(logFirstAttempt: false)
                } label: {
                    Text("Save").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(SnappetColor.workout)
                .accessibilityIdentifier("addClimb.save")
            }
        }
        .controlSize(.large)
        .padding(.horizontal)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(.bar)
    }

    // MARK: - Setter & Photos sections (Quick Session redesign follow-up)

    private var setterSection: some View {
        Section("Setter (optional)") {
            TextField("e.g. Alex H.", text: $setter)
                .submitLabel(.done)
                .accessibilityIdentifier("addClimb.setter")
        }
    }

    /// Optional photos for a NEW climb (ADD mode only): a removable thumbnail strip + a "paperclip" attach
    /// button presenting the photos-only `MediaPicker`. Picks are kept as `localIdentifier`s and filed as
    /// climb-level `SessionMedia` by the player after it creates the climb. On the simulator (no Photos) the
    /// picker resolves nothing and thumbnails render placeholders — the affordance still reaches XCUITests.
    private var photosSection: some View {
        Section("Photos (optional)") {
            if !photoIdentifiers.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Array(photoIdentifiers.enumerated()), id: \.element) { i, lid in
                            ClimbPhotoThumb(localIdentifier: lid, side: 64)
                                .overlay(alignment: .topTrailing) {
                                    Button {
                                        photoIdentifiers.removeAll { $0 == lid }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, .black.opacity(0.55))
                                    }
                                    .buttonStyle(.plain)
                                    .padding(3)
                                    .accessibilityIdentifier("addClimb.photoRemove.\(i)")
                                }
                                .accessibilityIdentifier("addClimb.photo.\(i)")
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            Button {
                Task { await ensureAccessThenPickPhotos() }
            } label: {
                Label(photoIdentifiers.isEmpty ? "Attach photos" : "Attach more photos",
                      systemImage: "paperclip")
                    .font(.subheadline)
            }
            .accessibilityIdentifier("addClimb.attachPhoto")
        }
        .sheet(isPresented: $showingPhotoPicker) {
            MediaPicker(filter: .images) { ids in
                for id in ids where !photoIdentifiers.contains(id) { photoIdentifiers.append(id) }
            }
        }
    }

    @MainActor private func ensureAccessThenPickPhotos() async {
        if app.sessionMedia.currentStatus == .notDetermined {
            app.photoAccess = await app.sessionMedia.requestAccess()
        }
        showingPhotoPicker = true
    }

    // MARK: - "Log a previous climb" section (ADD mode only)

    /// The inherited gym normalized for the "This gym" filter; `nil` when unset.
    private var scopeGym: String? { inheritedGym?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }

    private var filteredPrevious: [PreviousClimb] {
        PreviousClimb.filtered(previousClimbs, query: previousQuery, scope: previousScope,
                               gym: previousThisGym ? scopeGym : nil, sentOnly: previousSent)
    }

    private var selectedPreviousName: String? {
        guard let id = prefilledFromPreviousID else { return nil }
        return previousClimbs.first { $0.id == id }?.params.name
    }

    /// The literal first section in ADD mode (omitted when there's no history): a disclosure that expands to
    /// a search field, the `All · Boulder · Routes · This gym · Sent` filter rail, the distinct past climbs,
    /// and an "Add a new climb instead" escape. Selecting a row prefills the whole form.
    private var previousSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showPrevious) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search your climbs", text: $previousQuery)
                        .submitLabel(.search)
                        .accessibilityIdentifier("addClimb.previousSearch")
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(PreviousClimb.Scope.allCases, id: \.self) { s in
                            chip(scopeLabel(s), selected: previousScope == s) { previousScope = s }
                                .accessibilityIdentifier("addClimb.previousFilter.\(s.rawValue)")
                        }
                        if scopeGym != nil {
                            chip("This gym", selected: previousThisGym) { previousThisGym.toggle() }
                                .accessibilityIdentifier("addClimb.previousFilter.thisGym")
                        }
                        chip("Sent", selected: previousSent) { previousSent.toggle() }
                            .accessibilityIdentifier("addClimb.previousFilter.sent")
                    }
                    .padding(.vertical, 2)
                }

                if filteredPrevious.isEmpty {
                    Text("No climbs match.").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(filteredPrevious.enumerated()), id: \.element.id) { i, pc in
                        Button { selectPrevious(pc) } label: { previousRow(pc) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("addClimb.previousRow.\(i)")
                    }
                }

                Button { startFreshClimb() } label: {
                    Label("Add a new climb instead", systemImage: "plus")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(SnappetColor.workout)
                }
                .accessibilityIdentifier("addClimb.previousNew")
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(SnappetColor.workout)
                    Text("Log a previous climb").font(.subheadline.weight(.medium))
                    Spacer(minLength: 8)
                    if let name = selectedPreviousName {
                        Text(name).font(.caption.weight(.semibold))
                            .foregroundStyle(SnappetColor.workout).lineLimit(1)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("addClimb.previousDisclosure")
                .accessibilityValue(selectedPreviousName ?? "none")
            }
        } header: {
            Text("Log a previous climb")
        }
    }

    /// One previous-climb row: a photo-preview thumb (or the type glyph) with a colour-dot + count badge,
    /// the climb name, a `gym · wall · when` subtitle, and the grade pill (amber boulder / azure route).
    private func previousRow(_ pc: PreviousClimb) -> some View {
        HStack(spacing: 11) {
            previousThumb(pc)
            VStack(alignment: .leading, spacing: 2) {
                Text(pc.params.name).font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                Text(previousSubtitle(pc)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(pc.params.grade)
                .font(.caption.weight(.bold))
                .foregroundStyle(pc.params.type.isRoute ? SnappetColor.budget : SnappetColor.kilter)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background((pc.params.type.isRoute ? SnappetColor.budget : SnappetColor.kilter).opacity(0.18),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private func previousThumb(_ pc: PreviousClimb) -> some View {
        Group {
            if let lid = pc.photoLocalIdentifier {
                ClimbPhotoThumb(localIdentifier: lid, side: 46)
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(SnappetColor.surfaceMuted)
                    .frame(width: 46, height: 46)
                    .overlay(Image(systemName: pc.params.type.symbol).foregroundStyle(.secondary))
            }
        }
        .frame(width: 46, height: 46)
        .overlay(alignment: .topTrailing) {
            if pc.photoCount > 1 {
                Text("\(pc.photoCount)")
                    .font(.caption2.weight(.bold)).foregroundStyle(.white)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(3)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let c = pc.params.color {
                Circle().fill(Color(hex: c.hexValue))
                    .frame(width: 13, height: 13)
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                    .offset(x: 3, y: 3)
            }
        }
    }

    private func previousSubtitle(_ pc: PreviousClimb) -> String {
        var parts: [String] = []
        if let g = pc.params.gym { parts.append(g) }
        if let w = pc.params.wall { parts.append(w) }
        if parts.isEmpty { parts.append(pc.params.type.label) }
        parts.append(Self.relativeWhen(pc.lastLoggedAt))
        return parts.joined(separator: " · ")
    }

    private func scopeLabel(_ s: PreviousClimb.Scope) -> String {
        switch s {
        case .all:     return "All"
        case .boulder: return "Boulder"
        case .routes:  return "Routes"
        }
    }

    /// Prefill the whole form from a previous climb and collapse the picker. The grade/scale are set
    /// exactly (the type-snap is suppressed when the discipline changes); recents reload for the new scale.
    private func selectPrevious(_ pc: PreviousClimb) {
        if pc.params.type != type { suppressTypeSnap = true }
        seed(from: pc.params)
        // A re-log adopts the previous climb's IDENTITY only — never its (or an abandoned new-climb's)
        // photos. Clear any picked photos so they don't leak onto the re-logged climb (the documented
        // "old photos/attempts are not copied" contract; mirrors startFreshClimb).
        photoIdentifiers = []
        recentGrades = Self.loadRecents(scale: scale)
        recentWalls = Self.loadWalls(forGym: trimmedGym)
        prefilledFromPreviousID = pc.id
        withAnimation { showPrevious = false }
    }

    /// "Add a new climb instead": clear a prefill back to a blank new climb (if one was selected), then
    /// collapse. If nothing was prefilled, the user's in-progress entry is left untouched — just collapse.
    private func startFreshClimb() {
        if prefilledFromPreviousID != nil {
            type = .boulder
            scale = rememberedScale(for: .boulder)
            grade = scale.defaultGrade
            color = nil; name = ""; setter = ""; gym = inheritedGym ?? ""; wall = ""
            photoIdentifiers = []
            recentGrades = Self.loadRecents(scale: scale)
            recentWalls = Self.loadWalls(forGym: trimmedGym)
            prefilledFromPreviousID = nil
        }
        withAnimation { showPrevious = false }
    }

    /// Abbreviated relative "when" for a previous-climb row (e.g. "2d ago"). Single shared formatter.
    private static let relFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated; return f
    }()
    static func relativeWhen(_ date: Date) -> String {
        relFormatter.localizedString(for: date, relativeTo: Date())
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
/// `Equatable` so the previous-climb dedup + tests can compare two captured identities cheaply.
struct AddClimbParams: Equatable {
    let type: ClimbType
    let scale: GradeScale
    let grade: String
    let name: String
    let gym: String?
    let wall: String?
    let color: ClimbColor?
    /// The route-setter's name (optional). Persisted on `SessionExercise.setter`; `nil` ⇒ unset.
    let setter: String?
    /// PHAsset `localIdentifier`s of photos the user attached to a NEW climb in the sheet. The sheet can't
    /// mint the `SessionExercise.id` to file `SessionMedia` against, so it returns the picks here and the
    /// player inserts the climb-level media after creating the climb. Empty in edit mode (section hidden).
    let photoLocalIdentifiers: [String]

    init(type: ClimbType, scale: GradeScale, grade: String, name: String,
         gym: String?, wall: String?, color: ClimbColor?,
         setter: String? = nil, photoLocalIdentifiers: [String] = []) {
        self.type = type; self.scale = scale; self.grade = grade; self.name = name
        self.gym = gym; self.wall = wall; self.color = color
        self.setter = setter; self.photoLocalIdentifiers = photoLocalIdentifiers
    }

    /// Build a prefill from an existing climb `SessionExercise` (EDIT mode, prompt 09; also the re-log
    /// prefill source). The grade falls back to the scale's default when the climb has none, and the NAME
    /// to the type label so the sheet always opens on a valid grade rung and shows the climb's identity.
    /// Photos are never copied — a re-log starts with no attachments.
    init(from ex: SessionExercise) {
        self.type = ex.climbType
        self.scale = ex.climbGradeScale
        self.grade = ex.climbGradeLabel ?? ex.climbGradeScale.defaultGrade
        self.name = ex.displayName ?? ex.climbType.label
        self.gym = ex.gym?.isEmpty == false ? ex.gym : nil
        self.wall = ex.wall?.isEmpty == false ? ex.wall : nil
        self.color = ex.climbColor
        self.setter = ex.setter?.isEmpty == false ? ex.setter : nil
        self.photoLocalIdentifiers = []
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// A small rounded thumbnail for a PHAsset `localIdentifier` — used for the photos picked for a
/// not-yet-created climb and the previous-climb row previews. Loads via `PHImageManager`, on-device only
/// (`isNetworkAccessAllowed = false`); renders a placeholder where the asset is missing (e.g. the simulator
/// has no Photos), so the affordance is always reachable. Mirrors `SessionMediaThumb`'s loader without its
/// session-offset badge (a freshly-picked / cross-session photo has no offset to show).
private struct ClimbPhotoThumb: View {
    let localIdentifier: String
    var side: CGFloat = 56
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
                    .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task(id: localIdentifier) { await load() }
    }

    private func load() async {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = assets.firstObject else { return }
        let target = CGSize(width: side * 3, height: side * 3)
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = false   // on-device only
        let loaded: UIImage? = await withCheckedContinuation { cont in
            PHImageManager.default().requestImage(for: asset, targetSize: target,
                                                  contentMode: .aspectFill, options: options) { img, _ in
                cont.resume(returning: img)
            }
        }
        if let loaded { image = loaded }
    }
}
