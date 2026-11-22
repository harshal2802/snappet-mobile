import CryptoKit
import SwiftData
import XCTest
@testable import Snappet

/// Google sign-in + Drive (cloud-connect P3, prompt 268) — everything that needs no Google project.
final class GoogleAuthTests: XCTestCase {

    private let config = GoogleOAuthConfig(clientID: "1234-abcd.apps.googleusercontent.com")!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Config

    func testOnlyARealLookingClientIDConfiguresGoogle() {
        XCTAssertNil(GoogleOAuthConfig(clientID: nil))
        XCTAssertNil(GoogleOAuthConfig(clientID: ""))
        XCTAssertNil(GoogleOAuthConfig(clientID: "$(GOOGLE_CLIENT_ID)"), "an unexpanded build setting is not a client ID")
        XCTAssertNil(GoogleOAuthConfig(clientID: ".apps.googleusercontent.com"))
        XCTAssertNil(GoogleOAuthConfig(clientID: "not a client id"))
        XCTAssertEqual(GoogleOAuthConfig(clientID: " 1234-abcd.apps.googleusercontent.com\n")?.clientID,
                       "1234-abcd.apps.googleusercontent.com")
    }

    func testRedirectIsTheReversedClientID() {
        XCTAssertEqual(config.redirectScheme, "com.googleusercontent.apps.1234-abcd")
        XCTAssertEqual(config.redirectURI, "com.googleusercontent.apps.1234-abcd:/oauth2redirect")
    }

    // MARK: - PKCE

