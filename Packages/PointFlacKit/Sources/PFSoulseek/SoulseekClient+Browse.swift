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
        guard let slot = reservePeerSlot(for: peer, bypassGlobalCap: true) else { throw .peerUnreachable }
        let framed: FramedLink
        do {
            framed = FramedLink(
                try await TCPLink.connect(host: address.ip, port: port, timeout: config.peerConnectTimeout),
                maxFrame: FrameCaps.peer)
        } catch {
            releasePeerSlot(slot)
            throw .peerUnreachable
        }
        attach(framed, to: slot)
        defer { framed.close() }

        let files: [SearchResultFile]? = await withCheckedContinuation { continuation in
            folderWaiters[token] = (peer, flacOnly, continuation)
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
                    await self.releasePeerSlot(slot)
                }
                try? await Task.sleep(for: config.browseTimeout)
                await self.expireFolderWaiter(token)
            }
        }
        guard let files else { throw .timeout }
        return files
    }

    func expireFolderWaiter(_ token: UInt32) {
        guard let waiter = folderWaiters.removeValue(forKey: token) else { return }
        waiter.continuation.resume(returning: nil)
        closeIdleLinks(for: waiter.peer)
    }

    /// The filter for a listing we asked this peer for, or `nil` if we did not (the listing is then not inflated).
    func listingFilter(token: UInt32, peer: String) -> ResultFilter? {
        guard let waiter = folderWaiters[token], waiter.peer == peer else { return nil }
        return ResultFilter(flacOnly: waiter.flacOnly, excludedPhrases: excludedPhrases, limit: FolderListing.maxFiles)
    }

    /// Takes a listing that the per-peer task already filtered and sorted.
    func receiveFolderListing(_ files: [SearchResultFile], token: UInt32, peer: String) {
        guard let waiter = folderWaiters[token], waiter.peer == peer else { return }
        folderWaiters[token] = nil
        waiter.continuation.resume(returning: files)
        closeIdleLinks(for: peer)
    }

    /// Whether we expect traffic from this peer beyond a search response: a download or a folder listing.
    func hasBusiness(with peer: String) -> Bool {
        transfers.values.contains { $0.peer == peer } || folderWaiters.values.contains { $0.peer == peer }
    }
}
