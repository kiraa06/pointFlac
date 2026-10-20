import Foundation

/// One downloadable file as a provider describes it. Everything in it is a claim by a remote party: the manager
/// trusts none of it until the downloaded bytes pass `FlacValidator`.
public struct RemoteTrack: Sendable, Hashable, Identifiable, Codable {
    /// Unique within the provider and stable across searches, so the queue can recognise a track it already has.
    public var id: String
    /// The provider's `id`, e.g. "archive" or "soulseek".
    public var provider: String
    public var title: String
    public var artist: String?
    public var album: String?
    /// The remote file name. It must end in `.flac` (FLAC-only policy); the manager sanitises it before use.
    public var fileName: String
    public var sizeBytes: Int64?
    public var bitsPerSample: Int?
    public var sampleRate: Int?
    /// Provider-specific facts, e.g. "peer", "path", "identifier", "licence".
    public var detail: [String: String]

    public init(
        id: String, provider: String, title: String, artist: String? = nil, album: String? = nil, fileName: String,
        sizeBytes: Int64? = nil, bitsPerSample: Int? = nil, sampleRate: Int? = nil, detail: [String: String] = [:]
    ) {
        self.id = id
        self.provider = provider
        self.title = title
        self.artist = artist
        self.album = album
        self.fileName = fileName
        self.sizeBytes = sizeBytes
        self.bitsPerSample = bitsPerSample
        self.sampleRate = sampleRate
        self.detail = detail
    }
}

/// What a provider reports while it downloads one track.
public enum DownloadEvent: Sendable, Equatable {
    case queued
    /// Fraction done, 0...1.
    case progress(Double)
    /// The complete file, inside the staging directory the provider was given.
    case finished(URL)
    /// The provider gave up; the manager does not retry this.
    case failed(String)
}

/// A source of music files: the Internet Archive, or Soulseek through an adapter.
public protocol DownloadProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    /// Batches of results as they arrive; finishes when the provider is done or the time window ends.
    func search(_ query: String) -> AsyncThrowingStream<[RemoteTrack], Error>
    /// Downloads into `staging` (a directory); the last event is .finished(fileURL) or .failed.
    func download(_ track: RemoteTrack, into staging: URL) -> AsyncThrowingStream<DownloadEvent, Error>
}

extension RemoteTrack {
    /// What a result row shows as the format, using only what the provider actually stated: "FLAC 24/96",
    /// "FLAC 24-bit", or plain "FLAC" when the depth is unknown. Nothing is guessed.
    public var formatLabel: String {
        switch (bitsPerSample, sampleRate) {
        case (let bits?, let rate?):
            let kilohertz = Double(rate) / 1000
            let rateText =
                kilohertz == kilohertz.rounded() ? String(Int(kilohertz)) : String(format: "%.1f", kilohertz)
            return "FLAC \(bits)/\(rateText)"
        case (let bits?, nil): return "FLAC \(bits)-bit"
        case (nil, let rate?): return "FLAC \(String(format: "%g", Double(rate) / 1000)) kHz"
        case (nil, nil): return "FLAC"
        }
    }

    /// The listed size for a result row, e.g. "3.6 MB", or empty when the provider did not say.
    public var sizeLabel: String {
        guard let sizeBytes else { return "" }
        return ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}
