import Foundation
import Testing

@testable import PFDownloads

/// Where a picked download folder is, judged from its path: in the trash (a bookmark follows a folder the user
/// deleted into Recently Deleted, where downloads must not keep landing), or inside the app's own container (which
/// deleting the app deletes, so it defeats the point of the feature).
@Suite("FolderLocation")
struct FolderLocationTests {
    @Test(
        "a folder in a trash is recognised",
        arguments: [
            "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/.Trash/pointFlac",
            "/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/.Trash/Music/pointFlac",
            "/Users/kiran/.Trash/Music",
            "/Volumes/Card/.Trashes/501/Music",
        ])
    func trash(path: String) {
        #expect(FolderLocation.isInTrash(URL(filePath: path, directoryHint: .isDirectory)))
    }

    @Test(
        "an ordinary folder is not in the trash, whatever its name looks like",
        arguments: [
            "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/pointFlac",
            "/Users/kiran/Music/.Trashy",
            "/Users/kiran/Music/Trash",
            "/Users/kiran/Music/My .Trash notes",
        ])
    func notTrash(path: String) {
        #expect(!FolderLocation.isInTrash(URL(filePath: path, directoryHint: .isDirectory)))
    }

    @Test("folders inside the app's container are refused; its neighbours are not")
    func insideTheApp() {
        let container = URL(
            filePath: "/private/var/mobile/Containers/Data/Application/ABC", directoryHint: .isDirectory)
        func inside(_ path: String) -> Bool {
            FolderLocation.isInside(URL(filePath: path, directoryHint: .isDirectory), container: container)
        }
        #expect(inside("/private/var/mobile/Containers/Data/Application/ABC"))
        #expect(inside("/private/var/mobile/Containers/Data/Application/ABC/Documents"))
        // /var and /private/var are the same place.
        #expect(inside("/var/mobile/Containers/Data/Application/ABC/Documents/Library"))
        #expect(!inside("/private/var/mobile/Containers/Data/Application/ABC2/Documents"))
        #expect(!inside("/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/pointFlac"))
    }
}
