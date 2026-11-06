import Foundation

enum KiroUsageMapper {
    static func map(
        response: HTTPResponse,
        now: Date
    ) throws -> ProviderSnapshot {
        guard (200..<300).contains(response.statusCode) else {
            throw ProviderFailure(
                response.statusCode >= 500 ? .transient : .invalidResponse,
                "Kiro usage request failed (\(response.statusCode))."
            )
        }

        let body = try ProviderParsing.object(from: response.body)
        let plan = extractPlanName(from: body)
        let resetDate = ProviderParsing.date(body["nextDateReset"])

        var windows: [QuotaWindow] = []
        let breakdowns = ProviderParsing.array(body["usageBreakdownList"])

        for item in breakdowns {
            if let freeTrial = ProviderParsing.object(item["freeTrialInfo"]),
               freeTrial["freeTrialStatus"] as? String == "ACTIVE",
               let trialLimit = ProviderParsing.double(freeTrial["usageLimitWithPrecision"] ?? freeTrial["usageLimit"]),
               trialLimit > 0 {
                let trialUsage = ProviderParsing.double(freeTrial["currentUsageWithPrecision"] ?? freeTrial["currentUsage"]) ?? 0
                let trialReset = ProviderParsing.date(freeTrial["freeTrialExpiry"]) ?? ProviderParsing.date(item["nextDateReset"]) ?? resetDate
                let trialPercent = min(max((trialUsage / trialLimit) * 100, 0), 100)
                windows.append(QuotaWindow(kind: .credits, usedPercent: trialPercent, resetsAt: trialReset))
                continue
            }

            let current = ProviderParsing.double(item["currentUsageWithPrecision"]) ?? ProviderParsing.double(item["currentUsage"]) ?? 0
            let limit = ProviderParsing.double(item["usageLimitWithPrecision"]) ?? ProviderParsing.double(item["usageLimit"]) ?? 0
            let itemReset = ProviderParsing.date(item["nextDateReset"]) ?? resetDate
            let percent = limit > 0 ? min(max((current / limit) * 100, 0), 100) : 0

            let name = ProviderParsing.string(item["displayName"]) ?? ""
            let resourceType = ProviderParsing.string(item["resourceType"]) ?? ""

            let kind: QuotaKind
            if resourceType.caseInsensitiveCompare("CREDIT") == .orderedSame || name.localizedCaseInsensitiveContains("credit") {
                kind = .credits
            } else if name.localizedCaseInsensitiveContains("session") {
                kind = .session
            } else if name.localizedCaseInsensitiveContains("week") {
                kind = .weekly
            } else {
                kind = .credits
            }

            windows.append(QuotaWindow(kind: kind, usedPercent: percent, resetsAt: itemReset))
        }

        if windows.isEmpty {
            windows.append(QuotaWindow(kind: .credits, usedPercent: 0, resetsAt: resetDate))
        }

        let billing = extractBillingUsage(from: body, breakdowns: breakdowns)

        return ProviderSnapshot(
            provider: .kiro,
            planName: plan,
            windows: windows,
            billingUsage: billing,
            fetchedAt: now
        )
    }

    private static func extractPlanName(from body: [String: Any]) -> String? {
        let subscriptionInfo = ProviderParsing.object(body["subscriptionInfo"])
        guard let raw = ProviderParsing.string(subscriptionInfo?["subscriptionTitle"]) ??
                        ProviderParsing.string(subscriptionInfo?["type"]) else {
            return "Free"
        }

        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.range(of: #"^kiro\s+"#, options: [.caseInsensitive, .regularExpression]) != nil {
            cleaned = cleaned.replacingOccurrences(
                of: #"^kiro\s+"#,
                with: "",
                options: [.caseInsensitive, .regularExpression]
            )
        }

        if cleaned.localizedCaseInsensitiveContains("free") {
            return "Free"
        }
        if cleaned.localizedCaseInsensitiveContains("pro") {
            return "Pro"
        }
        if cleaned.localizedCaseInsensitiveContains("enterprise") {
            return "Enterprise"
        }
        return ProviderParsing.titleCaseIdentifier(cleaned)
    }

    private static func extractBillingUsage(
        from body: [String: Any],
        breakdowns: [[String: Any]]
    ) -> BillingUsage? {
        let overageConfig = ProviderParsing.object(body["overageConfiguration"])
        let isOverageEnabled = overageConfig?["overageStatus"] as? String == "ENABLED"
        guard isOverageEnabled else { return nil }

        let overageCharges = breakdowns.compactMap { ProviderParsing.double($0["overageCharges"]) }.first ?? 0
        guard overageCharges > 0 else { return nil }

        let currency = breakdowns.compactMap { ProviderParsing.string($0["currency"]) }.first ?? "USD"
        let overageCap = breakdowns.compactMap { ProviderParsing.double($0["overageCapWithPrecision"] ?? $0["overageCap"]) }.first
        let overageRate = breakdowns.compactMap { ProviderParsing.double($0["overageRate"]) }.first ?? 0.04

        if let cap = overageCap, cap > 0 {
            let limitAmount = cap * overageRate
            return .boundedSpend(usedAmount: overageCharges, limitAmount: limitAmount, currencyCode: currency)
        } else {
            return .unboundedSpend(usedAmount: overageCharges, currencyCode: currency)
        }
    }
}
