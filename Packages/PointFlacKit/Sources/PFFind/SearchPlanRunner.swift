/// Runs a ``SearchPlan`` against a provider the way the planner intends: one variant at a time, spaced by the
/// provider's search rate limit, stopping as soon as there are enough good album candidates.
///
/// Soulseek throttles accounts that search too often (spec §4.6: at least a few seconds between searches), so the
/// runner shares one ``TokenBucket`` across every run. Each batch of files is merged and re-ranked as it arrives, so
/// the UI fills while the search is still running.
public struct SearchPlanRunner: Sendable {
    /// One provider search for a literal query: batches of files until the provider's time window ends.
    public typealias Search = @Sendable (_ query: String) -> AsyncThrowingStream<[CandidateFile], Error>

    public let bucket: TokenBucket
    /// Stop after a variant once this many album candidates are complete…
    public let enoughComplete: Int
    /// …or this many candidates of any completeness.
    public let enoughCandidates: Int
    public let preference: FormatPreference

    public init(
        bucket: TokenBucket = .soulseekSearch, enoughComplete: Int = 3, enoughCandidates: Int = 8,
        preference: FormatPreference = .highest
    ) {
        self.bucket = bucket
        self.enoughComplete = enoughComplete
        self.enoughCandidates = enoughCandidates
        self.preference = preference
    }

    /// Ranked album candidates, re-emitted as batches arrive (at most every ``rankInterval``, and always at the end
    /// of a variant). Finishes when the plan is exhausted, enough candidates are found, or the consumer stops
    /// listening (which cancels the provider search in flight).
    public func albums(
        _ plan: SearchPlan, for entity: ResolvedEntity, excludedPhrases: [String] = [], search: @escaping Search
    ) -> AsyncStream<[AlbumCandidate]> {
        let preference = preference
        let enoughComplete = enoughComplete
        let enoughCandidates = enoughCandidates
        return run(
            plan, search: search,
            rank: { files in
                ResultRanker.rankAlbums(files, for: entity, preference: preference, excludedPhrases: excludedPhrases)
            },
            isEnough: { ranked in
                // Oversized folders are not complete (``AlbumCandidate/isComplete``), so a discography never stops it.
                ranked.filter(\.isComplete).count >= enoughComplete || ranked.count >= enoughCandidates
            })
    }

    /// Ranked track candidates for a track entity, for tracks with no known album or when one file is wanted.
    public func tracks(
        _ plan: SearchPlan, for entity: ResolvedEntity, excludedPhrases: [String] = [], search: @escaping Search
    ) -> AsyncStream<[TrackCandidate]> {
        let preference = preference
        let enoughCandidates = enoughCandidates
        return run(
            plan, search: search,
            rank: { files in
                ResultRanker.rankTracks(files, for: entity, preference: preference, excludedPhrases: excludedPhrases)
            },
            isEnough: { $0.count >= enoughCandidates })
    }

    /// How often a growing result list is re-ranked. Re-ranking every batch of a broad query (thousands of files)
    /// was the cost; four times a second still feels live.
    public static let rankInterval: Duration = .milliseconds(250)

    private func run<Ranked: Sendable>(
        _ plan: SearchPlan, search: @escaping Search, rank: @escaping @Sendable ([CandidateFile]) -> [Ranked],
        isEnough: @escaping @Sendable ([Ranked]) -> Bool
    ) -> AsyncStream<[Ranked]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [Ranked].self, bufferingPolicy: .bufferingNewest(4))
        let bucket = bucket
        let task = Task {
            defer { continuation.finish() }
            let clock = ContinuousClock()
            var files: [CandidateFile] = []
            var seen = Set<String>()
            var lastRank = clock.now - Self.rankInterval
            for variant in plan.variants {
                var unranked = false
                do {
                    try await bucket.acquire()
                    for try await batch in search(variant.query) {
                        for file in batch where seen.insert((file.peer ?? "") + "|" + file.path).inserted {
                            files.append(file)
                            unranked = true
                        }
                        if unranked, clock.now - lastRank >= Self.rankInterval {
                            continuation.yield(rank(files))
                            lastRank = clock.now
                            unranked = false
                        }
                    }
                } catch is CancellationError {
                    return
                } catch {
                    // One failed variant (a provider timeout) does not end the plan; the next variant may work.
                    if Task.isCancelled { return }
                }
                let ranked = rank(files)
                if unranked {
                    continuation.yield(ranked)
                    lastRank = clock.now
                }
                if isEnough(ranked) { return }
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}
