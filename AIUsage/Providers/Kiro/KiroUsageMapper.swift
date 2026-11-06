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
            if let freeTrial = activeFreeTrialWindow(
                item: item,
                fallbackReset: resetDate
            ) {
                windows.append(freeTrial)
                continue
            }
            // A breakdown Kiro sent without a limit is not a quota; adding a
            // zero-limit row would invent a window the account does not have.
            guard let limit = limit(of: item), limit > 0 else { continue }
            // A window that nothing reliable maps to a metric is skipped too,
            // rather than folded into Credits where it would collide with the
            // credit window's id.
            guard let kind = quotaKind(for: item) else { continue }
            windows.append(QuotaWindow(
                kind: kind,
                usedPercent: percent(usage(of: item), of: limit),
                resetsAt: ProviderParsing.date(item["nextDateReset"]) ??
                    resetDate
            ))
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

    /// The window a breakdown belongs to, or `nil` when Kiro did not say.
    /// Names and resource types are matched in both forms Kiro has shipped
    /// (`daily`/`weekly`, `credit`/`credits`, `agentic_request`) exactly,
    /// because a substring match would file an unrelated row under Credits.
    private static func quotaKind(for item: [String: Any]) -> QuotaKind? {
        guard let resourceType = normalized(item["resourceType"]),
              let resource = KiroResourceType(rawValue: resourceType) else {
            return nil
        }
        switch resource {
        case .credit:
            return .credits
        case .agenticRequest:
            guard let name = normalized(item["displayName"]) else { return nil }
            switch name {
            case "daily": return .daily
            case "session": return .session
            case "weekly": return .weekly
            default: return nil
            }
        }
    }

    /// Kiro reports either a bare word, a display name, or a plural display
    /// name for the same window.
    private static func normalized(_ value: Any?) -> String? {
        guard let text = ProviderParsing.string(value)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty else {
            return nil
        }
        var normalized = text.lowercased()
        if normalized.hasSuffix("s"), normalized.count > 1 {
            normalized.removeLast()
        }
        return normalized
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

    /// Clamps only the bar, like the other providers. The reported percentage
    /// is kept as it arrives.
    private static func percent(_ usage: Double, of limit: Double) -> Double {
        min(max((usage / limit) * 100, 0), 100)
    }

    // MARK: - Plan

    /// The plan title Kiro reports, or `nil` when it reports none. A missing
    /// subscription is not evidence of a free plan.
    private static func planName(from body: [String: Any]) -> String? {
        let subscription = ProviderParsing.object(body["subscriptionInfo"])
        guard let raw = ProviderParsing.string(
            subscription?["subscriptionTitle"]
        ) ?? ProviderParsing.string(subscription?["type"]),
            !raw.isEmpty else {
            return nil
        }

        // "KIRO STUDENT" is a Kiro-specific title; the tier is what the user
        // recognizes.
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(
                of: #"^kiro\s+"#,
                with: "",
                options: [.caseInsensitive, .regularExpression]
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        if cleaned.localizedCaseInsensitiveContains("free") {
            return "Free"
        }
        if cleaned.localizedCaseInsensitiveContains("pro") {
            return "Pro"
        }
        if cleaned.localizedCaseInsensitiveContains("enterprise") {
            return "Enterprise"
        }
        // A subscription `type` is an identifier such as
        // `Q_DEVELOPER_STANDALONE_STUDENT`, and titles arrive shouting as
        // "KIRO STUDENT"; both read better title-cased. A title that is
        // already readable is left as Kiro wrote it.
        let letters = cleaned.filter(\.isLetter)
        let shouts = !letters.isEmpty && letters.allSatisfy(\.isUppercase)
        return cleaned.contains("_") || shouts
            ? ProviderParsing.titleCaseIdentifier(cleaned)
            : cleaned
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

/// Kiro's `resourceType` values. Anything else is a probe row this app does
/// not know how to label, so it is left out instead of being forced into
/// Credits.
private enum KiroResourceType: String {
    case credit = "credit"
    case agenticRequest = "agentic_request"

    init?(rawValue: String) {
        switch rawValue {
        case "credit", "credits": self = .credit
        case "agentic_request", "agentic_requests": self = .agenticRequest
        default: return nil
        }
    }
}
