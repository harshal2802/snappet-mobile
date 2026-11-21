import CryptoKit
import Foundation

// MARK: - Google sign-in + Drive, the PURE part (cloud-connect P3, prompt 268)
//
// Everything Google needs that is not I/O: the OAuth 2 "installed app" flow with PKCE (no client
// secret, system browser sheet, custom-scheme redirect), token bookkeeping, and the handful of Drive
// v3 requests the backup vault makes. Built as plain request/response values so it is unit-tested
// with no network and no Google project. The client ID is CONFIG (`GoogleClientID` in Info.plist,
// from the `GOOGLE_CLIENT_ID` build setting) — empty until the Google Cloud project exists, and
// then every Google control in the app stays hidden.

struct GoogleOAuthConfig: Equatable, Sendable {
    static let clientIDSuffix = ".apps.googleusercontent.com"

    let clientID: String

    /// nil unless `raw` looks like an iOS OAuth client ID (`1234-abc.apps.googleusercontent.com`).
    init?(clientID raw: String?) {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(Self.clientIDSuffix),
              trimmed.count > Self.clientIDSuffix.count,
              !trimmed.contains("$("), !trimmed.contains(" ") else { return nil }
        clientID = trimmed
    }

    /// The build's client ID, if one was configured.
    static var fromBundle: GoogleOAuthConfig? {
        GoogleOAuthConfig(clientID: Bundle.main.object(forInfoDictionaryKey: "GoogleClientID") as? String)
    }

    /// Google's iOS redirect: the client ID reversed, as a URL scheme.
    var redirectScheme: String {
        "com.googleusercontent.apps." + clientID.dropLast(Self.clientIDSuffix.count)
    }
    var redirectURI: String { redirectScheme + ":/oauth2redirect" }
}

enum GoogleScope {
    /// Identity only — so the account row can say who is signed in.
    static let identity = ["openid", "email"]
    /// A hidden per-app folder in the person's Drive. Snappet can see ONLY what Snappet put there.
    static let driveAppData = "https://www.googleapis.com/auth/drive.appdata"
}

struct GooglePKCE: Equatable, Sendable {
    let verifier: String
    var challenge: String { Self.challenge(for: verifier) }

    init(verifier: String) { self.verifier = verifier }

    /// 32 random bytes → 43 URL-safe characters (RFC 7636 allows 43–128).
    static func random() -> GooglePKCE {
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
        return GooglePKCE(verifier: base64URL(Data(bytes)))
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

struct GoogleTokens: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
    var scopes: [String]
    var email: String?

    /// Refresh a minute early so a request never leaves with a token about to lapse.
    func needsRefresh(now: Date) -> Bool { now >= expiresAt.addingTimeInterval(-60) }
    func grants(_ scope: String) -> Bool { scopes.contains(scope) }
}

enum GoogleAuthError: LocalizedError, Equatable {
    case notConfigured
    case cancelled
    case stateMismatch
    case denied(String)
    case missingScope
    case signedOut
    case server(Int, String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Google sign-in isn’t set up in this build."
        case .cancelled: "Sign-in was cancelled."
        case .stateMismatch: "Sign-in couldn’t be verified. Try again."
        case .denied(let reason): "Google didn’t allow access (\(reason))."
        case .missingScope: "Snappet needs the Google Drive permission to back up. Sign in again and leave it ticked."
        case .signedOut: "Sign in to Google again to continue."
        case .server(let code, let message): "Google returned an error (\(code)\(message.isEmpty ? "" : ": \(message)"))."
        case .badResponse: "Google’s reply couldn’t be read."
        }
    }
}

enum GoogleOAuth {
    static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    static let revokeEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!

