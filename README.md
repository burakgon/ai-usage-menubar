<p align="center">
  <img src="AIUsage/Assets.xcassets/AppIcon.appiconset/icon_128.png" width="96" alt="AI Usage app icon">
</p>

<h1 align="center">AI Usage</h1>

<p align="center">
  <strong>Your coding agents' limits, one click away.</strong><br>
  Native Liquid Glass. Measured at 0.0% CPU between scheduled refreshes.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-26%2B-000000?logo=apple&logoColor=white" alt="macOS 26 or newer">
  <img src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white" alt="Swift 6">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License"></a>
</p>

<p align="center">
  <img src="docs/images/ai-usage-menubar-dark.png" width="900" alt="AI Usage open beneath its 85% macOS menu bar item in dark mode, showing remaining Claude Code and Codex limits">
</p>

<p align="center">
  <sub>A real native menu bar popover — no Dock icon or persistent window.</sub>
</p>

AI Usage shows Claude Code, Codex, Cursor, Antigravity, GitHub Copilot, Devin,
and Grok limits and stays out of the way. No extra account, API key, local
server, telemetry, usage history, or background log scanning.

## Choose exactly what appears.

<p align="center">
  <img src="docs/images/ai-usage-settings-dark.png" width="760" alt="AI Usage native settings popover in dark mode, with separate tracking, menu bar visibility, and metric choices for Claude Code and Codex">
</p>

<p align="center">
  <sub>Show either provider, then pick the metrics beneath it. Nothing more.</sub>
</p>

## Other usage apps stay heavy. AI Usage stays light.

<p align="center">
  <img src="docs/images/efficiency-comparison.svg" width="900" alt="Other always-on usage apps keep CPU, interface memory, and battery activity running. AI Usage releases its interface and only wakes briefly for scheduled refreshes.">
</p>

## Download

<p>
  <a href="https://github.com/burakgon/ai-usage-menubar/releases/latest/download/AI-Usage.dmg">
    <img src="https://img.shields.io/badge/Download-DMG-0A84FF?logo=apple&logoColor=white" alt="Download the latest AI Usage DMG">
  </a>
</p>

Open the DMG, drag **AI Usage** to Applications, and launch it. It appears in
the menu bar rather than the Dock. macOS 26 or newer is required.

> [!NOTE]
> Public builds are signed with a Developer ID certificate, notarized by Apple,
> and protected by Sparkle's EdDSA signature for secure in-app updates.

## What you get

- Claude Code session, weekly, Sonnet, and Fable limits
- Codex session, weekly, Spark, and Spark weekly limits
- Cursor total, Auto, and API usage
- Antigravity Gemini and Claude pool limits
- GitHub Copilot credits, chat, and completions
- Devin daily and weekly quota
- Grok weekly quota
- Claude Code extra usage and Codex credits when available
- Remaining or used percentages, switchable directly in the panel
- Independent menu bar controls and metric choices for each provider
- Configurable 1, 5, 15, 30, or 60-minute refresh and one-click manual refresh
- Signed update checks at launch and daily, plus **Check for Updates…**
- A direct **Update** button in the panel when a new version is available
- Provider cards only for installed tools, with signed-out status kept visible
- Native light and dark appearances with Liquid Glass
- Launch at Login enabled by default and still user-controllable

## Build from source

You need:

- macOS 26 or newer
- Xcode 27 or newer
- At least one supported coding agent already installed

Then:

```bash
git clone https://github.com/burakgon/ai-usage-menubar.git
cd ai-usage-menubar
./scripts/install.sh
```

The script builds a local Release version, installs it to
`~/Applications/AI Usage.app`, and opens it. AI Usage appears in the menu bar,
not the Dock.

To run without the installer, open `AIUsage.xcodeproj` in Xcode and run the
`AIUsage` scheme.

## How it works

AI Usage reuses credentials already created by supported tools, then requests
quota data directly from each provider's first-party endpoint.

- Credentials stay on your Mac.
- Tokens are never printed, logged, or sent anywhere else.
- Temporary failures keep the last successful values in memory and mark them
  stale.
- Nothing is cached across launches.

API-key-only Codex authentication can't read ChatGPT subscription usage.
`CLAUDE_CODE_OAUTH_TOKEN` is intentionally ignored because setup tokens don't
include the profile scope required by Claude's usage endpoint.

The exact researched contracts are documented in
[docs/provider-contracts.md](docs/provider-contracts.md).

## Menu bar behavior

Every provider can be shown or hidden independently. Under each provider,
choose any metric it currently returns. A single metric shows only its value;
multiple metrics use tiny labels to stay compact. **Weekly** is selected for
Claude Code and Codex by default, and **Left** is the default number mode.

Raw percentages are shown exactly as reported by the provider. Only progress
bar drawing is clamped to `0...100`. Remaining usage is bounded to `0...100`
because a negative remaining percentage is not meaningful.

## Development

Run the complete test suite:

```bash
xcodebuild test \
  -project AIUsage.xcodeproj \
  -scheme AIUsage \
  -destination 'platform=macOS'
```

The app is SwiftUI and AppKit, with a small provider layer and an in-memory
store. Its only runtime package dependency is
[Sparkle](https://github.com/sparkle-project/Sparkle), used for signed
over-the-air updates.

Contributions are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md)
before opening a pull request.

Release packaging and OTA feed maintenance are documented in
[docs/releasing.md](docs/releasing.md).

## Upstream research

Provider contracts and parts of the system-boundary implementation were
adapted from [OpenUsage](https://github.com/robinebers/openusage), using stable
tag `v0.7.6` and provider updates through commit
`9d2bf09f10e21f769494a525a9d65c84d7aeb1df`.
See [NOTICE](NOTICE) for attribution.

## License

AI Usage is available under the [MIT License](LICENSE).

---

If AI Usage saves you a few clicks, please
[star the repository](https://github.com/burakgon/ai-usage-menubar). It helps
other coding-agent users find it.
