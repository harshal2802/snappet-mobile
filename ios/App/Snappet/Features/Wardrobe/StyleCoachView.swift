import SwiftUI
import SwiftData

/// The Style Coach: a chat scoped to one item, answered by `WardrobeIntelligence`
/// (Apple Intelligence when available, composer-driven heuristic floor otherwise).
/// Answers cite OWNED pieces, rendered as tappable mini-cards.
struct StyleCoachView: View {
    let item: WardrobeItem

    @Query private var allItems: [WardrobeItem]
    @Query private var wearEvents: [WearEvent]

    @State private var messages: [Message] = []
    @State private var draft = ""
    @State private var thinking = false

    struct Message: Identifiable, Equatable {
        let id = UUID()
        var isUser: Bool
        var text: String
        var suggestedItemIDs: [UUID] = []
    }

    private let questionChips = ["What goes with this?", "Is this business casual?",
                                 "What colors work?", "How should I wear this?"]

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(messages) { message in
                            bubble(message)
                        }
                        if thinking {
                            ProgressView().padding(.leading, 16)
                        }
                    }
                    .padding(.vertical, 14)
                }
                .onChange(of: messages) { _, new in
                    if let last = new.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(questionChips, id: \.self) { q in
                        Button {
                            ask(q)
                        } label: {
                            Text(q)
                                .font(.caption.weight(.bold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(SnappetColor.wardrobe.opacity(0.08), in: Capsule())
                                .overlay(Capsule().strokeBorder(SnappetColor.wardrobe.opacity(0.25)))
                                .foregroundStyle(SnappetColor.wardrobe)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 6)

            HStack(spacing: 8) {
                TextField("Ask about this item…", text: $draft)
                    .textFieldStyle(.plain)
                    .onSubmit { ask(draft) }
                    .accessibilityIdentifier("wardrobe.coach.input")
                Button {
                    ask(draft)
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(SnappetColor.wardrobe, in: Circle())
                }
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || thinking)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(SnappetColor.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(SnappetColor.hairline))
            .padding(.horizontal, 14)

            Text("Answers generated on-device · your closet never leaves this iPhone")
                .font(.system(size: 9))
                .foregroundStyle(SnappetColor.textSecondary)
                .padding(.vertical, 6)
        }
        .background(SnappetColor.paper)
        .navigationTitle("Style Coach")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func bubble(_ message: Message) -> some View {
        VStack(alignment: message.isUser ? .trailing : .leading, spacing: 8) {
            Text(message.text)
                .font(.footnote)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(message.isUser ? AnyShapeStyle(SnappetColor.wardrobe) : AnyShapeStyle(SnappetColor.surface),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(message.isUser ? .clear : SnappetColor.hairline))
                .foregroundStyle(message.isUser ? .white : SnappetColor.ink)
                .frame(maxWidth: 300, alignment: message.isUser ? .trailing : .leading)

            if !message.suggestedItemIDs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(message.suggestedItemIDs, id: \.self) { id in
                            if let cited = allItems.first(where: { $0.id == id }) {
                                NavigationLink(value: cited) {
                                    VStack(spacing: 3) {
                                        WardrobeItemTile(item: cited, height: 54)
                                            .frame(width: 80)
                                        Text(cited.name)
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(SnappetColor.textSecondary)
                                            .lineLimit(1)
                                    }
                                    .padding(6)
                                    .background(SnappetColor.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(SnappetColor.hairline))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
        .id(message.id)
        .frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)
        .padding(.horizontal, 14)
    }

    private func ask(_ question: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !thinking else { return }
        draft = ""
        messages.append(Message(isUser: true, text: q))
        thinking = true

        let stats = WearStats.byItem(wornItemIDs: wearEvents.compactMap { e in e.itemID.map { ($0, e.wornOn) } })
        let closet = allItems.filter { !$0.isArchived }.map { i in
            i.profile(wearCount: stats[i.id]?.wearCount ?? 0, lastWornAt: stats[i.id]?.lastWornAt)
        }
        let profile = item.profile(wearCount: stats[item.id]?.wearCount ?? 0,
                                   lastWornAt: stats[item.id]?.lastWornAt)
        let month = Calendar.current.component(.month, from: .now)
        let season = GarmentSeason.forMonth(month)

        Task {
            let answer = await WardrobeIntelligence.coach(
                question: q, item: profile, closet: closet,
                season: season, tempBand: .forSeason(season))
            messages.append(Message(isUser: false, text: answer.text,
                                    suggestedItemIDs: answer.suggestedItemIDs))
            thinking = false
        }
    }
}
