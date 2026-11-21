import Foundation
import Observation
import Security

// MARK: - Google account + Drive vault, the edge (cloud-connect P3, prompt 268)

/// The network seam: production = URLSession; tests = an in-memory fake Google.
protocol GoogleHTTP: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionGoogleHTTP: GoogleHTTP {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GoogleAuthError.badResponse }
        return (data, http)
    }
}

/// Where the tokens rest. Keychain, THIS device only (not synchronizable): a Google session is
/// per-install; a new phone signs in again.
protocol GoogleTokenStore: Sendable {
    func load() -> GoogleTokens?
    func save(_ tokens: GoogleTokens?)
}

struct KeychainGoogleTokenStore: GoogleTokenStore {
    var service = "com.snappet.google"
    var account = "tokens-v1"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func load() -> GoogleTokens? {
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(read as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(GoogleTokens.self, from: data)
    }

    func save(_ tokens: GoogleTokens?) {
        SecItemDelete(query as CFDictionary)
        guard let tokens, let data = try? JSONEncoder().encode(tokens) else { return }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}

final class MemoryGoogleTokenStore: GoogleTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: GoogleTokens?
    init(_ tokens: GoogleTokens? = nil) { self.tokens = tokens }
    func load() -> GoogleTokens? { lock.withLock { tokens } }
    func save(_ new: GoogleTokens?) { lock.withLock { tokens = new } }
}

/// The signed-in Google account. Sign-in is two halves around the system browser sheet, which the
/// VIEW presents (`\.webAuthenticationSession`): `beginSignIn` → URL to open; `finishSignIn` with
/// the redirect it came back with. Nothing here runs unless the person taps "Sign in with Google".
@MainActor
@Observable
final class GoogleAccount {
    /// The app's account. UI tests (`-uiTestGoogleSignedIn`) get a configured, signed-in stand-in
    /// that never touches the network or the keychain — Google's own sign-in sheet can't be driven
    /// from a test, and the test vault is a local folder.
    static let shared: GoogleAccount = {
        guard CommandLine.arguments.contains("-uiTestGoogleSignedIn") else { return GoogleAccount() }
        let tokens = GoogleTokens(accessToken: "test", refreshToken: "test", expiresAt: .distantFuture,
                                  scopes: [GoogleScope.driveAppData], email: "tester@example.com")
        return GoogleAccount(config: GoogleOAuthConfig(clientID: "0-uitest.apps.googleusercontent.com"),
                             store: MemoryGoogleTokenStore(tokens))
    }()

    struct Pending: Equatable, Sendable {
        let url: URL
        let callbackScheme: String
        fileprivate let state: String
        fileprivate let pkce: GooglePKCE
        fileprivate let scopes: [String]
    }

    private(set) var tokens: GoogleTokens?
    @ObservationIgnored let config: GoogleOAuthConfig?
    @ObservationIgnored private let store: any GoogleTokenStore
    @ObservationIgnored private let http: any GoogleHTTP
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var refreshing: Task<GoogleTokens, Error>?

    init(config: GoogleOAuthConfig? = .fromBundle, store: any GoogleTokenStore = KeychainGoogleTokenStore(),
         http: any GoogleHTTP = URLSessionGoogleHTTP(), now: @escaping @Sendable () -> Date = { .now }) {
        self.config = config
        self.store = store
        self.http = http
        self.now = now
        tokens = config == nil ? nil : store.load()
    }

    /// False until a client ID is configured — every Google control hides.
    var isConfigured: Bool { config != nil }
    var isSignedIn: Bool { tokens?.refreshToken != nil }
    var email: String? { tokens?.email }
    func grants(_ scope: String) -> Bool { tokens?.grants(scope) ?? false }

    func beginSignIn(scopes: [String]) throws -> Pending {
        guard let config else { throw GoogleAuthError.notConfigured }
        let state = GooglePKCE.random().verifier
        let pkce = GooglePKCE.random()
        let all = GoogleScope.identity + scopes.filter { !GoogleScope.identity.contains($0) }
        return Pending(url: GoogleOAuth.authorizationURL(config: config, scopes: all, state: state,
                                                         pkce: pkce, loginHint: email),
                       callbackScheme: config.redirectScheme, state: state, pkce: pkce, scopes: scopes)
    }

