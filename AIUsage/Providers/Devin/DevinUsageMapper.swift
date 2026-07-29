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
        let hidesDaily = planInfo["hideDailyQuota"] as? Bool == true
        let dailyRemaining = ProviderParsing.double(
            planStatus["dailyQuotaRemainingPercent"]
        )
        let weeklyRemaining = ProviderParsing.double(
            planStatus["weeklyQuotaRemainingPercent"]
        )
        let weeklyReset = ProviderParsing.date(
            planStatus["weeklyQuotaResetAtUnix"]
        )
        var windows: [QuotaWindow] = []

        if !hidesDaily, let dailyRemaining {
            windows.append(QuotaWindow(
                kind: .daily,
                usedPercent: clampPercent(100 - dailyRemaining),
                resetsAt: ProviderParsing.date(
                    planStatus["dailyQuotaResetAtUnix"]
                )
            ))
        }
        if let weeklyRemaining {
            windows.append(QuotaWindow(
                kind: .weekly,
                usedPercent: clampPercent(100 - weeklyRemaining),
                resetsAt: weeklyReset
            ))
        } else if hidesDaily, let dailyRemaining {
            windows.append(QuotaWindow(
                kind: .weekly,
                usedPercent: clampPercent(100 - dailyRemaining),
                resetsAt: weeklyReset
            ))
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

    private static func clampPercent(_ value: Double) -> Double {
        min(max(value, 0), 100)
    }
}
