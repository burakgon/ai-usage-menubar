import Foundation

struct CursorAuthState: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        /// The editor's login in Cursor's state database.
        case sqlite
        /// The Cursor CLI's login in the Keychain.
        case keychain
    }

    var accessToken: String?
    let refreshToken: String?
    let source: Source
}

enum CursorLogin: Equatable, Sendable {
    case session(CursorAuthState)
    /// The editor is signed in, but Cursor 3.27 and later seal that login
    /// with a key only Cursor may read, and there is no Cursor CLI login.
    case sealedEditorLogin
    case signedOut
}

struct CursorAuthStore: Sendable {
    static let stateDatabasePath =
        "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    static let accessTokenKey = "cursorAuth/accessToken"
    static let refreshTokenKey = "cursorAuth/refreshToken"
    static let membershipTypeKey = "cursorAuth/stripeMembershipType"
    static let accessTokenService = "cursor-access-token"
    static let refreshTokenService = "cursor-refresh-token"
    /// Cursor 3.27 and later store the editor's tokens as
    /// `cursor-safe-storage:v1:` plus ciphertext from Electron's safe
    /// storage. The key is Cursor's own Keychain item, which AI Usage does
    /// not open, so a sealed value is a login that cannot be read. It is not
    /// a token, and it is never sent anywhere.
    static let sealedValuePrefix = "cursor-safe-storage:"

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

    func load() -> CursorLogin {
        let editorAccess = stateValue(Self.accessTokenKey)
        let editorRefresh = stateValue(Self.refreshTokenKey)
        // One sealed value means Cursor seals this login. The other is not
        // used alone: a refreshed token would be written back unsealed.
        let editorLoginIsSealed =
            Self.isSealed(editorAccess) || Self.isSealed(editorRefresh)
        let sqliteAccess = editorLoginIsSealed ? nil : editorAccess
        let sqliteRefresh = editorLoginIsSealed ? nil : editorRefresh
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
                return .session(CursorAuthState(
                    accessToken: keychainAccess,
                    refreshToken: keychainRefresh,
                    source: .keychain
                ))
            }
            return .session(CursorAuthState(
                accessToken: sqliteAccess,
                refreshToken: sqliteRefresh,
                source: .sqlite
            ))
        }

        guard keychainAccess != nil || keychainRefresh != nil else {
            return editorLoginIsSealed ? .sealedEditorLogin : .signedOut
        }
        return .session(CursorAuthState(
            accessToken: keychainAccess,
            refreshToken: keychainRefresh,
            source: .keychain
        ))
    }

    static func isSealed(_ value: String?) -> Bool {
        value?.hasPrefix(sealedValuePrefix) == true
    }

    func needsRefresh(_ accessToken: String?) -> Bool {
        guard let accessToken,
              let expiration = ProviderParsing.jwtExpiration(accessToken)
        else {
            return true
        }
        return expiration.timeIntervalSince(dateProvider.now()) <= 300
    }

    /// Writes a renewed access token back beside the editor's readable
    /// login. The Cursor CLI's Keychain items are only ever read.
    func saveEditorAccessToken(_ token: String) throws {
        let sql =
            "INSERT OR REPLACE INTO ItemTable (key, value) VALUES " +
            "('\(Self.sqlEscaped(Self.accessTokenKey))', " +
            "'\(Self.sqlEscaped(token))');"
        try sqlite.execute(path: Self.stateDatabasePath, sql: sql)
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
