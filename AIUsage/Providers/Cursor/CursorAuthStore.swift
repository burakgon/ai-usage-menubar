import Foundation

struct CursorAuthState: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case sqlite
        case keychain
    }

    var accessToken: String?
    let refreshToken: String?
    let source: Source
}

struct CursorAuthStore: Sendable {
    static let stateDatabasePath =
        "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    static let accessTokenKey = "cursorAuth/accessToken"
    static let refreshTokenKey = "cursorAuth/refreshToken"
    static let membershipTypeKey = "cursorAuth/stripeMembershipType"
    static let accessTokenService = "cursor-access-token"
    static let refreshTokenService = "cursor-refresh-token"

    let sqlite: SQLiteValueReading
    let keychain: KeychainAccessing
    let dateProvider: DateProviding

    init(
        sqlite: SQLiteValueReading = SQLiteCLIValueReader(),
        keychain: KeychainAccessing = SecurityKeychainAccessor(),
        dateProvider: DateProviding = SystemDateProvider()
    ) {
        self.sqlite = sqlite
        self.keychain = keychain
        self.dateProvider = dateProvider
    }

    func load() -> CursorAuthState? {
        let sqliteAccess = stateValue(Self.accessTokenKey)
        let sqliteRefresh = stateValue(Self.refreshTokenKey)
        let membership = stateValue(Self.membershipTypeKey)?.lowercased()
        let keychainAccess = keychainValue(Self.accessTokenService)
        let keychainRefresh = keychainValue(Self.refreshTokenService)

        if sqliteAccess != nil || sqliteRefresh != nil {
            let subjectsDiffer =
                tokenSubject(sqliteAccess) != nil &&
                tokenSubject(keychainAccess) != nil &&
                tokenSubject(sqliteAccess) != tokenSubject(keychainAccess)
            if membership == "free",
               subjectsDiffer,
               keychainAccess != nil || keychainRefresh != nil {
                return CursorAuthState(
                    accessToken: keychainAccess,
                    refreshToken: keychainRefresh,
                    source: .keychain
                )
            }
            return CursorAuthState(
                accessToken: sqliteAccess,
                refreshToken: sqliteRefresh,
                source: .sqlite
            )
        }

        guard keychainAccess != nil || keychainRefresh != nil else {
            return nil
        }
        return CursorAuthState(
            accessToken: keychainAccess,
            refreshToken: keychainRefresh,
            source: .keychain
        )
    }

    func needsRefresh(_ accessToken: String?) -> Bool {
        guard let accessToken,
              let expiration = ProviderParsing.jwtExpiration(accessToken)
        else {
            return true
        }
        return expiration.timeIntervalSince(dateProvider.now()) <= 300
    }

    func saveAccessToken(
        _ token: String,
        source: CursorAuthState.Source
    ) throws {
        switch source {
        case .sqlite:
            let sql =
                "INSERT OR REPLACE INTO ItemTable (key, value) VALUES " +
                "('\(Self.sqlEscaped(Self.accessTokenKey))', " +
                "'\(Self.sqlEscaped(token))');"
            try sqlite.execute(path: Self.stateDatabasePath, sql: sql)
        case .keychain:
            try keychain.writeGenericPassword(
                service: Self.accessTokenService,
                value: token
            )
        }
    }

    private func stateValue(_ key: String) -> String? {
        let sql =
            "SELECT value FROM ItemTable WHERE key = " +
            "'\(Self.sqlEscaped(key))' LIMIT 1"
        guard let value = try? sqlite.queryValue(
            path: Self.stateDatabasePath,
            sql: sql
        ) else {
            return nil
        }
        return Self.nonempty(value)
    }

    private func keychainValue(_ service: String) -> String? {
        guard let value = try? keychain.readGenericPassword(
            service: service
        ) else {
            return nil
        }
        return Self.nonempty(value)
    }

    private func tokenSubject(_ token: String?) -> String? {
        guard let token,
              let data = token.split(
                separator: ".",
                omittingEmptySubsequences: false
              ).dropFirst().first.flatMap({
                  ProviderParsing.base64URLData(String($0))
              }),
              let object = try? JSONSerialization.jsonObject(
                with: data
              ) as? [String: Any]
        else {
            return nil
        }
        return ProviderParsing.string(object["sub"])
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func sqlEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
}
