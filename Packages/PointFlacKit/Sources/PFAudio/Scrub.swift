import Foundation
import PFCore
import PFDSP
import Synchronization

// Audible scrubbing (spec §4.3 "audio follows the hand", §5.2): while a finger is on the record, the render thread
// plays a `ScrubVoice` reading a window of decoded music around the needle instead of the pipeline's ring.
//
// - `ScrubWindow` holds the music: a power-of-two ring of Float32 frames at the source rate, keyed by absolute source
//   frame, with the valid range published through atomics.
// - `ScrubFiller` keeps it filled around the needle from its own decoder on its own thread: the pipeline's decoder
//   belongs to the decode thread, and nothing slow may run on the render thread.
// - `ScrubTap` carries the hand from the player to the render thread, and the needle's position back, each field an
//   atomic with a single writer.

/// The decoded music around the needle while scrubbing.
///
/// The filler writes frames, then publishes them by moving `validEnd` up or `validStart` down (release). Before
/// overwriting slots it first gives them up by moving the far bound in (release). The render thread reads only inside
/// the bounds it loaded (acquire) and only near the needle, while the filler only ever gives up frames several seconds
/// from it, so the two never touch the same frames.
final class ScrubWindow: @unchecked Sendable {
    let channels: Int
    let sourceRate: Int
    let capacity: Int
    let mask: Int
    let storage: UnsafeMutablePointer<Float>
    /// The track's length in frames; 0 when unknown.
    let totalFrames: Int64
    let validStart: Atomic<Int64>
    let validEnd: Atomic<Int64>
    /// The frame under the needle, published by the render thread for the filler.
    let head: Atomic<Int64>

    /// About this much music fits: enough for several seconds either side of the needle.
    static let seconds = 8.0

    init(format: AudioFormat, totalFrames: Int64, at frame: Int64) {
        precondition(format.channels > 0 && format.sampleRate > 0, "a scrub window needs a format")
        channels = format.channels
        sourceRate = format.sampleRate
        var size = 1
        while Double(size) < Self.seconds * Double(format.sampleRate) { size <<= 1 }
        capacity = size
        mask = size - 1
        storage = .allocate(capacity: size * format.channels)
        self.totalFrames = totalFrames
        validStart = Atomic(frame)
        validEnd = Atomic(frame)
        head = Atomic(frame)
    }

    deinit {
        storage.deallocate()
    }

    /// The frames that may be read now. Any thread.
    var valid: Range<Int64> {
        let start = validStart.load(ordering: .acquiring)
        let end = validEnd.load(ordering: .acquiring)
        return start..<max(start, end)
    }
}

/// Keeps a `ScrubWindow` filled around the needle: ahead of it and behind it, nearer side first, giving up the far end
/// when the ring is full.
final class ScrubFiller: @unchecked Sendable {
    /// Frames decoded per step.
    static let chunk = 4096
    /// How far either side of the needle the filler keeps decoded.
    static let reachSeconds = 3.0

    let window: ScrubWindow
    private let item: PlaybackItem
    private let makeDecoder: @Sendable (PlaybackItem) throws -> PCMDecoding
    private let stopRequested = Atomic<Bool>(false)
    private let wakeup = DispatchSemaphore(value: 0)
    /// Set when the decoder could not be opened, did not match the window, or failed: the window stays as it is.
    let failed = Atomic<Bool>(false)
    /// Set when the thread has returned. For tests.
    let finished = Atomic<Bool>(false)

    init(item: PlaybackItem, window: ScrubWindow, makeDecoder: @escaping @Sendable (PlaybackItem) throws -> PCMDecoding)
    {
        self.item = item
        self.window = window
        self.makeDecoder = makeDecoder
    }

