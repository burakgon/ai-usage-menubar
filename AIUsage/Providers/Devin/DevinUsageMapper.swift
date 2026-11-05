import Foundation

enum DevinUsageMapper {
    static func map(
        response: HTTPResponse,
        now: Date
    ) throws -> ProviderSnapshot {
        guard (200..<300).contains(response.statusCode) else {
            throw ProviderFailure(
                response.statusCode >= 500 ? .transient : .invalidResponse,
                "Devin usage request failed (\(response.statusCode))."
            )
        }
        let body = try ProviderParsing.object(from: response.body)
        guard let status = ProviderParsing.object(body["userStatus"]) else {
            throw ProviderFailure(
                .invalidResponse,
                "Devin quota response changed."
            )
        }
        let planStatus = ProviderParsing.object(status["planStatus"]) ?? [:]
        let planInfo = ProviderParsing.object(planStatus["planInfo"]) ?? [:]
        let daily = try quota(
            planStatus,
            remaining: "dailyQuotaRemainingPercent",
            reset: "dailyQuotaResetAtUnix"
        )
        let weekly = try quota(
            planStatus,
            remaining: "weeklyQuotaRemainingPercent",
            reset: "weeklyQuotaResetAtUnix"
        )
        var windows: [QuotaWindow] = []

        if planInfo["hideDailyQuota"] as? Bool == true {
            // A plan that hides its daily quota still meters it. With no
            // weekly window, the Weekly row carries it.
            if let shown = weekly ?? daily.map({
                (remaining: $0.remaining, resetsAt: Date?.none)
            }) {
                windows.append(window(.weekly, shown))
            }
        } else {
            if let daily { windows.append(window(.daily, daily)) }
            if let weekly { windows.append(window(.weekly, weekly)) }
        }

        guard !windows.isEmpty else {
            throw ProviderFailure(
                .invalidResponse,
                "Devin quota data is unavailable."
            )
        }
        return ProviderSnapshot(
            provider: .devin,
            planName: ProviderParsing.string(planInfo["planName"]),
            windows: windows,
            fetchedAt: now
        )
    }

    /// Devin reports the share of a quota left. Proto3 JSON omits a zero, so
    /// a window with a reset time and no share has none left. A share that
    /// is present but unreadable is a changed schema, not an empty quota.
    private static func quota(
        _ planStatus: [String: Any],
        remaining key: String,
        reset resetKey: String
    ) throws -> (remaining: Double, resetsAt: Date?)? {
        let resetsAt = ProviderParsing.date(planStatus[resetKey])
        guard let value = planStatus[key], !(value is NSNull) else {
            return resetsAt.map { (remaining: 0, resetsAt: $0) }
        }
        guard let remaining = ProviderParsing.double(value) else {
            throw ProviderFailure(
                .invalidResponse,
                "Devin quota response changed."
            )
        }
        return (remaining, resetsAt)
    }

    private static func window(
        _ kind: QuotaKind,
        _ quota: (remaining: Double, resetsAt: Date?)
    ) -> QuotaWindow {
        QuotaWindow(
            kind: kind,
            usedPercent: clampPercent(100 - quota.remaining),
            resetsAt: quota.resetsAt
        )
    }

    private static func clampPercent(_ value: Double) -> Double {
        min(max(value, 0), 100)
    }
}
