import Foundation

struct DevinAuth: Equatable, Sendable {
    let apiKey: String
    let apiServerURL: String?
}

protocol SQLiteValueReading: Sendable {
    func queryValue(path: String, sql: String) throws -> String?
    func execute(path: String, sql: String) throws
}

struct SQLiteCLIValueReader: SQLiteValueReading {
    let runner: ProcessRunning

    init(runner: ProcessRunning = SystemProcessRunner()) {
        self.runner = runner
    }

    func queryValue(path: String, sql: String) throws -> String? {
        guard FileManager.default.fileExists(atPath: expandHome(path)) else {
            return nil
        }
        let result = try runner.run(
            executable: "/usr/bin/sqlite3",
            arguments: ["-readonly", expandHome(path), sql],
            environment: [:],
            timeout: 5
        )
        guard result.succeeded else { return nil }
        let value = result.stdout.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return value.isEmpty ? nil : value
    }

    func execute(path: String, sql: String) throws {
        let result = try runner.run(
            executable: "/usr/bin/sqlite3",
            arguments: [expandHome(path), sql],
            environment: [:],
            timeout: 5
        )
        guard result.succeeded else {
            throw ProviderFailure(
                .storage,
                "Local provider state could not be updated."
            )
        }
    }
}

struct DevinAuthStore: Sendable {
    static let credentialsPath = "~/.local/share/devin/credentials.toml"
    static let stateDatabasePath =
        "~/Library/Application Support/Devin/User/globalStorage/state.vscdb"
    static let defaultAPIServerURL = "https://server.codeium.com"

    let files: TextFileAccessing
    let sqlite: SQLiteValueReading

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        sqlite: SQLiteValueReading = SQLiteCLIValueReader()
    ) {
        self.files = files
        self.sqlite = sqlite
    }

    func loadCandidates() -> [DevinAuth] {
        var candidates: [DevinAuth] = []
        if let credentials = loadCredentialsFile() {
            candidates.append(credentials)
        }
        if let app = loadAppAuth(), !candidates.contains(app) {
            candidates.append(app)
        }
        return candidates
    }

    func loadCredentialsFile() -> DevinAuth? {
        guard files.exists(Self.credentialsPath),
              let text = try? files.readText(Self.credentialsPath),
              let apiKey = Self.readTOMLString(
                text,
                key: "windsurf_api_key"
              ) else {
            return nil
        }
        return DevinAuth(
            apiKey: apiKey,
            apiServerURL: Self.cleanServerURL(
                Self.readTOMLString(text, key: "api_server_url")
            )
        )
    }

    func loadAppAuth() -> DevinAuth? {
        let sql =
            "SELECT value FROM ItemTable " +
            "WHERE key = 'windsurfAuthStatus' LIMIT 1"
        guard let value = try? sqlite.queryValue(
            path: Self.stateDatabasePath,
            sql: sql
        ),
            let data = value.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(
                with: data
            ) as? [String: Any],
            let apiKey = (object["apiKey"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !apiKey.isEmpty else {
            return nil
        }
        return DevinAuth(apiKey: apiKey, apiServerURL: nil)
    }

    func effectiveServerURL(for auth: DevinAuth) -> String {
        auth.apiServerURL ?? Self.defaultAPIServerURL
    }

    static func readTOMLString(_ text: String, key: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(
                separator: "=",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard parts.count == 2,
                  parts[0].trimmingCharacters(
                    in: .whitespacesAndNewlines
                  ) == key else {
                continue
            }

            var value = parts[1].trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !value.isEmpty else { return nil }
            if value.first == "\"" || value.first == "'" {
                let quote = value.removeFirst()
                guard let end = value.firstIndex(of: quote) else { return nil }
                value = value[..<end].trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            } else if let comment = value.firstIndex(of: "#") {
                value = value[..<comment].trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            }
            return value.isEmpty ? nil : String(value)
        }
        return nil
    }

    private static func cleanServerURL(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ),
            value.hasPrefix("https://") else {
            return nil
        }
        return value.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
    }
}
