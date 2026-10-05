import Foundation
import Network
import Observation

/// Finds the household's phones on the local network and syncs with them (household prompt 02).
/// Bonjour (`_snappet-hh._tcp`) for discovery, plain TCP underneath, and `HouseholdSyncMachine` for
/// everything that matters: this class only moves bytes and decides when to talk.
///
/// Runs only while the app is in the foreground **and** there's a reason to: a shared household, an open
/// invite, or a join in progress. A solo user never meets the Local Network prompt.
@MainActor
@Observable
final class HouseholdPeerService {
    static let serviceType = "_snappet-hh._tcp"
    static let sessionTimeout: Duration = .seconds(20)
    static let joinTimeout: Duration = .seconds(25)

    enum JoinState: Equatable {
        case idle
        case searching(String)
        case joined(String)
        case failed(String)
    }

    private(set) var isRunning = false
    private(set) var activeSessions = 0
    private(set) var invite: HouseholdInvite?
    /// Name of whoever just joined with the open invite (the invite sheet's "Alex joined ✓").
    private(set) var inviteJoinedBy: String?
    private(set) var joinState: JoinState = .idle
    /// Household phones currently visible on the network, by device id.
    private(set) var nearby: [UUID: NWEndpoint] = [:]
    private(set) var lastError: String?

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var sessions: [ObjectIdentifier: HouseholdConnection] = [:]
    @ObservationIgnored private var storeProvider: () -> HouseholdStore? = { nil }
    @ObservationIgnored private var foreground = false
    @ObservationIgnored private var pendingJoin: (invite: HouseholdInvite, myName: String, bringChores: Bool)?
    @ObservationIgnored private var lastDial: [UUID: Date] = [:]
    @ObservationIgnored private var pushTask: Task<Void, Never>?
    @ObservationIgnored private var listenerTXT: [String: String] = [:]

    var isSyncing: Bool { activeSessions > 0 }

    /// `store` returns the app's household store if a household exists (never creates one).
    func configure(store: @escaping () -> HouseholdStore?) {
        storeProvider = store
        evaluate()
    }

    func setForeground(_ on: Bool) {
        foreground = on
        evaluate()
    }

    /// Start or stop to match the rules above. Cheap; call whenever the household may have changed.
    func evaluate() {
        let store = storeProvider()
        store?.onLocalChange = { [weak self] in self?.pushSoon() }
        let wanted = foreground && store != nil
            && ((store?.isShared ?? false) || invite != nil || pendingJoin != nil)
        if wanted, !isRunning { start() } else if !wanted, isRunning { stop() } else if isRunning { refreshTXT() }
    }

    /// "Sync now": dial every household phone in reach.
    func syncNow() {
        guard isRunning else { evaluate(); return }
        for (device, endpoint) in nearby { dial(device: device, endpoint: endpoint) }
    }

    // MARK: Invites and joining

