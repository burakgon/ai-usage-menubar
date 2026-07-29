import Foundation

enum GrokUsageMapper {
    static let weeklyPeriodType = "USAGE_PERIOD_TYPE_WEEKLY"

    static func map(
        response: HTTPResponse,
        planResponse: HTTPResponse?,
        now: Date
    ) throws -> ProviderSnapshot {
        guard (200..<300).contains(response.statusCode) else {
            throw ProviderFailure(
                response.statusCode >= 500 ? .transient : .invalidResponse,
                "Grok usage request failed (\(response.statusCode))."
            )
        }
        let body = try ProviderParsing.object(from: response.body)
        guard let config = ProviderParsing.object(body["config"]),
              let period = ProviderParsing.object(config["currentPeriod"]),
              let periodType = ProviderParsing.string(period["type"]),
              let end = ProviderParsing.date(period["end"]) else {
            throw ProviderFailure(
                .invalidResponse,
                "Grok quota response changed."
            )
        }

        var windows: [QuotaWindow] = []
        if periodType == Self.weeklyPeriodType {
            windows.append(QuotaWindow(
                kind: .weekly,
                usedPercent: clampPercent(
                    ProviderParsing.double(
                        config["creditUsagePercent"]
                    ) ?? 0
                ),
                resetsAt: end
            ))
        }
        guard !windows.isEmpty else {
            throw ProviderFailure(
                .invalidResponse,
                "Grok weekly quota is unavailable for this account."
            )
        }

        return ProviderSnapshot(
            provider: .grok,
            planName: planName(planResponse),
            windows: windows,
            fetchedAt: now
        )
    }

    private static func planName(_ response: HTTPResponse?) -> String? {
        guard let response,
              (200..<300).contains(response.statusCode),
              let body = try? ProviderParsing.object(from: response.body),
              let plan = ProviderParsing.string(
                body["subscription_tier_display"]
              )?.trimmingCharacters(in: .whitespacesAndNewlines),
              !plan.isEmpty else {
            return nil
        }
        return plan
    }

    private static func clampPercent(_ value: Double) -> Double {
        min(max(value, 0), 100)
    }
}
