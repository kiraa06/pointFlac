import Foundation

/// What the network side tells a running download.
enum TransferSignal: @unchecked Sendable {
    case placeInQueue(Int)
    case accepted(size: Int64)
    case denied(String)
    case uploadFailed
    case sizeMismatch(expected: Int64, announced: Int64)
    case fileConnection(FramedLink, size: Int64)
    case timeout
    case cancelled
}

/// One download the actor is routing messages for.
struct TransferEntry {
    enum Phase: Equatable {
        case waitingForRequest
        case awaitingFile(token: UInt32, size: Int64)
        case receiving
    }

    let peer: String
    let path: String
    let expectedSize: Int64
    let signals: AsyncStream<TransferSignal>.Continuation
    var phase: Phase = .waitingForRequest
    /// The F connection once the body is flowing, so logout can stop it.
    var fileLink: FramedLink?

    var isAwaitingFile: Bool {
        if case .awaitingFile = phase { return true }
        return false
    }
}

extension SoulseekClient {
    /// Downloads one FLAC file into its own folder inside `staging`.
    ///
    /// The flow is the modern Soulseek one: ask the server for the peer's address, connect, send QueueUpload, wait in
    /// the peer's queue, accept its TransferRequest (never for more bytes than the search said), then take the file
    /// over an F connection that the server forwards to us (ConnectToPeer type F, answered with PierceFireWall). The
    /// file lands as `<staging>/slsk-<hash>/<name>.flac`; an interrupted transfer leaves `<name>.flac.part`, and the
    /// next attempt resumes from its length. The caller must validate the file (§5.3) before publishing it.
    ///
    /// The last event is always `.finished` or `.failed`. Stopping iteration cancels the transfer.
    public nonisolated func download(_ file: SearchResultFile, into staging: URL) -> AsyncStream<SoulseekTransferEvent>
    {
        let (events, continuation) = AsyncStream.makeStream(of: SoulseekTransferEvent.self)
        let config = configuration
        let task = Task {
            let outcome = await Self.runDownload(
                file, staging: staging, client: self, config: config, events: continuation)
            continuation.yield(outcome)
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return events
    }

    @concurrent
    private nonisolated static func runDownload(
        _ file: SearchResultFile, staging: URL, client: SoulseekClient, config: SoulseekConfiguration,
        events: AsyncStream<SoulseekTransferEvent>.Continuation
    ) async -> SoulseekTransferEvent {
        guard file.isFLAC else { return .failed(.notFLAC) }
        guard await client.isLoggedIn, let me = await client.username else { return .failed(.notLoggedIn) }

        let folder = staging.appending(
            path: PathSanitizer.transferFolderName(peer: file.peer, path: file.path), directoryHint: .isDirectory)
        let destination = folder.appending(path: file.fileName, directoryHint: .notDirectory)
        let part = folder.appending(path: file.fileName + ".part", directoryHint: .notDirectory)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return .failed(.io("cannot create the staging folder"))
        }

        let (signals, signalContinuation) = AsyncStream.makeStream(of: TransferSignal.self)
        // One transfer per peer and path: two would write the same .part file.
        guard
            let id = await client.registerTransfer(
                TransferEntry(
                    peer: file.peer, path: file.path, expectedSize: file.sizeBytes, signals: signalContinuation))
        else { return .failed(.alreadyInProgress) }
        var controlLink: FramedLink?
        defer { controlLink?.close() }

        let outcome: SoulseekTransferEvent = await {
            guard let address = await client.resolvePeerAddress(file.peer, timeout: config.peerAddressTimeout),
                let port = UInt16(exactly: address.port)
            else { return .failed(.peerOffline) }
            let framed: FramedLink
            do {
                let link = try await TCPLink.connect(host: address.ip, port: port, timeout: config.peerConnectTimeout)
                framed = FramedLink(link, maxFrame: FrameCaps.peer)
                try await framed.send(Outgoing.peerInit(username: me, type: "P"))
                try await framed.send(Outgoing.queueUpload(path: file.path))
            } catch {
                return .failed(.peerUnreachable)
            }
            controlLink = framed
            await client.beginPeerConnection()
            Task {
                await servePeer(framed, peer: file.peer, client: client, readTimeout: config.transferRequestTimeout)
                await client.endPeerConnection()
            }
            events.yield(.requested)
            return await waitAndReceive(
                signals: signals, signalContinuation: signalContinuation, file: file, part: part,
                destination: destination, config: config, events: events)
        }()
        await client.unregisterTransfer(id)
        return outcome
    }

