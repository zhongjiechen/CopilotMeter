# CopilotMeter

A tiny native macOS menu bar app that tracks **how much you're actually using GitHub Copilot** — across Copilot CLI _and_ VS Code Copilot Chat — even when your subscription is "unlimited" and the built-in usage indicator stays stuck at 0 %.

<p align="center">
  <img src="docs/overview.png" alt="CopilotMeter popover showing today / week / month tiles, cache hit rate and per-model breakdown" width="420">
</p>

- Swift 5.9 / SwiftUI / `MenuBarExtra` (macOS 13 +)
- Apple Silicon native (`arm64`)
- Zero network calls — all data is read from local files on your Mac
- Dependency-free build (system `libsqlite3`, nothing else)

## What it shows

| Window | Metric |
|---|---|
| **Today** / **Week (7d)** / **Month (30d)** | Premium request count, output tokens, input tokens, cache reads, premium-cost-equivalent |
| **Estimated cost (USD)** | GitHub-overage equivalent (`premium_cost × $0.04`) and retail token-equivalent (at public Anthropic / OpenAI 2025 rates) |
| **Cache hit rate** | % of input tokens served from prompt cache, with hit / miss / written breakdown |
| Per model | Top models by request count, with mini progress bars and per-model cache hit % |
| Per source | Copilot CLI vs VS Code Agent vs VS Code Chat — colour-coded with a permanent legend at the top of the popover |
| Last 30 days | Bar sparkline of daily request counts |

The menu-bar icon shows **today's total premium-equivalent request count** so you can keep an eye on it without opening the popover.

### Cache hit rate

For each time window, CopilotMeter shows what fraction of your input tokens
came from prompt cache:

```
Cache hit rate                                              90.4 %
[████████████████████████████████████████  ▒▒▒▒▒]
✓ 3.2M hit    ○ 345K miss    ↓ 66K written
```

- **hit** — tokens served from cache (the cheap path)
- **miss** — tokens re-processed from scratch
- **written** — tokens newly written to cache for future re-use

Per-model rows in the *Top Models* list also include each model's cache hit
percentage, so you can see at a glance which models benefit most from
prompt caching in your usage patterns.

### Estimated cost in USD

For each window CopilotMeter shows two dollar figures side-by-side:

- **GitHub bill** — what GitHub would bill if you paid the standard
  per-premium-request overage rate (`premium_cost × $0.04`). For enterprise
  plans where every model's `cost` is recorded as 0 this stays at $0.
- **Retail tokens** — best-effort estimate of what the underlying provider
  (Anthropic / OpenAI) would charge for the same tokens at their public
  2025 list prices. This is the "what am I getting" number for unlimited
  enterprise seats.

Retail rate constants live in
[`Sources/CopilotMeter/Pricing/PricingCatalog.swift`](Sources/CopilotMeter/Pricing/PricingCatalog.swift)
— update them when official prices change. Cache reads are billed at a 10 %
discount of the input rate (Anthropic convention) and cache writes at a
25 % surcharge; you can override either per-model via the `ModelPrice`
initialiser.

## Data sources

CopilotMeter reads three local files. **Nothing leaves your machine.**

| File | Coverage |
|---|---|
| `~/.copilot/session-state/<sid>/events.jsonl` | Every Copilot CLI session AND every VS Code session that used the Copilot agent (`copilotcli` / agent mode). Each `session.shutdown` line carries authoritative `inputTokens`/`outputTokens`/`cacheReadTokens`/`cacheWriteTokens` and the recorded "premium request cost" per model. |
| `~/Library/Application Support/Code/User/globalStorage/github.copilot-chat/session-store.db` | VS Code Copilot Chat sessions whose `agent_name` is **not** `copilotcli` (i.e. "Ask" / "Edit" panels). These rows have no token data — they're counted as "blind interactions" with the model = `agent_name`. |
| `~/Library/Application Support/CopilotMeter/cache.db` | Our own local cache. Stores parsed records keyed by `(session_id, message_id, kind, model)` plus a per-file byte offset, so subsequent refreshes only read the newly-appended JSONL bytes. |

## Install

