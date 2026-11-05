# Provider contracts

This document records the narrow external contract used by AI Usage. It is
intentionally limited to quota windows that can be fetched from credentials
the supported tools already store locally.

The reference implementation was OpenUsage `v0.7.6`, its local language-server
discovery from `v0.7.16`, and provider updates through commit
`fdf7a234b76b6a71522880cc9ab5b38044471698`. These are undocumented provider
endpoints and may change; fixture tests protect the currently known behavior.

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
- `User-Agent: claude-cli/2.1.318 (external, cli)`

At most once an hour, the same read adds `?cedar_ember=1`, which also returns
Claude Code's banked usage-limit reset grants in `cedar_ember`. Anthropic
throttles this variant when it is polled, so it replaces the plain read instead
of adding a request, and a `429` on it postpones the next grants read by an
hour. Anthropic shows grants only to a recent Claude Code on its CLI surface;
`ineligible_reason` `surface` or `cli_version` is treated as unknown, while
`no_grant` is a known zero.

Mapped fields:

| JSON field | UI row |
| --- | --- |
| `five_hour.utilization` | Session |
| `seven_day.utilization` | Weekly |
| `seven_day_sonnet.utilization` | Sonnet |
| `limits[kind=weekly_scoped, scope.model.display_name=Fable].percent` | Fable |

Every row reads `resets_at`, accepting ISO-8601 with variable fractions and no
timezone (assumed UTC), epoch seconds, or epoch milliseconds.

A grant contributes `resets_left` resets until `ends_at`; a null `ends_at`
never expires, and expired grants are not counted. `extra_usage` reports
`used_credits` and `monthly_limit` in minor units of `currency` with
`decimal_places` digits, defaulting to US cents.

Refresh request:

- `POST https://platform.claude.com/v1/oauth/token`
- JSON body with `grant_type`, `refresh_token`, `client_id`, and `scope`
- client ID `9d1c250a-e61b-44d9-88ed-5944d1962f5e`
- scope string:
  `user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload`

The access token is refreshed within five minutes of `expiresAt` (epoch
milliseconds). A usage `401` or `403` causes at most one refresh and one retry.
`invalid_grant` means the session expired. A `429` honors `Retry-After`
(seconds or HTTP date) up to an hour, and always waits at least the backoff:
five minutes, doubling with each consecutive `429` up to an hour. The cooldown
applies to manual refreshes too, because Anthropic budgets this endpoint per
account and keeps its own penalty.

The display plan follows Anthropic's names: `max` with a `20x` or `ultra`
`rateLimitTier` is **Ultra**, other `max` plans are **Max**, and other plans
are title-cased `subscriptionType` plus an `Nx` fragment from `rateLimitTier`.

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
`reset_after_seconds`. The display plan uses OpenAI's published names:
`prolite` is `Pro 100`, `pro` is `Pro 200`, `promax` is `Pro 500`,
`self_serve_business_prolite` is `Business Premium`, and other
underscore-separated values are title-cased.

Credits come from `credits.balance`, then `x-codex-credits-balance`. When
`credits.has_credits` or `x-codex-credits-has-credits` is false, no Credits row
is shown.

Banked rate-limit resets are counted from `rate_limit_reset_credits.available_count`
on every read. Their expirations come from
`GET https://chatgpt.com/backend-api/wham/rate-limit-reset-credits` with the same
bearer and account headers plus `OpenAI-Beta: codex-1` and
`originator: Codex Desktop`. Only `available` entries are listed. The list is
read only while resets exist: hourly, or after five minutes when its
`available_count` no longer matches the usage count. A list that disagrees with
the current count never supplies expirations. Nothing is redeemed.

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
| Cursor | Cursor state SQLite database, then `cursor-access-token` and `cursor-refresh-token` Keychain items | `api2.cursor.sh` DashboardService Connect RPCs | Total, Auto, API, personal on-demand spend |
| Antigravity | Keychain service `gemini`, account `antigravity` | Google Cloud Code quota summary, then a running Antigravity app or `agy` CLI | Gemini session/weekly, Argon weekly, Claude session/weekly |
| GitHub Copilot | Copilot editor config, GitHub CLI config, then `gh:github.com` Keychain item | `api.github.com/copilot_internal/user` | Credits, Chat, Completions |
| Devin | `~/.local/share/devin/credentials.toml`, then Devin state SQLite database | Codeium SeatManagement Connect RPC | Daily, Weekly |
| Grok | `~/.grok/auth.json` | Grok CLI billing and settings APIs | Weekly |
| Z.ai | `ZAI_API_KEY`, Claude Code `settings.json` pointed at Z.ai, then OpenCode `auth.json` | `GET /api/monitor/usage/quota/limit` on `api.z.ai` or `open.bigmodel.cn` | Session, Weekly, Web Searches |

