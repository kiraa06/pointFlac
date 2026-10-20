import Darwin
import PFCore

/// Where rendered audio goes: a RemoteIO unit on device, `FakeOutput` in host tests.
///
/// The contract `PlaybackPipeline` relies on:
/// - `configure` sets the client format: interleaved, packed Float32 or signed Int32 (per `plan.client`) at
///   `plan.clientSampleRate`, `channels` wide. The pipeline always matches the client rate to the hardware rate, so
///   the output never resamples.
/// - Between `start()` and `stop()` the output calls `source?.render(into:frames:)` from its render thread, one call
///   at a time. `stop()` returns only once no render call is in flight, so the pipeline may then drop the source.
/// - The pipeline sets `source` only while the output is stopped, and serialises all of these calls, so an
///   implementation needs no locking of its own for them.
public protocol AudioOutput: AnyObject {
    func configure(_ plan: OutputPlan, channels: Int) throws
    func start() throws
    func stop()
    var source: RenderSource? { get set }
}

/// Why an output could not be set up or started. Each case carries the `OSStatus` the system returned.
public enum AudioOutputError: Error, Equatable {
    /// The output unit could not be created or given its render callback.
    case unitUnavailable(OSStatus)
    /// The unit refused the client format: setting it, or initialising with it.
    case formatRejected(OSStatus)
    /// The unit would not start.
    case startFailed(OSStatus)
}
