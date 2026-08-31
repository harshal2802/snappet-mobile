import SwiftUI
import SwiftData

/// Price paid, current price, and the ONE place a price check can be triggered (wardrobe prompt
/// 05). Deliberately a button and nothing else — no `onAppear` fetch, no refresh-on-pull, no
/// timer. The check reaches a third-party retailer, so it happens only when the user asks.
struct WardrobePurchaseSection: View {
    @Bindable var item: WardrobeItem

    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL

    @State private var isChecking = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            row("Paid", value: item.cost.map(currency) ?? "—")
            row("Current", value: currentValue) { deltaBadge }

            if !item.productURL.isEmpty {
                Button {
                    Task { await check() }
                } label: {
                    HStack(spacing: 7) {
                        if isChecking {
                            ProgressView().controlSize(.small)
                            Text("Checking…")
                        } else {
                            Image(systemName: "arrow.clockwise")
                            Text(item.currentPrice == nil ? "Check price" : "Check again")
                        }
                    }
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                }
                .buttonStyle(.bordered)
                .tint(SnappetColor.wardrobe)
                .disabled(isChecking)
                .accessibilityIdentifier("wardrobe.price.check")

                Button {
                    if let url = WardrobePriceService.validated(item.productURL) { openURL(url) }
                } label: {
                    Text(displayHost + " ↗")
                        .font(.caption2)
                        .foregroundStyle(SnappetColor.textSecondary)
                }
                .buttonStyle(.plain)
            }

            if let stamp = checkedStamp {
                Text(stamp).font(.system(size: 10.5)).foregroundStyle(SnappetColor.textSecondary)
            }
            if let failure {
                Text(failure).font(.caption2).foregroundStyle(.red)
            }
            if !item.productURL.isEmpty {
                Text("Checking opens a connection to the retailer. It only happens when you tap.")
                    .font(.system(size: 10))
                    .foregroundStyle(SnappetColor.textSecondary)
            }
        }
        .padding(12)
        .background(SnappetColor.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(SnappetColor.hairline))
    }

    // MARK: - Pieces

    // Two overloads rather than a defaulted @ViewBuilder: a default argument can't produce an
    // opaque `some View`, so the defaulted form doesn't type-check.
    private func row(_ label: String, value: String) -> some View {
        row(label, value: value) { EmptyView() }
    }

    private func row<Trailing: View>(_ label: String, value: String,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.caption).foregroundStyle(SnappetColor.textSecondary)
            Spacer()
            Text(value).font(.subheadline.weight(.semibold))
            trailing()
        }
    }

    private var currentValue: String {
        // The FETCHED price renders in the retailer's own currency when the parse carried one —
        // €89 must not read as $89 (prompt 07). "Paid" stays local: the user typed that number.
        item.currentPrice.map {
            $0.formatted(.currency(code: WearStats.fetchedPriceDisplayCode(
                fetched: item.currentPriceCurrencyRaw, local: WearStats.localCurrencyCode))
                .precision(.fractionLength(2)))
        } ?? "Not checked"
    }

    @ViewBuilder private var deltaBadge: some View {
        // No ↑/↓ across currencies — a percentage between a $ cost and a € price is nonsense.
        if WearStats.priceDeltaComparable(fetched: item.currentPriceCurrencyRaw,
                                          local: WearStats.localCurrencyCode),
           let fraction = item.priceDeltaFraction, abs(fraction) >= 0.01 {
            let down = fraction < 0
            Text("\(down ? "↓" : "↑") \(Int(abs(fraction) * 100))%")
                .font(.caption.weight(.heavy))
                .foregroundStyle(down ? SnappetColor.perfFresh : Color.red)
        }
    }

    /// A price without a date is a trap — an old number reads as live. Always stamped.
    private var checkedStamp: String? {
        guard let at = item.currentPriceCheckedAt else { return nil }
        return "Checked " + at.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    private var displayHost: String {
        WardrobePriceService.validated(item.productURL)?.host ?? item.productURL
    }

    private func currency(_ value: Double) -> String {
        value.formatted(.currency(code: WearStats.localCurrencyCode).precision(.fractionLength(2)))
    }

    // MARK: - The check

    private func check() async {
        isChecking = true
        failure = nil
        defer { isChecking = false }

        switch await WardrobePriceService.check(urlString: item.productURL) {
        case let .updated(amount, currencyCode, _):
            item.currentPrice = amount
            // Keep the currency WITH the amount — the parser extracted it all along; dropping
            // it here was how a €89 page rendered as $89 (prompt 07).
            item.currentPriceCurrencyRaw = currencyCode ?? ""
            item.currentPriceCheckedAt = .now
            try? modelContext.save()
        case let other:
            // Explicitly do NOT touch `currentPrice` or `currentPriceCheckedAt`: a failed check
            // must leave the last known price with its ORIGINAL timestamp, so the UI keeps
            // telling the truth about how old that number is.
            failure = other.message
        }
    }
}