    func testPKCEChallengeMatchesTheRFC7636Example() {
        XCTAssertEqual(GooglePKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testRandomVerifiersAreURLSafeLongEnoughAndDifferent() {
        let a = GooglePKCE.random(), b = GooglePKCE.random()
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.verifier.count, 43)
        XCTAssertNil(a.verifier.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
    }

    // MARK: - Authorization URL + callback

    func testAuthorizationURLCarriesPKCEStateAndOnlyTheAskedScopes() throws {
        let pkce = GooglePKCE(verifier: "verifier")
        let url = GoogleOAuth.authorizationURL(config: config, scopes: ["openid", "email", GoogleScope.driveAppData],
                                               state: "state-1", pkce: pkce)
        let items = Dictionary(uniqueKeysWithValues: try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(url.host, "accounts.google.com")
        XCTAssertEqual(items["client_id"], config.clientID)
        XCTAssertEqual(items["redirect_uri"], config.redirectURI)
        XCTAssertEqual(items["response_type"], "code")
        XCTAssertEqual(items["scope"], "openid email https://www.googleapis.com/auth/drive.appdata")
        XCTAssertEqual(items["state"], "state-1")
        XCTAssertEqual(items["code_challenge"], pkce.challenge)
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertNil(items["client_secret"], "an iOS client has no secret")
    }

    func testCallbackYieldsTheCodeOnlyForOurRedirectAndOurState() throws {
        let good = URL(string: "com.googleusercontent.apps.1234-abcd:/oauth2redirect?state=s1&code=4%2Fabc")!
        XCTAssertEqual(try GoogleOAuth.code(fromCallback: good, config: config, expectedState: "s1"), "4/abc")

        func error(_ string: String, state: String = "s1") -> GoogleAuthError? {
            do { _ = try GoogleOAuth.code(fromCallback: URL(string: string)!, config: config, expectedState: state); return nil }
            catch { return error as? GoogleAuthError }
        }
        XCTAssertEqual(error("com.googleusercontent.apps.1234-abcd:/oauth2redirect?state=other&code=x"), .stateMismatch)
        XCTAssertEqual(error("com.googleusercontent.apps.1234-abcd:/oauth2redirect?state=s1"), .badResponse)
        XCTAssertEqual(error("evil:/oauth2redirect?state=s1&code=x"), .badResponse)
        XCTAssertEqual(error("com.googleusercontent.apps.1234-abcd:/oauth2redirect?error=access_denied"), .cancelled)
        XCTAssertEqual(error("com.googleusercontent.apps.1234-abcd:/oauth2redirect?error=server_error"), .denied("server_error"))
    }

    // MARK: - Tokens

    func testTokenExchangeRequestSendsTheVerifierNotASecret() throws {
        let request = GoogleOAuth.tokenRequest(code: "4/abc", config: config, pkce: GooglePKCE(verifier: "ver"))
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url, GoogleOAuth.tokenEndpoint)
        XCTAssertEqual(body, "client_id=1234-abcd.apps.googleusercontent.com&code=4%2Fabc&code_verifier=ver"
                       + "&grant_type=authorization_code&redirect_uri=com.googleusercontent.apps.1234-abcd%3A%2Foauth2redirect")
    }

    func testTokensParseAndARefreshKeepsWhatTheReplyOmits() throws {
        let idToken = "h." + GooglePKCE.base64URL(Data(#"{"email":"me@example.com","sub":"1"}"#.utf8)) + ".s"
        let first = try GoogleOAuth.tokens(fromResponse: Data("""
            {"access_token":"a1","expires_in":3599,"refresh_token":"r1",
             "scope":"openid email https://www.googleapis.com/auth/drive.appdata","id_token":"\(idToken)"}
            """.utf8), now: now)
        XCTAssertEqual(first.accessToken, "a1")
        XCTAssertEqual(first.refreshToken, "r1")
        XCTAssertEqual(first.email, "me@example.com")
        XCTAssertTrue(first.grants(GoogleScope.driveAppData))
        XCTAssertEqual(first.expiresAt, now.addingTimeInterval(3599))

        let refreshed = try GoogleOAuth.tokens(fromResponse: Data(#"{"access_token":"a2","expires_in":3599}"#.utf8),
                                               now: now.addingTimeInterval(4000), previous: first)
        XCTAssertEqual(refreshed.accessToken, "a2")
        XCTAssertEqual(refreshed.refreshToken, "r1")
        XCTAssertEqual(refreshed.email, "me@example.com")
        XCTAssertEqual(refreshed.scopes, first.scopes)
        XCTAssertThrowsError(try GoogleOAuth.tokens(fromResponse: Data("{}".utf8), now: now))
    }

    func testTokensRefreshAMinuteEarly() {
        let tokens = GoogleTokens(accessToken: "a", refreshToken: "r", expiresAt: now, scopes: [])
        XCTAssertFalse(tokens.needsRefresh(now: now.addingTimeInterval(-61)))
        XCTAssertTrue(tokens.needsRefresh(now: now.addingTimeInterval(-59)))
    }

    func testARevokedSessionIsToldApartFromOtherErrors() {
        XCTAssertEqual(GoogleOAuth.error(status: 400, body: Data(#"{"error":"invalid_grant"}"#.utf8)), .signedOut)
        XCTAssertEqual(GoogleOAuth.error(status: 403, body: Data(#"{"error":{"code":403,"message":"Quota exceeded"}}"#.utf8)),
                       .server(403, "Quota exceeded"))
        XCTAssertEqual(GoogleOAuth.error(status: 500, body: Data()), .server(500, ""))
    }

    // MARK: - Drive requests

    func testDriveRequestsStayInsideTheAppDataFolder() throws {
        let list = GoogleDriveAPI.list(pageToken: "next")
        XCTAssertEqual(list.url?.absoluteString,
                       "https://www.googleapis.com/drive/v3/files?spaces=appDataFolder&fields=nextPageToken,files(id,name)&pageSize=1000&pageToken=next")

        let create = GoogleDriveAPI.startUpload(name: "a.snpbak", byteCount: 12)
        XCTAssertEqual(create.httpMethod, "POST")
        XCTAssertEqual(create.url?.absoluteString, "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable")
        XCTAssertEqual(String(decoding: try XCTUnwrap(create.httpBody), as: UTF8.self),
                       #"{"name":"a.snpbak","parents":["appDataFolder"]}"#)
        XCTAssertEqual(create.value(forHTTPHeaderField: "X-Upload-Content-Length"), "12")

        let replace = GoogleDriveAPI.startUpload(name: "a.snpbak", byteCount: 12, existingID: "id1")
        XCTAssertEqual(replace.httpMethod, "PATCH")
        XCTAssertEqual(replace.url?.absoluteString, "https://www.googleapis.com/upload/drive/v3/files/id1?uploadType=resumable")

        XCTAssertEqual(GoogleDriveAPI.download(id: "id1").url?.absoluteString,
                       "https://www.googleapis.com/drive/v3/files/id1?alt=media")
        XCTAssertEqual(GoogleDriveAPI.delete(id: "id1").httpMethod, "DELETE")
        XCTAssertEqual(GoogleDriveAPI.authorized(list, accessToken: "tok").value(forHTTPHeaderField: "Authorization"), "Bearer tok")
    }

    func testStatusLineNamesTheRightAccount() {
        XCTAssertEqual(CloudBackupStatusText.skipped(.noAccount, destination: .googleDrive), "Sign in to Google to back up.")
        XCTAssertEqual(CloudBackupStatusText.skipped(.noAccount, destination: .iCloud), "Sign in to iCloud in Settings to back up.")
        XCTAssertEqual(CloudBackupDestination.googleDrive.label, "Google Drive")
    }
}

// MARK: - A fake Google: token endpoint + Drive app-data folder, in memory

final class FakeGoogle: GoogleHTTP, @unchecked Sendable {
    struct Stored { var id: String; var name: String; var data: Data; var parent: String; var isFolder = false
                    var props: [String: String] = [:] }
    struct PickerItem { var id: String; var createTime: String; var isVideo: Bool; var fileName: String; var data: Data
                        var width = 1920; var height = 1080 }

    private let lock = NSLock()
    private var stored: [Stored] = []
    private var sessions: [String: (name: String, existingID: String?, parent: String, props: [String: String])] = [:]
    private var counter = 0
    private var validAccess = ""
    private var pollsLeft = 0
    private(set) var refreshCount = 0
    private(set) var requests: [String] = []
    /// For every PUT (the bytes of an upload): was it barred from cellular and hotspots?
    private(set) var putsBarredFromCellular: [Bool] = []
    /// Every upload of bytes fails this way (iOS refusing mobile data, a dropped connection).
    var uploadError: URLError?
    var grantedScope = "openid email " + GoogleScope.driveAppData
    var refreshRevoked = false
    var pageSize = 1000
    var email = "me@example.com"
    /// What the person "picks" in Google Photos, and how many polls it takes them.
    var pickerItems: [PickerItem] = []
    var pollsBeforePicked = 1
    var failingDownloads: Set<String> = []
    /// Drive file NAMES whose bytes cannot be fetched (a dropped connection).
    var failingFileDownloads: Set<String> = []
    /// A server that answers a range request with the whole file.
    var ignoresRanges = false
    private(set) var rangeRequests: [String] = []
    /// The person deletes a copy in Drive by hand.
    func deleteFile(named name: String) { lock.withLock { stored.removeAll { $0.name == name } } }
    /// Names of what was moved to the trash, in order.
    private(set) var trashedNames: [String] = []

    /// Files in the hidden app-data folder (the backup vault).
    var fileNames: [String] { lock.withLock { stored.filter { $0.parent == "appDataFolder" }.map(\.name).sorted() } }
    /// Files in visible Drive folders (the clip vault).
    var driveFileNames: [String] { lock.withLock { stored.filter { !$0.isFolder && $0.parent != "appDataFolder" }.map(\.name).sorted() } }
    var folderNames: [String] { lock.withLock { stored.filter(\.isFolder).map(\.name) } }
    /// Every visible Drive file as "Folder/Sub/name" from the top (the clip vault's layout).
    var drivePaths: [String] {
        lock.withLock { stored.filter { !$0.isFolder && $0.parent != "appDataFolder" }.map(path).sorted() }
    }
    private func path(_ item: Stored) -> String {
        var parts = [item.name], parent = item.parent
        while let folder = stored.first(where: { $0.isFolder && $0.id == parent }) {
            parts.insert(folder.name, at: 0)
            parent = folder.parent
        }
        return parts.joined(separator: "/")
    }
    func props(named name: String) -> [String: String]? { lock.withLock { stored.first { $0.name == name }?.props } }
    /// The person renames a file in Drive.
    func rename(_ name: String, to new: String) {
        lock.withLock { if let index = stored.firstIndex(where: { $0.name == name }) { stored[index].name = new } }
    }
    /// A file put in Drive by an older build: no private properties, parent given by folder NAME.
    func addLegacyFile(named name: String, data: Data, inFolderNamed folder: String, props: [String: String] = [:]) {
        lock.withLock {
            counter += 1
            let parent = stored.first { $0.isFolder && $0.name == folder }?.id ?? "root"
            stored.append(Stored(id: "file-\(counter)", name: name, data: data, parent: parent, props: props))
        }
    }
    func data(named name: String) -> Data? { lock.withLock { stored.first { $0.name == name }?.data } }
    /// Drive ends up holding something other than what was sent (a broken upload).
    func replaceData(named name: String, with data: Data) {
        lock.withLock { if let i = stored.firstIndex(where: { $0.name == name }) { stored[i].data = data } }
    }
    func expireAccessToken() { lock.withLock { validAccess = "" } }
    func count(of prefix: String) -> Int { lock.withLock { requests.filter { $0.hasPrefix(prefix) }.count } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if request.httpMethod == "PUT", let uploadError { throw uploadError }
        return lock.withLock { handle(request) }
    }

    private func reply(_ request: URLRequest, _ status: Int, _ body: String = "", headers: [String: String] = [:]) -> (Data, HTTPURLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
    private func bytes(_ request: URLRequest, _ data: Data) -> (Data, HTTPURLResponse) {
        (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    private func handle(_ request: URLRequest) -> (Data, HTTPURLResponse) {
        let url = request.url!, method = request.httpMethod ?? "GET"
        requests.append("\(method) \(url.host ?? "")\(url.path)")
        if method == "PUT" { putsBarredFromCellular.append(!request.allowsExpensiveNetworkAccess && !request.allowsCellularAccess) }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func param(_ name: String) -> String? { query.first { $0.name == name }?.value }

        if url == GoogleOAuth.revokeEndpoint { return reply(request, 200, "{}") }
        if url == GoogleOAuth.tokenEndpoint {
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            let isRefresh = body.contains("grant_type=refresh_token")
            if isRefresh {
                refreshCount += 1
                if refreshRevoked { return reply(request, 400, #"{"error":"invalid_grant"}"#) }
            }
            counter += 1
            validAccess = "access-\(counter)"
            let idToken = "h." + GooglePKCE.base64URL(Data(#"{"email":"\#(email)"}"#.utf8)) + ".s"
            return reply(request, 200, isRefresh
                ? #"{"access_token":"\#(validAccess)","expires_in":3600}"#
                : #"{"access_token":"\#(validAccess)","expires_in":3600,"refresh_token":"refresh-1","scope":"\#(grantedScope)","id_token":"\#(idToken)"}"#)
        }
        if url.host == "upload.test" {   // the resumable session URL carries no auth
            guard let session = sessions.removeValue(forKey: url.lastPathComponent) else { return reply(request, 404) }
            let data = request.httpBody ?? Data()
            if let id = session.existingID, let index = stored.firstIndex(where: { $0.id == id }) {
                stored[index].data = data
                return reply(request, 200, #"{"id":"\#(id)","name":"\#(session.name)"}"#)
            }
            counter += 1
            stored.append(Stored(id: "file-\(counter)", name: session.name, data: data, parent: session.parent,
                                 props: session.props))
            return reply(request, 200, #"{"id":"file-\#(counter)","name":"\#(session.name)"}"#)
        }
        guard !validAccess.isEmpty, request.value(forHTTPHeaderField: "Authorization") == "Bearer \(validAccess)" else {
            return reply(request, 401, #"{"error":{"code":401,"message":"Invalid Credentials"}}"#)
        }

        // Google Photos: picked-item bytes + the Picker API.
        if url.host == "lh3.test" {
            let name = url.lastPathComponent
            guard let item = pickerItems.first(where: { name == $0.id + ($0.isVideo ? "=dv" : "=d") }),
                  !failingDownloads.contains(item.id) else { return reply(request, 404) }
            return bytes(request, item.data)
        }
        if url.host == "photospicker.googleapis.com" {
            if url.path == "/v1/sessions", method == "POST" {
                pollsLeft = pollsBeforePicked
                return reply(request, 200, #"{"id":"sess-1","pickerUri":"https://photos.google.com/picker/sess-1","mediaItemsSet":false,"pollingConfig":{"pollInterval":"3s","timeoutIn":"60s"}}"#)
            }
            if url.path == "/v1/sessions/sess-1" {
                if method == "DELETE" { return reply(request, 200, "{}") }
                pollsLeft -= 1
                return reply(request, 200, #"{"id":"sess-1","mediaItemsSet":\#(pollsLeft <= 0)}"#)
            }
            if url.path == "/v1/mediaItems" {
                let start = Int(param("pageToken") ?? "0") ?? 0
                let size = min(pageSize, 100)
                let list = pickerItems.dropFirst(start).prefix(size).map {
                    #"{"id":"\#($0.id)","createTime":"\#($0.createTime)","type":"\#($0.isVideo ? "VIDEO" : "PHOTO")","mediaFile":{"baseUrl":"https://lh3.test/\#($0.id)","mimeType":"\#($0.isVideo ? "video/mp4" : "image/jpeg")","filename":"\#($0.fileName)","mediaFileMetadata":{"width":\#($0.width),"height":\#($0.height)}}}"#
                }.joined(separator: ",")
                let next = start + size < pickerItems.count ? #","nextPageToken":"\#(start + size)""# : ""
                return reply(request, 200, #"{"mediaItems":[\#(list)]\#(next)}"#)
            }
            return reply(request, 404)
        }

        // Drive.
        if url.path.hasPrefix("/upload/drive/v3/files") {
            let metadata = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
            counter += 1
            let existing = method == "PATCH" ? url.lastPathComponent : nil
            sessions["s\(counter)"] = (name: metadata?["name"] as? String ?? "", existingID: existing,
                                       parent: (metadata?["parents"] as? [String])?.first ?? "root",
                                       props: metadata?["appProperties"] as? [String: String] ?? [:])
            return reply(request, 200, headers: ["Location": "https://upload.test/session/s\(counter)"])
        }
        if url.path == "/drive/v3/files", method == "POST" {   // create a folder
            let metadata = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
            counter += 1
            let name = metadata?["name"] as? String ?? ""
            stored.append(Stored(id: "folder-\(counter)", name: name, data: Data(),
                                 parent: (metadata?["parents"] as? [String])?.first ?? "root", isFolder: true))
            return reply(request, 200, #"{"id":"folder-\#(counter)","name":"\#(name)"}"#)
        }
        if url.path == "/drive/v3/files" {
            var matching: [Stored]
            if let q = param("q") {
                if q.contains("appProperties has") {
                    matching = stored.filter { item in
                        !item.isFolder && item.props.contains { q.contains("key='\($0.key)' and value='\($0.value)'") } }
                } else if q.contains("mimeType = 'application/vnd.google-apps.folder'") {
                    matching = stored.filter { item in
                        item.isFolder && (!q.contains("name = '") || q.contains("name = '\(item.name)'")) }
                } else {   // like Drive: a folder's children are its files AND its subfolders
                    matching = stored.filter { item in q.contains("'\(item.parent)' in parents") }
                }
            } else {
                matching = stored.filter { $0.parent == "appDataFolder" }
            }
            let start = Int(param("pageToken") ?? "0") ?? 0
            let slice = matching.dropFirst(start).prefix(pageSize)
            let next = start + pageSize < matching.count ? #","nextPageToken":"\#(start + pageSize)""# : ""
            let list = slice.map { item -> String in
                let props = String(decoding: (try? JSONSerialization.data(withJSONObject: item.props, options: [.sortedKeys])) ?? Data("{}".utf8), as: UTF8.self)
                let md5 = Insecure.MD5.hash(data: item.data).map { String(format: "%02x", $0) }.joined()
                return #"{"id":"\#(item.id)","name":"\#(item.name)","size":"\#(item.data.count)","md5Checksum":"\#(md5)","parents":["\#(item.parent)"],"appProperties":\#(props)}"#
            }.joined(separator: ",")
            return reply(request, 200, #"{"files":[\#(list)]\#(next)}"#)
        }
        let id = url.lastPathComponent
        guard let index = stored.firstIndex(where: { $0.id == id }) else { return reply(request, 404) }
        if method == "DELETE" { stored.remove(at: index); return reply(request, 204) }
        if method == "PATCH" {   // rename / re-tag / move
            let metadata = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
            if metadata?["trashed"] as? Bool == true {   // to the trash, with everything inside
                trashedNames.append(stored[index].name)
                var gone: Set<String> = [id]
                while true {
                    let more = stored.filter { gone.contains($0.parent) && !gone.contains($0.id) }.map(\.id)
                    if more.isEmpty { break }
                    gone.formUnion(more)
                }
                stored.removeAll { gone.contains($0.id) }
                return reply(request, 200, #"{"id":"\#(id)"}"#)
            }
            if let name = metadata?["name"] as? String { stored[index].name = name }
            if let props = metadata?["appProperties"] as? [String: String] { stored[index].props.merge(props) { _, new in new } }
            if let add = param("addParents") {
                guard param("removeParents") == stored[index].parent else { return reply(request, 400, #"{"error":{"code":400}}"#) }
                stored[index].parent = add
            }
            return reply(request, 200, #"{"id":"\#(id)","name":"\#(stored[index].name)"}"#)
        }
        if failingFileDownloads.contains(stored[index].name) { return reply(request, 500, #"{"error":{"code":500}}"#) }
        // A byte range, as Drive serves it: "bytes=a-b" (inclusive) → 206 with just that part.
        if let range = request.value(forHTTPHeaderField: "Range"), range.hasPrefix("bytes="), !ignoresRanges {
            rangeRequests.append(range)
            let parts = range.dropFirst(6).split(separator: "-").compactMap { Int($0) }
            let data = stored[index].data
            guard parts.count == 2, parts[0] <= parts[1], parts[1] < data.count else { return reply(request, 416) }
            return (data.subdata(in: parts[0]..<(parts[1] + 1)),
                    HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: nil, headerFields: nil)!)
        }
        return bytes(request, stored[index].data)
    }
}

@MainActor
final class GoogleAccountTests: XCTestCase {

    private let config = GoogleOAuthConfig(clientID: "1234-abcd.apps.googleusercontent.com")!
    private var google: FakeGoogle!
    private var store: MemoryGoogleTokenStore!
    private var clock: Clock!

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_800_000_000)
        var now: Date { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
    }

    override func setUp() async throws {
        google = FakeGoogle()
        store = MemoryGoogleTokenStore()
        clock = Clock()
    }

    private func account(config: GoogleOAuthConfig? = nil, unconfigured: Bool = false) -> GoogleAccount {
        let clock = clock!
        return GoogleAccount(config: unconfigured ? nil : (config ?? self.config), store: store, http: google,
                             now: { clock.now })
    }

    private func signIn(_ account: GoogleAccount) async throws {
        let pending = try account.beginSignIn(scopes: [GoogleScope.driveAppData])
        let state = try XCTUnwrap(URLComponents(url: pending.url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "state" }?.value)
        try await account.finishSignIn(pending, callback: URL(string: "\(pending.callbackScheme):/oauth2redirect?state=\(state)&code=c1")!)
    }

    private func vault(_ account: GoogleAccount) -> GoogleDriveVault {
        GoogleDriveVault(accessToken: { force in try await account.accessToken(forceRefresh: force) },
                         isSignedIn: { await account.isSignedIn }, http: google)
    }

    func testWithoutAClientIDGoogleIsOffAndCannotStartSignIn() {
        store.save(GoogleTokens(accessToken: "a", refreshToken: "r", expiresAt: .distantFuture, scopes: []))
        let account = account(unconfigured: true)
        XCTAssertFalse(account.isConfigured)
        XCTAssertFalse(account.isSignedIn)
        XCTAssertThrowsError(try account.beginSignIn(scopes: [])) { XCTAssertEqual($0 as? GoogleAuthError, .notConfigured) }
    }

    func testSignInStoresTheSessionAndSurvivesARelaunch() async throws {
        let account = account()
        XCTAssertFalse(account.isSignedIn)
        try await signIn(account)
        XCTAssertTrue(account.isSignedIn)
        XCTAssertEqual(account.email, "me@example.com")
        XCTAssertTrue(account.grants(GoogleScope.driveAppData))
        XCTAssertEqual(self.account().email, "me@example.com", "tokens come back from the store")
    }

    func testARedirectWithSomeoneElsesStateIsRefused() async throws {
        let account = account()
        let pending = try account.beginSignIn(scopes: [GoogleScope.driveAppData])
        do {
            try await account.finishSignIn(pending, callback: URL(string: "\(pending.callbackScheme):/oauth2redirect?state=forged&code=c1")!)
            XCTFail("a forged state must not sign in")
        } catch { XCTAssertEqual(error as? GoogleAuthError, .stateMismatch) }
        XCTAssertFalse(account.isSignedIn)
        XCTAssertTrue(google.requests.isEmpty, "no code is exchanged for a redirect that isn't ours")
    }

    func testUntickingTheDrivePermissionIsReportedNotStored() async throws {
        google.grantedScope = "openid email"
        let account = account()
        do { try await signIn(account); XCTFail("sign-in without the Drive permission must fail") }
        catch { XCTAssertEqual(error as? GoogleAuthError, .missingScope) }
        XCTAssertFalse(account.isSignedIn)
    }

    func testAStaleTokenIsRefreshedOnceForConcurrentCallers() async throws {
        let account = account()
        try await signIn(account)
        let fresh = try await account.accessToken()
        XCTAssertEqual(google.refreshCount, 0, "a fresh token is used as is")
        clock.advance(3600)
        async let a = account.accessToken()
        async let b = account.accessToken()
        let (first, second) = try await (a, b)
        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, fresh)
        XCTAssertEqual(google.refreshCount, 1)
    }

    func testAccessRevokedAtGoogleSignsOutHere() async throws {
        let account = account()
        try await signIn(account)
        clock.advance(3600)
        google.refreshRevoked = true
        do { _ = try await account.accessToken(); XCTFail("a revoked session has no token") }
        catch { XCTAssertEqual(error as? GoogleAuthError, .signedOut) }
        XCTAssertFalse(account.isSignedIn)
        XCTAssertNil(store.load())
    }

    func testSignOutForgetsTheSessionAndAsksGoogleToRevokeIt() async throws {
        let account = account()
        try await signIn(account)
        await account.signOut()
        XCTAssertFalse(account.isSignedIn)
        XCTAssertNil(store.load())
        XCTAssertEqual(google.requests.last, "POST oauth2.googleapis.com/revoke")
    }

    // MARK: - Drive vault

    func testVaultWritesListsReadsReplacesAndRemoves() async throws {
        let account = account()
        try await signIn(account)
        let vault = vault(account)
        google.pageSize = 2   // listing spans pages
        for name in ["c", "a", "b"] { try await vault.write(Data(name.utf8), name: name) }
        let value1 = try await vault.names()
        XCTAssertEqual(value1, ["a", "b", "c"])
        let value2 = try await vault.read("b")
        XCTAssertEqual(value2, Data("b".utf8))

        try await vault.write(Data("b2".utf8), name: "b")
        let value3 = try await vault.names()
        XCTAssertEqual(value3, ["a", "b", "c"], "writing an existing name replaces it")
        let value4 = try await vault.read("b")
        XCTAssertEqual(value4, Data("b2".utf8))

        try await vault.remove("a")
        try await vault.remove("a")   // already gone: not an error
        XCTAssertEqual(google.fileNames, ["b", "c"])
        do { _ = try await vault.read("a"); XCTFail("missing file") }
        catch { XCTAssertEqual(error as? CloudVaultError, .notFound("a")) }
    }

    func testVaultRecoversFromATokenGoogleRejectsEarly() async throws {
        let account = account()
        try await signIn(account)
        let vault = vault(account)
        try await vault.write(Data("x".utf8), name: "x")
        google.expireAccessToken()   // Google says 401 although our clock says the token is fine
        let value5 = try await vault.read("x")
        XCTAssertEqual(value5, Data("x".utf8))
        XCTAssertEqual(google.refreshCount, 1)
    }

    func testVaultIsUnavailableWhenSignedOut() async throws {
        let account = account()
        let vault = vault(account)
        let available = await vault.isAvailable()
        XCTAssertFalse(available)
        do { _ = try await vault.names(); XCTFail("signed out") }
        catch { XCTAssertEqual(error as? GoogleAuthError, .signedOut) }
    }

    // MARK: - The backup service over Drive

    func testBackupToGoogleDriveUploadsSealedBytesAndRestoresThem() async throws {
        let container = try ModelContainer(for: Schema(SnappetSchema.models),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        container.mainContext.insert(JournalEntry(title: "kept", body: "private words"))
        try container.mainContext.save()
        let suite = "GoogleAccountTests.backup"
        UserDefaults().removePersistentDomain(forName: suite)
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let account = account()
        let vault = vault(account)
        let backup = CloudBackupService(defaults: UserDefaults(suiteName: suite)!,
                                        vaultFor: { $0 == .googleDrive ? vault : nil },
                                        keys: FixedBackupKeyStore(key: SymmetricKey(size: .bits256)),
                                        network: { .wifi }, deviceName: "Test iPhone")
        backup.update { $0.destination = .googleDrive }

        await backup.runIfNeeded(context: container.mainContext, storeHealthy: true, manual: true)
        XCTAssertTrue(google.fileNames.isEmpty, "signed out: nothing is uploaded")
        XCTAssertEqual(backup.note, "Sign in to Google to back up.")

        try await signIn(account)
        await backup.runIfNeeded(context: container.mainContext, storeHealthy: true, manual: true)
        let manifest = try XCTUnwrap(backup.lastManifest)
        XCTAssertEqual(backup.phase, .idle)
        XCTAssertEqual(google.fileNames, [manifest.fileName, manifest.fileName + ".manifest.json"])
        XCTAssertNil(google.data(named: manifest.fileName)?.range(of: Data("private words".utf8)), "Drive holds no plaintext")

        let restored = try await backup.download(manifest)
        XCTAssertEqual(restored.journalEntries.first?.title, "kept")
        withExtendedLifetime(container) {}
    }
}
