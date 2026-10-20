import SwiftUI

/// Minimal Settings for the soft launch: the appearance override, Diagnostics (Plan 1's debug library and player,
/// which the UI tests and the S1 listening checks use), the licences and the version.
struct SettingsView: View {
    let model: AppModel
    @AppStorage("appearance") private var appearance: AppearanceOverride = .system

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(AppearanceOverride.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("appearancePicker")
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("Both the Deck and the Cover have a light and a dark look. System follows the phone.")
                }
                Section {
                    LabeledContent("Turntable sounds", value: "Off")
                } footer: {
                    Text("Needle and run-out sounds are off by default and never play in Pure mode.")
                }
                Section("Diagnostics") {
                    NavigationLink {
                        DebugLibraryView(model: model)
                    } label: {
                        Label("Diagnostics", systemImage: "waveform.path.ecg")
                    }
                    .accessibilityIdentifier("diagnosticsLink")
                }
                Section("About") {
                    NavigationLink("Licences") { LicencesView() }
                        .accessibilityIdentifier("licencesLink")
                    LabeledContent("Version", value: Self.version)
                }
            }
            .navigationTitle("Settings")
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