    static func authorizationURL(config: GoogleOAuthConfig, scopes: [String], state: String,
                                 pkce: GooglePKCE, loginHint: String? = nil) -> URL {
        var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "include_granted_scopes", value: "true"),
        ]
        if let loginHint { items.append(URLQueryItem(name: "login_hint", value: loginHint)) }
        components.queryItems = items
        return components.url!
    }

    /// The authorization code out of the redirect — only for OUR redirect and OUR `state`.
    static func code(fromCallback url: URL, config: GoogleOAuthConfig, expectedState: String) throws -> String {
        guard url.scheme?.lowercased() == config.redirectScheme.lowercased() else { throw GoogleAuthError.badResponse }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") {
            throw error == "access_denied" ? GoogleAuthError.cancelled : GoogleAuthError.denied(error)
        }
        guard value("state") == expectedState else { throw GoogleAuthError.stateMismatch }
        guard let code = value("code"), !code.isEmpty else { throw GoogleAuthError.badResponse }
        return code
    }

    static func tokenRequest(code: String, config: GoogleOAuthConfig, pkce: GooglePKCE) -> URLRequest {
        form(tokenEndpoint, ["client_id": config.clientID, "code": code, "code_verifier": pkce.verifier,
                             "grant_type": "authorization_code", "redirect_uri": config.redirectURI])
    }

    static func refreshRequest(refreshToken: String, config: GoogleOAuthConfig) -> URLRequest {
        form(tokenEndpoint, ["client_id": config.clientID, "grant_type": "refresh_token",
                             "refresh_token": refreshToken])
    }

    static func revokeRequest(token: String) -> URLRequest { form(revokeEndpoint, ["token": token]) }

    private struct TokenResponse: Decodable {
        var access_token: String
        var expires_in: Double?
        var refresh_token: String?
        var scope: String?
        var id_token: String?
    }

    /// Tokens from a token-endpoint reply. A refresh reply omits the refresh token (and sometimes
    /// the scope / identity) — those carry over from `previous`.
    static func tokens(fromResponse data: Data, now: Date, previous: GoogleTokens? = nil) throws -> GoogleTokens {
        guard let reply = try? JSONDecoder().decode(TokenResponse.self, from: data), !reply.access_token.isEmpty
        else { throw GoogleAuthError.badResponse }
        return GoogleTokens(
            accessToken: reply.access_token,
            refreshToken: reply.refresh_token ?? previous?.refreshToken,
            expiresAt: now.addingTimeInterval(reply.expires_in ?? 3600),
            scopes: reply.scope.map { $0.split(separator: " ").map(String.init) } ?? previous?.scopes ?? [],
            email: reply.id_token.flatMap(email(fromIDToken:)) ?? previous?.email)
    }

    /// The `email` claim of an ID token. Read, not verified: it arrived over TLS straight from
    /// Google's token endpoint and is only ever SHOWN ("Signed in as …"), never trusted for access.
    static func email(fromIDToken token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload.append("=") }
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["email"] as? String
    }

    static func error(status: Int, body: Data) -> GoogleAuthError {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let code = object?["error"] as? String
        // A revoked / expired refresh token: the person has to sign in again.
        if code == "invalid_grant" { return .signedOut }
        let nested = (object?["error"] as? [String: Any])?["message"] as? String
        return .server(status, nested ?? (object?["error_description"] as? String) ?? code ?? "")
    }

    private static func form(_ url: URL, _ fields: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = Data(fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").utf8)
        return request
    }
}

// MARK: - Drive v3 requests for the app-data folder

struct GoogleDriveFile: Decodable, Equatable, Sendable {
    var id: String
    var name: String
}

enum GoogleDriveAPI {
    static let filesEndpoint = "https://www.googleapis.com/drive/v3/files"
    static let uploadEndpoint = "https://www.googleapis.com/upload/drive/v3/files"

    struct Page: Decodable, Equatable, Sendable {
        var files: [GoogleDriveFile]
        var nextPageToken: String?
    }

    /// Files in a space (`appDataFolder` = the hidden per-app folder).
    static func list(space: String = "appDataFolder", pageToken: String? = nil) -> URLRequest {
        var components = URLComponents(string: filesEndpoint)!
        components.queryItems = [URLQueryItem(name: "spaces", value: space),
                                 URLQueryItem(name: "fields", value: "nextPageToken,files(id,name)"),
                                 URLQueryItem(name: "pageSize", value: "1000")]
        if let pageToken { components.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        return URLRequest(url: components.url!)
    }

    static func page(from data: Data) throws -> Page {
        guard let page = try? JSONDecoder().decode(Page.self, from: data) else { throw GoogleAuthError.badResponse }
        return page
    }

    static func download(id: String) -> URLRequest {
        URLRequest(url: URL(string: "\(filesEndpoint)/\(id)?alt=media")!)
    }

    static func delete(id: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "\(filesEndpoint)/\(id)")!)
        request.httpMethod = "DELETE"
        return request
    }

    /// Step 1 of a resumable upload (no 5 MB cap, unlike multipart): describe the file; the reply's
    /// `Location` header is where the bytes go. `existingID` replaces that file's content instead.
    static func startUpload(name: String, byteCount: Int, parent: String = "appDataFolder",
                            existingID: String? = nil) -> URLRequest {
        var request = URLRequest(url: URL(string: existingID.map { "\(uploadEndpoint)/\($0)?uploadType=resumable" }
                                          ?? "\(uploadEndpoint)?uploadType=resumable")!)
        request.httpMethod = existingID == nil ? "POST" : "PATCH"
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/octet-stream", forHTTPHeaderField: "X-Upload-Content-Type")
        request.setValue(String(byteCount), forHTTPHeaderField: "X-Upload-Content-Length")
        let metadata: [String: Any] = existingID == nil ? ["name": name, "parents": [parent]] : ["name": name]
        request.httpBody = try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
        return request
    }

    /// Step 2: the bytes, in one PUT to the session URL.
    static func finishUpload(session: URL, data: Data) -> URLRequest {
        var request = URLRequest(url: session)
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        return request
    }

    static func authorized(_ request: URLRequest, accessToken: String) -> URLRequest {
        var copy = request
        copy.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return copy
    }
}
