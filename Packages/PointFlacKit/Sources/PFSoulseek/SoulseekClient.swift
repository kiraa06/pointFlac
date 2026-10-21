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
    /// Whether the server has sent its list yet this session. Searches wait briefly for it (see `runSearch`).
    var excludedPhrasesReceived = false
    public internal(set) var diagnostics = Diagnostics()

    /// Counters for tests and the debug screen.
    public struct Diagnostics: Sendable, Equatable {
        public var connectRequests = 0
        public var droppedAtCap = 0
        public var peerConnectFailures = 0
        public var searchResponses = 0
        public var malformedMessages = 0
        public var peakPeerConnections = 0
        public var droppedPerPeer = 0
        public var refusedAddresses = 0
        /// Responses for searches that had already ended, dropped before inflating.
        public var inactiveResponses = 0
    }

    /// Never logs credentials, queries, paths or message contents (§5.8); counts and states only.
    nonisolated let logger = Logger(subsystem: "app.pointflac", category: "soulseek")

    private var credentials: (username: String, password: String)?
    /// Bumped by login, logout and Relogged, so a connect that was in flight when one of them happened is discarded.
    private var sessionEpoch = 0
    private var server: FramedLink?
    private var serverGeneration = 0
    private var serverTasks: [Task<Void, Never>] = []
    private var reconnectTask: Task<Void, Never>?
    private var stateObservers: [UUID: AsyncStream<SoulseekConnectionState>.Continuation] = [:]

    private var nextTokenValue = UInt32.random(in: 1...0x3FFF_FFFF)
    var nextSearchSlot: ContinuousClock.Instant?
    var searches: [UInt32: SearchSession] = [:]
    var activePeerConnections = 0
    var connectionsPerPeer: [String: Int] = [:]
    var peerSlots: [UUID: (peer: String, link: FramedLink?)] = [:]
    /// Bounds how many responses are inflated and parsed at once (memory budget, see `maxConcurrentParses`).
    nonisolated let parseGate: AsyncSemaphore

    var transfers: [UUID: TransferEntry] = [:]
    var folderWaiters:
        [UInt32: (peer: String, flacOnly: Bool, continuation: CheckedContinuation<[SearchResultFile]?, Never>)] = [:]
    var addressWaiters: [UUID: (username: String, continuation: CheckedContinuation<PeerAddress?, Never>)] = [:]

    public init(configuration: SoulseekConfiguration = SoulseekConfiguration()) {
        self.configuration = configuration
        self.parseGate = AsyncSemaphore(configuration.maxConcurrentParses)
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

    /// Waits until the client is signed in, for up to `timeout`. On iOS every connection dies while the app is
    /// suspended, so a download started just after the app returns finds the server link still reconnecting; this
    /// lets it wait out the reconnect instead of failing. Gives up at once when waiting cannot help: the account was
    /// signed in elsewhere, or the client has stopped trying (`.failed` means no reconnect is pending).
    public func waitUntilLoggedIn(timeout: Duration) async -> Bool {
        if isLoggedIn { return true }
        let updates = stateUpdates()
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await state in updates {
                    switch state {
                    case .loggedIn: return true
                    case .kicked, .failed: return false
                    case .disconnected, .connecting, .reconnecting: continue
                    }
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let signedIn = await group.next() ?? false
            group.cancelAll()
            return signedIn
        }
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
        sessionEpoch += 1
        let epoch = sessionEpoch
        credentials = (username, password)
        setState(.connecting)
        do {
            try await establishSession()
        } catch {
            // Only this login's own failure may clear the account: a newer login or a logout owns the state now.
            if epoch == sessionEpoch {
                credentials = nil
                setState(.failed(error))
            }
            throw error
        }
    }

    /// Closes everything. Downloads in progress fail with `cancelled`; their `.part` files stay for a later resume.
    public func logout() {
        sessionEpoch += 1
        credentials = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        tearDownServer()
        finishAllSearches(error: nil)
        cancelTransfers(includingReceiving: true)
        setState(.disconnected)
    }

    private func cancelTransfers(includingReceiving: Bool) {
        for entry in transfers.values {
            if entry.phase == .receiving {
                if includingReceiving { entry.fileLink?.close() }
            } else {
                entry.signals.yield(.cancelled)
            }
        }
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
        let epoch = sessionEpoch
        tearDownServer()
        let config = configuration
        let link: TCPLink
        do {
            link = try await TCPLink.connect(
                host: config.serverHost, port: config.serverPort, timeout: config.connectTimeout)
        } catch {
            throw .serverUnavailable
        }
        guard epoch == sessionEpoch else {
            link.close()
            throw .connectionLost
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
            discard(framed)
            throw .timeout
        } catch {
            discard(framed)
            throw generation == serverGeneration ? .serverUnavailable : .connectionLost
        }
        guard generation == serverGeneration, epoch == sessionEpoch else {
            discard(framed)
            throw .connectionLost
        }

        if case .loginFailed(let reason) = reply {
            logger.notice("Soulseek: login refused (\(reason, privacy: .private))")
            discard(framed)
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
        // A logout or a newer login may have run during those sends.
        guard generation == serverGeneration, epoch == sessionEpoch else {
            discard(framed)
            throw .connectionLost
        }
        excludedPhrasesReceived = false

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
        // Keepalive: an idle server connection is otherwise dropped by NAT boxes and mobile networks.
        serverTasks.append(
            Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: config.keepaliveInterval)
                    guard !Task.isCancelled else { return }
                    try? await framed.send(Outgoing.ping())
                }
            })
        setState(.loggedIn(username: credentials.username))
        logger.info("Soulseek: logged in (protocol \(config.majorVersion, privacy: .public))")
    }

    /// Closes a server link from a login attempt, clearing `server` only if it is still that link.
    private func discard(_ framed: FramedLink) {
        framed.close()
        if server === framed { server = nil }
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
            tearDownServer()  // also stops the keepalive
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
                self?.logger.info("Soulseek: reconnect attempt \(attempt, privacy: .public)")
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self else { return }
                if await self.attemptReconnect() { return }
            }
        }
    }

    /// One reconnect attempt. Returns true when reconnecting should stop (success or a final refusal).
    private func attemptReconnect() async -> Bool {
        guard credentials != nil else { return true }
        let epoch = sessionEpoch
        do {
            try await establishSession()
            return true
        } catch {
            guard epoch == sessionEpoch else { return true }  // a login or logout took over
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
            excludedPhrasesReceived = true
        case .relogged:
            // Another client signed in with this account. Reconnecting would just kick that client in turn.
            sessionEpoch += 1
            credentials = nil
            reconnectTask?.cancel()
            setState(.kicked)
            logger.notice("Soulseek: the account signed in elsewhere; staying signed out")
            tearDownServer()
            finishAllSearches(error: .kicked)
            // Transfers still waiting need the server for their indirect connections; a body already flowing can
            // finish, since it no longer depends on the server.
            cancelTransfers(includingReceiving: false)
        case .peerAddress(let username, let ip, let port):
            resolveAddress(username: username, address: PeerAddress(ip: ip, port: port))
        case .loginSucceeded, .loginFailed, .cantConnectToPeer, .other:
            break
        }
    }

    // MARK: - Indirect peer connections

    /// The server forwards a peer's request to reach us (we are behind NAT, so peers cannot connect in). We connect out
    /// and identify ourselves with PierceFireWall. Search peers are capped globally and per peer, live at most until
    /// the search window ends, and are only accepted while a search is collecting. Peers we are downloading from or
    /// browsing bypass the global cap (a busy search must not stall a download) but still count towards it.
    private func handleConnectRequest(_ request: ConnectRequest) {
        diagnostics.connectRequests += 1
        guard configuration.allowPrivatePeerAddresses || AddressPolicy.isPublic(request.ip) else {
            diagnostics.refusedAddresses += 1
            return
        }
        let config = configuration
        switch request.type {
        case "P":
            let wanted = hasBusiness(with: request.username)
            if !wanted && !searchesAcceptingPeers() { return }
            guard let slot = reservePeerSlot(for: request.username, bypassGlobalCap: wanted) else { return }
            let deadline = wanted ? nil : searchConnectionDeadline()
            let timeout = wanted ? config.transferRequestTimeout : config.peerReadTimeout
            let maxFrame = wanted ? FrameCaps.peer : FrameCaps.searchPeer
            Task {
                await Self.runPiercedPeer(
                    request, client: self, config: config, slot: slot, readTimeout: timeout, deadline: deadline,
                    maxFrame: maxFrame)
                await self.releasePeerSlot(slot)
            }
        case "F":
            guard transfers.values.contains(where: { $0.peer == request.username && $0.isAwaitingFile }),
                let slot = reservePeerSlot(for: request.username, bypassGlobalCap: true)
            else { return }
            Task { await Self.runPiercedFile(request, client: self, config: config, slot: slot) }
        default:
            // "D" (distributed search relays): pointFlac is a leaf and relays nothing.
            break
        }
    }

    /// A search connection lives until the last running search's window closes, and never longer than
    /// `searchConnectionLifetime`, however slowly the peer trickles bytes.
    private func searchConnectionDeadline() -> ContinuousClock.Instant {
        let now = ContinuousClock.now
        let latest = searches.values.map(\.deadline).max() ?? now
        return min(latest, now + configuration.searchConnectionLifetime)
    }

    // MARK: - Connection slots

    /// Reserves one connection slot for `peer`. Every peer connection (search, control, browse, file) holds one, so
    /// the global and per-peer limits see all of them.
    func reservePeerSlot(for peer: String, bypassGlobalCap: Bool) -> UUID? {
        guard connectionsPerPeer[peer, default: 0] < configuration.maxConnectionsPerPeer else {
            diagnostics.droppedPerPeer += 1
            return nil
        }
        if !bypassGlobalCap && activePeerConnections >= configuration.maxConcurrentPeerConnections {
            diagnostics.droppedAtCap += 1
            return nil
        }
        activePeerConnections += 1
        connectionsPerPeer[peer, default: 0] += 1
        diagnostics.peakPeerConnections = max(diagnostics.peakPeerConnections, activePeerConnections)
        let slot = UUID()
        peerSlots[slot] = (peer, nil)
        return slot
    }

    /// Records the link that holds `slot`, so it can be closed when the business with that peer ends.
    func attach(_ link: FramedLink, to slot: UUID) {
        if peerSlots[slot] != nil {
            peerSlots[slot]?.link = link
        } else {
            link.close()
        }
    }

    func releasePeerSlot(_ slot: UUID) {
        guard let entry = peerSlots.removeValue(forKey: slot) else { return }
        activePeerConnections = max(0, activePeerConnections - 1)
        let remaining = connectionsPerPeer[entry.peer, default: 1] - 1
        connectionsPerPeer[entry.peer] = remaining > 0 ? remaining : nil
    }

    /// Closes every link to `peer` once nothing more is expected from it (a download or listing ended), instead of
    /// letting forwarded connections linger for the full transfer timeout.
    func closeIdleLinks(for peer: String) {
        guard !hasBusiness(with: peer) else { return }
        for entry in peerSlots.values where entry.peer == peer { entry.link?.close() }
    }

    func notePeerConnectFailure(_ reason: String = "unknown") {
        diagnostics.peerConnectFailures += 1
        if failureReasons.count < 12 || failureReasons[reason] != nil { failureReasons[reason, default: 0] += 1 }
    }

    /// Connect-failure reasons by count (error descriptions only, never addresses), for the device log.
    var failureReasons: [String: Int] = [:]

    func noteInactiveResponse() { diagnostics.inactiveResponses += 1 }

    @concurrent
    private nonisolated static func runPiercedPeer(
        _ request: ConnectRequest, client: SoulseekClient, config: SoulseekConfiguration, slot: UUID,
        readTimeout: Duration, deadline: ContinuousClock.Instant?, maxFrame: Int
    ) async {
        let framed: FramedLink
        do {
            framed = FramedLink(
                try await TCPLink.connect(host: request.ip, port: request.port, timeout: config.peerConnectTimeout),
                maxFrame: maxFrame)
            await client.attach(framed, to: slot)
            try await framed.send(Outgoing.pierceFireWall(token: request.token))
        } catch {
            await client.notePeerConnectFailure(String(describing: error).prefix(120).description)
            return
        }
        await servePeer(framed, peer: request.username, client: client, readTimeout: readTimeout, deadline: deadline)
    }

    /// Reads peer messages from one P connection until it closes, times out, passes its deadline, or has served its
    /// purpose. Search connections close after their one response unless we also have business with the peer.
    @concurrent
    nonisolated static func servePeer(
        _ framed: FramedLink, peer: String, client: SoulseekClient, readTimeout: Duration,
        deadline: ContinuousClock.Instant? = nil
    ) async {
        defer { framed.close() }
        var timeout = readTimeout
        while true {
            let frame: Frame
            do {
                frame = try await framed.nextFrame(timeout: timeout, deadline: deadline)
            } catch {
                return
            }
            switch frame.code {
            case PeerCode.fileSearchResponse:
                await handleSearchFrame(frame, peer: peer, client: client)
                if await !client.hasBusiness(with: peer) { return }
                continue
            case PeerCode.folderContentsResponse:
                await handleFolderFrame(frame, peer: peer, client: client)
                continue
            default:
                break
            }
            let message: PeerMessage
            do {
                message = try PeerMessage.parse(frame)
            } catch {
                await client.noteMalformed()
                continue
            }
            switch message {
            case .transferRequest(let direction, let token, let path, let size):
                let reply = await client.handleTransferRequest(
                    peer: peer, direction: direction, token: token, path: path, size: size)
                try? await framed.send(reply.bytes)
                reply.deliver()
            case .placeInQueue, .uploadFailed, .uploadDenied:
                await client.handleTransferNotice(message, peer: peer)
            case .searchResponse, .folderContents, .other:
                break
            }
            // Once nothing more is expected from this peer, a lingering connection only gets a short wait.
            if await !client.hasBusiness(with: peer) { timeout = min(timeout, client.configuration.peerReadTimeout) }
        }
    }

    /// Search responses: read the token from the first inflated bytes, drop responses for searches that are not
    /// running, then inflate, parse and filter under the shared parse gate, all off the actor. The actor only
    /// receives the final, capped batch.
    private nonisolated static func handleSearchFrame(_ frame: Frame, peer: String, client: SoulseekClient) async {
        let token: UInt32
        do {
            token = try SearchResponse.token(fromPrefix: Inflate.zlibPrefix(frame.payload, count: 520))
        } catch {
            return await client.noteMalformed()
        }
        guard let filter = await client.resultFilter(forSearch: token) else {
            return await client.noteInactiveResponse()
        }
        await client.parseGate.acquire()
        var files: [SearchResultFile]?
        if let inflated = try? Inflate.zlib(frame.payload, limit: Inflate.searchResponseLimit),
            let response = try? SearchResponse.parse(inflated), response.token == token
        {
            files = response.results(peer: peer, filter: filter)
        }
        await client.parseGate.release()
        guard let files else { return await client.noteMalformed() }
        await client.receiveSearchBatch(files, token: token)
    }

    private nonisolated static func handleFolderFrame(_ frame: Frame, peer: String, client: SoulseekClient) async {
        let token: UInt32
        do {
            var reader = WireReader(try Inflate.zlibPrefix(frame.payload, count: 4))
            token = try reader.u32()
        } catch {
            return await client.noteMalformed()
        }
        guard let filter = await client.listingFilter(token: token, peer: peer) else { return }
        await client.parseGate.acquire()
        var files: [SearchResultFile]?
        if let inflated = try? Inflate.zlib(frame.payload, limit: Inflate.folderListingLimit),
            let listing = try? FolderListing.parse(inflated), listing.token == token
        {
            files = listing.results(peer: peer, filter: filter)
        }
        await client.parseGate.release()
        guard let files else { return await client.noteMalformed() }
        await client.receiveFolderListing(files, token: token, peer: peer)
    }
}

struct PeerAddress: Sendable, Equatable {
    var ip: String
    var port: UInt32
}
