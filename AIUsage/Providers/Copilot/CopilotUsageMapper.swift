import Foundation

enum CopilotUsageMapper {
    static func map(
        response: HTTPResponse,
        now: Date
    ) throws -> ProviderSnapshot {
        guard (200..<300).contains(response.statusCode) else {
            throw ProviderFailure(
                response.statusCode >= 500 ? .transient : .invalidResponse,
                "Copilot usage request failed (\(response.statusCode))."
            )
        }

        let body = try ProviderParsing.object(from: response.body)
        let reset = resetDate(body)
        let snapshots = ProviderParsing.object(body["quota_snapshots"])
        var windows: [QuotaWindow] = []

        if let credits = quotaWindow(
            snapshots?["premium_interactions"],
            kind: .credits,
            resetsAt: reset
        ) {
            windows.append(credits)
        }
        if let chat = quotaWindow(
            snapshots?["chat"],
            kind: .chat,
            resetsAt: reset
        ) {
            windows.append(chat)
        }
        if let completions = quotaWindow(
            snapshots?["completions"],
            kind: .completions,
            resetsAt: reset
        ) {
            windows.append(completions)
        }

        if windows.isEmpty {
            let limited = ProviderParsing.object(body["limited_user_quotas"])
            let monthly = ProviderParsing.object(body["monthly_quotas"])
            if let chat = legacyWindow(
                remaining: limited?["chat"],
                total: monthly?["chat"],
                kind: .chat,
                resetsAt: reset
            ) {
                windows.append(chat)
            }
            if let completions = legacyWindow(
                remaining: limited?["completions"],
                total: monthly?["completions"],
                kind: .completions,
                resetsAt: reset
            ) {
                windows.append(completions)
            }
        }

        let isOrganizationSeat = body["token_based_billing"] as? Bool == true
        guard !windows.isEmpty || isOrganizationSeat else {
            throw ProviderFailure(
                .invalidResponse,
                "Copilot usage data is unavailable for this account."
            )
        }

        return ProviderSnapshot(
            provider: .copilot,
            planName: planName(body["copilot_plan"]),
            windows: windows,
            fetchedAt: now
        )
    }

    private static func quotaWindow(
        _ value: Any?,
        kind: QuotaKind,
        resetsAt: Date?
    ) -> QuotaWindow? {
        guard let bucket = ProviderParsing.object(value) else { return nil }
        let entitlement = ProviderParsing.double(bucket["entitlement"])
        let remaining = ProviderParsing.double(bucket["remaining"])

        if bucket["unlimited"] as? Bool == true ||
            entitlement == -1 ||
            remaining == -1 ||
            entitlement == 0 {
            return nil
        }

        let usedPercent: Double
        if let percentRemaining = ProviderParsing.double(
            bucket["percent_remaining"]
        ) {
            usedPercent = clampPercent(100 - percentRemaining)
        } else if let entitlement, entitlement > 0, let remaining {
            usedPercent = clampPercent(
                100 - (remaining / entitlement) * 100
            )
        } else {
            return nil
        }
        return QuotaWindow(
            kind: kind,
            usedPercent: usedPercent,
            resetsAt: resetsAt
        )
    }

    private static func legacyWindow(
        remaining: Any?,
        total: Any?,
        kind: QuotaKind,
        resetsAt: Date?
    ) -> QuotaWindow? {
        guard let total = ProviderParsing.double(total), total > 0,
              let remaining = ProviderParsing.double(remaining) else {
            return nil
        }
        return QuotaWindow(
            kind: kind,
            usedPercent: clampPercent(
                ((total - remaining) / total) * 100
            ),
            resetsAt: resetsAt
        )
    }

    private static func resetDate(_ body: [String: Any]) -> Date? {
        if let date = ProviderParsing.date(body["quota_reset_date"]) {
            return date
        }
        guard let value = ProviderParsing.string(
            body["limited_user_reset_date"]
        ) else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }

    private static func planName(_ value: Any?) -> String? {
        guard let raw = ProviderParsing.string(value)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return ProviderParsing.titleCaseIdentifier(raw)
    }

    private static func clampPercent(_ value: Double) -> Double {
        min(max(value, 0), 100)
    }
}
