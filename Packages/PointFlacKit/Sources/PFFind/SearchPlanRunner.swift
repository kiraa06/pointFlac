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
        bucket: TokenBucket = TokenBucket(interval: .seconds(5)), enoughComplete: Int = 3, enoughCandidates: Int = 8,
        preference: FormatPreference = .highest
    ) {
        self.bucket = bucket
        self.enoughComplete = enoughComplete
        self.enoughCandidates = enoughCandidates
        self.preference = preference
    }

    /// Ranked album candidates, re-emitted after every batch. Finishes when the plan is exhausted, enough candidates
    /// are found, or the consumer stops listening (which cancels the provider search in flight).
    public func albums(
        _ plan: SearchPlan, for entity: ResolvedEntity, excludedPhrases: [String] = [], search: @escaping Search
    ) -> AsyncStream<[AlbumCandidate]> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: [AlbumCandidate].self, bufferingPolicy: .bufferingNewest(4))
        let runner = self
        let task = Task {
            defer { continuation.finish() }
            var files: [CandidateFile] = []
            var seen = Set<String>()
            for variant in plan.variants {
                do {
                    try await runner.bucket.acquire()
                    for try await batch in search(variant.query) {
                        for file in batch where seen.insert((file.peer ?? "") + "|" + file.path).inserted {
                            files.append(file)
                        }
                        continuation.yield(
                            ResultRanker.rankAlbums(
                                files, for: entity, preference: runner.preference, excludedPhrases: excludedPhrases))
                    }
                } catch is CancellationError {
                    return
                } catch {
                    // One failed variant (a provider timeout) does not end the plan; the next variant may work.
                    if Task.isCancelled { return }
                    continue
                }
                let ranked = ResultRanker.rankAlbums(
                    files, for: entity, preference: runner.preference, excludedPhrases: excludedPhrases)
                if ranked.filter(\.isComplete).count >= runner.enoughComplete
                    || ranked.count >= runner.enoughCandidates
                {
                    return
                }
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}
