import Darwin
import Foundation

protocol EnvironmentReading: Sendable {
    func value(for name: String) -> String?
}

struct ProcessEnvironmentReader: EnvironmentReading {
    func value(for name: String) -> String? {
        if let value = ProcessInfo.processInfo.environment[name]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        return LoginShellEnvironment.shared.value(for: name)
    }
}

final class LoginShellEnvironment: @unchecked Sendable {
    static let shared = LoginShellEnvironment()

    private static let supportedNames = ["CLAUDE_CONFIG_DIR", "CODEX_HOME"]
    private static let beginMarker = "__AIUSAGE_ENV_BEGIN__"
    private static let endMarker = "__AIUSAGE_ENV_END__"

    private let runner: ProcessRunning
    private let stateLock = NSLock()
    private let captureLock = NSLock()
    private var cached: [String: String]?

    init(runner: ProcessRunning = SystemProcessRunner()) {
        self.runner = runner
    }

    func value(for name: String) -> String? {
        guard Self.supportedNames.contains(name) else { return nil }
        if let environment = cachedSnapshot() {
            return environment[name]
        }
        guard !Thread.isMainThread else { return nil }
        return capturedEnvironment()[name]
    }

    func prewarm() {
        Task.detached(priority: .utility) { [weak self] in
            _ = self?.capturedEnvironment()
        }
    }

    private func cachedSnapshot() -> [String: String]? {
        stateLock.withLock { cached }
    }

    private func capturedEnvironment() -> [String: String] {
        captureLock.lock()
        defer { captureLock.unlock() }
        if let environment = cachedSnapshot() {
            return environment
        }
        let environment = capture()
        stateLock.withLock { cached = environment }
        return environment
    }

    private func capture() -> [String: String] {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let names = Self.supportedNames.joined(separator: " ")
        let command = """
        printf '%s\\0' \(Self.beginMarker); \
        for name in \(names); do value=$(printenv "$name"); \
        if [ -n "$value" ]; then printf '%s=%s\\0' "$name" "$value"; fi; done; \
        printf '%s\\0' \(Self.endMarker)
        """
        guard let result = try? runner.run(
            executable: shell,
            arguments: ["-ilc", command],
            environment: [:],
            timeout: 5
        ), result.succeeded else {
            return [:]
        }
        return Self.parse(result.stdout)
    }

    static func parse(_ output: String) -> [String: String] {
        let tokens = output.components(separatedBy: "\0")
        guard let begin = tokens.firstIndex(of: beginMarker) else { return [:] }
        let end = tokens.firstIndex(of: endMarker) ?? tokens.count
        guard begin < end else { return [:] }

        var environment: [String: String] = [:]
        for token in tokens[(begin + 1)..<end] {
            guard let separator = token.firstIndex(of: "=") else { continue }
            let key = String(token[..<separator])
            let value = String(token[token.index(after: separator)...])
            if !key.isEmpty, !value.isEmpty {
                environment[key] = value
            }
        }
        return environment
    }
}

protocol TextFileAccessing: Sendable {
    func exists(_ path: String) -> Bool
    func readText(_ path: String) throws -> String
    func writeText(_ path: String, _ text: String) throws
}

struct LocalTextFileAccessor: TextFileAccessing {
    private static let privateFileMode = mode_t(S_IRUSR | S_IWUSR)

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: expandHome(path))
    }

    func readText(_ path: String) throws -> String {
        try String(contentsOfFile: expandHome(path), encoding: .utf8)
    }

    func writeText(_ path: String, _ text: String) throws {
        let expanded = expandHome(path)
        let parent = URL(fileURLWithPath: expanded).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let destination = URL(fileURLWithPath: expanded)
        let temporary = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        )
        let descriptor = temporary.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, Self.privateFileMode)
        }
        guard descriptor >= 0 else { throw Self.currentPOSIXError() }

        var descriptorIsOpen = true
        var temporaryExists = true
        defer {
            if descriptorIsOpen { _ = Darwin.close(descriptor) }
            if temporaryExists {
                temporary.path.withCString { _ = Darwin.unlink($0) }
            }
        }

        guard Darwin.fchmod(descriptor, Self.privateFileMode) == 0 else {
            throw Self.currentPOSIXError()
        }
        try Self.writeAll(Data(text.utf8), to: descriptor)
        guard Darwin.fsync(descriptor) == 0 else { throw Self.currentPOSIXError() }
        let closeResult = Darwin.close(descriptor)
        descriptorIsOpen = false
        guard closeResult == 0 else { throw Self.currentPOSIXError() }

        let renameResult = temporary.path.withCString { source in
            expanded.withCString { destination in
                Darwin.rename(source, destination)
            }
        }
        guard renameResult == 0 else { throw Self.currentPOSIXError() }
        temporaryExists = false
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw currentPOSIXError()
                }
                guard result > 0 else { throw POSIXError(.EIO) }
                offset += result
            }
        }
    }

    private static func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

protocol KeychainAccessing: Sendable {
    func readGenericPassword(service: String) throws -> String?
    func writeGenericPassword(service: String, value: String) throws
    func readGenericPasswordForCurrentUser(service: String) throws -> String?
    func writeGenericPasswordForCurrentUser(service: String, value: String) throws
}

struct SecurityKeychainAccessor: KeychainAccessing {
    private static let itemNotFoundExitCode: Int32 = 44
    let processRunner: ProcessRunning

    init(processRunner: ProcessRunning = SystemProcessRunner()) {
        self.processRunner = processRunner
    }

    func readGenericPassword(service: String) throws -> String? {
        try readPassword(["find-generic-password", "-s", service, "-w"])
    }

    func readGenericPasswordForCurrentUser(service: String) throws -> String? {
        try readPassword([
            "find-generic-password",
            "-a", currentUserAccount(),
            "-s", service,
            "-w"
        ])
    }

    func writeGenericPassword(service: String, value: String) throws {
        try writePassword(["add-generic-password", "-U", "-s", service, "-w", value])
    }

    func writeGenericPasswordForCurrentUser(service: String, value: String) throws {
        try writePassword([
            "add-generic-password",
            "-U",
            "-a", currentUserAccount(),
            "-s", service,
            "-w", value
        ])
    }

    private func readPassword(_ arguments: [String]) throws -> String? {
        let result = try processRunner.run(
            executable: "/usr/bin/security",
            arguments: arguments,
            environment: [:],
            timeout: 5
        )
        guard result.succeeded else {
            if result.exitCode == Self.itemNotFoundExitCode { return nil }
            throw KeychainError.readFailed
        }
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func writePassword(_ arguments: [String]) throws {
        let result = try processRunner.run(
            executable: "/usr/bin/security",
            arguments: arguments,
            environment: [:],
            timeout: 5
        )
        guard result.succeeded else {
            throw KeychainError.writeFailed
        }
    }

    private func currentUserAccount() -> String {
        let processUser = ProcessInfo.processInfo.environment["USER"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return processUser?.isEmpty == false ? processUser! : NSUserName()
    }
}

enum KeychainError: LocalizedError {
    case readFailed
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .readFailed: "Keychain could not be read."
        case .writeFailed: "Keychain could not be updated."
        }
    }
}

func expandHome(_ path: String) -> String {
    guard path == "~" || path.hasPrefix("~/") else { return path }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return path == "~" ? home : home + String(path.dropFirst())
}
