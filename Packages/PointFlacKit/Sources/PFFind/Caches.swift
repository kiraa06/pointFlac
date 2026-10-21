import CryptoKit
import Foundation
import Synchronization

/// A small thread-safe least-recently-used cache.
///
/// Typeahead reads it synchronously on every keystroke, so it is a `Mutex`-guarded dictionary rather than an actor:
/// no suspension point between the keystroke and the cached rows. Eviction scans for the oldest entry, which is
/// cheaper than list bookkeeping at the few hundred entries it holds.
public final class LRUCache<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    private struct State {
        var entries: [Key: (value: Value, tick: UInt64, cost: Int)] = [:]
        var tick: UInt64 = 0
        var totalCost = 0
    }

    public let capacity: Int
    /// The most total cost (for example bytes) the cache holds; the oldest entries go first beyond it.
    public let maxCost: Int
    private let cost: @Sendable (Value) -> Int
    private let state = Mutex(State())

    public init(capacity: Int, maxCost: Int = .max, cost: @escaping @Sendable (Value) -> Int = { _ in 0 }) {
        precondition(capacity > 0, "an LRU cache holds at least one entry")
        self.capacity = capacity
        self.maxCost = maxCost
        self.cost = cost
    }

    /// The value for `key`, marking it most recently used.
    public func value(for key: Key) -> Value? {
        state.withLock { state in
            guard let entry = state.entries[key] else { return nil }
            state.tick &+= 1
            state.entries[key] = (entry.value, state.tick, entry.cost)
            return entry.value
        }
    }

    /// Stores `value`, evicting the least recently used entry when full.
    public func insert(_ value: Value, for key: Key) {
        let itemCost = cost(value)
        state.withLock { state in
            state.tick &+= 1
            if let previous = state.entries[key] { state.totalCost -= previous.cost }
            state.entries[key] = (value, state.tick, itemCost)
            state.totalCost += itemCost
            while state.entries.count > capacity || (state.totalCost > maxCost && state.entries.count > 1),
                let oldest = state.entries.min(by: { $0.value.tick < $1.value.tick })?.key
            {
                state.totalCost -= state.entries[oldest]?.cost ?? 0
                state.entries[oldest] = nil
            }
        }
    }

    public func remove(_ key: Key) {
        state.withLock { state in
            if let entry = state.entries.removeValue(forKey: key) { state.totalCost -= entry.cost }
        }
    }

    public func removeAll() {
        state.withLock { state in
            state.entries.removeAll()
            state.totalCost = 0
        }
    }

    public var totalCost: Int {
        state.withLock { $0.totalCost }
    }

    public var count: Int {
        state.withLock { $0.entries.count }
    }
}

/// A small on-disk response cache with a time to live.
///
/// MusicBrainz data changes slowly, so a week-old answer is still a good suggestion, and an expired one is far better
/// than nothing when the phone is offline: ``read(_:allowStale:now:)`` can return it, marked stale. Each entry is
/// one file named by the SHA-256 of its key; its modification date is its age. The folder is pruned oldest-first
/// beyond ``maxEntries`` so the cache never grows without bound.
public struct DiskCache: Sendable {
    public let directory: URL
    public let timeToLive: TimeInterval
    public let maxEntries: Int

    public init(directory: URL, timeToLive: TimeInterval = 7 * 24 * 3600, maxEntries: Int = 2_000) {
        self.directory = directory
        self.timeToLive = timeToLive
        self.maxEntries = maxEntries
    }

    /// The default location: `Caches/pointFlac/MusicBrainz`, which iOS may purge under storage pressure.
    public static func defaultDirectory() -> URL {
        let caches =
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appending(path: "pointFlac/MusicBrainz", directoryHint: .isDirectory)
    }

    /// The cached data for `key`, if present and fresh, or present at all when `allowStale` is set.
    public func read(_ key: String, allowStale: Bool = false, now: Date = Date()) -> (data: Data, isFresh: Bool)? {
        let url = fileURL(for: key)
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let modified = attributes[.modificationDate] as? Date
        else { return nil }
        let isFresh = now.timeIntervalSince(modified) < timeToLive
        guard isFresh || allowStale, let data = try? Data(contentsOf: url) else { return nil }
        return (data, isFresh)
    }

    /// Stores `data` for `key`, stamped `now`. Failures are ignored: a cache that cannot write is just a miss.
    public func write(_ data: Data, for key: String, now: Date = Date()) {
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = fileURL(for: key)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        try? manager.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
        prune()
    }

    /// Deletes the entry for `key`, if any.
    public func remove(_ key: String) {
        try? FileManager.default.removeItem(at: fileURL(for: key))
    }

    /// Deletes every entry: the cache folder and everything in it.
    public func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func fileURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "\(digest).json", directoryHint: .notDirectory)
    }

    private func prune() {
        let manager = FileManager.default
        guard
            let files = try? manager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey]),
            files.count > maxEntries
        else { return }
        let dated = files.map { url in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            return (url, values?.contentModificationDate ?? .distantPast)
        }
        for (url, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(files.count - maxEntries) {
            try? manager.removeItem(at: url)
        }
    }
}