### Option 1 — one-line installer (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/zhongjiechen/CopilotMeter/main/Scripts/install.sh | bash
```

The script downloads the latest `CopilotMeter.dmg`, strips the macOS
quarantine attribute, copies the app into `/Applications`, and ejects the
disk image. Then add **CopilotMeter** to **System Settings → General →
Login Items** to launch at login.

### Option 2 — download the DMG manually

> ⚠️ **Gatekeeper note**: the DMG is ad-hoc codesigned, not notarised.
> Downloading it through Safari/Chrome attaches `com.apple.quarantine`, and
> double-clicking gives the dreaded *"Apple cannot verify that
> CopilotMeter.dmg is free of malware"* dialog. Run **one** of the
> following first:

```bash
# Strip quarantine from the DMG, then double-click as normal
xattr -d com.apple.quarantine ~/Downloads/CopilotMeter.dmg
open ~/Downloads/CopilotMeter.dmg
```

After dragging `CopilotMeter.app` to `Applications`, if the first launch
is still blocked:

```bash
xattr -dr com.apple.quarantine /Applications/CopilotMeter.app
open -a CopilotMeter
```

This isn't a security workaround — it tells macOS "I downloaded this on
purpose, stop pretending it came from the internet". Code-signing
properly requires a paid Apple Developer ID; the source is right here in
this repo for anyone who wants to inspect it.

### Option 3 — build from source

Requires Xcode command line tools (Swift 5.9 +) on Apple Silicon.

```bash
git clone https://github.com/zhongjiechen/CopilotMeter.git
cd CopilotMeter
make app             # builds Release arm64 and assembles CopilotMeter.app
make run             # builds + opens the app
make dmg             # builds + packages CopilotMeter.dmg for distribution
make install         # copies CopilotMeter.app to /Applications
make reset-cache     # wipe the local SQLite cache (forces a full reparse)
make clean           # remove all build artifacts
make icon            # regenerate Resources/AppIcon.icns
```

If your terminal is running under Rosetta (`uname -m` returns `x86_64` on an
Apple Silicon Mac), the Makefile automatically prefixes the build with
`arch -arm64` so you still get a native arm64 binary.

### Preview / debug window

The menu-bar popover can also be opened in a regular resizable window
(handy for screenshots or to see the full UI without anchoring it to the
menu bar):

```bash
open build/CopilotMeter.app --args --preview
```

## Configuration

There's nothing to configure. On first launch CopilotMeter:

1. Creates `~/Library/Application Support/CopilotMeter/cache.db`.
2. Scans every `events.jsonl` under `~/.copilot/session-state/`.
3. Imports interactions from the VS Code Copilot Chat DB.
4. Refreshes every 60 seconds (and on manual ↻).

The full reparse takes a few seconds on first run; subsequent refreshes are
near-instant because we resume each file from its last byte offset.

## How "premium requests" are counted

- **Per `assistant.message` event** → `requestCount += 1`, attributed to that message's timestamp and model. (Model falls back to `session.start.selectedModel` when older event-log formats omit the per-message `model` field.)
- **Per `session.shutdown` modelMetrics entry** → `inputTokens` / `cacheReadTokens` / `cacheWriteTokens` / `premiumCost` are taken from the session-shutdown summary and attributed to the shutdown timestamp. (Most sessions end the same day they started, so the bucketing is accurate in practice.)
- **VS Code Chat / Ask mode** → one interaction per `turns` row (= one user prompt). No token data available; shown separately as "+N chat" in the Today/Week/Month tiles.

The "≈ premium" total in each tile is the sum of recorded `requests.cost`
values from `session.shutdown` summaries — i.e. what GitHub itself recorded
as your "premium request units" for that session. For enterprise plans where
the cost field is heavily discounted or zero, this number will simply be
small.

## Project layout

```
CopilotMeter/
├── Package.swift             # SwiftPM manifest
├── Makefile                  # build / run / install targets
├── Scripts/build-app.sh      # assembles the .app bundle
├── Resources/Info.plist      # LSUIElement = true (menu-bar only)
└── Sources/CopilotMeter/
    ├── App.swift             # @main + MenuBarExtra
    ├── Models/               # UsageRecord, TimeWindow, UsageStats
    ├── DataSources/          # SQLite wrapper, JSONL parser, VS Code reader
    ├── Storage/CacheStore.swift
    ├── Services/             # UsageAggregator, UsageRefresher
    └── Views/                # WindowTile, ModelBreakdown, DailySparkline, PopoverView
```

## Privacy

Everything is local. No network access. No telemetry. You can verify by
running `lsof -p <pid>` while the app is running — you'll only see file
handles into `~/.copilot/` and `~/Library/Application Support/`.

## License

Personal utility, do whatever you want with it.
