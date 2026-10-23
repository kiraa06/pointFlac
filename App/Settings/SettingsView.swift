import PFDesign
import SwiftUI

/// Minimal Settings for the soft launch: the appearance override, Diagnostics (Plan 1's debug library and player,
/// which the UI tests and the S1 listening checks use), the licences and the version.
struct SettingsView: View {
    let model: AppModel
    @AppStorage("appearance") private var appearance: AppearanceOverride = .system
    @AppStorage("monochrome") private var monochrome = false
    @AppStorage(DeckPreferences.designKey) private var deckDesignID = DeckDesign.standard.id
    @AppStorage(AppModel.lookupNamesKey) private var lookupNames = true
    @AppStorage(AppModel.lookupArtworkKey) private var lookupArtwork = false

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
                    NavigationLink {
                        CustomizeDeckView()
                    } label: {
                        LabeledContent("Customize deck", value: DeckDesign.design(id: deckDesignID).name)
                    }
                    .accessibilityIdentifier("customizeDeckLink")
                }
                Section {
                    Toggle("Monochrome", isOn: $monochrome)
                        .accessibilityIdentifier("monochromeToggle")
                } footer: {
                    Text("Everything in greys except album artwork.")
                }
                Section {
                    Toggle("Look up names online (MusicBrainz)", isOn: $lookupNames)
                        .accessibilityIdentifier("lookupNamesToggle")
                    Toggle("Look up cover art online", isOn: $lookupArtwork)
                        .accessibilityIdentifier("lookupArtworkToggle")
                } header: {
                    Text("Privacy")
                } footer: {
                    Text(
                        "Names: what you type in Get Music is sent to musicbrainz.org for suggestions. "
                            + "Cover art: the album's MusicBrainz ID is sent to coverartarchive.org. "
                            + "Nothing else leaves the phone.")
                }
                .onChange(of: lookupNames) { model.lookupsChanged() }
                .onChange(of: lookupArtwork) { model.lookupsChanged() }
                #if SOULSEEK
                    Section {
                        NavigationLink {
                            Form { SoulseekSettingsSection(account: model.soulseek) }
                                .navigationTitle("Soulseek")
                        } label: {
                            LabeledContent("Soulseek", value: model.soulseek.isSignedIn ? "Signed in" : "Signed out")
                        }
                        .accessibilityIdentifier("soulseekLink")
                    }
                #endif
                #if DEBUG
                    // Plan 1's debug harness, for the UI tests and the S1 listening checks; never in Release.
                    Section("Diagnostics") {
                        NavigationLink {
                            DebugLibraryView(model: model)
                        } label: {
                            Label("Diagnostics", systemImage: "waveform.path.ecg")
                        }
                        .accessibilityIdentifier("diagnosticsLink")
                    }
                #endif
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

#if SOULSEEK
    /// Settings → Soulseek (spec §4.7, §5.6): the account, its status, and the honest warnings.
    private struct SoulseekSettingsSection: View {
        let account: SoulseekAccount
        @State private var username = ""
        @State private var password = ""

        var body: some View {
            Section {
                LabeledContent("Status", value: account.status)
                    .accessibilityIdentifier("soulseekStatus")
                if account.isSignedIn {
                    Button("Sign Out", role: .destructive) {
                        Task { await account.signOut() }
                    }
                    .monoDestructive()
                    .accessibilityIdentifier("soulseekSignOut")
                } else {
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("soulseekUsername")
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .accessibilityIdentifier("soulseekPassword")
                    Button(account.isBusy ? "Signing In…" : "Sign In") {
                        Task {
                            await account.signIn(username: username, password: password)
                            if account.isSignedIn { password = "" }
                        }
                    }
                    .disabled(account.isBusy || username.isEmpty || password.isEmpty)
                    .accessibilityIdentifier("soulseekSignIn")
                }
            } header: {
                Text("Soulseek")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("The Soulseek protocol sends your password unencrypted: use a password you use nowhere else.")
                    Text("Signing in here signs out any other client using the same account.")
                    Text("A new name creates a new account, and Soulseek has no password reset: check the spelling.")
                    Text("pointFlac downloads FLAC only. It never shares or uploads anything.")
                    Text("Some peers refuse users who share nothing.")
                    Text("When both you and a peer are behind NAT, that peer may be unreachable.")
                }
            }
            .onAppear { if username.isEmpty { username = account.savedUsername } }
        }
    }
#endif
