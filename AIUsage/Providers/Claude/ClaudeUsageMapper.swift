import Foundation

/// Claude Code's banked usage-limit reset grants (`cedar_ember`).
struct ClaudeResetGrants: Equatable, Sendable {
    struct Grant: Equatable, Sendable {
        let id: String
        let resetsLeft: Int
        let endsAt: Date?
    }

    let grants: [Grant]

    /// `nil` when the block is missing, malformed, or withheld from this
    /// client, so an unknown inventory is never shown as zero.
    static func parse(_ value: Any?) -> ClaudeResetGrants? {
        guard let block = ProviderParsing.object(value) else { return nil }
        let reason = ProviderParsing.string(block["ineligible_reason"])
        if block["eligible"] as? Bool != true,
           reason == "surface" || reason == "cli_version" {
            return nil
        }
        guard let rows = block["grants"] as? [Any] else {
            return reason == "no_grant" ? ClaudeResetGrants(grants: []) : nil
        }

        var grants: [Grant] = []
        for row in rows {
            guard let grant = ProviderParsing.object(row),
                  let id = ProviderParsing.string(grant["id"]),
                  let resetsLeft = ProviderParsing.double(grant["resets_left"]),
                  resetsLeft.isFinite,
                  resetsLeft < Double(Int32.max) else {
                return nil
            }
            grants.append(Grant(
                id: id,
                resetsLeft: max(0, Int(resetsLeft.rounded(.down))),
                endsAt: ProviderParsing.date(grant["ends_at"])
            ))
        }
        return ClaudeResetGrants(grants: grants)
    }

    func resets(at now: Date) -> UsageResets {
        var count = 0
        var expirations: [Date] = []
        for grant in grants where grant.resetsLeft > 0 {
            if let endsAt = grant.endsAt, endsAt <= now { continue }
            count += grant.resetsLeft
            if let endsAt = grant.endsAt {
                expirations += Array(repeating: endsAt, count: grant.resetsLeft)
            }
        }
        return UsageResets(availableCount: count, expirations: expirations)
    }
}

enum ClaudeUsageMapper {
    static func map(
        response: HTTPResponse,
        credentials: ClaudeOAuth,
        resets: UsageResets? = nil,
        now: Date
    ) throws -> ProviderSnapshot {
        guard (200..<300).contains(response.statusCode) else {
            throw ProviderFailure(
                response.statusCode >= 500 ? .transient : .invalidResponse,
                "Claude usage request failed (\(response.statusCode))."
            )
        }
        let body = try ProviderParsing.object(from: response.body)
        var windows: [QuotaWindow] = []

        appendWindow(body["five_hour"], kind: .session, to: &windows)
        appendWindow(body["seven_day"], kind: .weekly, to: &windows)
        appendWindow(body["seven_day_sonnet"], kind: .sonnet, to: &windows)
        appendFable(body["limits"], to: &windows)

        return ProviderSnapshot(
            provider: .claude,
            planName: planName(credentials),
            windows: windows,
            billingUsage: billingUsage(body["extra_usage"]),
            resets: resets,
            fetchedAt: now
        )
    }

    static func resetGrants(from response: HTTPResponse) -> ClaudeResetGrants? {
        guard (200..<300).contains(response.statusCode),
              let body = try? ProviderParsing.object(from: response.body) else {
            return nil
        }
        return ClaudeResetGrants.parse(body["cedar_ember"])
    }

    /// Anthropic now sells the 5x and 20x Max plans as Max and Ultra.
    static func planName(_ credentials: ClaudeOAuth) -> String? {
        guard var raw = credentials.subscriptionType?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        if raw.lowercased().hasPrefix("claude_") {
            raw.removeFirst("claude_".count)
        }
        let base = ProviderParsing.titleCaseIdentifier(raw)
        let tier = credentials.rateLimitTier?.lowercased() ?? ""
        if base == "Ultra" ||
            (base == "Max" && (tier.contains("ultra") || tier.contains("20x"))) {
            return "Ultra"
        }
        if base == "Max" {
            return "Max"
        }
        guard let range = tier.range(of: #"\d+x"#, options: .regularExpression)
        else {
            return base
        }
        return "\(base) \(tier[range])"
    }

    private static func appendWindow(
        _ value: Any?,
        kind: QuotaKind,
        to windows: inout [QuotaWindow]
    ) {
        guard
            let object = ProviderParsing.object(value),
            let used = ProviderParsing.double(object["utilization"])
        else {
            return
        }
        windows.append(QuotaWindow(
            kind: kind,
            usedPercent: used,
            resetsAt: ProviderParsing.date(object["resets_at"])
        ))
    }

    private static func appendFable(
        _ value: Any?,
        to windows: inout [QuotaWindow]
    ) {
        guard let limits = value as? [Any] else { return }
        for item in limits {
            guard
                let limit = ProviderParsing.object(item),
                ProviderParsing.string(limit["kind"]) == "weekly_scoped",
                let scope = ProviderParsing.object(limit["scope"]),
                let model = ProviderParsing.object(scope["model"]),
                ProviderParsing.string(model["display_name"]) == "Fable",
                let used = ProviderParsing.double(limit["percent"])
            else {
                continue
            }
            windows.append(QuotaWindow(
                kind: .fable,
                usedPercent: used,
                resetsAt: ProviderParsing.date(limit["resets_at"])
            ))
            return
        }
    }

    /// Anthropic names these fields "credits" but reports minor units of the
    /// account's billing currency (cents for USD, unless `decimal_places`
    /// says otherwise).
    private static func billingUsage(_ value: Any?) -> BillingUsage? {
        guard
            let object = ProviderParsing.object(value),
            object["is_enabled"] as? Bool == true,
            let usedMinor = ProviderParsing.double(object["used_credits"])
        else {
            return nil
        }

        let currency = ProviderParsing.string(object["currency"])?
            .uppercased() ?? "USD"
        let decimals = ProviderParsing.double(object["decimal_places"])
            .map { min(max($0.rounded(), 0), 4) } ?? 2
        let divisor = pow(10, decimals)
        let usedAmount = usedMinor.rounded() / divisor
        if let limitMinor = ProviderParsing.double(object["monthly_limit"]),
           limitMinor > 0 {
            return .boundedSpend(
                usedAmount: usedAmount,
                limitAmount: limitMinor.rounded() / divisor,
                currencyCode: currency
            )
        }
        guard usedAmount > 0 else {
            return nil
        }
        return .unboundedSpend(
            usedAmount: usedAmount,
            currencyCode: currency
        )
    }
}
