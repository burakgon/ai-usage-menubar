# Product

<!-- impeccable:product-schema 1 -->

## Platform

adaptive

<!--
Impeccable 4.0.2 has no macOS platform token. `adaptive` is used only to route
future work through native guidance instead of web guidance. AI Usage is a
native macOS-only product; this is not a cross-platform commitment.
-->

## Users

AI Usage is for macOS developers who use Claude Code and/or Codex locally and
want to check their remaining session or weekly allowance without opening a
CLI, visiting a provider dashboard, or leaving their current coding workflow.

## Product Purpose

AI Usage keeps the limits that affect an active coding session visible at a
glance from the macOS menu bar. It should make an accurate answer available in
one click, then get out of the user's way. Success means the user can understand
their current allowance and reset timing immediately while the app remains
stable and nearly idle in the background.

## Positioning

AI Usage is a focused native utility, not an analytics dashboard. It reuses the
local OAuth sessions already created by the Claude Code and Codex CLIs and
requests quota data directly from each provider's first-party endpoint. It
requires no AI Usage account, API key, local server, telemetry, usage-history
database, or background transcript scanning.

## Operating Context

- The app lives in the macOS menu bar without a Dock icon or persistent main
  window.
- At least one supported CLI is normally installed locally. A genuinely absent
  tool is hidden; an installed but signed-out or temporarily unavailable tool
  remains visible with its real status.
- Usage refreshes automatically at a user-selected interval and can be
  refreshed manually.
- Users can choose the provider, primary quota period, and whether percentages
  mean Left or Used. Left is the default.
- Launch at Login is enabled by default and remains user-controllable.
- Signed over-the-air updates are delivered through Sparkle, with a manual
  update action available in the panel.

## Capabilities and Constraints

- Supported providers are intentionally limited to Claude Code and Codex.
- Claude Code surfaces session, weekly, Sonnet, and Fable quota windows.
- Codex surfaces session, weekly, Spark, and Spark Weekly quota windows.
- Automatic menu-bar selection compares the selected primary period across
  available providers. A pinned provider may fall back to its other primary
  period when the selected one is absent, but never to a Spark-specific quota.
- Provider percentages are displayed as reported. Progress-bar drawing is
  bounded to a valid visual range, and calculated remaining percentages are
  bounded to `0...100`.
- Credentials are discovered locally and used only with the corresponding
  first-party provider. Secrets must never be printed, logged, or sent to any
  other service.
- AI Usage creates no usage cache or history of its own. Provider credential
  rotations may be written back to the existing local credential store when
  required to keep the user's CLI session valid.
- macOS 26 or newer is required. The app is implemented natively with SwiftUI
  and AppKit and distributed as a universal `arm64`/`x86_64` application.
- Low idle CPU use, small memory footprint, fast startup, stability, and a
  compact non-scrolling primary experience are binding quality requirements.
- OpenUsage is the technical authority for current provider authentication and
  usage contracts. The older KDE widget is only a reference for product
  simplicity, not provider implementation.

## Brand Commitments

- The product name is **AI Usage**.
- The interface must feel native to contemporary macOS and preserve its clean,
  compact Liquid Glass identity in light and dark appearances.
- Claude Code and Codex use recognizable monochrome provider marks in the menu
  bar and panel.
- Product language stays concise, factual, and unobtrusive.
- The project is open source under the MIT License. Provider trademarks identify
  their respective services and do not imply endorsement.

## Evidence on Hand

- Product positioning, installation, behavior, and privacy claims:
  `README.md`
- Current menu-bar product screenshot:
  `docs/images/ai-usage-menubar-dark.png`
- App and provider identity assets:
  `AIUsage/Assets.xcassets/`
- Researched provider behavior and limitations:
  `docs/provider-contracts.md`
- Native implementation:
  `AIUsage/AIUsageApp.swift`, `AIUsage/Views/`, and `AIUsage/Providers/`
- Automated behavior, visual sizing, theme, provider-state, and accessibility
  coverage: `AIUsageTests/`
- Release and OTA process: `docs/releasing.md`, `docs/releases/`, and
  `appcast.xml`

No customer testimonials, usage benchmarks, pricing, enterprise claims, or
third-party endorsements are established. Future product work must not invent
them.

## Product Principles

1. **Glance, understand, return to work.** Every interaction should minimize
   time and attention away from the user's coding task.
2. **Show provider truth.** Prefer current first-party contracts and explicit
   states over inferred usage, fabricated estimates, or stale technical
   assumptions.
3. **Privacy is architectural.** Reuse local sessions, communicate only with the
   relevant provider, and collect nothing.
4. **Native efficiency is part of the product.** Visual polish cannot justify
   sustained idle work, instability, excess complexity, or resource waste.
5. **Absence and failure are different states.** Hide unsupported local tools,
   but explain sign-out, expiry, rate limits, stale data, and transient failures
   honestly.

## Accessibility & Inclusion

Preserve native keyboard and assistive-technology behavior, meaningful
accessibility labels, semantic system colors, readable light and dark
appearances, and Reduce Transparency support. Status and meaning must never
depend on color alone.
