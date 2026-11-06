import Foundation

/// Where one download is in the pipeline (spec §4.7, Downloads list).
///
/// The happy path is `queued → downloading → validating → saving → published`. A download only counts as finished
/// once it is `published`, i.e. it passed validation and the library accepted it (spec §5.4).
public enum DownloadState: Sendable, Hashable, Codable {
    case queued
    /// `progress` is 0...1, or `nil` while the provider has not reported a fraction yet.
    case downloading(progress: Double?)
    /// The source has the request but is not sending yet: a Soulseek peer sends one file at a time to each person
    /// and keeps the rest in its upload queue. Becomes `downloading` again when bytes flow.
    case waiting
    /// The file is complete and is being checked against the FLAC admission rule.
    case validating
    /// The file passed validation and is being handed to the library.
    case saving
    /// The user paused it: the transfer is stopped, its staging folder and partial file kept, and it waits for
    /// `resume`, even across launches. `progress` is how far it had got, when the provider had said.
    case paused(progress: Double?)
    case published
    /// A plain-language reason, safe to show in the UI.
    case failed(String)
    case cancelled

    /// No further transitions happen without `retry`.
    public var isFinal: Bool {
        switch self {
        case .published, .failed, .cancelled: true
        case .queued, .downloading, .waiting, .validating, .saving, .paused: false
        }
    }

    /// Whether `pause` takes the job: only before validation. A validated file is moments from the library, and
    /// stopping it there would gain nothing.
    public var isPausable: Bool {
        switch self {
        case .queued, .downloading, .waiting: true
        case .validating, .saving, .paused, .published, .failed, .cancelled: false
        }
    }

    /// A short label for the Downloads list.
    public var label: String {
        switch self {
        case .queued: "Queued"
        case .downloading: "Downloading"
        case .waiting: "Waiting"
        case .validating: "Checking"
        case .saving: "Saving"
        case .paused(let progress?): "Paused · \(Int((progress * 100).rounded()))%"
        case .paused(nil): "Paused"
        case .published: "Done"
        case .failed(let reason): "Failed: \(reason)"
        case .cancelled: "Cancelled"
        }
    }

    /// Fraction done for a progress bar, or `nil` when there is nothing meaningful to draw.
    public var progress: Double? {
        switch self {
        case .downloading(let progress): progress
        case .validating, .saving, .published: 1
        case .queued, .waiting, .paused, .failed, .cancelled: nil
        }
    }
}

/// One entry in the download queue, as the UI sees it.
public struct DownloadItem: Sendable, Hashable, Identifiable, Codable {
    /// The job's own identifier. A track that is downloaded again after being removed gets a new job.
    public let id: String
    public var track: RemoteTrack
    public var state: DownloadState
    /// Download attempts made so far, including retries after transient errors.
    public var attempts: Int
    public let createdAt: Date
    /// The validated file waiting in staging after a failed `publish`, so a retry need not download again.
    var stagedFileName: String?
    /// Set when the job was published somewhere other than asked, in words for the Downloads list ("Saved in
    /// pointFlac (folder unavailable)"); `nil` for a plain "Done". Optional, so queues saved before it existed load.
    public var note: String?
    /// The library track the download became when it was published: the track admitted from the download folder, the
    /// one the app's import added, or the one it already had. Lets the Downloads list delete the song. Optional, so
    /// queues saved before it existed load.
    public var publishedTrackID: String?

    init(id: String, track: RemoteTrack, state: DownloadState = .queued, attempts: Int = 0, createdAt: Date = Date()) {
        self.id = id
        self.track = track
        self.state = state
        self.attempts = attempts
        self.createdAt = createdAt
    }
}
