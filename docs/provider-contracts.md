# Provider contracts

This document records the narrow external contract used by AI Usage. It is
intentionally limited to quota windows that can be fetched from credentials
the supported tools already store locally.

The reference implementation was OpenUsage `v0.7.6`, plus provider updates
through commit `9d2bf09f10e21f769494a525a9d65c84d7aeb1df`. These are
undocumented provider endpoints and may change; fixture tests protect the
currently known behavior.

## Claude Code

Credential source order:

1. macOS Keychain current-user item
2. macOS Keychain legacy service-only item
3. `$CLAUDE_CONFIG_DIR/.credentials.json`, otherwise
   `~/.claude/.credentials.json`

The production Keychain service is `Claude Code-credentials`. With
`CLAUDE_CONFIG_DIR`, the app first tries the service suffixed with the first
eight lowercase SHA-256 characters of the normalized directory, then the
production service.

`CLAUDE_CODE_OAUTH_TOKEN` is not a live-usage credential and is never selected.
A stored non-empty `scopes` array must contain `user:profile`; absent or empty
scope metadata is treated as unknown and allowed.

Usage request:

- `GET https://api.anthropic.com/api/oauth/usage`
- `Authorization: Bearer <access token>`
- `anthropic-beta: oauth-2025-04-20`
- `User-Agent: claude-code/2.1.69`

Mapped fields:

| JSON field | UI row |
| --- | --- |
| `five_hour.utilization` | Session |
| `seven_day.utilization` | Weekly |
| `seven_day_sonnet.utilization` | Sonnet |
| `limits[kind=weekly_scoped, scope.model.display_name=Fable].percent` | Fable |

Every row reads `resets_at`, accepting ISO-8601 with variable fractions and no
timezone (assumed UTC), epoch seconds, or epoch milliseconds.

Refresh request:

- `POST https://platform.claude.com/v1/oauth/token`
- JSON body with `grant_type`, `refresh_token`, `client_id`, and `scope`
- client ID `9d1c250a-e61b-44d9-88ed-5944d1962f5e`
- scope string:
  `user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload`

The access token is refreshed within five minutes of `expiresAt` (epoch
milliseconds). A usage `401` or `403` causes at most one refresh and one retry.
`invalid_grant` means the session expired. A `429` honors `Retry-After`
(seconds or HTTP date) and otherwise starts a five-minute cooldown, including
manual refreshes.

The display plan is title-cased `subscriptionType`, plus an `Nx` fragment
extracted from `rateLimitTier`.

## Codex

Credential source order:

1. `$CODEX_HOME/auth.json`, when `CODEX_HOME` is set
2. otherwise `~/.config/codex/auth.json`
3. then `~/.codex/auth.json`
4. macOS Keychain service `Codex Auth`

An auth document uses `tokens.access_token`, `refresh_token`, `id_token`, and
`account_id`, plus top-level `last_refresh`. A document containing only
`OPENAI_API_KEY` produces “Usage not available for API key.”

Usage request:

- `GET https://chatgpt.com/backend-api/wham/usage`
- `Authorization: Bearer <access token>`
- optional `ChatGPT-Account-Id`

The main `rate_limit.primary_window` and `secondary_window` objects use
`used_percent`. Response headers `x-codex-primary-used-percent` and
`x-codex-secondary-used-percent` are fallbacks.

Windows are classified by `limit_window_seconds`:

- `18000`: Session
- `604800`: Weekly
- unknown or missing duration: primary/secondary slot fallback

The first `additional_rate_limits` entry whose `limit_name` or
`metered_feature` contains `spark` case-insensitively is mapped through the
same classifier to Spark and Spark Weekly.

Reset time uses epoch-seconds `reset_at`, then relative
`reset_after_seconds`. The display plan maps `prolite` to `Pro 5x`, `pro` to
`Pro 20x`, and title-cases other underscore-separated values.

Refresh request:

- `POST https://auth.openai.com/oauth/token`
- `application/x-www-form-urlencoded`
- client ID `app_EMoamEEZ73f0CkXaXp7hrann`

JWT `exp` is the primary refresh clock with five minutes of slack. Only when
`exp` cannot be decoded does `last_refresh` older than eight days trigger a
refresh. With neither value, no proactive refresh occurs. Before proactive
refresh, the exact credential source is re-read so a token already rotated by
the Codex CLI is adopted.

The recognized refresh failures are `refresh_token_expired`,
`refresh_token_reused`, and `refresh_token_invalidated`. A usage `401` or `403`
causes at most one refresh and one retry.

## Additional providers

| Provider | Local credential source | First-party usage contract | Mapped metrics |
| --- | --- | --- | --- |
| Cursor | Cursor state SQLite database, then `cursor-access-token` and `cursor-refresh-token` Keychain items | `api2.cursor.sh` DashboardService Connect RPCs | Total, Auto, API |
| Antigravity | Keychain service `gemini`, account `antigravity` | Google Cloud Code quota-summary API, with model-quota fallback | Gemini session/weekly, Claude session/weekly |
| GitHub Copilot | Copilot editor config, GitHub CLI config, then `gh:github.com` Keychain item | `api.github.com/copilot_internal/user` | Credits, Chat, Completions |
| Devin | `~/.local/share/devin/credentials.toml`, then Devin state SQLite database | Codeium SeatManagement Connect RPC | Daily, Weekly |
| Grok | `~/.grok/auth.json` | Grok CLI billing and settings APIs | Weekly |

Cursor, Antigravity, and Grok refresh expiring access tokens using the refresh
credential already stored by the corresponding tool. Refreshed tokens are
persisted only where necessary; Antigravity's derived access token is cached
privately by AI Usage and bound to a hash of the current refresh credential.

OpenCode is intentionally not included: its current limits require scanning
local usage databases and are machine-local estimates, which conflicts with
AI Usage's no-background-log-scanning design. OpenRouter and Z.ai are also
excluded because they require users to add API keys instead of reusing a local
agent login.

## Persistence and failure policy

Rotated credentials are persisted only to the source from which they were
loaded. Claude compares the complete ordered credential generation before
writing and again before publishing usage. Codex compares the exact source
before writing. This prevents an in-flight refresh from overwriting a new CLI
login.

Temporary network failures, `429`, server errors, and invalid response shapes
preserve the last-good in-memory snapshot and mark it stale. Authentication and
storage failures clear that provider's snapshot.