    private nonisolated static func timer(
        _ duration: Duration, _ signals: AsyncStream<TransferSignal>.Continuation
    ) -> Task<Void, Never> {
        Task {
            try? await Task.sleep(for: duration)
            if !Task.isCancelled { signals.yield(.timeout) }
        }
    }

    private nonisolated static func waitAndReceive(
        signals: AsyncStream<TransferSignal>, signalContinuation: AsyncStream<TransferSignal>.Continuation,
        file: SearchResultFile, part: URL, destination: URL, config: SoulseekConfiguration,
        events: AsyncStream<SoulseekTransferEvent>.Continuation
    ) async -> SoulseekTransferEvent {
        var deadline = timer(config.transferRequestTimeout, signalContinuation)
        defer { deadline.cancel() }
        for await signal in signals {
            switch signal {
            case .placeInQueue(let place):
                events.yield(.remotelyQueued(place: place))
            case .accepted:
                deadline.cancel()
                deadline = timer(config.fileConnectionTimeout, signalContinuation)
            case .denied(let reason):
                return .failed(.denied(reason))
            case .uploadFailed:
                return .failed(.uploadFailed)
            case .sizeMismatch(let expected, let announced):
                return .failed(.sizeMismatch(expected: expected, announced: announced))
            case .fileConnection(let framed, let size):
                deadline.cancel()
                return await receiveFile(
                    framed, size: size, part: part, destination: destination, config: config, events: events)
            case .timeout:
                return .failed(.timeout)
            case .cancelled:
                return .failed(.cancelled)
            }
        }
        return .failed(.cancelled)
    }

    /// Streams the file body to the `.part` file, resuming from its current length.
    private nonisolated static func receiveFile(
        _ framed: FramedLink, size: Int64, part: URL, destination: URL, config: SoulseekConfiguration,
        events: AsyncStream<SoulseekTransferEvent>.Continuation
    ) async -> SoulseekTransferEvent {
        defer { framed.close() }
        let manager = FileManager.default
        var offset = Int64((try? manager.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.int64Value ?? 0)
        if offset > size { offset = 0 }
        if !manager.fileExists(atPath: part.path) || offset == 0 {
            guard manager.createFile(atPath: part.path, contents: nil) else { return .failed(.io("cannot create")) }
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: part)
            try handle.truncate(atOffset: UInt64(offset))
            try handle.seekToEnd()
        } catch {
            return .failed(.io("cannot open the partial file"))
        }
        defer { try? handle.close() }

        var received = offset
        do {
            try await framed.send(Outgoing.fileOffset(UInt64(offset)))
            events.yield(.started(offset: offset, size: size))
            var lastReport = ContinuousClock.now
            var chunk = framed.drain()
            while true {
                if !chunk.isEmpty {
                    // Never take more than the accepted size, whatever the peer keeps sending.
                    let take = Int(min(Int64(chunk.count), size - received))
                    try handle.write(contentsOf: chunk.prefix(take))
                    received += Int64(take)
                    let now = ContinuousClock.now
                    if now - lastReport >= .milliseconds(200) || received == size {
                        lastReport = now
                        events.yield(.progress(received: received, size: size))
                    }
                }
                if received >= size { break }
                chunk = try await framed.link.receive(maximum: 256 * 1024, timeout: config.transferIdleTimeout)
            }
        } catch LinkError.timeout {
            return .failed(.timeout)
        } catch is LinkError {
            if Task.isCancelled { return .failed(.cancelled) }
            return .failed(.incomplete(received: received, expected: size))
        } catch {
            if Task.isCancelled { return .failed(.cancelled) }
            return .failed(.io("write failed"))
        }

        do {
            try handle.synchronize()
            try? manager.removeItem(at: destination)
            try manager.moveItem(at: part, to: destination)
        } catch {
            return .failed(.io("cannot finalise the file"))
        }
        return .finished(destination)
    }

    @concurrent
    nonisolated static func runPiercedFile(
        _ request: ConnectRequest, client: SoulseekClient, config: SoulseekConfiguration
    ) async {
        let framed: FramedLink
        let token: UInt32
        do {
            let link = try await TCPLink.connect(
                host: request.ip, port: request.port, timeout: config.peerConnectTimeout)
            try await link.send(Outgoing.pierceFireWall(token: request.token))
            framed = FramedLink(link, maxFrame: FrameCaps.peerInit)
            // FileTransferInit: the uploader names the transfer by the token from its TransferRequest.
            let raw = try await framed.readRaw(4, timeout: config.peerReadTimeout)
            token = UInt32(raw[0]) | UInt32(raw[1]) << 8 | UInt32(raw[2]) << 16 | UInt32(raw[3]) << 24
        } catch {
            await client.notePeerConnectFailure()
            return
        }
        guard let claim = await client.claimFileConnection(peer: request.username, token: token, link: framed) else {
            framed.close()
            return
        }
        claim.signals.yield(.fileConnection(framed, size: claim.size))
    }

