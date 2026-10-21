import PFAudio
import SwiftUI
import UIKit

enum AppTab: Hashable {
    case player, getMusic, downloads, settings
}

/// The app's frame (spec §4.1): the player is home, with the Shelf inside it; Get Music, Downloads and Settings sit
/// beside it in a Liquid Glass tab bar. The appearance override applies here, to everything.
struct RootView: View {
    let model: AppModel
    @AppStorage("appearance") private var appearance: AppearanceOverride = .system
    @AppStorage("monochrome") private var monochrome = false
    @State private var tab: AppTab = Self.launchTab
    @Environment(\.scenePhase) private var scenePhase
    @State private var grace = BackgroundGrace()

    var body: some View {
        TabView(selection: $tab) {
            Tab("Player", systemImage: "opticaldisc", value: AppTab.player) {
                PlayerScreen(model: model, tab: $tab)
            }
            Tab("Get Music", systemImage: "magnifyingglass.circle", value: AppTab.getMusic) {
                GetMusicView(finder: model.finder, library: model.library)
            }
            Tab("Downloads", systemImage: "arrow.down.circle", value: AppTab.downloads) {
                DownloadsView(finder: model.finder)
            }
            .badge(activeDownloads)
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                SettingsView(model: model)
            }
        }
        .preferredColorScheme(appearance.colorScheme)
        // Monochrome: system controls (tab bar, toggles, buttons, links) take the ink grey, and views that draw a
        // colour of their own read the flag. The look switches live, over a short fade.
        .tint(monochrome ? Theme.monochromeInk : nil)
        .environment(\.isMonochrome, monochrome)
        .animation(.easeInOut(duration: 0.3), value: monochrome)
        .onChange(of: monochrome, initial: true) { _, on in Self.tintWindows(on) }
        .task { await model.load() }
        .onChange(of: scenePhase) { old, new in
            // Back from the background: pick up files added in the Files app meanwhile (stream A: rescan on every
            // foreground). Launch already scans in `load()`.
            if old == .background, new != .background { Task { await model.reload() } }
            if new == .background, activeDownloads > 0 { grace.begin() }
            if new == .active {
                grace.end()
                #if SOULSEEK
                    Task { await model.soulseek.returnedToForeground() }
                #endif
            }
        }
        .onChange(of: model.player.status) { _, status in
            model.playback.playerStatusChanged(to: status)
        }
        .onChange(of: model.player.currentIndex) { old, new in
            model.playback.playerTrackChanged(from: old, to: new)
        }
    }

    /// UIKit-hosted pieces (alerts) take their tint from the window, not from SwiftUI's `.tint`.
    private static func tintWindows(_ monochrome: Bool) {
        let tint = monochrome ? UIColor(Theme.monochromeInk) : nil
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows { window.tintColor = tint }
        }
    }

    /// `-PFTab getMusic|downloads|settings` (DEBUG only) opens on that tab, for screenshots.
    private static var launchTab: AppTab {
        #if DEBUG
            switch UserDefaults.standard.string(forKey: "PFTab") {
            case "getMusic": return .getMusic
            case "downloads": return .downloads
            case "settings": return .settings
            default: return .player
            }
        #else
            return .player
        #endif
    }

    /// Transfers still under way, for the Downloads badge (spec §4.1: a badge shows activity).
    private var activeDownloads: Int {
        model.finder.downloads.filter { $0.progress != nil || $0.state == "Queued" || $0.state.hasPrefix("Waiting") }
            .count
    }
}
