import Foundation
import CryptoKit

/// One sync conversation between two phones (household prompt 02), as a pure state machine: feed it the
/// bytes that arrive, send the frames it returns. No sockets, so two machines wired back to back are the
/// test harness and `HouseholdPeerService` is only a pipe.
///
/// Flow: `hello` both ways (plaintext, carrying nonces) → keys from HKDF → sealed `auth` both ways (proves
/// the secret; nothing about the household is sent before the peer's auth opens) → join only: `welcome`
/// from the inviter → `state` (version vectors) both ways → each sends the `ops` the other is missing →
/// `done` both ways.
@MainActor
final class HouseholdSyncMachine {
    enum Role: Sendable { case dialer, listener }
    enum Mode: String, Sendable { case sync, join }

    /// The log behind one side of the conversation. Payloads are the stored op JSON, verbatim.
    struct Log {
        var vector: () -> VersionVector
        var missing: (VersionVector) -> [String]
        var ingest: ([String]) -> Int
    }

    struct Identity: Sendable {
        var device: UUID
        var member: UUID
        var name: String
    }

    /// The listener doesn't know which mode a dialer wants until its hello, so it holds both secrets.
    struct ListenerSecrets {
        var householdKey: Data?
        var log: Log?
        /// An open invite: its token and what to hand over once the token checks out.
        var invite: (token: Data, welcome: HouseholdWelcome)?
    }

    struct Peer: Equatable, Sendable {
        var device: UUID
        var member: UUID?
        var name: String
        var platform: String
    }

    struct Summary: Equatable, Sendable {
        var peer: Peer
        var sent: Int
        var received: Int
        /// The highest seq of my own device the peer now has (everything of mine was sent).
        var ackedSeq: Int
        /// Listener: someone joined with my invite. Dialer: the household I joined.
        var welcome: HouseholdWelcome?
    }

    enum Failure: Error, Equatable, Sendable {
        case authFailed
        case wrongVersion
        case noSuchSecret(Mode)
        case rejected(String)
        case protocolError(String)
    }

    enum Outcome: Equatable, Sendable {
        case completed(Summary)
        case failed(Failure)
    }

    let role: Role
    private(set) var mode: Mode
    private let identity: Identity
    private var secret: Data?
    private var log: Log?
    private let listenerSecrets: ListenerSecrets?
    /// Dialer, join mode: builds the joined household's log from the welcome.
    private let onWelcome: ((HouseholdWelcome) -> Log?)?

    private var reader = HouseholdFrame.Reader()
    private let myNonce = HouseholdCrypto.randomBytes(32)
    private var keys: HouseholdCrypto.SessionKeys?
    private var peerDevice: UUID?
    private var peerAuthed = false
    private var stateSent = false
    private var peerState: HouseholdSyncMessage?
    private var doneSent = false
    private var peerDone = false
    private var sent = 0, received = 0, ackedSeq = 0
    private var welcome: HouseholdWelcome?

    private(set) var outcome: Outcome?
    var isFinished: Bool { outcome != nil }
    /// Listener: the invite's welcome went out, so the token must be burnt now (single use, even if
    /// the rest of the sync fails).
    private(set) var sentWelcome = false

    /// A dialer: knows its mode and secret up front.
    init(dialing mode: Mode, identity: Identity, secret: Data, log: Log?,
         onWelcome: ((HouseholdWelcome) -> Log?)? = nil) {
        role = .dialer
        self.mode = mode
        self.identity = identity
        self.secret = secret
        self.log = log
        self.onWelcome = onWelcome
        listenerSecrets = nil
    }

    /// A listener: learns the mode from the dialer's hello.
    init(listening identity: Identity, secrets: ListenerSecrets) {
        role = .listener
        mode = .sync
        self.identity = identity
        listenerSecrets = secrets
        onWelcome = nil
    }

    /// Frames to send first (the dialer's hello; nothing for a listener).
    func start() -> [Data] {
        guard role == .dialer else { return [] }
        return [plain(.hello(mode: mode.rawValue, device: identity.device, nonce: myNonce))]
    }

    /// Feeds arriving bytes (any split) and returns frames to send. Once `isFinished`, stop.
    func receive(_ bytes: Data) -> [Data] {
        guard outcome == nil else { return [] }
        do {
            var out: [Data] = []
            for payload in try reader.push(bytes) where outcome == nil {
                out += try handle(payload)
            }
            return out
        } catch let f as Failure {
            outcome = .failed(f)
            return []
        } catch {
            outcome = .failed(.protocolError("\(error)"))
            return []
        }
    }

    // MARK: - Steps