    func start() {
        let thread = Thread { [self] in
            run()
            finished.store(true, ordering: .releasing)
        }
        thread.name = "pointFlac.scrub"
        // A finger is waiting on it: the music under the needle must arrive within a render cycle or two.
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Asks the thread to stop; it returns on its own after the step it is in.
    func stop() {
        stopRequested.store(true, ordering: .releasing)
        wakeup.signal()
    }

    private var stopping: Bool { stopRequested.load(ordering: .acquiring) }

    private func run() {
        let decoder: PCMDecoding
        do {
            decoder = try makeDecoder(item)
        } catch {
            failed.store(true, ordering: .releasing)
            return
        }
        guard decoder.format.channels == window.channels, decoder.format.sampleRate == window.sourceRate,
            (1...32).contains(decoder.format.bitsPerSample)
        else {
            failed.store(true, ordering: .releasing)
            return
        }
        let channels = window.channels
        let scale = Float(1) / Float(Double(1 << (decoder.format.bitsPerSample - 1)))
        var ints = [Int32](repeating: 0, count: Self.chunk * channels)
        var total = window.totalFrames > 0 ? window.totalFrames : decoder.totalFrames
        let reach = Int64(Self.reachSeconds * Double(window.sourceRate))
        // The ring never fills completely: a second of slack stays between the two ends.
        let span = Int64(window.capacity) - Int64(window.sourceRate)
        var decoderAt: Int64 = -1

        // Fill outward from the needle: the music under it first (from just behind it, which the resampler's taps
        // reach), then whichever side runs short first.
        let start = max(0, window.head.load(ordering: .acquiring) - 256)
        window.validStart.store(start, ordering: .releasing)
        window.validEnd.store(start, ordering: .releasing)

        /// Decodes up to `count` frames from `frame` and converts them into the window's slots. Returns frames read.
        func decode(from frame: Int64, count: Int) throws -> Int {
            if decoderAt != frame { try decoder.seek(toFrame: frame) }
            var done = 0
            try ints.withUnsafeMutableBufferPointer { buffer in
                while done < count {
                    let n = try decoder.read(
                        into: UnsafeMutableBufferPointer(rebasing: buffer[0..<((count - done) * channels)]),
                        maxFrames: count - done)
                    guard n > 0 else { break }
                    for i in 0..<n {
                        let slot = window.storage + Int((frame + Int64(done + i)) & Int64(window.mask)) * channels
                        for c in 0..<channels { slot[c] = Float(buffer[i * channels + c]) * scale }
                    }
                    done += n
                }
            }
            decoderAt = frame + Int64(done)
            return done
        }

        while !stopping {
            let head = window.head.load(ordering: .acquiring)
            let lower = window.validStart.load(ordering: .acquiring)
            let upper = window.validEnd.load(ordering: .acquiring)
            let wantUpper = total > 0 ? min(total, head + reach) : head + reach
            let wantLower = max(0, head - reach)
            let needAhead = upper < wantUpper
            let needBehind = lower > wantLower
            // The side the needle is closer to running out of goes first.
            let forward = needAhead && (!needBehind || upper - head <= head - lower)
            do {
                if forward {
                    let count = Self.chunk
                    // Give up the far end first if this chunk would overfill the ring.
                    if upper + Int64(count) - lower > span {
                        window.validStart.store(upper + Int64(count) - span, ordering: .releasing)
                    }
                    let n = try decode(from: upper, count: count)
                    if n == 0 {
                        total = upper  // the end of the track
                    } else {
                        window.validEnd.store(upper + Int64(n), ordering: .releasing)
                    }
                } else if needBehind {
                    let begin = max(0, lower - Int64(Self.chunk))
                    let count = Int(lower - begin)
                    if upper - begin > span {
                        window.validEnd.store(begin + span, ordering: .releasing)
                    }
                    let n = try decode(from: begin, count: count)
                    guard n == count else { throw CocoaError(.fileReadCorruptFile) }
                    window.validStart.store(begin, ordering: .releasing)
                } else {
                    // Filled both ways: look again shortly, the needle may move.
                    _ = wakeup.wait(timeout: .now() + .milliseconds(3))
                }
            } catch {
                failed.store(true, ordering: .releasing)
                return
            }
        }
    }
}

/// The hand, from the player to the render thread, and the needle, back.
///
/// Each field has one writer. The player writes the run's set-up before bumping `generation` (release), so the render
/// thread, which acquires `generation`, sees a complete run. The hand travels under a sequence lock: the player makes
/// `handSequence` odd, writes, then makes it even; the render thread keeps its last hand unless it read an even,
/// unchanged sequence around the fields.
final class ScrubTap: @unchecked Sendable {
    enum Phase: UInt8 {
        /// No finger on the record: the render thread plays the ring.
        case idle
        /// The voice follows the hand.
        case hand
        /// The hand let go of a playing record: the motor spins the voice up to speed, then the ring takes over.
        case motor
        /// The hand let go of a stopped record: the voice fades out.
        case fade
    }

    // Player → render.
    let phase = Atomic<UInt8>(Phase.idle.rawValue)
    let generation = Atomic<UInt64>(0)
    let anchorFrame = Atomic<Int64>(0)
    let anchorRendered = Atomic<Int64>(0)
    let startSpeedBits = Atomic<UInt64>(0)
    let motorSecondsBits = Atomic<UInt64>(0.9.bitPattern)
    let handSequence = Atomic<UInt64>(0)
    let handOffsetBits = Atomic<UInt64>(0)
    let handSpeedBits = Atomic<UInt64>(0)
    /// The source frame at which the ring takes over again; −1 for none yet.
    let handoverFrame = Atomic<Int64>(-1)
    let window = Atomic<UnsafeMutableRawPointer?>(nil)

