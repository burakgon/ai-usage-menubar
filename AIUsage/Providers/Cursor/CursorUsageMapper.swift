import Foundation

enum CursorUsageMapper {
    static func map(
        usageResponse: HTTPResponse,
        planResponse: HTTPResponse?,
        now: Date
    ) throws -> ProviderSnapshot {
        guard (200..<300).contains(usageResponse.statusCode) else {
            throw ProviderFailure(
                usageResponse.statusCode >= 500
                    ? .transient
                    : .invalidResponse,
                "Cursor usage request failed " +
                    "(\(usageResponse.statusCode))."
            )
        }
        let body = try ProviderParsing.object(
            from: usageResponse.body
        )
        guard body["enabled"] as? Bool != false,
              let planUsage = ProviderParsing.object(body["planUsage"])
        else {
            throw ProviderFailure(
                .authentication,
                "No active Cursor subscription."
            )
        }

        let reset = ProviderParsing.date(body["billingCycleEnd"])
        var windows: [QuotaWindow] = []
        if let percent = totalPercent(planUsage) {
            windows.append(QuotaWindow(
                kind: .totalUsage,
                usedPercent: clamp(percent),
                resetsAt: reset
            ))
        }
        if let percent = ProviderParsing.double(
            planUsage["autoPercentUsed"]
        ) {
            windows.append(QuotaWindow(
                kind: .autoUsage,
                usedPercent: clamp(percent),
                resetsAt: reset
            ))
        }
        if let percent = ProviderParsing.double(
            planUsage["apiPercentUsed"]
        ) {
            windows.append(QuotaWindow(
                kind: .apiUsage,
                usedPercent: clamp(percent),
                resetsAt: reset
            ))
        }
        guard !windows.isEmpty else {
            throw ProviderFailure(
                .invalidResponse,
                "Cursor quota response changed."
            )
        }

        return ProviderSnapshot(
            provider: .cursor,
            planName: planName(planResponse),
            windows: windows,
            billingUsage: onDemandUsage(
                ProviderParsing.object(body["spendLimitUsage"])
            ),
            fetchedAt: now
        )
    }

    /// Cursor's on-demand usage beyond the plan, in cents. A team's shared
    /// pool is not the member's own limit, so only a personal limit, or
    /// personal spend without one, is shown.
    static func onDemandUsage(_ spend: [String: Any]?) -> BillingUsage? {
        guard let spend else { return nil }
        let individualLimit = ProviderParsing.double(spend["individualLimit"])
        let isTeamPool = individualLimit == nil && (
            ProviderParsing.string(spend["limitType"])?.lowercased() == "team" ||
                (ProviderParsing.double(spend["pooledLimit"]) ?? 0) > 0
        )
        guard !isTeamPool else { return nil }

        let limit = individualLimit ?? 0
        let remaining = ProviderParsing.double(spend["individualRemaining"]) ?? 0
        let reported = [
            ProviderParsing.double(spend["individualUsed"]),
            ProviderParsing.double(spend["totalSpend"])
        ].compactMap { $0 }
        let spentCents = reported.first { $0 > 0 }
            ?? max(0, limit - remaining)

        if limit > 0 {
            return .boundedSpend(
                usedAmount: ProviderParsing.centsToDollars(spentCents),
                limitAmount: ProviderParsing.centsToDollars(limit),
                currencyCode: "USD"
            )
        }
        guard spentCents > 0 else { return nil }
        return .unboundedSpend(
            usedAmount: ProviderParsing.centsToDollars(spentCents),
            currencyCode: "USD"
        )
    }

    private static func totalPercent(
        _ planUsage: [String: Any]
    ) -> Double? {
        if let reported = ProviderParsing.double(
            planUsage["totalPercentUsed"]
        ) {
            return reported
        }
        guard let limit = ProviderParsing.double(planUsage["limit"]),
              limit > 0 else {
            return nil
        }
        let spent = ProviderParsing.double(planUsage["totalSpend"])
            ?? (limit - (
                ProviderParsing.double(planUsage["remaining"]) ?? limit
            ))
        return spent / limit * 100
    }

    private static func planName(_ response: HTTPResponse?) -> String? {
        guard let response,
              (200..<300).contains(response.statusCode),
              let body = try? ProviderParsing.object(
                from: response.body
              ),
              let info = ProviderParsing.object(body["planInfo"])
        else {
            return nil
        }
        return ProviderParsing.string(info["planName"])
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 100)
    }
}