    // MARK: - Actor-side routing

    func registerTransfer(_ entry: TransferEntry) -> UUID? {
        guard !transfers.values.contains(where: { $0.peer == entry.peer && $0.path == entry.path }) else { return nil }
        let id = UUID()
        transfers[id] = entry
        return id
    }

    func unregisterTransfer(_ id: UUID) {
        transfers[id]?.signals.finish()
        transfers[id] = nil
    }

    /// The reply to a TransferRequest, plus the signal to deliver once the reply is on the wire. Sending first matters:
    /// a refused download closes its connections at once, and the peer should still hear why.
    struct TransferReply: Sendable {
        var bytes: [UInt8]
        var signal: TransferSignal?
        var signals: AsyncStream<TransferSignal>.Continuation?

        func deliver() { if let signal { signals?.yield(signal) } }
    }

    /// Answers a peer's TransferRequest. Only uploads *to* us for a file we queued, at a size no larger than the
    /// search result, are accepted; pointFlac never uploads (§2).
    func handleTransferRequest(peer: String, direction: UInt32, token: UInt32, path: String, size: Int64?)
        -> TransferReply
    {
        guard direction == 1 else {
            return TransferReply(
                bytes: Outgoing.transferResponse(token: token, allowed: false, reason: "File not shared."))
        }
        guard
            let (id, entry) = transfers.first(where: {
                $0.value.peer == peer && $0.value.path == path && $0.value.phase == .waitingForRequest
            })
        else {
            return TransferReply(bytes: Outgoing.transferResponse(token: token, allowed: false, reason: "Cancelled"))
        }
        guard let size, size > 0, size <= entry.expectedSize else {
            return TransferReply(
                bytes: Outgoing.transferResponse(token: token, allowed: false, reason: "Cancelled"),
                signal: .sizeMismatch(expected: entry.expectedSize, announced: size ?? 0), signals: entry.signals)
        }
        transfers[id]?.phase = .awaitingFile(token: token, size: size)
        return TransferReply(
            bytes: Outgoing.transferResponse(token: token, allowed: true), signal: .accepted(size: size),
            signals: entry.signals)
    }

    func handleTransferNotice(_ message: PeerMessage, peer: String) {
        func entry(for path: String) -> TransferEntry? {
            transfers.values.first { $0.peer == peer && $0.path == path }
        }
        switch message {
        case .placeInQueue(let path, let place):
            entry(for: path)?.signals.yield(.placeInQueue(place))
        case .uploadDenied(let path, let reason):
            entry(for: path)?.signals.yield(.denied(reason))
        case .uploadFailed(let path):
            entry(for: path)?.signals.yield(.uploadFailed)
        default:
            break
        }
    }

    func claimFileConnection(peer: String, token: UInt32, link: FramedLink) -> (
        signals: AsyncStream<TransferSignal>.Continuation, size: Int64
    )? {
        for (id, entry) in transfers where entry.peer == peer {
            if case .awaitingFile(let expectedToken, let size) = entry.phase, expectedToken == token {
                transfers[id]?.phase = .receiving
                transfers[id]?.fileLink = link
                return (entry.signals, size)
            }
        }
        return nil
    }

    func resolvePeerAddress(_ username: String, timeout: Duration) async -> PeerAddress? {
        let id = UUID()
        return await withCheckedContinuation { continuation in
            addressWaiters[id] = (username, continuation)
            Task {
                guard await self.sendToServer(Outgoing.getPeerAddress(username)) else {
                    return await self.expireAddressWaiter(id)
                }
                try? await Task.sleep(for: timeout)
                await self.expireAddressWaiter(id)
            }
        }
    }

    private func expireAddressWaiter(_ id: UUID) {
        addressWaiters.removeValue(forKey: id)?.continuation.resume(returning: nil)
    }

    func resolveAddress(username: String, address: PeerAddress) {
        let usable = address.port > 0 && address.ip != "0.0.0.0" ? address : nil
        for (id, waiter) in addressWaiters where waiter.username == username {
            addressWaiters[id] = nil
            waiter.continuation.resume(returning: usable)
        }
    }
}
