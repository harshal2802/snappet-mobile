import Foundation

/// **Universal links** (prompt 200): every `snappet://<host>/<path>?<query>` link has an https twin,
/// `https://harshal2802.github.io/Snappet/open/<host>/<path>?<query>`. The https form is what shared QR codes and links
/// carry. The Camera shows "Open in Snappet", Messages / Notes make it tappable, and without the app it opens a web page
/// that says how to get it. The domain's `apple-app-site-association` claims `/Snappet/open/*` for the app. Everything
/// that parses a link calls `appForm` first, so both forms work everywhere (old `snappet://` QR codes keep working).
/// Pure.
enum SnappetWebLink {
    static let host = "harshal2802.github.io"
    static let prefix = "/Snappet/open"

    /// `https://…/Snappet/open/kilter/climb/x?angle=40` → `snappet://kilter/climb/x?angle=40`; anything else unchanged.
    static func appForm(_ string: String) -> String {
        let s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let c = URLComponents(string: s), c.scheme?.lowercased() == "https",
              c.host?.lowercased() == host, c.percentEncodedPath.hasPrefix(prefix + "/") else { return s }
        let rest = String(c.percentEncodedPath.dropFirst(prefix.count + 1))
        guard !rest.isEmpty else { return s }
        var out = "snappet://" + rest
        if let q = c.percentEncodedQuery { out += "?" + q }
        if let f = c.percentEncodedFragment { out += "#" + f }
        return out
    }

    static func appForm(_ url: URL) -> URL { URL(string: appForm(url.absoluteString)) ?? url }

    /// `snappet://kilter/climb/x?angle=40` → its https twin; anything else unchanged.
    static func webForm(_ string: String) -> String {
        guard let c = URLComponents(string: string), c.scheme?.lowercased() == "snappet",
              let h = c.percentEncodedHost, !h.isEmpty else { return string }
        var out = "https://\(host)\(prefix)/\(h)\(c.percentEncodedPath)"
        if let q = c.percentEncodedQuery { out += "?" + q }
        if let f = c.percentEncodedFragment { out += "#" + f }
        return out
    }

    static func webForm(_ url: URL) -> URL { URL(string: webForm(url.absoluteString)) ?? url }
}