    @discardableResult
    func openInvite() -> HouseholdInvite? {
        guard let store = storeProvider() else { return nil }
        store.ensureKey()
        let i = HouseholdInvite.make(householdID: store.household.id, name: store.displayName)
        invite = i
        inviteJoinedBy = nil
        evaluate()
        refreshTXT()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(HouseholdInvite.lifetime))
            if self?.invite == i { self?.closeInvite() }
        }
        return i
    }

    func closeInvite() {
        invite = nil
        refreshTXT()
        evaluate()
    }

    func join(_ invite: HouseholdInvite, myName: String, bringChores: Bool) {
        guard !invite.isExpired() else {
            joinState = .failed("This invite has expired. Ask for a new code.")
            return
        }
        pendingJoin = (invite, myName, bringChores)
        joinState = .searching(invite.name)
        evaluate()
        Task { [weak self] in
            try? await Task.sleep(for: Self.joinTimeout)
            guard let self, self.pendingJoin?.invite == invite else { return }
            self.pendingJoin = nil
            self.joinState = .failed("Couldn't find \(invite.name.isEmpty ? "the household" : invite.name) on this Wi-Fi. Make sure you're on the same network and the invite is still open.")
            self.evaluate()
        }
    }

    func resetJoin() {
        pendingJoin = nil
        joinState = .idle
        evaluate()
    }

    // MARK: Lifecycle

    private func start() {
        guard let store = storeProvider() else { return }
        do {
            let l = try NWListener(using: .tcp)
            l.service = NWListener.Service(name: store.myDevice.uuidString.lowercased(), type: Self.serviceType,
                                           domain: nil, txtRecord: NWTXTRecord(txt()))
            listenerTXT = txt()
            l.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            l.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    if case .failed(let error) = state { self?.lastError = "\(error)"; self?.stop() }
                }
            }
            l.start(queue: .main)
            listener = l

            let b = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: .tcp)
            b.browseResultsChangedHandler = { [weak self] results, _ in
                MainActor.assumeIsolated { self?.handle(results) }
            }
            b.start(queue: .main)
            browser = b
            isRunning = true
        } catch {
            lastError = "\(error)"
        }
    }

    private func stop() {
        listener?.cancel()
        browser?.cancel()
        listener = nil
        browser = nil
        nearby = [:]
        isRunning = false
    }

    private func txt() -> [String: String] {
        var t = ["v": "1"]
        if let tag = storeProvider()?.tag { t["hh"] = tag }
        if let invite, !invite.isExpired() { t["inv"] = invite.tag }
        return t
    }

    private func refreshTXT() {
        guard let listener, let store = storeProvider() else { return }
        let t = txt()
        guard t != listenerTXT else { return }
        listenerTXT = t
        listener.service = NWListener.Service(name: store.myDevice.uuidString.lowercased(), type: Self.serviceType,
                                              domain: nil, txtRecord: NWTXTRecord(t))
    }

    // MARK: Discovery

    private func handle(_ results: Set<NWBrowser.Result>) {
        guard let store = storeProvider() else { return }
        var seen: [UUID: NWEndpoint] = [:]
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint,
                  let device = UUID(uuidString: name), device != store.myDevice,
                  case .bonjour(let record) = result.metadata else { continue }
            if let pending = pendingJoin, record["inv"] == pending.invite.tag {
                dialJoin(endpoint: result.endpoint, pending: pending)
                continue
            }
            if let tag = store.tag, record["hh"] == tag { seen[device] = result.endpoint }
        }
        let fresh = seen.filter { nearby[$0.key] == nil }
        nearby = seen
        // Discovery-triggered syncs: only the smaller device id dials, so a pair opens one connection.
        for (device, endpoint) in fresh where store.myDevice.uuidString < device.uuidString {
            dial(device: device, endpoint: endpoint)
        }
    }

    /// After a local change, push it to whoever's in reach (debounced).
    private func pushSoon() {
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.syncNow()
        }
    }

    // MARK: Sessions

    private func dial(device: UUID, endpoint: NWEndpoint) {
        guard let store = storeProvider(), store.household.key.count == 32 else { return }
        if let last = lastDial[device], Date.now.timeIntervalSince(last) < 2 { return }
        lastDial[device] = .now
        let machine = HouseholdSyncMachine(dialing: .sync, identity: store.identity, secret: store.household.key,
                                           log: store.syncLog)
        run(HouseholdConnection(connection: NWConnection(to: endpoint, using: .tcp), machine: machine))
    }

    private func dialJoin(endpoint: NWEndpoint, pending: (invite: HouseholdInvite, myName: String, bringChores: Bool)) {
        guard let store = storeProvider() else { return }
        pendingJoin = nil   // one attempt per scan
        // This phone's ids in the joined household, minted now so the inviter records the real ones.
        let identity = HouseholdSyncMachine.Identity(device: UUID(), member: UUID(), name: pending.myName)
        let machine = HouseholdSyncMachine(dialing: .join, identity: identity, secret: pending.invite.token, log: nil,
                                           onWelcome: { welcome in
            store.join(welcome, as: identity, bringChores: pending.bringChores)
        })
        run(HouseholdConnection(connection: NWConnection(to: endpoint, using: .tcp), machine: machine))
    }

    private func accept(_ connection: NWConnection) {
        guard let store = storeProvider() else { connection.cancel(); return }
        var secrets = HouseholdSyncMachine.ListenerSecrets(householdKey: store.household.key.count == 32 ? store.household.key : nil,
                                                           log: store.syncLog)
        if let invite, !invite.isExpired() {
            secrets.invite = (invite.token, HouseholdWelcome(householdID: store.household.id, name: store.displayName,
                                                             key: store.ensureKey()))
        }
        run(HouseholdConnection(connection: connection,
                                machine: HouseholdSyncMachine(listening: store.identity, secrets: secrets)))
    }

    private func run(_ session: HouseholdConnection) {
        let key = ObjectIdentifier(session)
        sessions[key] = session
        activeSessions = sessions.count
        session.onWelcomeSent = { [weak self] in
            // Single use: burn the token the moment it's been honoured.
            self?.invite = nil
            self?.refreshTXT()
        }
        session.onFinish = { [weak self] outcome, machine in
            guard let self else { return }
            self.sessions[key] = nil
            self.activeSessions = self.sessions.count
            self.finished(outcome, machine: machine)
        }
        session.start(timeout: Self.sessionTimeout)
    }

    private func finished(_ outcome: HouseholdSyncMachine.Outcome?, machine: HouseholdSyncMachine) {
        let store = storeProvider()
        switch outcome {
        case .completed(let summary):
            store?.recordSync(summary)
            if machine.role == .listener, summary.welcome != nil {
                inviteJoinedBy = summary.peer.name.isEmpty ? "Someone" : summary.peer.name
            }
            if machine.role == .dialer, machine.mode == .join, let w = summary.welcome {
                joinState = .joined(w.name)
            }
            evaluate()
        case .failed(let failure):
            if machine.role == .dialer, machine.mode == .join { joinState = .failed(Self.describe(failure)) }
        case nil:
            if machine.role == .dialer, machine.mode == .join {
                joinState = .failed("The other phone stopped answering. Try again with a new code.")
            }
        }
    }

    static func describe(_ failure: HouseholdSyncMachine.Failure) -> String {
        switch failure {
        case .rejected("invite_closed"), .noSuchSecret(.join):
            return "That invite has expired or already been used. Ask for a new code."
        case .authFailed:
            return "That code didn't match. Ask for a new one."
        case .wrongVersion:
            return "The other phone needs a newer version of Snappet."
        case .rejected, .noSuchSecret, .protocolError:
            return "Something went wrong talking to the other phone. Try again."
        }
    }
}