    private func handle(_ payload: Data) throws -> [Data] {
        guard let keys else { return try handleHello(payload) }
        let message: HouseholdSyncMessage
        do {
            message = try HouseholdSyncMessage.decode(HouseholdCrypto.open(payload, key: keys.receive))
        } catch {
            // Before the peer's auth opens, a frame that won't open means they don't hold the secret.
            throw peerAuthed ? Failure.protocolError("bad frame") : Failure.authFailed
        }
        if !peerAuthed {
            guard message.t == "auth", message.device == peerDevice?.uuidString.lowercased() else {
                throw message.t == "reject" ? Failure.rejected(message.reason ?? "") : Failure.authFailed
            }
            peerAuthed = true
            return try afterAuth()
        }
        switch message.t {
        case "welcome":
            guard role == .dialer, mode == .join, welcome == nil,
                  let h = message.household.flatMap(UUID.init(uuidString:)),
                  let k = message.key.flatMap({ Data(base64Encoded: $0) }), k.count == 32
            else { throw Failure.protocolError("unexpected welcome") }
            let w = HouseholdWelcome(householdID: h, name: message.name ?? "", key: k)
            welcome = w
            log = onWelcome?(w)
            guard log != nil else { throw Failure.protocolError("couldn't join") }
            return try sendState()
        case "state":
            peerState = message
            var out = try sendState()
            out += try sendOpsAndDone(for: message.vector)
            return out
        case "ops":
            received += log?.ingest(message.ops ?? []) ?? 0
            return []
        case "done":
            peerDone = true
            finishIfDone()
            return []
        case "reject":
            throw Failure.rejected(message.reason ?? "")
        default:
            return []   // a newer peer's message: ignore
        }
    }

    private func handleHello(_ payload: Data) throws -> [Data] {
        let hello = try HouseholdSyncMessage.decode(payload)
        if hello.t == "reject" { throw Failure.rejected(hello.reason ?? "") }
        guard hello.t == "hello" else { throw Failure.protocolError("expected hello") }
        guard hello.v == 1 else { throw Failure.wrongVersion }
        guard let device = hello.device.flatMap(UUID.init(uuidString:)),
              let nonce = hello.nonce.flatMap({ Data(base64Encoded: $0) }), nonce.count == 32
        else { throw Failure.protocolError("bad hello") }
        peerDevice = device

        switch role {
        case .dialer:
            keys = HouseholdCrypto.sessionKeys(secret: secret ?? Data(), dialerNonce: myNonce, listenerNonce: nonce,
                                               isDialer: true)
            return [try sealed(.auth(device: identity.device))]
        case .listener:
            mode = Mode(rawValue: hello.mode ?? "") ?? .sync
            switch mode {
            case .sync:
                guard let key = listenerSecrets?.householdKey, !key.isEmpty else {
                    outcome = .failed(.noSuchSecret(.sync))
                    return [plain(.reject("not_a_member"))]
                }
                secret = key
            case .join:
                guard let invite = listenerSecrets?.invite else {
                    // Say so in plaintext: "this invite has expired or been used" beats a silent timeout.
                    outcome = .failed(.noSuchSecret(.join))
                    return [plain(.reject("invite_closed"))]
                }
                secret = invite.token
            }
            log = listenerSecrets?.log
            keys = HouseholdCrypto.sessionKeys(secret: secret ?? Data(), dialerNonce: nonce, listenerNonce: myNonce,
                                               isDialer: false)
            return [plain(.hello(mode: nil, device: identity.device, nonce: myNonce)),
                    try sealed(.auth(device: identity.device))]
        }
    }

    private func afterAuth() throws -> [Data] {
        if role == .listener, mode == .join, let invite = listenerSecrets?.invite {
            welcome = invite.welcome
            sentWelcome = true
            return [try sealed(.welcome(invite.welcome))] + (try sendState())
        }
        if role == .dialer, mode == .join { return [] }   // wait for the welcome
        return try sendState()
    }

    private func sendState() throws -> [Data] {
        guard !stateSent, let log else { return [] }
        stateSent = true
        var out = [try sealed(.state(log.vector(), member: identity.member, name: identity.name))]
        // A state that arrived before ours could go out (join dialer) is answered now.
        if let peerState, !doneSent { out += try sendOpsAndDone(for: peerState.vector) }
        return out
    }

    private func sendOpsAndDone(for theirs: VersionVector) throws -> [Data] {
        guard stateSent, !doneSent, let log else { return [] }
        let payloads = log.missing(theirs)
        var out: [Data] = []
        var chunk: [String] = [], size = 0
        for p in payloads {
            if size + p.utf8.count > 256 * 1024, !chunk.isEmpty {
                out.append(try sealed(.ops(chunk)))
                chunk = []; size = 0
            }
            chunk.append(p); size += p.utf8.count
        }
        if !chunk.isEmpty { out.append(try sealed(.ops(chunk))) }
        sent = payloads.count
        ackedSeq = log.vector()[identity.device]
        out.append(try sealed(.done))
        doneSent = true
        finishIfDone()
        return out
    }

    private func finishIfDone() {
        guard doneSent, peerDone, let peerDevice else { return }
        let peer = Peer(device: peerDevice, member: peerState?.member.flatMap(UUID.init(uuidString:)),
                        name: peerState?.name ?? "", platform: peerState?.platform ?? "")
        outcome = .completed(Summary(peer: peer, sent: sent, received: received, ackedSeq: ackedSeq, welcome: welcome))
    }

    // MARK: - Frames

    private func plain(_ m: HouseholdSyncMessage) -> Data {
        HouseholdFrame.encode((try? m.encoded()) ?? Data())
    }

    private func sealed(_ m: HouseholdSyncMessage) throws -> Data {
        guard let keys else { throw Failure.protocolError("no keys") }
        return HouseholdFrame.encode(try HouseholdCrypto.seal(m.encoded(), key: keys.send))
    }
}
