# Contributing

Thanks for helping make AI Usage better.

## Before you start

- Keep the app focused on Claude Code and Codex subscription limits.
- Prefer native macOS APIs and semantic system colors.
- Avoid telemetry, background log scanning, local servers, and persistent
  usage history.
- Never include credentials, tokens, or real authentication fixtures.

For a larger change, open an issue first so the scope can be agreed before
implementation.

## Development

Requirements:

- macOS 26 or newer
- Xcode 27 or newer

Run the app from the `AIUsage` scheme. Before opening a pull request, run:

```bash
xcodebuild test \
  -project AIUsage.xcodeproj \
  -scheme AIUsage \
  -destination 'platform=macOS'
```

## Pull requests

- Keep each pull request narrow.
- Explain the user-facing impact and the reason for the change.
- Add tests for provider parsing, credential handling, store behavior, or
  layout regressions when applicable.
- Include a screenshot for visible UI changes.
- Confirm that no secrets or user-specific paths are included.
