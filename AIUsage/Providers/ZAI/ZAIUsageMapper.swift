import Foundation

enum ZAIUsageMapper {
    private static let hourSeconds: Double = 60 * 60
    private static let daySeconds: Double = 24 * hourSeconds

    static func map(response: HTTPResponse, now: Date) throws -> ProviderSnapshot {
        guard (200..<300).contains(response.statusCode) else {
            throw ProviderFailure(
                response.statusCode >= 500 ? .transient : .invalidResponse,
                "Z.ai usage request failed (\(response.statusCode))."
            )
        }
        let root = try ProviderParsing.object(from: response.body)
        if root["success"] as? Bool == false {
            let message = ProviderParsing.string(root["msg"]) ?? ""
            if message.localizedCaseInsensitiveContains("coding plan") {
                throw ProviderFailure(
                    .invalidResponse,
                    "No active GLM Coding Plan on this Z.ai key."
                )
            }
            if ProviderParsing.double(root["code"]) == 401 {
                throw ProviderFailure(
                    .authentication,
                    "Z.ai rejected the API key."
                )
            }
            throw ProviderFailure(.invalidResponse, "Z.ai usage is unavailable.")
        }

        let container = ProviderParsing.object(root["data"]) ?? root
        guard let limits = container["limits"] as? [[String: Any]] else {
            throw ProviderFailure(.invalidResponse, "Z.ai quota response changed.")
        }

        var windows: [QuotaWindow] = []
        for limit in limits {
            guard let window = window(limit),
                  !windows.contains(where: { $0.kind == window.kind }) else {
                continue
            }
            windows.append(window)
        }
        let order: [QuotaKind] = [.session, .daily, .weekly, .webSearches]
        windows.sort {
            (order.firstIndex(of: $0.kind) ?? order.count) <
                (order.firstIndex(of: $1.kind) ?? order.count)
        }

        return ProviderSnapshot(
            provider: .zai,
            planName: ProviderParsing.string(container["level"]).map {
                ProviderParsing.titleCaseIdentifier($0)
            },
            windows: windows,
            fetchedAt: now
        )
    }

    /// Z.ai has used both `type` and `name` for a limit's identity.
    private static func window(_ limit: [String: Any]) -> QuotaWindow? {
        let type = ProviderParsing.string(limit["type"])
            ?? ProviderParsing.string(limit["name"])
        let reset = ProviderParsing.date(limit["nextResetTime"])
        switch type {
        case "CREDIT_LIMIT", "TOKENS_LIMIT":
            guard let kind = tokenWindowKind(limit),
                  let percent = ProviderParsing.double(limit["percentage"]) else {
                return nil
            }
            return QuotaWindow(
                kind: kind,
                usedPercent: min(max(percent, 0), 100),
                resetsAt: reset
            )
        case "TIME_LIMIT":
            guard let used = ProviderParsing.double(limit["currentValue"]),
                  let total = ProviderParsing.double(limit["usage"]),
                  total > 0 else {
                return nil
            }
            return QuotaWindow(
                kind: .webSearches,
                usedPercent: min(max(used / total * 100, 0), 100),
                resetsAt: reset
            )
        default:
            return nil
        }
    }

    /// `unit` and `number` describe the window: unit 3 is hours, 4 days,
    /// 6 weeks, and 5 months. A five-hour window is the session.
    private static func tokenWindowKind(_ limit: [String: Any]) -> QuotaKind? {
        guard let unit = ProviderParsing.double(limit["unit"]),
              let number = ProviderParsing.double(limit["number"]),
              number > 0 else {
            return nil
        }
        let unitSeconds: Double
        switch unit {
        case 3: unitSeconds = hourSeconds
        case 4: unitSeconds = daySeconds
        case 6: unitSeconds = 7 * daySeconds
        case 5: unitSeconds = 30 * daySeconds
        default: return nil
        }
        let seconds = unitSeconds * number
        switch seconds {
        case ..<daySeconds: return .session
        case ..<(7 * daySeconds): return .daily
        case ..<(28 * daySeconds): return .weekly
        default: return nil
        }
    }
}
