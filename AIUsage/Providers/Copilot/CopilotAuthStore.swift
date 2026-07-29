import Foundation

struct CopilotToken: Equatable, Sendable {
    let value: String
}

struct CopilotAuthStore: Sendable {
    static let editorAppsPath = "~/.config/github-copilot/apps.json"
    static let editorHostsPath = "~/.config/github-copilot/hosts.json"
    static let ghHostsPath = "~/.config/gh/hosts.yml"
    static let ghKeychainService = "gh:github.com"

    let files: TextFileAccessing
    let keychain: KeychainAccessing

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        keychain: KeychainAccessing = SecurityKeychainAccessor()
    ) {
        self.files = files
        self.keychain = keychain
    }

    func loadToken() -> CopilotToken? {
        loadFromEditorConfig() ?? loadFromGitHubCLIFile() ?? loadFromKeychain()
    }

    func loadFromEditorConfig() -> CopilotToken? {
        for path in [Self.editorAppsPath, Self.editorHostsPath] {
            guard files.exists(path),
                  let text = try? files.readText(path),
                  let token = Self.oauthToken(fromEditorJSON: text) else {
                continue
            }
            return CopilotToken(value: token)
        }
        return nil
    }

    func loadFromGitHubCLIFile() -> CopilotToken? {
        guard files.exists(Self.ghHostsPath),
              let text = try? files.readText(Self.ghHostsPath),
              let token = Self.yamlValue(text, key: "oauth_token") else {
            return nil
        }
        return CopilotToken(value: token)
    }

    func loadFromKeychain() -> CopilotToken? {
        guard
            let raw = try? keychain.readGenericPassword(
                service: Self.ghKeychainService
            ),
            let token = Self.unwrapGoKeyring(raw)
        else {
            return nil
        }
        return CopilotToken(value: token)
    }

    static func oauthToken(fromEditorJSON text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(
                with: data
              ) as? [String: Any] else {
            return nil
        }

        for (host, rawValue) in object
        where host == "github.com" || host.hasPrefix("github.com:") {
            guard let value = rawValue as? [String: Any],
                  let token = (value["oauth_token"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !token.isEmpty else {
                continue
            }
            return token
        }
        return nil
    }

    static func yamlValue(
        _ text: String,
        key: String,
        host: String = "github.com"
    ) -> String? {
        let keyPrefix = "\(key):"
        let hostHeader = "\(host):"
        var isInHost = false

        for line in text.split(whereSeparator: \.isNewline) {
            if let first = line.first, !first.isWhitespace {
                isInHost = line
                    .trimmingCharacters(in: .whitespaces)
                    .hasPrefix(hostHeader)
                continue
            }
            guard isInHost else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(keyPrefix) else { continue }
            let value = trimmed
                .dropFirst(keyPrefix.count)
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(
                    in: CharacterSet(charactersIn: "\"'")
                )
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private static func unwrapGoKeyring(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "go-keyring-base64:"
        if trimmed.hasPrefix(prefix) {
            let encoded = String(trimmed.dropFirst(prefix.count))
            guard let data = Data(base64Encoded: encoded),
                  let decoded = String(data: data, encoding: .utf8) else {
                return nil
            }
            let token = decoded.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            return token.isEmpty ? nil : token
        }
        return trimmed.isEmpty ? nil : trimmed
    }
}
