import Foundation

/// Reads the quota summary from a running Antigravity app or `agy` CLI.
///
/// Google's Cloud Code endpoint does not share quota with every account
/// (Starter accounts answer `PERMISSION_DENIED` #3501), while the tools
/// themselves keep reporting it. Both serve the same `RetrieveUserQuotaSummary`
/// payload their Models & Quota screen renders on a loopback listener guarded
/// by a CSRF token.
struct AntigravityLocalClient: Sendable {
    static let summaryPath =
        "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"
    static let csrfEnvironmentName = "ANTIGRAVITY_CSRF_TOKEN"
    private static let maximumEndpoints = 8
    private static let appMarkers: Set<String> = ["antigravity", "antigravity-ide"]
    private static let metadata = Data(
        #"{"metadata":{"ideName":"antigravity","extensionName":"antigravity","ideVersion":"unknown","locale":"en"}}"#
            .utf8
    )

    struct Endpoint: Equatable, Sendable {
        let url: URL
        let csrfToken: String?
    }

    private let inspector: ProcessInspecting
    private let http: HTTPClient

    init(
        inspector: ProcessInspecting = SystemProcessInspector(),
        http: HTTPClient = LoopbackHTTPClient()
    ) {
        self.inspector = inspector
        self.http = http
    }

    /// The first summary a running Antigravity tool answers with, or `nil`
    /// when none is running or none answers with quota groups.
    func summary() async -> Data? {
        for endpoint in endpoints().prefix(Self.maximumEndpoints) {
            var headers = [
                "Content-Type": "application/json",
                "Connect-Protocol-Version": "1"
            ]
            if let csrfToken = endpoint.csrfToken {
                headers["X-Codeium-Csrf-Token"] = csrfToken
            }
            guard let response = try? await http.send(HTTPRequest(
                method: .post,
                url: endpoint.url,
                headers: headers,
                body: Self.metadata
            )),
                (200..<300).contains(response.statusCode),
                AntigravityUsageMapper.containsSummary(response.body) else {
                continue
            }
            return response.body
        }
        return nil
    }

    /// Loopback endpoints of the running Antigravity app first, then `agy`.
    func endpoints() -> [Endpoint] {
        let processes = inspector.processes()
        var endpoints: [Endpoint] = []

        for process in processes where Self.isLanguageServer(process) {
            guard let commandLine = inspector.commandLine(of: process.pid),
                  Self.belongsToAntigravity(process, commandLine: commandLine),
                  let csrfToken = commandLine.value(forFlag: "--csrf_token")
            else {
                continue
            }
            for port in inspector.listeningPorts(of: process.pid) {
                endpoints += Self.urls(port: port, schemes: ["https", "http"])
                    .map { Endpoint(url: $0, csrfToken: csrfToken) }
            }
            if let port = commandLine.value(forFlag: "--extension_server_port")
                .flatMap(Int.init) {
                endpoints += Self.urls(port: port, schemes: ["http"])
                    .map { Endpoint(url: $0, csrfToken: csrfToken) }
            }
        }

        for process in processes where process.executableName == "agy" {
            let ports = inspector.listeningPorts(of: process.pid)
            guard !ports.isEmpty else { continue }
            let csrfToken = cliCSRFToken(pid: process.pid)
            for port in ports {
                endpoints += Self.urls(port: port, schemes: ["https", "http"])
                    .map { Endpoint(url: $0, csrfToken: csrfToken) }
            }
        }
        return endpoints
    }

    /// `agy` does not take its CSRF token on the command line. It hands the
    /// token to the processes it starts, so read it from its own environment
    /// or from one of its children.
    private func cliCSRFToken(pid: Int32) -> String? {
        let own = inspector.commandLine(of: pid)
        if let token = own?.value(forFlag: "--csrf_token")
            ?? own?.environmentValue(Self.csrfEnvironmentName) {
            return token
        }
        for child in inspector.children(of: pid) {
            if let token = inspector.commandLine(of: child)?
                .environmentValue(Self.csrfEnvironmentName) {
                return token
            }
        }
        return nil
    }

    static func isLanguageServer(_ process: LocalProcess) -> Bool {
        let name = process.executableName.lowercased()
        return name == "language_server" || name.hasPrefix("language_server_")
    }

    /// Other Codeium-derived editors run a `language_server` too. Prefer the
    /// editor's own identity flags, then the Antigravity app bundle path.
    static func belongsToAntigravity(
        _ process: LocalProcess,
        commandLine: ProcessCommandLine
    ) -> Bool {
        let identities = ["--ide_name", "--override_ide_name", "--app_data_dir"]
            .compactMap { commandLine.value(forFlag: $0)?.lowercased() }
        if !identities.isEmpty {
            return identities.contains(where: appMarkers.contains)
        }
        let path = process.executablePath.lowercased()
        return path.contains("/antigravity.app/") || path.contains("/antigravity/")
    }

    private static func urls(port: Int, schemes: [String]) -> [URL] {
        schemes.compactMap {
            URL(string: "\($0)://127.0.0.1:\(port)\(summaryPath)")
        }
    }
}

/// Talks only to `127.0.0.1`, where the Antigravity tools serve a self-signed
/// certificate. Every other host keeps the system's default trust evaluation.
struct LoopbackHTTPClient: HTTPClient {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard request.url.host == "127.0.0.1" else {
            throw ProviderFailure(.invalidResponse, "Only loopback requests are allowed.")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 6
        let session = URLSession(
            configuration: configuration,
            delegate: LoopbackTrustDelegate(),
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }

        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderFailure(.transient, "The server returned an invalid response.")
        }
        return HTTPResponse(statusCode: httpResponse.statusCode, headers: [:], body: data)
    }
}

private final class LoopbackTrustDelegate: NSObject, URLSessionDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod ==
            NSURLAuthenticationMethodServerTrust,
            challenge.protectionSpace.host == "127.0.0.1",
            let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }
}
