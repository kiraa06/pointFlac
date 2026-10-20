import Foundation
import os

/// A search-and-download-only Soulseek client (spec §5.6).
///
/// The actor owns the server connection and all routing state. Network reads, parsing and inflation run in
/// nonisolated tasks and hop onto the actor only to deliver typed messages, so a flood of peer connections (the live
/// probe saw ~23,000 `ConnectToPeer` requests in 30 s) never stalls login, keepalive or downloads.
///
/// pointFlac shares nothing: it announces zero files, refuses every upload request and never answers browse requests.
public actor SoulseekClient {
    public nonisolated let configuration: SoulseekConfiguration
    public private(set) var state: SoulseekConnectionState = .disconnected
    /// Lower-cased phrases from the server's ExcludedSearchPhrases (160). Never searched for, never shown.
    public private(set) var excludedPhrases: [String] = []
    public internal(set) var diagnostics = Diagnostics()

    /// Counters for tests and the debug screen.
    public struct Diagnostics: Sendable, Equatable {
        public var connectRequests = 0
        public var droppedAtCap = 0
        public var peerConnectFailures = 0
        public var searchResponses = 0
        public var malformedMessages = 0
        public var peakPeerConnections = 0
    }

    let logger = Logger(subsystem: "app.pointflac", category: "soulseek")

    private var credentials: (username: String, password: String)?
    private var server: FramedLink?
    private var serverGeneration = 0
    private var serverTasks: [Task<Void, Never>] = []
    private var reconnectTask: Task<Void, Never>?
    private var stateObservers: [UUID: AsyncStream<SoulseekConnectionState>.Continuation] = [:]

    private var nextTokenValue = UInt32.random(in: 1...0x3FFF_FFFF)
    var nextSearchSlot: ContinuousClock.Instant?
    var searches: [UInt32: SearchSession] = [:]
    var activePeerConnections = 0

    var transfers: [UUID: TransferEntry] = [:]
    var addressWaiters: [UUID: (username: String, continuation: CheckedContinuation<PeerAddress?, Never>)] = [:]

    public init(configuration: SoulseekConfiguration = SoulseekConfiguration()) {
        self.configuration = configuration
    }

    // MARK: - State

    public func stateUpdates() -> AsyncStream<SoulseekConnectionState> {
        let (stream, continuation) = AsyncStream.makeStream(of: SoulseekConnectionState.self)
        let id = UUID()
        stateObservers[id] = continuation
        continuation.yield(state)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        return stream
    }

    private func removeObserver(_ id: UUID) { stateObservers[id] = nil }

    private func setState(_ newState: SoulseekConnectionState) {
        guard newState != state else { return }
        state = newState
        for observer in stateObservers.values { observer.yield(newState) }
    }

    var isLoggedIn: Bool {
        if case .loggedIn = state { return true }
        return false
    }

    var username: String? { credentials?.username }

    func makeToken() -> UInt32 {
        nextTokenValue = nextTokenValue &+ 1
        if nextTokenValue == 0 { nextTokenValue = 1 }
        return nextTokenValue
    }

    // MARK: - Login

    /// Connects and logs in. Soulseek creates an account for an unknown name, so the UI must warn about typos (§4.7).
    public func login(username: String, password: String) async throws(SoulseekError) {
        guard !username.isEmpty, !password.isEmpty else { throw .invalidUsername }
        reconnectTask?.cancel()
        reconnectTask = nil
        credentials = (username, password)
        setState(.connecting)
        do {
            try await establishSession()
        } catch {
            credentials = nil
            setState(.failed(error))
            throw error
        }
    }

    /// Closes everything. Downloads in progress fail with `cancelled`; their `.part` files stay for a later resume.
    public func logout() {
        credentials = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        tearDownServer()
        finishAllSearches(error: nil)
        for entry in transfers.values { entry.signals.yield(.cancelled) }
        setState(.disconnected)
    }

    private func tearDownServer() {
        serverGeneration += 1
        for task in serverTasks { task.cancel() }
        serverTasks = []
        server?.close()
        server = nil
    }

    private func establishSession() async throws(SoulseekError) {
        guard let credentials else { throw .notLoggedIn }
        tearDownServer()
        let config = configuration
        let link: TCPLink
        do {
            link = try await TCPLink.connect(
                host: config.serverHost, port: config.serverPort, timeout: config.connectTimeout)
        } catch {
            throw .serverUnavailable
        }
        let framed = FramedLink(link, maxFrame: FrameCaps.server)
        serverGeneration += 1
        let generation = serverGeneration
        server = framed

        let reply: ServerMessage
        do {
            try await framed.send(
                Outgoing.login(
                    username: credentials.username, password: credentials.password, major: config.majorVersion,
                    minor: config.minorVersion))
            reply = try await Self.awaitLoginReply(framed, timeout: config.loginTimeout)
        } catch LinkError.timeout {
            framed.close()
            server = nil
            throw .timeout
        } catch {
            framed.close()
            server = nil
            throw .serverUnavailable
        }
        guard generation == serverGeneration else { throw .connectionLost }

        if case .loginFailed(let reason) = reply {
            framed.close()
            server = nil
            switch reason {
            case "INVALIDPASS": throw .invalidPassword
            case "INVALIDUSERNAME": throw .invalidUsername
            case "INVALIDVERSION": throw .invalidVersion
            default: throw .rejected(reason)
            }
        }

        // Online, sharing nothing, a leaf of the distributed network. The advertised port is never reachable behind
        // NAT, so peers fall back to asking the server to forward ConnectToPeer to us.
        for message in [
            Outgoing.setWaitPort(config.listenPort), Outgoing.setStatusOnline(), Outgoing.sharedNothing(),
            Outgoing.haveNoParent(),
        ] {
            try? await framed.send(message)
        }

        serverTasks.append(
            Task { [weak self] in
                do {
                    while true {
                        let frame = try await framed.nextFrame()
                        let message: ServerMessage
                        do {
                            message = try ServerMessage.parse(frame)
                        } catch {
                            await self?.noteMalformed()
                            continue
                        }
                        guard let self else { return }
                        await self.handleServer(message, generation: generation)
                    }
                } catch {
                    await self?.serverConnectionEnded(generation: generation)
                }
            })
        serverTasks.append(
            Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: config.keepaliveInterval)
                    guard !Task.isCancelled else { return }
                    try? await framed.send(Outgoing.ping())
                    _ = self
                }
            })
        setState(.loggedIn(username: credentials.username))
    }

    private static func awaitLoginReply(_ framed: FramedLink, timeout: Duration) async throws -> ServerMessage {
        let deadline = ContinuousClock.now + timeout
        while true {
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else { throw LinkError.timeout }
            let frame = try await framed.nextFrame(timeout: remaining)
            guard frame.code == ServerCode.login else { continue }
            return try ServerMessage.parse(frame)
        }
    }

    func noteMalformed() { diagnostics.malformedMessages += 1 }

    private func serverConnectionEnded(generation: Int) {
        guard generation == serverGeneration else { return }
        server?.close()
        server = nil
        guard state != .kicked else { return }
        finishAllSearches(error: .connectionLost)
        guard configuration.autoReconnect, credentials != nil else {
            setState(.failed(.connectionLost))
            return
        }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        let delays = configuration.reconnectDelays
        reconnectTask = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                attempt += 1
                let delay = delays.isEmpty ? .seconds(5) : delays[min(attempt - 1, delays.count - 1)]
                await self?.setState(.reconnecting(attempt: attempt))
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self else { return }
                if await self.attemptReconnect() { return }
            }
        }
    }

    /// One reconnect attempt. Returns true when reconnecting should stop (success or a final refusal).
    private func attemptReconnect() async -> Bool {
        guard credentials != nil else { return true }
        do {
            try await establishSession()
            return true
        } catch {
            switch error {
            case .invalidPassword, .invalidUsername, .invalidVersion, .rejected:
                credentials = nil
                setState(.failed(error))
                return true
            default:
                return false
            }
        }
    }

    func sendToServer(_ bytes: [UInt8]) async -> Bool {
        guard let server else { return false }
        do {
            try await server.send(bytes)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Server messages

    private func handleServer(_ message: ServerMessage, generation: Int) {
        guard generation == serverGeneration else { return }
        switch message {
        case .connectToPeer(let request):
            handleConnectRequest(request)
        case .excludedPhrases(let phrases):
            excludedPhrases = phrases.map { $0.lowercased() }.filter { !$0.isEmpty }
        case .relogged:
            // Another client signed in with this account. Reconnecting would just kick that client in turn.
            credentials = nil
            reconnectTask?.cancel()
            setState(.kicked)
            tearDownServer()
            finishAllSearches(error: .kicked)
        case .peerAddress(let username, let ip, let port):
            resolveAddress(username: username, address: PeerAddress(ip: ip, port: port))
        case .loginSucceeded, .loginFailed, .cantConnectToPeer, .other:
            break
        }
    }

    // MARK: - Indirect peer connections

    /// The server forwards a peer's request to reach us (we are behind NAT, so peers cannot connect in). We connect out
    /// and identify ourselves with PierceFireWall. Search peers are capped and only accepted while a search is
    /// collecting; peers we are downloading from always get through.
    private func handleConnectRequest(_ request: ConnectRequest) {
        diagnostics.connectRequests += 1
        switch request.type {
        case "P":
            let wanted = transfers.values.contains { $0.peer == request.username }
            if !wanted {
                guard searchesAcceptingPeers() else { return }
                guard activePeerConnections < configuration.maxConcurrentPeerConnections else {
                    diagnostics.droppedAtCap += 1
                    return
                }
            }
            beginPeerConnection()
            let timeout = wanted ? configuration.transferRequestTimeout : configuration.peerReadTimeout
            let config = configuration
            Task { [weak self] in
                guard let self else { return }
                await Self.runPiercedPeer(request, client: self, config: config, readTimeout: timeout)
                await self.endPeerConnection()
            }
        case "F":
            guard transfers.values.contains(where: { $0.peer == request.username && $0.isAwaitingFile }) else {
                return
            }
            let config = configuration
            Task { [weak self] in
                guard let self else { return }
                await Self.runPiercedFile(request, client: self, config: config)
            }
        default:
            // "D" (distributed search relays): pointFlac is a leaf and relays nothing.
            break
        }
    }

    func beginPeerConnection() {
        activePeerConnections += 1
        diagnostics.peakPeerConnections = max(diagnostics.peakPeerConnections, activePeerConnections)
    }

    func endPeerConnection() { activePeerConnections = max(0, activePeerConnections - 1) }

    func notePeerConnectFailure() { diagnostics.peerConnectFailures += 1 }

    @concurrent
    private nonisolated static func runPiercedPeer(
        _ request: ConnectRequest, client: SoulseekClient, config: SoulseekConfiguration, readTimeout: Duration
    ) async {
        let link: TCPLink
        do {
            link = try await TCPLink.connect(host: request.ip, port: request.port, timeout: config.peerConnectTimeout)
            try await link.send(Outgoing.pierceFireWall(token: request.token))
        } catch {
            await client.notePeerConnectFailure()
            return
        }
        await servePeer(
            FramedLink(link, maxFrame: FrameCaps.peer), peer: request.username, client: client,
            readTimeout: readTimeout)
    }

    /// Reads peer messages from one P connection until it closes, times out, or has served its purpose. Search
    /// connections close after their one response unless the peer is also one we are downloading from.
    @concurrent
    nonisolated static func servePeer(_ framed: FramedLink, peer: String, client: SoulseekClient, readTimeout: Duration)
        async
    {
        defer { framed.close() }
        while true {
            let frame: Frame
            do {
                frame = try await framed.nextFrame(timeout: readTimeout)
            } catch {
                return
            }
            let message: PeerMessage
            do {
                message = try PeerMessage.parse(frame)
            } catch {
                await client.noteMalformed()
                continue
            }
            switch message {
            case .searchResponse(let response):
                await client.receiveSearchResponse(response, peer: peer)
                if await !client.hasTransfer(with: peer) { return }
            case .transferRequest(let direction, let token, let path, let size):
                let reply = await client.handleTransferRequest(
                    peer: peer, direction: direction, token: token, path: path, size: size)
                try? await framed.send(reply.bytes)
                reply.deliver()
            case .placeInQueue, .uploadFailed, .uploadDenied:
                await client.handleTransferNotice(message, peer: peer)
            case .other:
                break
            }
        }
    }
}

struct PeerAddress: Sendable, Equatable {
    var ip: String
    var port: UInt32
}
