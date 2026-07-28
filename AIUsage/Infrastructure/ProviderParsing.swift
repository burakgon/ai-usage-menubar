import CryptoKit
import CoreFoundation
import Foundation

enum ProviderParsing {
    static func object(from data: Data) throws -> [String: Any] {
        guard
            let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw ProviderFailure(.invalidResponse, "The server returned unreadable usage data.")
        }
        return value
    }

    static func object(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    static func array(_ value: Any?) -> [[String: Any]] {
        value as? [[String: Any]] ?? []
    }

    static func string(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }

    static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let result = number.doubleValue
            return result.isFinite ? result : nil
        }
        if let string = value as? String {
            let result = Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
            return result?.isFinite == true ? result : nil
        }
        return nil
    }

    static func centsToDollars(_ cents: Double) -> Double {
        cents.rounded() / 100
    }

    static func decodeWithHexFallback<T: Decodable>(_ text: String, as type: T.Type) -> T? {
        if let data = text.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(type, from: data) {
            return decoded
        }

        var hex = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("0x") || hex.hasPrefix("0X") {
            hex = String(hex.dropFirst(2))
        }
        guard !hex.isEmpty, hex.count.isMultiple(of: 2), hex.allSatisfy(\.isHexDigit) else {
            return nil
        }

        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return try? JSONDecoder().decode(type, from: Data(bytes))
    }

    static func date(_ value: Any?) -> Date? {
        if let number = double(value) {
            let seconds = number > 10_000_000_000 ? number / 1_000 : number
            return Date(timeIntervalSince1970: seconds)
        }

        guard var normalized = string(value)?
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        if normalized.hasSuffix(" UTC") {
            normalized = String(normalized.dropLast(4)) + "Z"
        }
        if normalized.range(
            of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}"#,
            options: .regularExpression
        ) != nil {
            let separator = normalized.index(normalized.startIndex, offsetBy: 10)
            normalized.replaceSubrange(separator...separator, with: "T")
        }
        if normalized.range(
            of: #"(Z|[+-]\d{2}:\d{2})$"#,
            options: .regularExpression
        ) == nil {
            normalized += "Z"
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = formatter.date(from: normalized) {
            return parsed
        }
        formatter.formatOptions = [.withInternetDateTime]
        if let parsed = formatter.date(from: normalized) {
            return parsed
        }
        return nil
    }

    static func retryDate(from response: HTTPResponse, now: Date) -> Date {
        guard let value = response.header("Retry-After")?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return now.addingTimeInterval(300)
        }
        if let seconds = TimeInterval(value) {
            return now.addingTimeInterval(max(seconds, 0))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter.date(from: value) ?? now.addingTimeInterval(300)
    }

    static func jwtExpiration(_ token: String) -> Date? {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count > 1,
              let payload = base64URLData(String(segments[1])),
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let expiration = double(object["exp"])
        else {
            return nil
        }
        return Date(timeIntervalSince1970: expiration)
    }

    static func base64URLData(_ value: String) -> Data? {
        var normalized = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        return Data(base64Encoded: normalized)
    }

    static func shortSHA256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .prefix(4)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func formBody(_ values: [(String, String)]) -> Data {
        let body = values.map { "\(formEncode($0.0))=\(formEncode($0.1))" }.joined(separator: "&")
        return Data(body.utf8)
    }

    static func titleCaseIdentifier(_ value: String) -> String {
        value
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }

    private static func formEncode(_ value: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8)
        return value.utf8.map { byte in
            allowed.contains(byte) ? String(UnicodeScalar(byte)) : String(format: "%%%02X", byte)
        }.joined()
    }
}