Cursor, Antigravity, and Grok refresh expiring access tokens using the refresh
credential already stored by the corresponding tool. Refreshed tokens are
persisted only where necessary; Antigravity's derived access token is cached
privately by AI Usage and bound to a hash of the current refresh credential.

Devin omits a zero `*QuotaRemainingPercent` in proto3 JSON, so a window with a
reset time and no share is fully used. Grok answers `412` with "no personal
team" for team accounts, which have no personal quota. GitHub sends rate limits
as `429` or as `403` with `x-ratelimit-remaining: 0` or `Retry-After`; those
wait until `x-ratelimit-reset` instead of reporting a rejected token. Cursor's
`spendLimitUsage` is shown as extra usage only for a personal limit or personal
spend, never for a team's shared pool.

### Antigravity

Cloud Code requests use the Antigravity client's own identity:
`User-Agent: antigravity/2.24.0 (aidev_client; os_type=darwin; arch=arm64)`
(`amd64` on Intel). With any other User-Agent, Google answers the quota summary
without the Gemini group and `loadCodeAssist` without `paidTier`.

1. `POST /v1internal:loadCodeAssist` with
   `{"metadata":{"ideType":"ANTIGRAVITY","platform":"PLATFORM_UNSPECIFIED","pluginType":"GEMINI"}}`,
   read at most hourly, supplies the plan (`paidTier.id` `g1-pro-tier`,
   `g1-ultra-tier`, or `g1-ultra-lite-tier`, then the tier name) and
   `cloudaicompanionProject`.
2. `POST /v1internal:retrieveUserQuotaSummary` with `{"project": …}` goes to
   `cloudcode-pa.googleapis.com` first, then `daily-cloudcode-pa.googleapis.com`
   unless production already returned all four shared pools. Buckets are merged
   by id, first answer winning.

`gemini-5h`, `gemini-weekly`, `3p-5h`, and `3p-weekly` map to Session, Weekly,
Claude, and Claude Weekly. Argon Weekly is the single enabled weekly bucket of
the `Gemini 4 Argon` group, or a `gemini-argon-wtu-weekly` bucket. A bucket
without a usable `remainingFraction` is dropped rather than shown as 0% or 100%.
`fetchAvailableModels` is not used: it reports `remainingFraction: 1` for every
model even when the weekly quota is nearly gone.

A `401` renews the Google token once. A `403` means Google does not share quota
for this account (such as `PERMISSION_DENIED` #3501 on Starter accounts); it is
not a sign-out, so the last reading stays visible while AI Usage asks a running
Antigravity tool instead. That fallback finds the Antigravity app's
`language_server` (by its `--ide_name` or `--app_data_dir` flag, or its app
bundle path) or the `agy` CLI, reads only those processes' own listening ports
with `lsof -a -p`, and calls `RetrieveUserQuotaSummary` on `127.0.0.1` with the
tool's CSRF token. The app passes its token as `--csrf_token`; `agy` hands it to
the processes it starts as `ANTIGRAVITY_CSRF_TOKEN`. The loopback listener's
self-signed certificate is trusted only for `127.0.0.1`.

### Z.ai

AI Usage never asks for a Z.ai key. It reuses the first GLM Coding Plan key it
finds: `ZAI_API_KEY`; Claude Code `settings.json` whose
`env.ANTHROPIC_BASE_URL` points at `api.z.ai` or `open.bigmodel.cn`, with
`ANTHROPIC_AUTH_TOKEN` or `ANTHROPIC_API_KEY`; or OpenCode's
`~/.local/share/opencode/auth.json` entries `zai-coding-plan`, `zai`,
`zhipuai-coding-plan`, and `zhipuai`. Zhipu keys go only to `open.bigmodel.cn`,
the others only to `api.z.ai`. Z.ai is shown only while such a key exists.

`CREDIT_LIMIT` and `TOKENS_LIMIT` entries become windows from `unit` (3 hours,
4 days, 6 weeks) times `number`: shorter than a day is Session, shorter than a
week Daily, and shorter than four weeks Weekly. `percentage` is the used share
and `nextResetTime` is epoch milliseconds. `TIME_LIMIT` is Web Searches,
`currentValue` of `usage`. `data.level` is the plan.

OpenCode is intentionally not included: its current limits require scanning
local usage databases and are machine-local estimates, which conflicts with
AI Usage's no-background-log-scanning design. OpenRouter is also excluded
because it requires users to add an API key instead of reusing a local agent
login.

## Persistence and failure policy

Rotated credentials are persisted only to the source from which they were
loaded. Claude compares the complete ordered credential generation before
writing and again before publishing usage. Codex compares the exact source
before writing. This prevents an in-flight refresh from overwriting a new CLI
login.

Temporary network failures, `429`, server errors, denied Antigravity quota, and
invalid response shapes preserve the last-good in-memory snapshot and mark it
stale. Authentication and storage failures clear that provider's snapshot.
Every `Retry-After` is honored for at most an hour.
