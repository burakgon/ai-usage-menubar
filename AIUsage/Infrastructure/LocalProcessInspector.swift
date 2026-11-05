import Darwin
import Foundation

struct LocalProcess: Equatable, Sendable {
    let pid: Int32
    let executablePath: String

    var executableName: String {
        (executablePath as NSString).lastPathComponent
    }
}

struct ProcessCommandLine: Equatable, Sendable {
    let arguments: [String]
    let environment: [String]

    func value(forFlag flag: String) -> String? {
        let prefix = flag + "="
        for (index, argument) in arguments.enumerated() {
            if argument == flag {
                let next = index + 1
                return next < arguments.count ? arguments[next] : nil
            }
            if argument.hasPrefix(prefix) {
                return String(argument.dropFirst(prefix.count))
            }
        }
        return nil
    }

    func environmentValue(_ name: String) -> String? {
        let prefix = name + "="
        guard let entry = environment.first(where: { $0.hasPrefix(prefix) })
        else {
            return nil
        }
        let value = String(entry.dropFirst(prefix.count))
        return value.isEmpty ? nil : value
    }
}

/// Read-only access to the current user's running processes, used only to
/// find a coding tool's own loopback server.
protocol ProcessInspecting: Sendable {
    func processes() -> [LocalProcess]
    func commandLine(of pid: Int32) -> ProcessCommandLine?
    func children(of pid: Int32) -> [Int32]
    func listeningPorts(of pid: Int32) -> [Int]
}

struct SystemProcessInspector: ProcessInspecting {
    let runner: ProcessRunning

    init(runner: ProcessRunning = SystemProcessRunner()) {
        self.runner = runner
    }

    /// Executable paths only: other processes' arguments are never listed.
    func processes() -> [LocalProcess] {
        guard let result = try? runner.run(
            executable: "/bin/ps",
            arguments: ["-ax", "-o", "pid=,comm="],
            environment: [:],
            timeout: 5
        ), result.succeeded else {
            return []
        }
        return Self.parseProcesses(result.stdout)
    }

    /// Reads one process's arguments and environment with
    /// `KERN_PROCARGS2`, which macOS allows only for the user's own processes.
    func commandLine(of pid: Int32) -> ProcessCommandLine? {
        var maximumMIB: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var maximum: Int32 = 0
        var maximumSize = MemoryLayout<Int32>.size
        guard sysctl(&maximumMIB, 2, &maximum, &maximumSize, nil, 0) == 0,
              maximum > 0 else {
            return nil
        }

        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = Int(maximum)
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        return Self.parseCommandLine(Array(buffer.prefix(size)))
    }

    func children(of pid: Int32) -> [Int32] {
        guard let result = try? runner.run(
            executable: "/usr/bin/pgrep",
            arguments: ["-P", String(pid)],
            environment: [:],
            timeout: 3
        ), result.succeeded else {
            return []
        }
        return result.stdout
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    func listeningPorts(of pid: Int32) -> [Int] {
        guard let result = try? runner.run(
            executable: "/usr/sbin/lsof",
            // `-a` ANDs the selectors. Without it lsof would list every
            // listening socket on the Mac instead of this process's own.
            arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", String(pid)],
            environment: [:],
            timeout: 5
        ), result.succeeded else {
            return []
        }
        return Self.parseListeningPorts(result.stdout)
    }

    static func parseProcesses(_ output: String) -> [LocalProcess] {
        output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let separator = line.firstIndex(where: \.isWhitespace),
                  let pid = Int32(line[..<separator]) else {
                return nil
            }
            let path = line[separator...].trimmingCharacters(in: .whitespaces)
            return path.isEmpty ? nil : LocalProcess(pid: pid, executablePath: path)
        }
    }

    /// Loopback listening ports from `lsof -nP -iTCP -sTCP:LISTEN` output.
    static func parseListeningPorts(_ output: String) -> [Int] {
        var ports: [Int] = []
        for line in output.split(whereSeparator: \.isNewline)
        where line.contains("(LISTEN)") {
            for field in line.split(separator: " ") {
                guard let colon = field.lastIndex(of: ":") else { continue }
                let host = field[..<colon]
                guard ["127.0.0.1", "localhost", "[::1]", "*"]
                    .contains(String(host)),
                    let port = Int(field[field.index(after: colon)...]),
                    (1...65_535).contains(port) else {
                    continue
                }
                if !ports.contains(port) {
                    ports.append(port)
                }
            }
        }
        return ports
    }

    /// Parses a `KERN_PROCARGS2` buffer: `argc`, the executable path and its
    /// padding, `argc` arguments, then environment strings up to an empty
    /// string.
    static func parseCommandLine(_ bytes: [UInt8]) -> ProcessCommandLine? {
        guard bytes.count > MemoryLayout<Int32>.size else { return nil }
        let argumentCount = bytes.withUnsafeBytes {
            Int($0.loadUnaligned(as: Int32.self))
        }
        guard argumentCount >= 0 else { return nil }

        var offset = MemoryLayout<Int32>.size
        while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
        while offset < bytes.count, bytes[offset] == 0 { offset += 1 }

        func nextString() -> String? {
            guard offset < bytes.count else { return nil }
            let start = offset
            while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
            let value = String(decoding: bytes[start..<offset], as: UTF8.self)
            offset += 1
            return value
        }

        var arguments: [String] = []
        while arguments.count < argumentCount, let argument = nextString() {
            arguments.append(argument)
        }
        var environment: [String] = []
        while let entry = nextString(), !entry.isEmpty {
            environment.append(entry)
        }
        return ProcessCommandLine(arguments: arguments, environment: environment)
    }
}
