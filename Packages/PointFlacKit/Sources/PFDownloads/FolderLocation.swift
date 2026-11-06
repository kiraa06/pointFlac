import Foundation

/// Where a picked download folder is, judged from its path alone.
///
/// A bookmark follows its folder when it moves, and deleting a folder in Files moves it into a trash (iCloud Drive's
/// Recently Deleted is a `.Trash` folder; a volume's is `.Trashes`), so a deleted download folder still resolves.
/// Downloads must not keep landing there, out of sight until the trash is emptied and they are gone. Nor may the
/// folder be inside the app's own container: deleting the app deletes it, which is what the feature exists to avoid.
public enum FolderLocation {
    /// Folder names that are trashes. Compared ignoring case: the file system does.
    static let trashNames: Set<String> = [".trash", ".trashes"]

    /// Whether any folder on the way to `url` is a trash.
    public static func isInTrash(_ url: URL) -> Bool {
        url.standardizedFileURL.pathComponents.contains { trashNames.contains($0.lowercased()) }
    }

    /// Whether `url` is `container` or inside it. Symlinks are resolved and `/private` is ignored, so `/var/…` and
    /// `/private/var/…` agree, and a trailing slash keeps "ABC2" from counting as inside "ABC".
    public static func isInside(_ url: URL, container: URL) -> Bool {
        isInside(url, comparableContainer: comparablePath(container))
    }

    /// `isInside` with the container's `comparablePath` worked out beforehand, so checking many files resolves only
    /// theirs.
    public static func isInside(_ url: URL, comparableContainer: String) -> Bool {
        comparablePath(url).hasPrefix(comparableContainer)
    }

    /// `url`'s path as `isInside` compares paths. Reads the file system, to resolve symlinks.
    public static func comparablePath(_ url: URL) -> String {
        var path = url.standardizedFileURL.resolvingSymlinksInPath().path
        if path.hasPrefix("/private/") { path.removeFirst("/private".count) }
        return path.hasSuffix("/") ? path : path + "/"
    }
}
