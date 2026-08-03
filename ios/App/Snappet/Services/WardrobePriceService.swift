import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// The on-demand price check (wardrobe prompt 05).
//
// **This is the app's first third-party network call.** Everything else in Snappet is on-device,
// and the existing network paths (Kilter catalogs, festival lineups) fetch OUR OWN GitHub Pages.
// This one reaches an arbitrary retailer, so the posture is deliberately narrow and stated in the
// UI: one GET per explicit tap, no polling, no background refresh, no accounts, no cookies kept.
// If you are adding a caller, that constraint is the feature — do not wire this to `onAppear`, a
// timer, or a background task.
//
// Parsing follows the `WardrobeIntelligence` contract: the pure `WardrobePriceParser` floor always
// runs, and an on-device Foundation Models pass only refines it. A device without Apple
// Intelligence gets the floor's answer, not an error.

@MainActor
enum WardrobePriceService {

    enum Outcome: Equatable {
        case updated(amount: Double, currencyCode: String?, refinedByAI: Bool)
        /// The page loaded but carried no readable price.
        case noPriceFound
        /// The link is not usable (empty, not http(s), malformed).
        case badLink
        case networkFailed(String)

        /// User-facing line. Deliberately blunt about failure — a stale price presented as fresh
        /// is worse than an admission.
        var message: String {
            switch self {
            case .updated: return ""
            case .noPriceFound: return "Couldn't find a price on that page."
            case .badLink: return "That link doesn't look like a web address."
            case .networkFailed(let why): return why
            }
        }
    }

    /// Fetch and parse. **Never** mutates the item — the caller decides what to keep, which is what
    /// makes "a failed check preserves the last known price AND its timestamp" enforceable in one
    /// place rather than at every call site.
    static func check(urlString: String) async -> Outcome {
        guard let url = validated(urlString) else { return .badLink }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.httpShouldHandleCookies = false
        // Some retailers serve a JS shell to unknown agents; a plain desktop UA gets served HTML
        // with the structured metadata the parser wants.
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
                         + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

        let html: String
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return .networkFailed("The store returned an error (\(http.statusCode)).")
            }
            guard let decoded = decodeHTML(data) else {
                return .networkFailed("Couldn't read that page.")
            }
            html = decoded
        } catch {
            return .networkFailed("Couldn't reach the store.")
        }

        guard let floor = WardrobePriceParser.parse(html: html) else { return .noPriceFound }
        let refined = await refine(floor, html: html)
        return .updated(amount: refined.amount, currencyCode: refined.currencyCode,
                        refinedByAI: refined != floor)
    }

    /// http(s) only, and a host that at least looks like one. Anything else is a typo, not a shop.
    static func validated(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: withScheme),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, host.contains(".") else { return nil }
        return url
    }

    /// Best-effort text decode: HTML is usually UTF-8, but plenty of retail pages are still
    /// Latin-1 and would otherwise fail to decode entirely.
    private static func decodeHTML(_ data: Data) -> String? {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? String(data: data, encoding: .ascii)
    }

    // MARK: - The optional Apple Intelligence pass

    /// Refine the heuristic answer with an on-device model. Returns the floor unchanged whenever
    /// FM is unavailable, times out, or produces something implausible — this can only ever
    /// improve the result, never replace it with a failure.
    private static func refine(_ floor: WardrobePriceParser.Result,
                               html: String) async -> WardrobePriceParser.Result {
        #if canImport(FoundationModels)
        guard #available(iOS 26, *), SystemLanguageModel.default.isAvailable else { return floor }
        // Feed a trimmed window, not the whole document: a product page is mostly script and CSS,
        // and the context window is finite.
        let snippet = String(priceNeighborhood(html).prefix(4000))
        guard !snippet.isEmpty else { return floor }
        let prompt = """
        This is part of a product web page. The current selling price appears to be \
        \(floor.amount). If that is wrong, reply with the correct current selling price \
        (not a crossed-out list price, not an instalment). Reply with the number only.

        \(snippet)
        """
        do {
            let session = LanguageModelSession()
            let reply = try await session.respond(to: prompt).content
            guard let value = WardrobePriceParser.number(from: reply) else { return floor }
            // Guard rail: only accept a correction in the same ballpark. A model that returns a
            // product id or a shipping cost must not overwrite a good structured-metadata read.
            guard value > floor.amount / 10, value < floor.amount * 10 else { return floor }
            return WardrobePriceParser.Result(amount: value, currencyCode: floor.currencyCode,
                                              source: floor.source)
        } catch {
            return floor
        }
        #else
        return floor
        #endif
    }

    /// A window of markup around the first currency symbol — the part of the page a human would
    /// look at, and far smaller than the document.
    private static func priceNeighborhood(_ html: String) -> String {
        guard let index = html.firstIndex(where: { "$£€₹".contains($0) }) else {
            return String(html.prefix(4000))
        }
        let start = html.index(index, offsetBy: -1500, limitedBy: html.startIndex) ?? html.startIndex
        let end = html.index(index, offsetBy: 2500, limitedBy: html.endIndex) ?? html.endIndex
        return String(html[start..<end])
    }
}
