import SwiftUI

@main
struct PointFlacApp: App {
    @State private var model = AppModel()

    init() {
        #if DEBUG
            NetProbe.runIfRequested()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
    }
}
