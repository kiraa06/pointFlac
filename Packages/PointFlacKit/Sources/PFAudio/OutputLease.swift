import Foundation
import PFCore

/// Lends the player's one `AudioOutput` to one pipeline at a time, and holds that output: built on the first lease, and
/// again on the first lease after `discardOutput()`.
///
/// The player builds a fresh `PlaybackPipeline` for every start, so that a stopped pipeline's unread events arrive on a
/// stream the player no longer reads. They all render through the same output, and each reaches it only through its
/// own `OutputLease`. A revoked lease drops every call. That matters because a stopped pipeline touches its output
/// once more: `PlaybackPipeline.deinit` stops it and clears its source. The old facade can outlive the next start (an
/// in-flight `start` or `seek` call keeps it alive), and that last `stop()` would otherwise silence its successor.
///
/// The lock also serialises output calls across pipelines, since each pipeline serialises only its own. And it lets
/// the main actor read `hardwareSideSampleRate` and `hardwareSideChannels` while a decode thread may be configuring the
/// output.
///
/// Lock order: a pipeline's own output lock, then this one. Nothing is called back while this lock is held.
final class OutputArbiter: @unchecked Sendable {
    private let lock = NSLock()
    /// Nil until the first lease builds it, and after `discardOutput()`. Touched only while holding `lock`.
    private var output: AudioOutput?
    /// The lease that may drive the output, or nil. Guarded by `lock`.
    private var holder: UInt64?
    /// Guarded by `lock`.
    private var issued: UInt64 = 0

    /// A lease that holds the output from now on. Whichever lease held it before loses it.
    ///
    /// With no output yet (the first start, or the first since `discardOutput()`), `build` makes one first. It runs
    /// under the lock, so no pipeline can reach a half-installed output. If it throws, no lease is issued, and the
    /// lease that held the output before keeps it.
    func lease(building build: () throws -> AudioOutput) throws -> OutputLease {
        let id = try lock.withLock {
            if output == nil { output = try build() }
            issued += 1
            holder = issued
            return issued
        }
        return OutputLease(id: id, arbiter: self)
    }

    /// The output's hardware-side rate after its last `configure`.
    var hardwareSideSampleRate: Int? {
        lock.withLock { output?.hardwareSideSampleRate }
    }

    /// The output's hardware-side channel count after its last `configure`.
    var hardwareSideChannels: Int? {
        lock.withLock { output?.hardwareSideChannels }
    }

    /// Stops the output and drops it for good; the next `lease` builds a fresh one. For a media-services reset, after
    /// which the old output's audio unit is dead. Every lease loses it, so no pipeline, current or retired, can reach the
    /// old output again; it is stopped and its source cleared once, here, and then released.
    func discardOutput() {
        let old = lock.withLock { () -> AudioOutput? in
            defer {
                output = nil
                holder = nil
            }
            return output
        }
        // Outside the lock: no lease can reach `old` any more, so nothing else calls it.
        old?.stop()
        old?.source = nil
    }

    fileprivate func revoke(_ id: UInt64) {
        lock.withLock {
            if holder == id { holder = nil }
        }
    }

    fileprivate func holds(_ id: UInt64) -> Bool {
        lock.withLock { holder == id }
    }

    /// Runs `body` on the output if lease `id` holds it; nil otherwise.
    fileprivate func withOutput<T>(for id: UInt64, _ body: (AudioOutput) throws -> T) rethrows -> T? {
        try lock.withLock {
            guard holder == id, let output else { return nil }
            return try body(output)
        }
    }
}

/// One pipeline's handle on the player's output. While it holds the output, it forwards every call. Once revoked,
/// `stop()` and setting `source` do nothing, and `configure` and `start` throw. So a pipeline that outlives its turn
/// can neither silence its successor nor start the output under it.
final class OutputLease: AudioOutput, Sendable {
    /// What `configure` and `start` throw once the lease is revoked.
    struct Revoked: Error, CustomStringConvertible {
        var description: String { "the output belongs to a newer pipeline" }
    }

    private let id: UInt64
    private let arbiter: OutputArbiter

    fileprivate init(id: UInt64, arbiter: OutputArbiter) {
        self.id = id
        self.arbiter = arbiter
    }

    /// Whether this lease still holds the output, so its pipeline is the player's current one.
    var holdsOutput: Bool {
        arbiter.holds(id)
    }

    /// Takes the output away for good. Stop the pipeline first, while its calls still reach the output.
    func revoke() {
        arbiter.revoke(id)
    }

    func configure(_ plan: OutputPlan, channels: Int) throws {
        guard try arbiter.withOutput(for: id, { try $0.configure(plan, channels: channels) }) != nil else {
            throw Revoked()
        }
    }

    func start() throws {
        guard try arbiter.withOutput(for: id, { try $0.start() }) != nil else { throw Revoked() }
    }

    func stop() {
        _ = arbiter.withOutput(for: id) { $0.stop() }
    }

    var source: RenderSource? {
        get { arbiter.withOutput(for: id) { $0.source } ?? nil }
        set { _ = arbiter.withOutput(for: id) { $0.source = newValue } }
    }

    var hardwareSideSampleRate: Int? {
        arbiter.withOutput(for: id) { $0.hardwareSideSampleRate } ?? nil
    }

    var hardwareSideChannels: Int? {
        arbiter.withOutput(for: id) { $0.hardwareSideChannels } ?? nil
    }
}
