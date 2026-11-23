import XCTest
@testable import AIUsage

final class CursorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    /// What Cursor 3.27 and later keep in the state database instead of a
    /// token: a prefix and ciphertext only Cursor can open.
    private let sealedAccess = "cursor-safe-storage:v1:djEwc2VhbGVkLWFjY2Vzcw=="
    private let sealedRefresh = "cursor-safe-storage:v1:djEwc2VhbGVkLXJlZnJlc2g="

    // MARK: - Sign-in selection

    func testSealedEditorLoginYieldsToTheCLILogin() {
        let cli = token(subject: "cli")
        let store = authStore(
            state: sealedState(membership: "pro"),
            keychain: [
                CursorAuthStore.accessTokenService: cli,
                CursorAuthStore.refreshTokenService: "cli-refresh"
            ]
        )

        XCTAssertEqual(store.load(), .session(CursorAuthState(
            accessToken: cli,
            refreshToken: "cli-refresh",
            source: .keychain
        )))
    }

    func testSealedEditorLoginWithoutACLILoginIsNotASession() {
        XCTAssertEqual(
            authStore(state: sealedState(membership: "pro")).load(),
            .sealedEditorLogin
        )
        // One sealed value is enough: the other is not used on its own.
        XCTAssertEqual(
            authStore(state: [
                CursorAuthStore.accessTokenKey: sealedAccess,
                CursorAuthStore.refreshTokenKey: "plain-refresh"
            ]).load(),
            .sealedEditorLogin
        )
        XCTAssertEqual(
            authStore(state: [
                CursorAuthStore.accessTokenKey: token(subject: "editor"),
                CursorAuthStore.refreshTokenKey: sealedRefresh
            ]).load(),
            .sealedEditorLogin
        )
        XCTAssertEqual(authStore(state: [:]).load(), .signedOut)
    }

    func testReadableEditorLoginStillComesFirst() {
        let editor = token(subject: "editor")
        let store = authStore(
            state: [
                CursorAuthStore.accessTokenKey: editor,
                CursorAuthStore.refreshTokenKey: "editor-refresh",
                CursorAuthStore.membershipTypeKey: "pro"
            ],
            keychain: [CursorAuthStore.accessTokenService: token(subject: "cli")]
        )

        XCTAssertEqual(store.load(), .session(CursorAuthState(
            accessToken: editor,
            refreshToken: "editor-refresh",
            source: .sqlite
        )))
    }

    func testFreeEditorLoginYieldsToAnotherAccountsCLILogin() {
        let cli = token(subject: "cli")
        let store = authStore(
            state: [
                CursorAuthStore.accessTokenKey: token(subject: "editor"),
                CursorAuthStore.membershipTypeKey: "FREE"
            ],
            keychain: [CursorAuthStore.accessTokenService: cli]
        )

        XCTAssertEqual(store.load(), .session(CursorAuthState(
            accessToken: cli,
            refreshToken: nil,
            source: .keychain
        )))
    }

    // MARK: - Provider

    func testSealedEditorLoginIsNeverSentAndTheCLILoginReadsUsage() async throws {
        let cli = token(subject: "cli")
        let database = CursorStateDatabase(sealedState(membership: "pro"))
        let http = RoutedHTTPClient([
            CursorUsageClient.usageURL.absoluteString: [httpResponse(json: usageJSON)],
            CursorUsageClient.planURL.absoluteString: [
                httpResponse(json: #"{"planInfo":{"planName":"Pro"}}"#)
            ]
        ])
        let provider = provider(
            database: database,
            keychain: [
                CursorAuthStore.accessTokenService: cli,
                CursorAuthStore.refreshTokenService: "cli-refresh"
            ],
            http: http
        )

        let snapshot = try await provider.fetch()

        XCTAssertEqual(snapshot.planName, "Pro")
        XCTAssertEqual(
            snapshot.windows.map(\.kind),
            [.totalUsage, .autoUsage, .apiUsage]
        )
        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.map(\.url), [
            CursorUsageClient.usageURL,
            CursorUsageClient.planURL
        ])
        XCTAssertEqual(
            requests.map { $0.headers["Authorization"] },
            ["Bearer \(cli)", "Bearer \(cli)"]
        )
        XCTAssertEqual(database.writes(), [])
    }

    func testSealedEditorLoginWithoutACLILoginSaysWhatToDoWithoutARequest() async {
        let database = CursorStateDatabase(sealedState(membership: "pro"))
        let http = RoutedHTTPClient([:])
        let provider = provider(database: database, http: http)

        await assertFailure(
            provider,
            kind: .authentication,
            message: "Cursor's editor login is encrypted. " +
                "Sign in to the Cursor CLI with `agent login`."
        )

        // The sealed value used to be posted to Cursor as a refresh token.
        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.count, 0)
        XCTAssertEqual(database.writes(), [])
    }

    func testExpiredCLISessionNamesTheCLISignIn() async {
        let http = RoutedHTTPClient([
            CursorUsageClient.refreshURL.absoluteString: [
                httpResponse(json: #"{"access_token":"","shouldLogout":true}"#)
            ]
        ])
        let provider = provider(
            database: CursorStateDatabase(sealedState(membership: "pro")),
            keychain: [
                CursorAuthStore.accessTokenService: token(subject: "cli", expiresIn: -60),
                CursorAuthStore.refreshTokenService: "cli-refresh"
            ],
            http: http
        )

        await assertFailure(
            provider,
            kind: .authentication,
            message: "Cursor CLI session expired. Run `agent login`."
        )

        let requests = await http.capturedRequests()
        let body = try? JSONSerialization.jsonObject(
            with: requests.first?.body ?? Data()
        ) as? [String: String]
        XCTAssertEqual(body?["refresh_token"], "cli-refresh")
    }

    func testExpiredCLITokenIsRenewedOnceAndNeverWrittenBack() async throws {
        let expired = token(subject: "cli", expiresIn: -60)
        let renewed = token(subject: "cli")
        let database = CursorStateDatabase(sealedState(membership: "pro"))
        let keychain = MemoryKeychain(generic: [
            CursorAuthStore.accessTokenService: expired,
            CursorAuthStore.refreshTokenService: "cli-refresh"
        ])
        let http = RoutedHTTPClient([
            CursorUsageClient.refreshURL.absoluteString: [
                httpResponse(json: #"{"access_token":"\#(renewed)"}"#)
            ],
            CursorUsageClient.usageURL.absoluteString: [httpResponse(json: usageJSON)],
            CursorUsageClient.planURL.absoluteString: [httpResponse(json: "{}")]
        ])
        let date = FixedDateProvider(value: now)
        let provider = CursorProvider(
            authStore: CursorAuthStore(
                sqlite: database,
                keychain: keychain,
                dateProvider: date
            ),
            client: CursorUsageClient(http: http),
            dateProvider: date
        )

        _ = try await provider.fetch()
        _ = try await provider.fetch()

        // The second read reuses the token renewed by the first.
        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.map(\.url), [
            CursorUsageClient.refreshURL,
            CursorUsageClient.usageURL,
            CursorUsageClient.planURL,
            CursorUsageClient.usageURL,
            CursorUsageClient.planURL
        ])
        XCTAssertEqual(
            requests.last?.headers["Authorization"],
            "Bearer \(renewed)"
        )
        // The CLI's Keychain items and Cursor's database are left as found.
        XCTAssertEqual(
            try keychain.readGenericPassword(
                service: CursorAuthStore.accessTokenService
            ),
            expired
        )
        XCTAssertEqual(database.writes(), [])
    }

    func testReadableEditorLoginRefreshesIntoTheStateDatabase() async throws {
        let fresh = token(subject: "editor")
        let database = CursorStateDatabase([
            CursorAuthStore.accessTokenKey: token(subject: "editor", expiresIn: -60),
            CursorAuthStore.refreshTokenKey: "editor-refresh",
            CursorAuthStore.membershipTypeKey: "pro"
        ])
        let http = RoutedHTTPClient([
            CursorUsageClient.refreshURL.absoluteString: [
                httpResponse(json: #"{"access_token":"\#(fresh)"}"#)
            ],
            CursorUsageClient.usageURL.absoluteString: [httpResponse(json: usageJSON)],
            CursorUsageClient.planURL.absoluteString: [httpResponse(json: "{}")]
        ])

        _ = try await provider(database: database, http: http).fetch()

        XCTAssertEqual(database.writes().count, 1)
        XCTAssertTrue(database.writes().first?.contains(fresh) == true)
    }

    func testExpiredEditorSessionStillSaysToSignInAgain() async {
        let http = RoutedHTTPClient([
            CursorUsageClient.refreshURL.absoluteString: [
                httpResponse(json: #"{"access_token":"","shouldLogout":true}"#)
            ]
        ])
        let provider = provider(
            database: CursorStateDatabase([
                CursorAuthStore.accessTokenKey: token(subject: "editor", expiresIn: -60),
                CursorAuthStore.refreshTokenKey: "editor-refresh"
            ]),
            http: http
        )

        await assertFailure(
            provider,
            kind: .authentication,
            message: "Cursor session expired. Sign in again."
        )
    }

    // MARK: - Helpers

    private var usageJSON: String {
        """
        {
          "enabled": true,
          "billingCycleEnd": 1800100000000,
          "planUsage": {
            "totalPercentUsed": 25,
            "autoPercentUsed": 40,
            "apiPercentUsed": 12
          }
        }
        """
    }

    private func sealedState(membership: String) -> [String: String] {
        [
            CursorAuthStore.accessTokenKey: sealedAccess,
            CursorAuthStore.refreshTokenKey: sealedRefresh,
            CursorAuthStore.membershipTypeKey: membership
        ]
    }

    private func token(subject: String, expiresIn: TimeInterval = 3_600) -> String {
        func segment(_ json: String) -> String {
            Data(json.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let expiration = now.timeIntervalSince1970 + expiresIn
        return [
            segment(#"{"alg":"none"}"#),
            segment(#"{"sub":"\#(subject)","exp":\#(expiration)}"#),
            "signature"
        ].joined(separator: ".")
    }

    private func authStore(
        state: [String: String],
        keychain: [String: String] = [:]
    ) -> CursorAuthStore {
        CursorAuthStore(
            sqlite: CursorStateDatabase(state),
            keychain: MemoryKeychain(generic: keychain),
            dateProvider: FixedDateProvider(value: now)
        )
    }

    private func provider(
        database: CursorStateDatabase,
        keychain: [String: String] = [:],
        http: HTTPClient
    ) -> CursorProvider {
        let date = FixedDateProvider(value: now)
        return CursorProvider(
            authStore: CursorAuthStore(
                sqlite: database,
                keychain: MemoryKeychain(generic: keychain),
                dateProvider: date
            ),
            client: CursorUsageClient(http: http),
            dateProvider: date
        )
    }

    private func assertFailure(
        _ provider: CursorProvider,
        kind: ProviderFailureKind,
        message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await provider.fetch()
            XCTFail("Expected a \(kind) failure", file: file, line: line)
        } catch let failure as ProviderFailure {
            XCTAssertEqual(failure.kind, kind, file: file, line: line)
            XCTAssertEqual(failure.message, message, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }
}

/// Cursor's state database: answers a query by the key it names and records
/// every statement that would change it.
private final class CursorStateDatabase: SQLiteValueReading, @unchecked Sendable {
    private let lock = NSLock()
    private let values: [String: String]
    private var statements: [String] = []

    init(_ values: [String: String]) {
        self.values = values
    }

    func queryValue(path: String, sql: String) throws -> String? {
        values.first { sql.contains("'\($0.key)'") }?.value
    }

    func execute(path: String, sql: String) throws {
        lock.withLock { statements.append(sql) }
    }

    func writes() -> [String] {
        lock.withLock { statements }
    }
}
