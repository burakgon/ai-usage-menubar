import Foundation

enum ClaudeUsageMapper {
    static func map(
        response: HTTPResponse,
        credentials: ClaudeOAuth,
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
            fetchedAt: now
        )
    }

    static func planName(_ credentials: ClaudeOAuth) -> String? {
        guard let raw = credentials.subscriptionType?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        let base = ProviderParsing.titleCaseIdentifier(raw)
        guard
            let tier = credentials.rateLimitTier,
            let range = tier.range(of: #"\d+x"#, options: .regularExpression)
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
}
