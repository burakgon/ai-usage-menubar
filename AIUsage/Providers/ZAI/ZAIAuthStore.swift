import Foundation

struct ZAICredential: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case environment
        case claudeCodeSettings
        case openCode
    }

    let apiKey: String
    /// `https://api.z.ai`, or `https://open.bigmodel.cn` for keys issued on
    /// Zhipu's mainland China platform.
    let baseURL: URL
    let source: Source
}

/// Finds a GLM Coding Plan key that another coding tool on this Mac already
/// uses. AI Usage never asks for the key itself.
struct ZAIAuthStore: Sendable {
    static let internationalBaseURL = URL(string: "https://api.z.ai")!
    static let chinaBaseURL = URL(string: "https://open.bigmodel.cn")!
    static let environmentName = "ZAI_API_KEY"
    static let openCodeAuthPath = "~/.local/share/opencode/auth.json"
    static let openCodeProviders: [(id: String, baseURL: URL)] = [
        ("zai-coding-plan", internationalBaseURL),
        ("zai", internationalBaseURL),
        ("zhipuai-coding-plan", chinaBaseURL),
        ("zhipuai", chinaBaseURL)
    ]

    let environment: EnvironmentReading
    let files: TextFileAccessing

    init(
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        files: TextFileAccessing = LocalTextFileAccessor()
    ) {
        self.environment = environment
        self.files = files
    }

    func loadCredential() -> ZAICredential? {
        if let key = Self.nonEmpty(environment.value(for: Self.environmentName)) {
            return ZAICredential(
                apiKey: key,
                baseURL: Self.internationalBaseURL,
                source: .environment
            )
        }
        return loadClaudeCodeSettings() ?? loadOpenCode()
    }

    /// Claude Code pointed at the GLM Coding Plan through
    /// `env.ANTHROPIC_BASE_URL` and `env.ANTHROPIC_AUTH_TOKEN`, the setup
    /// Z.ai documents for Claude Code.
    func loadClaudeCodeSettings() -> ZAICredential? {
        for path in claudeSettingsPaths() {
            guard files.exists(path),
                  let text = try? files.readText(path),
                  let root = Self.jsonObject(text),
                  let env = root["env"] as? [String: Any],
                  let baseURL = Self.platformBaseURL(
                      ProviderParsing.string(env["ANTHROPIC_BASE_URL"])
                  ),
                  let key = Self.nonEmpty(
                      ProviderParsing.string(env["ANTHROPIC_AUTH_TOKEN"])
                          ?? ProviderParsing.string(env["ANTHROPIC_API_KEY"])
                  ) else {
                continue
            }
            return ZAICredential(
                apiKey: key,
                baseURL: baseURL,
                source: .claudeCodeSettings
            )
        }
        return nil
    }

    func loadOpenCode() -> ZAICredential? {
        guard files.exists(Self.openCodeAuthPath),
              let text = try? files.readText(Self.openCodeAuthPath),
              let root = Self.jsonObject(text) else {
            return nil
        }
        for provider in Self.openCodeProviders {
            guard let entry = root[provider.id] as? [String: Any],
                  let key = Self.nonEmpty(ProviderParsing.string(entry["key"]))
            else {
                continue
            }
            return ZAICredential(
                apiKey: key,
                baseURL: provider.baseURL,
                source: .openCode
            )
        }
        return nil
    }

    /// The Z.ai platform an Anthropic-compatible base URL belongs to.
    static func platformBaseURL(_ value: String?) -> URL? {
        guard let value,
              let host = URL(string: value.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ))?.host?.lowercased() else {
            return nil
        }
        if host == "api.z.ai" || host.hasSuffix(".z.ai") {
            return internationalBaseURL
        }
        if host == "open.bigmodel.cn" || host.hasSuffix(".bigmodel.cn") {
            return chinaBaseURL
        }
        return nil
    }

    private func claudeSettingsPaths() -> [String] {
        let override = environment.value(for: "CLAUDE_CONFIG_DIR")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var directories: [String] = []
        if let override, !override.isEmpty {
            directories.append(override)
        }
        directories.append("~/.claude")
        return directories.map { "\($0)/settings.json" }
    }

    private static func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
