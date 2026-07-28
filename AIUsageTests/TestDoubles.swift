import Foundation
@testable import AIUsage

struct FixedDateProvider: DateProviding {
    let value: Date

    func now() -> Date { value }
}

struct MockEnvironment: EnvironmentReading {
    var values: [String: String] = [:]

    func value(for name: String) -> String? {
        values[name]
    }
}

struct FixedProviderAvailabilityChecker: ProviderAvailabilityChecking {
    var installed: Set<ProviderID>? = Set(ProviderID.allCases)

    func installedProviders() async -> Set<ProviderID>? {
        installed
    }
}

final class MemoryFiles: TextFileAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String]

    init(_ storage: [String: String] = [:]) {
        self.storage = storage
    }

    func exists(_ path: String) -> Bool {
        lock.withLock { storage[path] != nil }
    }

    func readText(_ path: String) throws -> String {
        try lock.withLock {
            guard let value = storage[path] else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            return value
        }
    }

    func writeText(_ path: String, _ text: String) throws {
        lock.withLock { storage[path] = text }
    }

    func value(at path: String) -> String? {
        lock.withLock { storage[path] }
    }
}

final class MemoryKeychain: KeychainAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private var generic: [String: String]
    private var currentUser: [String: String]
    private(set) var genericReads: [String] = []
    private(set) var currentUserReads: [String] = []

    init(
        generic: [String: String] = [:],
        currentUser: [String: String] = [:]
    ) {
        self.generic = generic
        self.currentUser = currentUser
    }

    func readGenericPassword(service: String) throws -> String? {
        lock.withLock {
            genericReads.append(service)
            return generic[service]
        }
    }

    func writeGenericPassword(service: String, value: String) throws {
        lock.withLock { generic[service] = value }
    }

    func readGenericPasswordForCurrentUser(service: String) throws -> String? {
        lock.withLock {
            currentUserReads.append(service)
            return currentUser[service]
        }
    }

    func writeGenericPasswordForCurrentUser(service: String, value: String) throws {
        lock.withLock { currentUser[service] = value }
    }

    func currentValue(service: String) -> String? {
        lock.withLock { currentUser[service] }
    }
}

actor MockHTTPClient: HTTPClient {
    private var responses: [HTTPResponse]
    private var requests: [HTTPRequest] = []

    init(_ responses: [HTTPResponse]) {
        self.responses = responses
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else {
            throw ProviderFailure(.transient, "No mock response available.")
        }
        return responses.removeFirst()
    }

    func capturedRequests() -> [HTTPRequest] {
        requests
    }
}

actor SequencedProvider: UsageProvider {
    nonisolated let id: ProviderID
    private var results: [Result<ProviderSnapshot, ProviderFailure>]

    init(id: ProviderID, results: [Result<ProviderSnapshot, ProviderFailure>]) {
        self.id = id
        self.results = results
    }

    func fetch() async throws -> ProviderSnapshot {
        guard !results.isEmpty else {
            throw ProviderFailure(.transient, "No mock result available.")
        }
        return try results.removeFirst().get()
    }
}

actor CountingProvider: UsageProvider {
    nonisolated let id: ProviderID
    private let result: Result<ProviderSnapshot, ProviderFailure>
    private var count = 0

    init(
        id: ProviderID,
        result: Result<ProviderSnapshot, ProviderFailure>
    ) {
        self.id = id
        self.result = result
    }

    func fetch() async throws -> ProviderSnapshot {
        count += 1
        return try result.get()
    }

    func fetchCallCount() -> Int {
        count
    }
}

func httpResponse(
    _ status: Int = 200,
    json: String = "{}",
    headers: [String: String] = [:]
) -> HTTPResponse {
    HTTPResponse(statusCode: status, headers: headers, body: Data(json.utf8))
}

func encodedJSON<T: Encodable>(_ value: T) -> String {
    String(data: try! JSONEncoder().encode(value), encoding: .utf8)!
}

func jwt(expiration: TimeInterval) -> String {
    let header = Data(#"{"alg":"none"}"#.utf8).base64URLEncoded
    let payload = Data(#"{"exp":\#(expiration)}"#.utf8).base64URLEncoded
    return "\(header).\(payload).signature"
}

private extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
