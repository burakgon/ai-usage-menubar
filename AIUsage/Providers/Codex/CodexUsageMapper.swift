import Foundation

enum CodexUsageMapper {
    private enum WindowKind {
        case session
        case weekly
    }

    private struct WindowCandidate {
        let object: [String: Any]
        let usedPercent: Double?
        let fallbackKind: WindowKind
    }

    static func map(response: HTTPResponse, now: Date) throws -> ProviderSnapshot {
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
            creditUsage: creditUsage(body["credits"]),
            fetchedAt: now
        )
    }

    static func planName(_ value: Any?) -> String? {
        guard let raw = ProviderParsing.string(value)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        switch raw.lowercased() {
        case "prolite": return "Pro 5x"
        case "pro": return "Pro 20x"
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

    private static func creditUsage(_ value: Any?) -> CreditUsage? {
        guard let object = ProviderParsing.object(value) else {
            return nil
        }

        let balanceAmount = ProviderParsing.double(object["balance"])
            .map { max($0, 0) }
        let isUnlimited = object["unlimited"] as? Bool == true
        let hasCredits = (object["has_credits"] as? Bool) ??
            (object["hasCredits"] as? Bool)
        guard balanceAmount != nil || isUnlimited || hasCredits == true else {
            return nil
        }

        let currencyCode = ProviderParsing.string(object["currency"])?
            .uppercased() ?? "USD"
        return CreditUsage(
            balanceAmount: balanceAmount,
            currencyCode: currencyCode,
            isUnlimited: isUnlimited
        )
    }
}