    // Render → player.
    let voicePositionBits = Atomic<UInt64>(0)
    let voiceSpeedBits = Atomic<UInt64>(0)
    /// The generation whose voice has handed over to the ring.
    let handedOver = Atomic<UInt64>(0)
    /// Set while a render call may be reading the window (see `retireWindow`).
    let rendering = Atomic<Bool>(false)

    /// The voice and its bookkeeping, touched only by the render thread. Allocated once, never freed while the tap
    /// lives; the render thread reaches them without reference counting.
    let state: UnsafeMutablePointer<ScrubRenderState>

    /// The window of the current run, kept alive here while the render thread may read it.
    private let keep = Mutex<ScrubWindow?>(nil)

    init() {
        state = .allocate(capacity: 1)
        state.initialize(to: ScrubRenderState())
    }

    deinit {
        state.deinitialize(count: 1)
        state.deallocate()
    }

    var currentPhase: Phase { Phase(rawValue: phase.load(ordering: .acquiring)) ?? .idle }

    /// Player: starts a run. The render thread takes over from the ring at its next call.
    func begin(window: ScrubWindow, anchorFrame: Int64, anchorRendered: Int64, startSpeed: Double) {
        keep.withLock { $0 = window }
        self.window.store(Unmanaged.passUnretained(window).toOpaque(), ordering: .releasing)
        self.anchorFrame.store(anchorFrame, ordering: .relaxed)
        self.anchorRendered.store(anchorRendered, ordering: .relaxed)
        startSpeedBits.store(startSpeed.bitPattern, ordering: .relaxed)
        handoverFrame.store(-1, ordering: .relaxed)
        // The hand has just landed and holds the record: a playing record brakes to a stop under it.
        setHand(offsetFrames: 0, speed: 0)
        phase.store(Phase.hand.rawValue, ordering: .releasing)
        generation.wrappingAdd(1, ordering: .acquiringAndReleasing)
    }

    /// Player: the hand is `offsetFrames` source frames from where it landed, turning at platter speed `speed`.
    func setHand(offsetFrames: Double, speed: Double) {
        let sequence = handSequence.load(ordering: .relaxed)
        handSequence.store(sequence &+ 1, ordering: .releasing)
        atomicMemoryFence(ordering: .acquiringAndReleasing)
        handOffsetBits.store(offsetFrames.bitPattern, ordering: .relaxed)
        handSpeedBits.store(speed.bitPattern, ordering: .relaxed)
        handSequence.store(sequence &+ 2, ordering: .releasing)
    }

    /// Render: the hand, if it changed since `last` and was read whole.
    func readHand(after last: UInt64) -> (sequence: UInt64, offset: Double, speed: Double)? {
        let before = handSequence.load(ordering: .acquiring)
        guard before != last, before & 1 == 0 else { return nil }
        let offset = Double(bitPattern: handOffsetBits.load(ordering: .relaxed))
        let speed = Double(bitPattern: handSpeedBits.load(ordering: .relaxed))
        atomicMemoryFence(ordering: .acquiringAndReleasing)
        guard handSequence.load(ordering: .relaxed) == before else { return nil }
        return (before, offset, speed)
    }

    var voicePosition: Double { Double(bitPattern: voicePositionBits.load(ordering: .acquiring)) }
    var voiceSpeed: Double { Double(bitPattern: voiceSpeedBits.load(ordering: .acquiring)) }

    /// Player: ends the run at once (no fade, no handover) and lets the window go once no render call can read it.
    func retireWindow() {
        phase.store(Phase.idle.rawValue, ordering: .sequentiallyConsistent)
        window.store(nil, ordering: .sequentiallyConsistent)
        // A render call that loaded the old pointer set `rendering` first (sequentially consistent with the stores
        // above), so once it reads false no call can still hold the window.
        let deadline = ContinuousClock.now + .milliseconds(200)
        while rendering.load(ordering: .sequentiallyConsistent), ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.0005)
        }
        keep.withLock { $0 = nil }
    }
}

/// The render thread's scrub bookkeeping. Plain values only, so assigning it never allocates or retains.
struct ScrubRenderState {
    init(generation: UInt64 = 0) {
        self.generation = generation
    }

    var voice: ScrubVoice?
    /// The voice has taken over for this run (it stays nil until the music at the needle is decoded).
    var started = false
    var generation: UInt64 = 0
    var handSequence: UInt64 = 0
    /// Where the voice started, the anchor of the hand's offsets.
    var start: Double = 0
    var released = false
    /// Frames of fade-out left (`.fade`), or −1.
    var fadeLeft = -1
    /// Frames of the cross-fade to the ring done so far, or −1 before the handover starts.
    var crossfade = -1
}
