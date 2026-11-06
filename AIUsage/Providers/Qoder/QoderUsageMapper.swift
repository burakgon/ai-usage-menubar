import Foundation

enum QoderUsageMapper {
    static func map(
        usage: HTTPResponse,
        plan: HTTPResponse?,
        fallbackPlanName: String?,
        now: Date
    ) throws -> ProviderSnapshot {
        guard (200..<300).contains(usage.statusCode) else {
            throw ProviderFailure(
                usage.statusCode >= 500 ? .transient : .invalidResponse,
                "Qoder usage request failed (\(usage.statusCode))."
            )
        }

        let body = try ProviderParsing.object(from: usage.body)
        return try snapshot(
            body: body,
            planName: planName(from: plan) ?? fallbackPlanName,
            now: now
        )
    }

    static func mapCached(
        usage: Data,
        planName: String?,
        now: Date
    ) throws -> ProviderSnapshot {
        let body = try ProviderParsing.object(from: usage)
        return try snapshot(body: body, planName: planName, now: now)
    }

    private static func snapshot(
        body: [String: Any],
        planName: String?,
        now: Date
    ) throws -> ProviderSnapshot {
        let resetsAt = ProviderParsing.date(
            body["expires_at"] ?? body["expiresAt"]
        )
        var windows: [QuotaWindow] = []

        if let plan = quota(
            body["user_quota"] ?? body["userQuota"],
            kind: .credits,
            resetsAt: resetsAt
        ) {
            windows.append(plan)
        }
        if let bonus = quota(
            body["add_on_quota"] ?? body["addOnQuota"],
            kind: .bonusCredits,
            resetsAt: nil
        ) {
            windows.append(bonus)
        }

        guard !windows.isEmpty else {
            throw ProviderFailure(
                .invalidResponse,
                "Qoder quota response changed."
            )
        }

        return ProviderSnapshot(
            provider: .qoder,
            planName: planName,
            windows: windows,
            fetchedAt: now
        )
    }

    private static func quota(
        _ value: Any?,
        kind: QuotaKind,
        resetsAt: Date?
    ) -> QuotaWindow? {
        guard let object = ProviderParsing.object(value) else { return nil }
        let used = ProviderParsing.double(object["used"])
        let total = ProviderParsing.double(object["total"])
            ?? ProviderParsing.double(object["cap"])
        guard used != nil || total != nil || object["percentage"] != nil else {
            return nil
        }

        let percent: Double
        if let reported = ProviderParsing.double(object["percentage"]) {
            percent = reported >= 0 && reported <= 1 ? reported * 100 : reported
        } else if let used, let total, total > 0 {
            percent = used / total * 100
        } else {
            percent = 0
        }

        return QuotaWindow(
            kind: kind,
            usedPercent: min(max(percent, 0), 100),
            resetsAt: resetsAt
        )
    }

    private static func planName(from response: HTTPResponse?) -> String? {
        guard let response, (200..<300).contains(response.statusCode),
              let body = try? ProviderParsing.object(from: response.body) else {
            return nil
        }
        if let name = ProviderParsing.string(
            body["plan_tier_name"] ?? body["planTierName"] ?? body["plan_name"] ?? body["planName"]
        ) {
            return name
        }
        guard let userType = ProviderParsing.string(
            body["user_type"] ?? body["userType"]
        ) else {
            return nil
        }
        return ProviderParsing.titleCaseIdentifier(userType)
    }
}
