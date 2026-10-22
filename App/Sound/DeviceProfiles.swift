import PFCore
import PFDSP
import SwiftUI

/// An output with settings of its own (Task 15), as the Sound tab lists it.
struct DeviceProfile: Identifiable, Equatable {
    let key: String
    let port: OutputPort
    /// What its settings do, in a few words: "Pure", "EQ · Tone".
    let summary: String

    var id: String { key }

    static func summary(of s: SoundSettings) -> String {
        if s.pure { return "Pure" }
        let blocks = s.activeBlockNames.filter { $0 != "Limiter" }
        return blocks.isEmpty ? "Nothing on" : blocks.joined(separator: " · ")
    }
}

extension OutputPort {
    /// The device's own name, or for the built-in output and a nameless device, what it is.
    var displayName: String {
        func named(_ name: String, else fallback: String) -> String { name.isEmpty ? fallback : name }
        return switch self {
        case .usb(let name): named(name, else: "USB audio")
        case .wired(let name): named(name, else: "Wired headphones")
        case .bluetooth(let name): named(name, else: "Bluetooth device")
        case .builtIn: "Built-in speaker"
        case .airPlay(let name): named(name, else: "AirPlay device")
        case .other(let name): named(name, else: "Other output")
        }
    }

    /// The kind of connection, in a word.
    var kindName: String {
        switch self {
        case .usb: "USB"
        case .wired: "Wired"
        case .bluetooth: "Bluetooth"
        case .builtIn: "Built-in"
        case .airPlay: "AirPlay"
        case .other: "Other"
        }
    }

    var symbolName: String {
        switch self {
        case .usb: "cable.connector"
        case .wired: "headphones"
        case .bluetooth: "wave.3.right"
        case .builtIn: "iphone"
        case .airPlay: "airplayaudio"
        case .other: "hifispeaker"
        }
    }
}

/// The Sound tab's per-device settings (Task 15): the switch, and while it is on, the output whose settings the tab
/// shows ("Settings for: <device>"), and the other outputs that have settings of their own, each with what they do
/// and a Forget. A route change while the tab is open updates it in place: the store follows the port.
struct DeviceProfileRows: View {
    let store: SoundStore
    let theme: Theme
    #if DEBUG
        /// `-PFFakeRoute`'s switch, when the launch asked for one.
        @Environment(FakeRouteSwitch.self) private var fakeRoute: FakeRouteSwitch?
    #endif

    var body: some View {
        Toggle(isOn: Binding(get: { store.useProfiles }, set: { on in withAnimation { store.setUseProfiles(on) } })) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Per-device settings")
                Text(
                    store.useProfiles
                        ? "Each output keeps its own sound, Pure included."
                        : "Every output plays these settings."
                )
                .font(.caption)
                .foregroundStyle(theme.inkSecondary)
            }
        }
        .tint(theme.processingTint)
        .accessibilityIdentifier("profilesToggle")
        if store.useProfiles {
            current
            ForEach(store.otherDevices) { other in
                row(other)
            }
        }
        #if DEBUG
            if let fakeRoute, fakeRoute.device != .builtIn {
                Button(
                    "Simulate: switch to \(fakeRoute.next.displayName)", systemImage: "arrow.triangle.swap",
                    action: fakeRoute.toggle
                )
                .font(.subheadline)
                .accessibilityIdentifier("fakeRouteButton")
            }
        #endif
    }

    /// The output in use: whose settings the tab shows.
    private var current: some View {
        let port = store.device
        return HStack(spacing: 12) {
            glyph(port, lit: true)
            VStack(alignment: .leading, spacing: 3) {
                Text("SETTINGS FOR")
                    .font(Typeface.cellLabel)
                    .tracking(1.4)
                    .foregroundStyle(theme.inkSecondary)
                Text(port.displayName)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 8)
            Text("IN USE · \(port.kindName.uppercased())")
                .font(Typeface.cellLabel)
                .tracking(1.2)
                .foregroundStyle(theme.processingTint)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.vertical, 2)
        .animation(.snappy(duration: 0.25), value: port)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Settings for: \(port.displayName)")
        .accessibilityValue("\(port.kindName), in use")
        .accessibilityIdentifier("profileDevice")
    }

    private func row(_ other: DeviceProfile) -> some View {
        HStack(spacing: 12) {
            glyph(other.port, lit: false)
            VStack(alignment: .leading, spacing: 2) {
                Text(other.port.displayName)
                    .lineLimit(1)
                Text("\(other.port.kindName) · \(other.summary)")
                    .font(.caption)
                    .foregroundStyle(theme.inkSecondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            Button("Forget") {
                withAnimation { store.forgetDevice(other.key) }
            }
            .buttonStyle(.borderless)
            .font(.subheadline)
            .foregroundStyle(theme.processingTint)
            .accessibilityLabel("Forget \(other.port.displayName)")
            .accessibilityHint("Its settings are dropped; next time it starts from the settings playing then.")
            .accessibilityIdentifier("forgetDevice-\(other.key)")
        }
    }

    private func glyph(_ port: OutputPort, lit: Bool) -> some View {
        Image(systemName: port.symbolName)
            .font(.body.weight(.medium))
            .frame(width: 32, height: 32)
            .foregroundStyle(lit ? theme.background : theme.inkSecondary)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(lit ? theme.processingTint : theme.ink.opacity(theme.isDark ? 0.10 : 0.06))
            )
            .accessibilityHidden(true)
    }
}
