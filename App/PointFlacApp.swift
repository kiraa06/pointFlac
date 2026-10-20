import SwiftUI

@main
struct PointFlacApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            DebugLibraryView(model: model)
        }
    }
}
