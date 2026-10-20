import Foundation

/// One running search, owned by the actor.
struct SearchSession {
    let token: UInt32
    let options: SoulseekSearchOptions
    let continuation: AsyncThrowingStream<[SearchResultFile], any Error>.Continuation
    let deadline: ContinuousClock.Instant
    let acceptPeersUntil: ContinuousClock.Instant
    var pending: [SearchResultFile] = []
    var delivered = 0
    var seen: Set<String> = []
    var reachedCap = false
}

extension SoulseekClient {
    /// Searches the network and streams batches of matching files.
    ///
    /// The stream throws `SoulseekError.notLoggedIn`, `.emptyQuery` or `.excludedPhrase` up front, and
    /// `.connectionLost` or `.kicked` if the server goes away mid-search. Otherwise it finishes when the window ends,
    /// when `options.maxFiles` have been delivered, or when the consumer stops iterating. Searches are spaced at least
    /// `searchMinimumInterval` apart; a search started sooner waits its turn rather than flooding the server.
    ///
    /// Soulseek matches words literally: every word of the query must appear in the path. Callers that resolve a
    /// "canonical" name should search for fewer, distinctive words.
    public nonisolated func search(
        _ query: String, options: SoulseekSearchOptions = SoulseekSearchOptions()
    ) -> AsyncThrowingStream<[SearchResultFile], any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: [SearchResultFile].self)
        let task = Task { await self.runSearch(query, options: options, continuation: continuation) }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    func matchesExcludedPhrase(_ text: String) -> Bool {
        guard !excludedPhrases.isEmpty else { return false }
        let lowered = text.lowercased()
        return excludedPhrases.contains { lowered.contains($0) }
    }

    private func runSearch(
        _ query: String, options: SoulseekSearchOptions,
        continuation: AsyncThrowingStream<[SearchResultFile], any Error>.Continuation
    ) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return continuation.finish(throwing: SoulseekError.emptyQuery) }
        guard isLoggedIn else { return continuation.finish(throwing: SoulseekError.notLoggedIn) }
        let phrasesDeadline = ContinuousClock.now + configuration.excludedPhrasesWait
        while !excludedPhrasesReceived, ContinuousClock.now < phrasesDeadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
        }
        // Wait once per session at most: a server that never sends the list must not slow every search.
        excludedPhrasesReceived = true
        guard !matchesExcludedPhrase(trimmed) else {
            return continuation.finish(throwing: SoulseekError.excludedPhrase)
        }

        // Reserve the next slot before sleeping, so concurrent callers queue up instead of all firing together.
        let now = ContinuousClock.now
        let slot = max(now, nextSearchSlot ?? now)
        reserveSearchSlot(after: slot)
        if slot > now { try? await Task.sleep(until: slot, clock: .continuous) }
        guard !Task.isCancelled else { return continuation.finish() }
        guard isLoggedIn else { return continuation.finish(throwing: SoulseekError.notLoggedIn) }

        let token = makeToken()
        let start = ContinuousClock.now
        let deadline = start + options.window
        let tail = min(configuration.searchTailCutoff, options.window / 2)
        searches[token] = SearchSession(
            token: token, options: options, continuation: continuation, deadline: deadline,
            acceptPeersUntil: deadline - tail)
        guard await sendToServer(Outgoing.fileSearch(token: token, query: trimmed)) else {
            searches[token] = nil
            return continuation.finish(throwing: SoulseekError.connectionLost)
        }

        while !Task.isCancelled, ContinuousClock.now < deadline {
            try? await Task.sleep(for: options.batchInterval)
            guard searches[token] != nil else { return }  // finished elsewhere (kicked, lost, logout)
            flush(token)
            if searches[token]?.reachedCap == true { break }
        }
        flush(token)
        if let session = searches.removeValue(forKey: token) {
            logger.info("Soulseek: search finished with \(session.delivered, privacy: .public) files")
        }
        continuation.finish()
    }

    private func reserveSearchSlot(after slot: ContinuousClock.Instant) {
        nextSearchSlot = slot + configuration.searchMinimumInterval
    }

    private func flush(_ token: UInt32) {
        guard var session = searches[token], !session.pending.isEmpty else { return }
        let batch = session.pending
        session.pending = []
        session.delivered += batch.count
        searches[token] = session
        session.continuation.yield(batch)
    }

    func searchesAcceptingPeers() -> Bool {
        let now = ContinuousClock.now
        return searches.values.contains { !$0.reachedCap && now < $0.acceptPeersUntil }
    }

    /// The filter a per-peer task applies before handing results over, or `nil` when no search with this token is
    /// collecting (the response is then dropped without being inflated).
    func resultFilter(forSearch token: UInt32) -> ResultFilter? {
        guard let session = searches[token], !session.reachedCap else { return nil }
        let room = session.options.maxFiles - session.delivered - session.pending.count
        guard room > 0 else { return nil }
        return ResultFilter(
            flacOnly: session.options.flacOnly, excludedPhrases: excludedPhrases,
            limit: min(room, SearchResponse.maxFilesKept))
    }

    /// Takes one peer's already filtered, capped batch. Only de-duplication and the early-stop cap happen here.
    func receiveSearchBatch(_ files: [SearchResultFile], token: UInt32) {
        diagnostics.searchResponses += 1
        guard var session = searches[token], !session.reachedCap else { return }
        for file in files where session.seen.insert(file.id).inserted {
            session.pending.append(file)
            if session.delivered + session.pending.count >= session.options.maxFiles {
                session.reachedCap = true
                break
            }
        }
        searches[token] = session
    }

    func finishAllSearches(error: SoulseekError?) {
        let sessions = searches.values
        searches = [:]
        for session in sessions {
            if !session.pending.isEmpty { session.continuation.yield(session.pending) }
            if let error {
                session.continuation.finish(throwing: error)
            } else {
                session.continuation.finish()
            }
        }
    }
}
