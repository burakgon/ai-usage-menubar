import Foundation

/// The banked rate-limit resets listed by Codex's reset-credits endpoint.
struct CodexResetCreditList: Equatable, Sendable {
    let availableCount: Int
    let expirations: [Date]

    static func parse(_ data: Data) -> CodexResetCreditList? {
        guard let body = try? ProviderParsing.object(from: data),
              let count = CodexUsageMapper.availableResetCount(body) else {
            return nil
        }
        let credits = body["credits"] as? [[String: Any]] ?? []
        let expirations = credits
            .filter { credit in
                guard let status = ProviderParsing.string(credit["status"]) else {
                    return true
                }
                return status == "available"
            }
            .compactMap { ProviderParsing.date($0["expires_at"]) }
        return CodexResetCreditList(availableCount: count, expirations: expirations)
    }
}

enum CodexUsageMapper {
    // Codex flex credits are worth four US cents each.
    static let creditUSDRate = 0.04

    private enum WindowKind {
        case session
        case weekly
    }

    private struct WindowCandidate {
        let object: [String: Any]
        let usedPercent: Double?
        let fallbackKind: WindowKind
    }

    static func map(
        response: HTTPResponse,
        resetCreditList: CodexResetCreditList? = nil,
        now: Date
    ) throws -> ProviderSnapshot {
        guard (200..<300).contains(response.statusCode) else {
            throw ProviderFailure(
                response.statusCode >= 500 ? .transient : .invalidResponse,
                "Codex usage request failed (\(response.statusCode))."
            )
        }
        let body = try ProviderParsing.object(from: response.body)
        var windows = classify(
            rateLimit: ProviderParsing.object(body["rate_limit"]),
            kinds: (.session, .weekly),
            headerPercents: (
                ProviderParsing.double(response.header("x-codex-primary-used-percent")),
                ProviderParsing.double(response.header("x-codex-secondary-used-percent"))
            ),
            now: now
        )

        if let entries = body["additional_rate_limits"] as? [Any] {
            for rawEntry in entries {
                guard let entry = ProviderParsing.object(rawEntry), isSpark(entry),
                      let rateLimit = ProviderParsing.object(entry["rate_limit"]) else {
                    continue
                }
                windows.append(contentsOf: classify(
                    rateLimit: rateLimit,
                    kinds: (.sparkSession, .sparkWeekly),
                    headerPercents: (nil, nil),
                    now: now
                ))
                break
            }
        }

        return ProviderSnapshot(
            provider: .codex,
            planName: planName(body["plan_type"]),
            windows: windows,
            billingUsage: billingUsage(response: response, body: body),
            resets: resets(
                embeddedCount: embeddedResetCount(body),
                list: resetCreditList
            ),
            fetchedAt: now
        )
    }

    /// The count of banked resets in this usage response, if it has one.
    static func embeddedResetCount(_ body: [String: Any]) -> Int? {
        ProviderParsing.object(body["rate_limit_reset_credits"])
            .flatMap(availableResetCount)
    }

    static func availableResetCount(_ source: [String: Any]) -> Int? {
        guard let count = ProviderParsing.double(source["available_count"]),
              count >= 0,
              count < Double(Int32.max) else {
            return nil
        }
        return Int(count.rounded(.down))
    }

    /// The usage response's count is current on every read. The list, read
    /// less often, supplies expirations only while it agrees with that count,
    /// so it never stands in for a reset spent or granted since.
    static func resets(
        embeddedCount: Int?,
        list: CodexResetCreditList?
    ) -> UsageResets? {
        guard let count = embeddedCount ?? list?.availableCount else {
            return nil
        }
        guard let list, list.availableCount == count else {
            return UsageResets(availableCount: count)
        }
        return UsageResets(availableCount: count, expirations: list.expirations)
    }

    static func planName(_ value: Any?) -> String? {
        guard let raw = ProviderParsing.string(value)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        // OpenAI's published Pro plan names.
        switch raw.lowercased() {
        case "prolite": return "Pro 100"
        case "pro": return "Pro 200"
        case "promax": return "Pro 500"
        case "self_serve_business_prolite": return "Business Premium"
        default: return ProviderParsing.titleCaseIdentifier(raw)
        }
    }

