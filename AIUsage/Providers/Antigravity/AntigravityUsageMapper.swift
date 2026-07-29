import Foundation

enum AntigravityUsageMapper {
    private static let summaryKinds: [
        String: QuotaKind
    ] = [
        "gemini-5h": .session,
        "gemini-weekly": .weekly,
        "3p-5h": .claudePool,
        "3p-weekly": .claudePoolWeekly
    ]

    static func summary(
        _ data: Data,
        planName: String?,
        now: Date
    ) -> ProviderSnapshot? {
        guard let root = try? ProviderParsing.object(from: data),
              let container = ProviderParsing.object(root["response"])
                ?? Optional(root),
              let groups = container["groups"] as? [[String: Any]]
        else {
            return nil
        }
        var windows: [QuotaWindow] = []
        for group in groups {
            for bucket in ProviderParsing.array(group["buckets"]) {
                guard let identifier = ProviderParsing.string(
                    bucket["bucketId"]
                ),
                    let kind = summaryKinds[identifier],
                    let remaining = ProviderParsing.double(
                        bucket["remainingFraction"]
                    ),
                    !windows.contains(where: { $0.kind == kind })
                else {
                    continue
                }
                windows.append(QuotaWindow(
                    kind: kind,
                    usedPercent: clamp((1 - remaining) * 100).rounded(),
                    resetsAt: ProviderParsing.date(bucket["resetTime"])
                ))
            }
        }
        return ProviderSnapshot(
            provider: .antigravity,
            planName: planName,
            windows: ordered(windows),
            fetchedAt: now
        )
    }

    static func legacy(
        _ data: Data,
        planName: String?,
        now: Date
    ) -> ProviderSnapshot? {
        guard let root = try? ProviderParsing.object(from: data),
              let models = root["models"] as? [String: Any]
        else {
            return nil
        }
        var worstRemaining: [QuotaKind: (Double, Date?)] = [:]
        for (identifier, rawModel) in models {
            guard let model = ProviderParsing.object(rawModel),
                  model["isInternal"] as? Bool != true,
                  let label = ProviderParsing.string(model["displayName"])
                    ?? ProviderParsing.string(model["label"]),
                  let quota = ProviderParsing.object(model["quotaInfo"])
            else {
                continue
            }
            let kind: QuotaKind = label.lowercased().contains("gemini")
                ? .session
                : .claudePool
            let remaining = ProviderParsing.double(
                quota["remainingFraction"]
            ) ?? 0
            let candidate = (
                remaining,
                ProviderParsing.date(quota["resetTime"])
            )
            if candidate.0 < (worstRemaining[kind]?.0 ?? 2) {
                worstRemaining[kind] = candidate
            }
            _ = identifier
        }
        let windows = worstRemaining.map { kind, value in
            QuotaWindow(
                kind: kind,
                usedPercent: clamp((1 - value.0) * 100).rounded(),
                resetsAt: value.1
            )
        }
        guard !windows.isEmpty else { return nil }
        return ProviderSnapshot(
            provider: .antigravity,
            planName: planName,
            windows: ordered(windows),
            fetchedAt: now
        )
    }

    static func plan(_ data: Data?) -> String? {
        guard let data,
              let root = try? ProviderParsing.object(from: data)
        else {
            return nil
        }
        let tier = ProviderParsing.object(root["paidTier"])
            ?? ProviderParsing.object(root["currentTier"])
        guard let raw = ProviderParsing.string(tier?["name"]) else {
            return nil
        }
        for name in ["Ultra", "Pro", "Free"]
        where raw.localizedCaseInsensitiveContains(name) {
            return name
        }
        return ProviderParsing.titleCaseIdentifier(raw)
    }

    private static func ordered(
        _ windows: [QuotaWindow]
    ) -> [QuotaWindow] {
        let order: [QuotaKind] = [
            .session, .weekly, .claudePool, .claudePoolWeekly
        ]
        return windows.sorted {
            (order.firstIndex(of: $0.kind) ?? 99)
                < (order.firstIndex(of: $1.kind) ?? 99)
        }
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 100)
    }
}
