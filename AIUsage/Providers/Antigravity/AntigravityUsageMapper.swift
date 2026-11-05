import Foundation

enum AntigravityUsageMapper {
    private static let sharedPoolKinds: [String: QuotaKind] = [
        "gemini-5h": .session,
        "gemini-weekly": .weekly,
        "3p-5h": .claudePool,
        "3p-weekly": .claudePoolWeekly
    ]
    private static let argonGroupName = "Gemini 4 Argon"
    private static let argonBucketIDs: Set<String> = [
        "gemini-argon-wtu-weekly",
        "gemini-argon-weekly"
    ]
    private static let order: [QuotaKind] = [
        .session, .weekly, .argonWeekly, .claudePool, .claudePoolWeekly
    ]
    private static let paidTierPlans = [
        "g1-pro-tier": "Google AI Pro",
        "g1-ultra-tier": "Google AI Ultra",
        "g1-ultra-lite-tier": "Google AI Ultra Lite"
    ]

    /// Maps one or more `RetrieveUserQuotaSummary` bodies, merged by bucket id
    /// with the first usable bucket winning. A host can omit a whole pool, so
    /// no single body is trusted to be complete. Returns `nil` only when no
    /// body is a quota summary at all. Buckets without a usable
    /// `remainingFraction` are dropped rather than reported as 0% or 100%.
    static func summary(
        _ bodies: [Data],
        planName: String?,
        now: Date
    ) -> ProviderSnapshot? {
        let groupLists = bodies.compactMap(groups)
        guard !groupLists.isEmpty else { return nil }

        var windows: [QuotaWindow] = []
        for group in groupLists.joined()
        where ProviderParsing.string(group["displayName"]) != argonGroupName {
            for bucket in ProviderParsing.array(group["buckets"]) {
                guard let identifier = ProviderParsing.string(bucket["bucketId"]),
                      let kind = sharedPoolKinds[identifier],
                      !windows.contains(where: { $0.kind == kind }),
                      let window = window(kind: kind, bucket: bucket)
                else {
                    continue
                }
                windows.append(window)
            }
        }
        // Argon is judged per body: combining two hosts' Argon groups would
        // read as an ambiguous bucket.
        if let argon = groupLists.lazy.compactMap(argonWindow).first {
            windows.append(argon)
        }

        return ProviderSnapshot(
            provider: .antigravity,
            planName: planName,
            windows: windows.sorted {
                (order.firstIndex(of: $0.kind) ?? order.count) <
                    (order.firstIndex(of: $1.kind) ?? order.count)
            },
            fetchedAt: now
        )
    }

    /// Whether one body already holds every shared pool, so the other host
    /// cannot change the merged result.
    static func isCompleteSummary(_ data: Data) -> Bool {
        guard let groups = groups(data) else { return false }
        let usable = Set(groups
            .filter {
                ProviderParsing.string($0["displayName"]) != argonGroupName
            }
            .flatMap { ProviderParsing.array($0["buckets"]) }
            .compactMap { bucket -> String? in
                guard ProviderParsing.double(bucket["remainingFraction"]) != nil
                else {
                    return nil
                }
                return ProviderParsing.string(bucket["bucketId"])
            })
        return sharedPoolKinds.keys.allSatisfy(usable.contains)
    }

    static func containsSummary(_ data: Data) -> Bool {
        groups(data) != nil
    }

    static func plan(_ data: Data?) -> String? {
        guard let data,
              let root = try? ProviderParsing.object(from: data)
        else {
            return nil
        }
        let paidTier = ProviderParsing.object(root["paidTier"])
        if let identifier = ProviderParsing.string(paidTier?["id"]),
           let plan = paidTierPlans[identifier] {
            return plan
        }
        if let name = trimmed(paidTier?["name"]) {
            return formattedPlan(name)
        }
        let currentTier = ProviderParsing.object(root["currentTier"])
        if ProviderParsing.string(currentTier?["id"]) == "free-tier" {
            return "Free"
        }
        // The free tier is simply named "Antigravity", which would only
        // repeat the provider name in the panel.
        guard let name = trimmed(currentTier?["name"]),
              name.caseInsensitiveCompare("Antigravity") != .orderedSame
        else {
            return nil
        }
        return formattedPlan(name)
    }

    static func project(_ data: Data?) -> String? {
        guard let data,
              let root = try? ProviderParsing.object(from: data)
        else {
            return nil
        }
        return trimmed(root["cloudaicompanionProject"])
    }

    private static func groups(_ data: Data) -> [[String: Any]]? {
        guard let root = try? ProviderParsing.object(from: data) else {
            return nil
        }
        let container = ProviderParsing.object(root["response"]) ?? root
        return container["groups"] as? [[String: Any]]
    }

    /// The Argon weekly quota, only when exactly one enabled weekly bucket
    /// identifies it: the `Gemini 4 Argon` group's weekly bucket, or a bucket
    /// with a known Argon id.
    private static func argonWindow(_ groups: [[String: Any]]) -> QuotaWindow? {
        var candidates: [String: [String: Any]] = [:]
        for group in groups {
            let isArgonGroup =
                ProviderParsing.string(group["displayName"]) == argonGroupName
            for bucket in ProviderParsing.array(group["buckets"]) {
                guard let identifier = ProviderParsing.string(bucket["bucketId"]),
                      sharedPoolKinds[identifier] == nil
                else {
                    continue
                }
                let isWeekly = ProviderParsing.string(bucket["window"]) == "weekly"
                if argonBucketIDs.contains(identifier) ||
                    (isArgonGroup && isWeekly) {
                    candidates[identifier] = bucket
                }
            }
        }
        guard candidates.count == 1,
              let bucket = candidates.values.first
        else {
            return nil
        }
        if let disabled = bucket["disabled"], !(disabled is NSNull) {
            guard let number = disabled as? NSNumber,
                  CFGetTypeID(number) == CFBooleanGetTypeID(),
                  !number.boolValue else {
                return nil
            }
        }
        return window(kind: .argonWeekly, bucket: bucket)
    }

    private static func window(
        kind: QuotaKind,
        bucket: [String: Any]
    ) -> QuotaWindow? {
        guard let remaining = ProviderParsing.double(bucket["remainingFraction"])
        else {
            return nil
        }
        let clamped = min(max(remaining, 0), 1)
        return QuotaWindow(
            kind: kind,
            usedPercent: ((1 - clamped) * 100).rounded(),
            resetsAt: ProviderParsing.date(bucket["resetTime"])
        )
    }

    private static func formattedPlan(_ name: String) -> String {
        for tier in ["Ultra Lite", "Ultra", "Pro"]
        where name.localizedCaseInsensitiveContains(tier) {
            return "Google AI \(tier)"
        }
        return name
            .split(whereSeparator: \.isWhitespace)
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private static func trimmed(_ value: Any?) -> String? {
        guard let value = ProviderParsing.string(value)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
