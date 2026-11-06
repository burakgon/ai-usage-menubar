import Foundation

struct QoderAuthState: Equatable, Sendable {
    let accessToken: String
    let planName: String?
}

struct QoderAuthStore: Sendable {
    struct Source: Equatable, Sendable {
        let path: String
        let keychainService: String
        let keychainAccount: String
    }

    static let sources = [
        Source(
            path: "~/Library/Application Support/com.qoder.app.stable/auth.v1.dat",
            keychainService: "Qoder App Safe Storage",
            keychainAccount: "Qoder App Key"
        ),
        Source(
            path: "~/Library/Application Support/com.qodercn.app.stable/auth.v1.dat",
            keychainService: "Qoder CN App Safe Storage",
            keychainAccount: "Qoder CN App Key"
        )
    ]

    let files: TextFileAccessing
    let keychain: KeychainAccessing

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        keychain: KeychainAccessing = SecurityKeychainAccessor()
    ) {
        self.files = files
        self.keychain = keychain
    }

    func load() -> QoderAuthState? {
        for source in Self.sources {
            if let auth = load(source) {
                return auth
            }
        }
        return nil
    }

    private func load(_ source: Source) -> QoderAuthState? {
        guard files.exists(source.path),
              let payload = try? files.readData(source.path),
              let password = try? keychain.readGenericPassword(
                service: source.keychainService,
                account: source.keychainAccount
              ),
              !password.isEmpty,
              let decrypted = QoderSecretBox.decrypt(
                payload: payload,
                password: password
              ),
              let object = try? JSONSerialization.jsonObject(with: decrypted) as? [String: Any],
              let token = trimmed(object["token"] as? String) else {
            return nil
        }

        let user = ProviderParsing.object(object["user"])
        let planName = trimmed(user?["planTierName"] as? String)
            ?? trimmed(object["plan_tier_name"] as? String)
        return QoderAuthState(accessToken: token, planName: planName)
    }

    private func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
