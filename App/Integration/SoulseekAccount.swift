#if SOULSEEK
    import Foundation
    import Observation
    import PFSoulseek
    import Security

    /// The one Soulseek session for the app's lifetime, and the account it signs in with (Settings → Soulseek).
    ///
    /// One `SoulseekClient` per process, because signing in a second time with the same account kicks the first
    /// session. Credentials live only in the Keychain (spec §5.8), never in UserDefaults; UserDefaults only remembers
    /// whether to sign in again at launch, which a sign-out or a kick turns off, so pointFlac never keeps kicking the
    /// person's desktop client off by itself.
    @MainActor
    @Observable
    final class SoulseekAccount {
        /// What Settings shows: "Signed in as …", "Signing in…", "Signed in elsewhere", "Sign-in failed: …".
        private(set) var status = "Signed out"
        private(set) var isSignedIn = false
        private(set) var isBusy = false
        /// The saved username, for the field.
        private(set) var savedUsername = ""

        @ObservationIgnored let client = SoulseekClient()
        @ObservationIgnored private var watcher: Task<Void, Never>?
        @ObservationIgnored private let defaults: UserDefaults
        private static let autoSignInKey = "soulseekAutoSignIn"

        init(defaults: UserDefaults = .standard) {
            self.defaults = defaults
            savedUsername = SoulseekKeychain.load()?.username ?? ""
            let client = client
            watcher = Task { [weak self] in
                for await state in await client.stateUpdates() {
                    self?.show(state)
                }
            }
        }

        /// Signs in again at launch if the person was signed in when the app last ran.
        func resume() async {
            guard defaults.bool(forKey: Self.autoSignInKey), let saved = SoulseekKeychain.load() else { return }
            await signIn(username: saved.username, password: saved.password)
        }

        func signIn(username: String, password: String) async {
            let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !password.isEmpty else {
                status = "Enter a username and a password"
                return
            }
            isBusy = true
            defer { isBusy = false }
            do {
                try await client.login(username: name, password: password)
                SoulseekKeychain.save(username: name, password: password)
                savedUsername = name
                defaults.set(true, forKey: Self.autoSignInKey)
            } catch {
                defaults.set(false, forKey: Self.autoSignInKey)
            }
        }

        /// Signs out and forgets the password. The username stays in the field.
        func signOut() async {
            defaults.set(false, forKey: Self.autoSignInKey)
            await client.logout()
            SoulseekKeychain.delete()
        }

        private func show(_ state: SoulseekConnectionState) {
            isSignedIn = false
            switch state {
            case .disconnected: status = "Signed out"
            case .connecting: status = "Signing in…"
            case .loggedIn(let username):
                isSignedIn = true
                status = "Signed in as \(username)"
            case .reconnecting(let attempt): status = "Reconnecting (attempt \(attempt))…"
            case .kicked:
                defaults.set(false, forKey: Self.autoSignInKey)
                status = "Signed in elsewhere: this account signed in from another client"
            case .failed(let error): status = "Sign-in failed: \(Self.reason(error))"
            }
        }

        static func reason(_ error: SoulseekError) -> String {
            switch error {
            case .invalidPassword: "wrong password"
            case .invalidUsername: "the username was refused"
            case .invalidVersion: "the server refused this client version"
            case .rejected(let why): "the server refused (\(why))"
            case .serverUnavailable: "the server is unreachable"
            case .timeout: "timed out"
            case .notLoggedIn: "not signed in"
            case .kicked: "signed in elsewhere"
            case .connectionLost: "the connection dropped"
            case .excludedPhrase: "excluded phrase"
            case .emptyQuery: "empty query"
            case .protocolViolation: "the server broke the protocol"
            }
        }
    }

    /// The Soulseek username and password as one generic-password Keychain item, readable only on this device after
    /// the first unlock, so it is never synced or backed up (spec §5.8).
    enum SoulseekKeychain {
        private static let service = "io.github.kiraa06.pointflac.soulseek"

        static func save(username: String, password: String) {
            delete()
            var item = base
            item[kSecAttrAccount as String] = username
            item[kSecValueData as String] = Data(password.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(item as CFDictionary, nil)
        }

        static func load() -> (username: String, password: String)? {
            var query = base
            query[kSecReturnAttributes as String] = true
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                let found = result as? [String: Any], let account = found[kSecAttrAccount as String] as? String,
                let data = found[kSecValueData as String] as? Data, let password = String(data: data, encoding: .utf8)
            else { return nil }
            return (account, password)
        }

        static func delete() {
            SecItemDelete(base as CFDictionary)
        }

        private static var base: [String: Any] {
            [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        }
    }
#endif
