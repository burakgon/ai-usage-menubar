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
        let resetDate = ProviderParsing.date(body["nextDateReset"])
        let breakdowns = ProviderParsing.array(body["usageBreakdownList"])

        var windows: [QuotaWindow] = []
        for item in breakdowns {
            let itemWindows = [
                creditWindow(item: item, fallbackReset: resetDate),
                activeFreeTrialWindow(item: item, fallbackReset: resetDate)
            ]
            // One window per kind: a second one would collide with the first
            // one's id in the panel.
            for case let window? in itemWindows
            where !windows.contains(where: { $0.kind == window.kind }) {
                windows.append(window)
            }
        }

        return ProviderSnapshot(
            provider: .kiro,
            planName: planName(from: body),
            windows: windows,
            billingUsage: billingUsage(from: body, breakdowns: breakdowns),
            fetchedAt: now
        )
    }

    // MARK: - Windows

    /// Kiro's monthly credits. A `CREDIT` entry is the only limit Kiro has
    /// been seen to report; other entries are left out rather than given a
    /// label Kiro never used, and an entry without a limit is not a quota.
    private static func creditWindow(
        item: [String: Any],
        fallbackReset: Date?
    ) -> QuotaWindow? {
        guard let type = ProviderParsing.string(item["resourceType"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased(),
            type == "CREDIT" || type == "CREDITS",
            let limit = limit(of: item),
            limit > 0 else {
            return nil
        }
        return QuotaWindow(
            kind: .credits,
            usedPercent: percent(usage(of: item), of: limit),
            resetsAt: ProviderParsing.date(item["nextDateReset"]) ??
                fallbackReset
        )
    }

    /// The bonus credits of an active free trial. They come on top of the
    /// entry's own credits, so both are shown.
    private static func activeFreeTrialWindow(
        item: [String: Any],
        fallbackReset: Date?
    ) -> QuotaWindow? {
        guard let trial = ProviderParsing.object(item["freeTrialInfo"]),
              trial["freeTrialStatus"] as? String == "ACTIVE",
              let limit = limit(of: trial),
              limit > 0 else {
            return nil
        }
        return QuotaWindow(
            kind: .freeTrial,
            usedPercent: percent(usage(of: trial), of: limit),
            resetsAt: ProviderParsing.date(trial["freeTrialExpiry"]) ??
                ProviderParsing.date(item["nextDateReset"]) ??
                fallbackReset
        )
    }

    private static func usage(of object: [String: Any]) -> Double {
        ProviderParsing.double(object["currentUsageWithPrecision"]) ??
            ProviderParsing.double(object["currentUsage"]) ??
            0
    }

    private static func limit(of object: [String: Any]) -> Double? {
        ProviderParsing.double(object["usageLimitWithPrecision"]) ??
            ProviderParsing.double(object["usageLimit"])
    }

    /// Kiro reports usage and a limit, not a percentage, so the calculated
    /// percentage is bounded to `0...100` like the other providers'.
    private static func percent(_ usage: Double, of limit: Double) -> Double {
        min(max((usage / limit) * 100, 0), 100)
    }

    // MARK: - Plan

    /// The plan title Kiro shows without the product name, so "KIRO PRO+" is
    /// "Pro+". `nil` when Kiro reports no title: a missing subscription is not
    /// evidence of a free plan, and the subscription `type` is an internal
    /// identifier such as `Q_DEVELOPER_STANDALONE_STUDENT`, not a plan name.
    private static func planName(from body: [String: Any]) -> String? {
        let subscription = ProviderParsing.object(body["subscriptionInfo"])
        guard let title = ProviderParsing.string(
            subscription?["subscriptionTitle"]
        ) else {
            return nil
        }
        let name = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(
                of: #"^kiro\s+"#,
                with: "",
                options: [.caseInsensitive, .regularExpression]
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        // Titles arrive in capitals ("KIRO STUDENT") and read better in title
        // case. A title Kiro already wrote in mixed case is kept as written.
        let letters = name.filter(\.isLetter)
        let isCapitals = !letters.isEmpty && letters.allSatisfy(\.isUppercase)
        return isCapitals ? ProviderParsing.titleCaseIdentifier(name) : name
    }

    // MARK: - Billing

    /// On-demand spend Kiro reports while overage is enabled. Nothing is
    /// derived from an assumed rate: a cap is only shown when Kiro reports
    /// both the cap and the rate that converts it.
    private static func billingUsage(
        from body: [String: Any],
        breakdowns: [[String: Any]]
    ) -> BillingUsage? {
        let overage = ProviderParsing.object(body["overageConfiguration"])
        guard overage?["overageStatus"] as? String == "ENABLED",
              let charges = firstNumber(in: breakdowns, key: "overageCharges"),
              charges > 0 else {
            return nil
        }
        let currency = firstString(in: breakdowns, key: "currency") ?? "USD"

        if let cap = firstNumber(in: breakdowns, key: "overageCapWithPrecision") ??
                firstNumber(in: breakdowns, key: "overageCap"),
            cap > 0,
            let rate = firstNumber(in: breakdowns, key: "overageRate"),
            rate > 0 {
            return .boundedSpend(
                usedAmount: charges,
                limitAmount: cap * rate,
                currencyCode: currency
            )
        }
        return .unboundedSpend(usedAmount: charges, currencyCode: currency)
    }

    private static func firstNumber(
        in breakdowns: [[String: Any]],
        key: String
    ) -> Double? {
        breakdowns.compactMap { ProviderParsing.double($0[key]) }.first
    }

    private static func firstString(
        in breakdowns: [[String: Any]],
        key: String
    ) -> String? {
        breakdowns.compactMap { ProviderParsing.string($0[key]) }.first
    }
}
