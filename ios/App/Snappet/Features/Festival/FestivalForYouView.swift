import SwiftUI
import SwiftData

/// The "For you" sheet (wireframe frame 8), reached from the schedule's ✨ button. Ranked, clash-free
/// suggestions to fill the gaps in your plan — the pure `SetRecommender` is the floor (it orders the
/// cards and writes each template reason); on-device Foundation Models, when available, rewrite ONLY
/// the reason line into warmer prose (`FestivalPlanIntelligence`, the E7 contract). No entitlement ⇒
/// identical cards, template reasons. Adding a ★ here reschedules reminders and drops the card.
///
/// Its own `NavigationStack` (a sheet may carry one, per the suite rule) for the title bar + Done.
struct FestivalForYouView: View {
    let lineup: FestivalLineup
    let pack: FestivalPack

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(SnappetCore.self) private var core

    @Query private var stars: [FestivalStar]
    @AppStorage(FestivalNotifications.leadStorageKey)
    private var leadMinutes = FestivalNotifications.defaultLeadMinutes

    @State private var suggestions: [SetRecommender.Suggestion] = []
    @State private var lines: [FestivalPlanIntelligence.Line] = []
    @State private var loaded = false

    private let notifications = FestivalNotifications()

    init(lineup: FestivalLineup, pack: FestivalPack) {
        self.lineup = lineup
        self.pack = pack
        let packID = lineup.packID
        _stars = Query(filter: #Predicate<FestivalStar> { $0.packID == packID })
    }

    private var starredIDs: Set<UUID> { Set(stars.map(\.setID)) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    hero
                    if loaded && suggestions.isEmpty {
                        emptyState
                    } else {
                        ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                            suggestionCard(suggestion, line: lines[safe: index])
                        }
                    }
                    leadSettingRow
                    privacyCard
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            }
            .navigationTitle("For you")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("festival.forYou.done")
                }
            }
        }
        .task {
            // Deliberate surface: this is where we ask for notification permission (never mid-scroll
            // on the schedule), so a first-time user grants it right as reminders become useful.
            notifications.requestAuthorization()
            await refresh()
            loaded = true
        }
        .onChange(of: stars.count) { _, _ in Task { await refresh() } }
    }

    // MARK: - Sections

    private var hero: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("✨ BUILT FROM HOW YOU DANCE")
                .font(.caption2.weight(.bold)).kerning(1)
                .foregroundStyle(SnappetColor.festival)
            Text(heroHeadline)
                .font(.title3.weight(.bold))
                .foregroundStyle(SnappetColor.ink)
            Text("Ranked from your own heart-rate history and the gaps in your plan"
                 + (FestivalPlanIntelligence.isIntelligenceAvailable ? " — reasons written on device." : "."))
                .font(.footnote)
                .foregroundStyle(SnappetColor.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(SnappetColor.festival.opacity(0.10), in: RoundedRectangle(cornerRadius: SnappetRadius.lg))
        .accessibilityIdentifier("festival.forYou.hero")
    }

    private var heroHeadline: String {
        switch suggestions.count {
        case 0: return "Your plan's looking full"
        case 1: return "1 set worth starring"
        default: return "\(suggestions.count) sets worth starring"
        }
    }

    private func suggestionCard(_ suggestion: SetRecommender.Suggestion,
                                line: FestivalPlanIntelligence.Line?) -> some View {
        let set = suggestion.set
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(set.artist)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(SnappetColor.ink)
                Spacer(minLength: 6)
                Text("\(set.stage) · \(FestivalSchedule.timeLabel(set.start, offsetSeconds: pack.utcOffsetSeconds))")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(SnappetColor.textSecondary)
                Button {
                    star(set)
                } label: {
                    Label("Star", systemImage: "plus")
                        .labelStyle(.iconOnly)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(SnappetColor.festival)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Star \(set.artist)")
                .accessibilityIdentifier("festival.forYou.add.\(set.artist)")
            }
            HStack(alignment: .top, spacing: 6) {
                Text(symbol(for: suggestion.reason)).font(.caption)
                Text(line?.text ?? suggestion.templateReason)
                    .font(.caption)
                    .foregroundStyle(SnappetColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    // The reason line carries the card's test id — NOT the container, which would
                    // flatten the ＋★ button out of the XCUITest tree (the highlights-P5 gotcha).
                    .accessibilityIdentifier("festival.forYou.reason.\(set.artist)")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SnappetColor.surface, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
        .overlay(RoundedRectangle(cornerRadius: SnappetRadius.md)
            .strokeBorder(SnappetColor.hairline, lineWidth: 1))
    }

    private var emptyState: some View {
        Text("Every clash-free upcoming set is already in your plan. Nice work.")
            .font(.footnote)
            .foregroundStyle(SnappetColor.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            .accessibilityIdentifier("festival.forYou.empty")
    }

    private var leadSettingRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "alarm").foregroundStyle(SnappetColor.festival)
            Text("Remind me before starred sets").font(.footnote)
            Spacer()
            Menu {
                ForEach(FestivalNotifications.leadOptions, id: \.self) { minutes in
                    Button(FestivalNotifications.leadLabel(minutes)) { setLead(minutes) }
                }
            } label: {
                Text(FestivalNotifications.leadLabel(leadMinutes))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(SnappetColor.festival)
            }
            .accessibilityIdentifier("festival.forYou.lead")
        }
        .padding(12)
        .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
    }

    private var privacyCard: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(SnappetColor.festival)
            Text("On-device only. Foundation Models write the “why” lines; the ranking is pure Snappet "
                 + "logic. Nothing about your taste leaves the phone.")
                .font(.caption2)
                .foregroundStyle(SnappetColor.textSecondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
    }

    private func symbol(for reason: SetRecommender.Reason) -> String {
        switch reason {
        case .heardBefore: return "♥"
        case .fillsGap: return "📈"
        case .sameStage: return "🚶"
        case .freshPick: return "✦"
        }
    }

    // MARK: - Actions (thin edges)

    private func refresh() async {
        let history = FestivalHistoryService.history(context: context)
        let ranked = SetRecommender.suggestions(in: pack, starred: starredIDs,
                                                 history: history, now: .now)
        suggestions = ranked
        // Show the template floor immediately, then let the on-device pass refine in place.
        lines = ranked.map { .init(text: $0.templateReason, source: .template) }
        let resolved = await FestivalPlanIntelligence.reasonLines(for: ranked)
        if resolved.count == suggestions.count { lines = resolved }
    }

    private func star(_ set: FestivalSet) {
        guard !starredIDs.contains(set.id) else { return }
        context.insert(FestivalStar(packID: lineup.packID, setID: set.id))
        core.log(module: FestivalModule.id, action: "star",
                 summary: "Starred \(set.artist) from For You")
        try? context.save()
        // Reschedule from the new plan (the @Query hasn't refreshed yet, so union explicitly).
        let plan = FestivalPlan(starredSetIDs: starredIDs.union([set.id]))
        notifications.reschedule(plan: plan, pack: pack, leadMinutes: leadMinutes)
    }

    private func setLead(_ minutes: Int) {
        leadMinutes = minutes
        notifications.reschedule(plan: FestivalPlan(starredSetIDs: starredIDs),
                                 pack: pack, leadMinutes: minutes)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
