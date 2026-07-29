import CryptoKit
import Foundation

struct AntigravityToken: Equatable, Sendable {
    let accessToken: String?
    let refreshToken: String?
    let expiry: Date?
}

private struct AntigravityCachedToken: Codable {
    let accessToken: String
    let expiresAt: Date
    let refreshFingerprint: String
}

struct AntigravityAuthStore: Sendable {
    static let cachePath =
        "~/Library/Application Support/AI Usage/antigravity-auth.json"

    let runner: ProcessRunning
    let files: TextFileAccessing
    let dateProvider: DateProviding

    init(
        runner: ProcessRunning = SystemProcessRunner(),
        files: TextFileAccessing = LocalTextFileAccessor(),
        dateProvider: DateProviding = SystemDateProvider()
    ) {
        self.runner = runner
        self.files = files
        self.dateProvider = dateProvider
    }

    func load() throws -> AntigravityToken? {
        let result = try runner.run(
            executable: "/usr/bin/security",
            arguments: [
                "find-generic-password",
                "-s", "gemini",
                "-a", "antigravity",
                "-w"
            ],
            environment: [:],
            timeout: 5
        )
        if result.exitCode == 44 {
            return nil
        }
        guard result.succeeded else {
            throw ProviderFailure(
                .storage,
                "Antigravity sign-in could not be read from Keychain."
            )
        }
        return Self.decode(result.stdout)
    }

    func usableAccessToken(from token: AntigravityToken) -> String? {
        if let access = Self.nonempty(token.accessToken),
           token.expiry?.timeIntervalSince(dateProvider.now()) ?? 61 > 60 {
            return access
        }
        guard let refresh = Self.nonempty(token.refreshToken),
              files.exists(Self.cachePath),
              let text = try? files.readText(Self.cachePath),
              let data = text.data(using: .utf8),
              let cached = try? JSONDecoder().decode(
                  AntigravityCachedToken.self,
                  from: data
              ),
              cached.refreshFingerprint == Self.fingerprint(refresh),
              cached.expiresAt.timeIntervalSince(dateProvider.now()) > 60
        else {
            return nil
        }
        return cached.accessToken
    }

    func cache(
        accessToken: String,
        expiresIn: TimeInterval,
        refreshToken: String
    ) {
        let cached = AntigravityCachedToken(
            accessToken: accessToken,
            expiresAt: dateProvider.now().addingTimeInterval(expiresIn),
            refreshFingerprint: Self.fingerprint(refreshToken)
        )
        guard let data = try? JSONEncoder().encode(cached) else { return }
        try? files.writeText(
            Self.cachePath,
            String(decoding: data, as: UTF8.self)
        )
    }

    static func decode(_ raw: String) -> AntigravityToken? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("go-keyring-base64:") {
            text.removeFirst("go-keyring-base64:".count)
            guard let data = Data(base64Encoded: text) else { return nil }
            text = String(decoding: data, as: UTF8.self)
        }
        if text.hasPrefix("Bearer ") {
            text.removeFirst("Bearer ".count)
            return AntigravityToken(
                accessToken: nonempty(text),
                refreshToken: nil,
                expiry: nil
            )
        }
        guard let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data)
        else {
            return AntigravityToken(
                accessToken: nonempty(text),
                refreshToken: nil,
                expiry: nil
            )
        }
        if let text = value as? String {
            return AntigravityToken(
                accessToken: nonempty(text),
                refreshToken: nil,
                expiry: nil
            )
        }
        guard let root = value as? [String: Any],
              let token = token(from: root) else {
            return nil
        }
        return token
    }

    private static func token(
        from object: [String: Any]
    ) -> AntigravityToken? {
        let source = object["token"] as? [String: Any] ?? object
        let access = firstString(
            source,
            keys: ["access_token", "accessToken", "id_token", "idToken"]
        )
        let refresh = firstString(
            source,
            keys: ["refresh_token", "refreshToken"]
        )
        let expiry = firstString(
            source,
            keys: ["expiry", "expires_at", "expiresAt"]
        ).flatMap(ProviderParsing.date)
        if access != nil || refresh != nil {
            return AntigravityToken(
                accessToken: access,
                refreshToken: refresh,
                expiry: expiry
            )
        }
        for key in ["tokens", "oauth", "oauth2", "credentials", "auth"] {
            if let nested = object[key] as? [String: Any],
               let result = token(from: nested) {
                return result
            }
        }
        return nil
    }

    private static func firstString(
        _ object: [String: Any],
        keys: [String]
    ) -> String? {
        keys.lazy.compactMap { nonempty(object[$0] as? String) }.first
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func fingerprint(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
