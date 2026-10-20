import Foundation

extension SoulseekClient {
    /// Lists every file in one remote folder, for the album preview before downloading (§4.7: "Album folders are
    /// previewed (full FLAC listing) before downloading").
    ///
    /// Pass a result's `folder` and `peer`. The listing has no slot, speed or queue figures (it is not a search
    /// response), so those fields keep their defaults; merge them from the search result if the UI shows them. Sizes in
    /// the listing are what the download size check enforces. Throws `peerOffline`, `peerUnreachable` or `timeout`.
    public func browseFolder(_ folder: String, of peer: String, flacOnly: Bool = true)
        async throws(SoulseekTransferFailure) -> [SearchResultFile]
    {
        guard isLoggedIn, let me = username else { throw .notLoggedIn }
        let token = makeToken()
        let config = configuration
        guard let address = await resolvePeerAddress(peer, timeout: config.peerAddressTimeout),
            let port = UInt16(exactly: address.port)
        else { throw .peerOffline }
        let framed: FramedLink
        do {
            framed = FramedLink(
                try await TCPLink.connect(host: address.ip, port: port, timeout: config.peerConnectTimeout),
                maxFrame: FrameCaps.peer)
        } catch {
            throw .peerUnreachable
        }
        defer { framed.close() }

        let files: [SearchResultFile]? = await withCheckedContinuation { continuation in
            folderWaiters[token] = (peer, continuation)
            beginPeerConnection()
            Task {
                do {
                    try await framed.send(Outgoing.peerInit(username: me, type: "P"))
                    try await framed.send(Outgoing.folderContentsRequest(token: token, folder: folder))
                } catch {
                    await self.expireFolderWaiter(token)
                }
                // The answer may come back on this connection or on a new server-forwarded one; both are served.
                Task {
                    await Self.servePeer(framed, peer: peer, client: self, readTimeout: config.browseTimeout)
                    await self.endPeerConnection()
                }
                try? await Task.sleep(for: config.browseTimeout)
                await self.expireFolderWaiter(token)
            }
        }
        guard let files else { throw .timeout }
        return flacOnly ? files.filter(\.isFLAC) : files
    }

    func expireFolderWaiter(_ token: UInt32) {
        folderWaiters.removeValue(forKey: token)?.continuation.resume(returning: nil)
    }

    func receiveFolderListing(_ listing: FolderListing, peer: String) {
        guard let waiter = folderWaiters[listing.token], waiter.peer == peer else { return }
        folderWaiters[listing.token] = nil
        let files = listing.files
            .filter { $0.size > 0 && !matchesExcludedPhrase($0.path) }
            .map { file in
                SearchResultFile(
                    peer: peer, path: file.path, sizeBytes: file.size, bitsPerSample: file.attributes[5].map(Int.init),
                    sampleRate: file.attributes[4].map(Int.init), bitrate: file.attributes[0].map(Int.init),
                    durationSeconds: file.attributes[1].map(Int.init))
            }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        waiter.continuation.resume(returning: files)
    }

    /// Whether we expect traffic from this peer beyond a search response: a download or a folder listing.
    func hasBusiness(with peer: String) -> Bool {
        transfers.values.contains { $0.peer == peer } || folderWaiters.values.contains { $0.peer == peer }
    }
}