/// One TCP connection running one `HouseholdSyncMachine`. Bytes in → machine → bytes out.
@MainActor
final class HouseholdConnection {
    private let connection: NWConnection
    let machine: HouseholdSyncMachine
    var onFinish: ((HouseholdSyncMachine.Outcome?, HouseholdSyncMachine) -> Void)?
    var onWelcomeSent: (() -> Void)?
    private var finished = false
    private var welcomeReported = false

    init(connection: NWConnection, machine: HouseholdSyncMachine) {
        self.connection = connection
        self.machine = machine
    }

    func start(timeout: Duration) {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .ready:
                    self.send(self.machine.start())
                    self.receiveNext()
                case .failed, .cancelled:
                    self.finish()
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.connection.cancel()
        }
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, !self.finished else { return }
                if let data, !data.isEmpty {
                    let out = self.machine.receive(data)
                    if self.machine.sentWelcome, !self.welcomeReported {
                        self.welcomeReported = true
                        self.onWelcomeSent?()
                    }
                    if self.machine.isFinished {
                        // Flush the last frames, then hang up.
                        self.send(out, thenHangUp: true)
                        return
                    }
                    self.send(out)
                }
                if isComplete || error != nil { self.connection.cancel(); return }
                self.receiveNext()
            }
        }
    }

    private func send(_ frames: [Data], thenHangUp: Bool = false) {
        guard !frames.isEmpty else {
            if thenHangUp { connection.cancel() }
            return
        }
        let data = frames.reduce(Data(), +)
        let connection = connection
        connection.send(content: data, completion: .contentProcessed { _ in
            if thenHangUp { connection.cancel() }
        })
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        onFinish?(machine.outcome, machine)
    }
}