    func finishSignIn(_ pending: Pending, callback: URL) async throws {
        guard let config else { throw GoogleAuthError.notConfigured }
        let code = try GoogleOAuth.code(fromCallback: callback, config: config, expectedState: pending.state)
        let (data, response) = try await http.send(GoogleOAuth.tokenRequest(code: code, config: config, pkce: pending.pkce))
        guard response.statusCode == 200 else { throw GoogleOAuth.error(status: response.statusCode, body: data) }
        let fresh = try GoogleOAuth.tokens(fromResponse: data, now: now(), previous: tokens)
        // Google's consent screen lets the person untick a permission; say so instead of failing later.
        guard pending.scopes.allSatisfy(fresh.grants) else { throw GoogleAuthError.missingScope }
        set(fresh)
    }

    /// A usable access token, refreshed when stale. Concurrent callers share one refresh.
    func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let config, let current = tokens, let refreshToken = current.refreshToken else {
            throw GoogleAuthError.signedOut
        }
        if !forceRefresh, !current.needsRefresh(now: now()) { return current.accessToken }
        if let refreshing { return try await refreshing.value.accessToken }
        let http = http, now = now
        let task = Task { () throws -> GoogleTokens in
            let (data, response) = try await http.send(GoogleOAuth.refreshRequest(refreshToken: refreshToken, config: config))
            guard response.statusCode == 200 else { throw GoogleOAuth.error(status: response.statusCode, body: data) }
            return try GoogleOAuth.tokens(fromResponse: data, now: now(), previous: current)
        }
        refreshing = task
        defer { refreshing = nil }
        do {
            let fresh = try await task.value
            set(fresh)
            return fresh.accessToken
        } catch GoogleAuthError.signedOut {
            set(nil)   // revoked from Google's side: forget the dead session
            throw GoogleAuthError.signedOut
        }
    }

    /// Forget the session here and ask Google to revoke it (best effort — offline still signs out).
    func signOut() async {
        let token = tokens?.refreshToken ?? tokens?.accessToken
        set(nil)
        if let token { _ = try? await http.send(GoogleOAuth.revokeRequest(token: token)) }
    }

    private func set(_ new: GoogleTokens?) {
        tokens = new
        store.save(new)
    }
}

/// Backup files in the hidden per-app folder of the person's Google Drive (`drive.appdata`): Snappet
/// can read and write only what it put there, and the folder doesn't appear in their Drive.
struct GoogleDriveVault: CloudVault {
    /// (forceRefresh) → access token; throws when signed out.
    let accessToken: @Sendable (Bool) async throws -> String
    let isSignedIn: @Sendable () async -> Bool
    var http: any GoogleHTTP = URLSessionGoogleHTTP()

    func isAvailable() async -> Bool { await isSignedIn() }

    func names() async throws -> [String] { try await files().map(\.name).sorted() }

    func read(_ name: String) async throws -> Data {
        guard let file = try await files().first(where: { $0.name == name }) else { throw CloudVaultError.notFound(name) }
        return try await send(GoogleDriveAPI.download(id: file.id)).0
    }

    func write(_ data: Data, name: String) async throws {
        let existing = try await files().first { $0.name == name }
        let (_, response) = try await send(GoogleDriveAPI.startUpload(name: name, byteCount: data.count, existingID: existing?.id))
        guard let location = response.value(forHTTPHeaderField: "Location"), let session = URL(string: location) else {
            throw GoogleAuthError.badResponse
        }
        _ = try await send(GoogleDriveAPI.finishUpload(session: session, data: data))
    }

    func remove(_ name: String) async throws {
        for file in try await files() where file.name == name {
            _ = try await send(GoogleDriveAPI.delete(id: file.id))
        }
    }

    private func files() async throws -> [GoogleDriveFile] {
        var all: [GoogleDriveFile] = []
        var token: String?
        repeat {
            let page = try GoogleDriveAPI.page(from: try await send(GoogleDriveAPI.list(pageToken: token)).0)
            all += page.files
            token = page.nextPageToken
        } while token != nil
        return all
    }

    /// Authorized send; one retry with a fresh token on 401.
    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var (data, response) = try await http.send(
            GoogleDriveAPI.authorized(request, accessToken: try await accessToken(false)))
        if response.statusCode == 401 {
            (data, response) = try await http.send(
                GoogleDriveAPI.authorized(request, accessToken: try await accessToken(true)))
        }
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 404 { throw CloudVaultError.notFound(request.url?.lastPathComponent ?? "") }
            throw GoogleOAuth.error(status: response.statusCode, body: data)
        }
        return (data, response)
    }
}

extension GoogleDriveVault {
    /// The vault for the app's signed-in account.
    static func forSharedAccount() -> GoogleDriveVault {
        GoogleDriveVault(accessToken: { force in try await GoogleAccount.shared.accessToken(forceRefresh: force) },
                         isSignedIn: { await GoogleAccount.shared.isSignedIn })
    }
}
