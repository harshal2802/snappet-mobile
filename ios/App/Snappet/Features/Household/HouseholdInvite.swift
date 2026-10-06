import Foundation
import CryptoKit

/// A one-time invitation to a household (household prompt 02, wireframe frame 4). The QR / link carries
/// a **token**, never the household key: the joiner proves it holds the token over the encrypted channel
/// and only then receives the key. The token is single-use and expires after five minutes, so a
/// screenshot of the code is useless later.
struct HouseholdInvite: Equatable, Sendable {
    static let lifetime: TimeInterval = 5 * 60

    var householdID: UUID
    var name: String
    var token: Data
    var expires: Date

    static func make(householdID: UUID, name: String, now: Date = .now) -> HouseholdInvite {
        HouseholdInvite(householdID: householdID, name: name, token: HouseholdCrypto.randomBytes(32),
                        expires: now.addingTimeInterval(lifetime))
    }

    func isExpired(now: Date = .now) -> Bool { now >= expires }

    /// `snappet://household/join?v=1&h=<uuid>&n=<name>&t=<token b64url>&e=<unix>`.
    var url: URL {
        var c = URLComponents()
        c.scheme = "snappet"
        c.host = "household"
        c.path = "/join"
        c.queryItems = [
            URLQueryItem(name: "v", value: "1"),
            URLQueryItem(name: "h", value: householdID.uuidString.lowercased()),
            URLQueryItem(name: "n", value: name),
            URLQueryItem(name: "t", value: token.base64URL),
            URLQueryItem(name: "e", value: String(Int(expires.timeIntervalSince1970))),
        ]
        return c.url!
    }

    init(householdID: UUID, name: String, token: Data, expires: Date) {
        self.householdID = householdID
        self.name = name
        self.token = token
        self.expires = expires
    }

    /// Parses an invite link; nil for anything else (another app's link, a wrong version, a bad token).
    init?(url: URL) {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme?.lowercased() == "snappet", c.host?.lowercased() == "household", c.path == "/join"
        else { return nil }
        let q = Dictionary((c.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        guard q["v"] == "1",
              let h = q["h"].flatMap(UUID.init(uuidString:)),
              let t = q["t"].flatMap(Data.init(base64URL:)), t.count == 32,
              let e = q["e"].flatMap(Int.init) else { return nil }
        self.init(householdID: h, name: q["n"] ?? "", token: t, expires: Date(timeIntervalSince1970: TimeInterval(e)))
    }

    init?(string: String) {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        self.init(url: url)
    }

    /// The Bonjour TXT tag a joiner looks for: shows which phone holds this invite without revealing it.
    var tag: String { HouseholdCrypto.tag(secret: token, label: HouseholdCrypto.inviteTagLabel) }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        self.init(base64Encoded: b)
    }
}