    private static func classify(
        rateLimit: [String: Any]?,
        kinds: (session: QuotaKind, weekly: QuotaKind),
        headerPercents: (primary: Double?, secondary: Double?),
        now: Date
    ) -> [QuotaWindow] {
        let candidates = [
            candidate(
                rateLimit?["primary_window"],
                headerPercent: headerPercents.primary,
                fallbackKind: .session
            ),
            candidate(
                rateLimit?["secondary_window"],
                headerPercent: headerPercents.secondary,
                fallbackKind: .weekly
            )
        ].compactMap { $0 }

        var windows: [QuotaWindow] = []
        if let session = window(
            kind: .session,
            outputKind: kinds.session,
            candidates: candidates,
            now: now
        ) {
            windows.append(session)
        }
        if let weekly = window(
            kind: .weekly,
            outputKind: kinds.weekly,
            candidates: candidates,
            now: now
        ) {
            windows.append(weekly)
        }
        return windows
    }

    private static func candidate(
        _ value: Any?,
        headerPercent: Double?,
        fallbackKind: WindowKind
    ) -> WindowCandidate? {
        let object: [String: Any]
        if let parsed = ProviderParsing.object(value) {
            object = parsed
        } else if headerPercent != nil {
            object = [:]
        } else {
            return nil
        }
        return WindowCandidate(
            object: object,
            usedPercent: ProviderParsing.double(object["used_percent"]) ?? headerPercent,
            fallbackKind: fallbackKind
        )
    }

    private static func window(
        kind: WindowKind,
        outputKind: QuotaKind,
        candidates: [WindowCandidate],
        now: Date
    ) -> QuotaWindow? {
        let exact = candidates.first { exactKind($0.object) == kind }
        let fallback = candidates.first {
            exactKind($0.object) == nil && $0.fallbackKind == kind
        }
        guard let candidate = exact ?? fallback,
              let used = candidate.usedPercent else {
            return nil
        }
        return QuotaWindow(
            kind: outputKind,
            usedPercent: used,
            resetsAt: resetDate(candidate.object, now: now)
        )
    }

    private static func exactKind(_ window: [String: Any]) -> WindowKind? {
        guard let seconds = ProviderParsing.double(window["limit_window_seconds"]) else {
            return nil
        }
        switch Int(seconds.rounded()) {
        case 18_000: return .session
        case 604_800: return .weekly
        default: return nil
        }
    }

    private static func resetDate(_ window: [String: Any], now: Date) -> Date? {
        if let resetAt = ProviderParsing.double(window["reset_at"]) {
            return Date(timeIntervalSince1970: resetAt)
        }
        if let resetAfter = ProviderParsing.double(window["reset_after_seconds"]) {
            return now.addingTimeInterval(resetAfter)
        }
        return nil
    }

    private static func isSpark(_ entry: [String: Any]) -> Bool {
        [entry["limit_name"], entry["metered_feature"]]
            .compactMap(ProviderParsing.string)
            .map { $0.lowercased() }
            .contains { $0.contains("spark") }
    }

    private static func billingUsage(
        response: HTTPResponse,
        body: [String: Any]
    ) -> BillingUsage? {
        guard let remaining = creditsRemaining(response: response, body: body) else {
            return nil
        }

        // Price the whole-credit balance after flooring, matching Codex/OpenUsage.
        let floored = remaining.rounded(.down)
        let remainingCredits: Int
        if floored <= 0 {
            remainingCredits = 0
        } else if floored >= Double(Int.max) {
            remainingCredits = Int.max
        } else {
            remainingCredits = Int(floored)
        }
        return .flexCreditBalance(
            remainingCredits: remainingCredits,
            usdValue: Double(remainingCredits) * creditUSDRate
        )
    }

    /// An account without credits shows no Credits row rather than $0.
    private static func creditsRemaining(
        response: HTTPResponse,
        body: [String: Any]
    ) -> Double? {
        let credits = ProviderParsing.object(body["credits"])
        let hasCredits = (credits?["has_credits"] as? Bool)
            ?? boolean(response.header("x-codex-credits-has-credits"))
        guard hasCredits != false else { return nil }
        return ProviderParsing.double(credits?["balance"])
            ?? ProviderParsing.double(response.header("x-codex-credits-balance"))
    }

    private static func boolean(_ value: String?) -> Bool? {
        switch value?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "true", "1": true
        case "false", "0": false
        default: nil
        }
    }
}
