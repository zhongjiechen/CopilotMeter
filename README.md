<p align="center">
  <img src="docs/copilotmeter.png" alt="CopilotMeter logo" width="200">
</p>

<h1 align="center">CopilotMeter</h1>

A tiny native macOS menu-bar app that tracks **how much you're actually using GitHub Copilot** — today / 7-day / 30-day breakdown, cache-hit rate, per-model split, and a USD cost estimate, all from a glance.

<p align="center">
  <img src="docs/overview.png" alt="CopilotMeter popover" width="420">
</p>

Works for any Copilot plan, but **especially valuable for GitHub Copilot Enterprise users**: your seat is "Unlimited", the official dashboard at <https://github.com/settings/billing/usage> reports 0 % forever, and there is no API for per-turn token data. CopilotMeter parses the same local files Copilot writes anyway and gives you a real number.

Pro / Pro+ / Business users still get a nicer, always-visible breakdown than the web dashboard — without leaving the menu bar.

## Privacy &amp; safety

- **No login.** Doesn't ask for your GitHub credentials, OAuth token, or any API key. There's literally no auth flow.
- **Only two network endpoints, both passive:**
  - SSH to hosts *you* tick in the popover (for tracking your own remote dev boxes — disabled by default).
  - `api.github.com` once a week to check `releases/latest` for a new version (no auth, no payload, no identifying headers; disable with `defaults write dev.local.CopilotMeter disableUpdateChecks 1`).
- **No telemetry, no crash reporters, no third-party SDKs.** Single Swift binary, sandbox-friendly.
- **Reads only locally-written Copilot session-state.** Specifically:
  - `~/.copilot/session-state/<sid>/events.jsonl` — for CLI / Agent token rollups
  - `~/Library/Application Support/Code/User/{globalStorage,workspaceStorage}/.../github.copilot-chat/...` — for Chat request counts (prompt text is **never** loaded into the app's memory — see `VSCodeChatTranscriptsReader.swift` / `VSCodeChatReader.swift`)
- **Nothing is uploaded.** All aggregation happens on your Mac and is stored at `~/Library/Application Support/CopilotMeter/cache.db`. Uninstall by deleting that directory + `/Applications/CopilotMeter.app`; no leftovers elsewhere.

Open source under MIT, so feel free to audit the ~1.2 MB of Swift before installing.

## Lightweight by design

| | Size |
|---|---|
| `.dmg` download | ~ 900 KB |
| Installed `.app` bundle | 1.6 MB |
| Native arm64 binary | 1.2 MB |
| Resident memory while running | ~ 45 MB |
| CPU when idle | 0 % |
| Local refresh tick | every 60 s (parses only the new tail of each `events.jsonl` / transcript) |
| Remote refresh tick | every 1 h (incremental; typically < 1 KB of SSH traffic per host after the first sync) |

No background daemons, no helper tools. The whole app is one Swift binary linked against system frameworks (no Electron, no embedded Node/Python runtime — the small Python extractor we ship is only ever piped over SSH to remote hosts, never spawned locally).

## 📣 News

- **v0.1.16** — **AI Credits as the primary metric.** The menu-bar number, popover tile, model breakdown, remote chips, 30-day sparkline, and footer all now show **AI Credits** (= GitHub's official 2026-06-01 billing unit, 1 credit = $0.01 USD) instead of request counts. When the Copilot CLI emits `session.shutdown.modelMetrics.<model>.totalNanoAiu` we read it **directly** as the authoritative figure; otherwise we fall back to a per-token estimate using the public rates (exact within rounding). A green **`AIU ✓`** chip in the cost row tells you the displayed number came straight from GitHub. Request counts are still surfaced as secondary info / tooltips. ([#21](https://github.com/zhongjiechen/CopilotMeter/pull/21))
- **v0.1.15** — Bug-fix release: menu-bar count now matches the popover's "Today" tile (both add up all sources / local + remote), and remote-host rows are no longer all `unknown` — local & remote parsers now honour the CLI's `selectedModel`. ([#20](https://github.com/zhongjiechen/CopilotMeter/pull/20))
- **v0.1.14** — Menu-bar icon reverted to the original SF Symbol (`chart.bar.fill`). The custom helmet template tried in v0.1.12 / v0.1.13 looked rough at 18 px; the SF Symbol is cleaner. The colored helmet logo is kept everywhere else: README header, Dock / Finder app icon, DMG icon.
- **v0.1.13** — **Fix:** menu-bar icon in v0.1.12 rendered as a featureless white blob — `fill="#fff"` on the visor was still ink because macOS template images only honour the alpha channel. Rewrote the SVG to use a `fill-rule="evenodd"` compound path that actually punches the visor out as transparent, so the helmet silhouette + cat ears + antenna + chart bars are all legible at 18 px again.
- **v0.1.12** — **New colored app icon + custom menu-bar template** that match the friendly CopilotMeter helmet logo. Bundle now ships `MenuBarIcon@{1,2,3}x.png` and renders it as a template image so it auto-tints to the menu-bar appearance (light/dark/accent). DMG icon redesigned to use the helmet on a Big-Sur-style blue squircle. ([#18](https://github.com/zhongjiechen/CopilotMeter/pull/18))
- **v0.1.11** — **Updated to GitHub Copilot's 2026-06-01 AI Credit billing model.** New rates pulled directly from [the official docs](https://docs.github.com/en/copilot/reference/copilot-billing/models-and-pricing): Claude Opus dropped to $5 / $25 per M (was estimated $15 / $75), GPT-5.5 added at $5 / $30, plus the entire new model family (GPT-5.2/.3/.4/.4-mini/.4-nano, Sonnet 4.5/4.6, Opus 4.5/4.6/4.7, Gemini 3 Flash / 3.1 Pro, Raptor mini, Goldeneye). The right-hand cost column is now labeled **"AI Credits"** (1 credit = $0.01 USD = exactly what GitHub bills). Cost-formula popover updated. ([#17](https://github.com/zhongjiechen/CopilotMeter/pull/17))
- **v0.1.10** — Added an **ⓘ button** next to "Estimated cost" in the popover. Click it for a full explanation of how each column is computed (GitHub-bill formula vs retail-token formula, per-model rates, why VS Code Chat is $0). ([#16](https://github.com/zhongjiechen/CopilotMeter/pull/16))
- **v0.1.9** — Renamed the **"Coding Agent"** source label to **"Cloud Agent"** to better reflect what it is (the GitHub-side, cloud-dispatched agent triggered by PR `@copilot` mentions / "Delegate to coding agent"). Internal raw value is unchanged so existing `cache.db` rows continue to decode. ([#15](https://github.com/zhongjiechen/CopilotMeter/pull/15))
- **v0.1.8** — Update check now runs **weekly** (was 6-hourly — overkill for an app that ships once a week at most). Current version (`v0.1.x`) now shown next to the popover title so you always know what you're running. ([#14](https://github.com/zhongjiechen/CopilotMeter/pull/14))
- **v0.1.7** — **In-app update notifications.** CopilotMeter now polls GitHub Releases at most once every 6 h and shows an orange banner in the popover (plus a dot on the menu-bar icon) when a newer version is available. Click "Open" to view the release notes & DMG. Opt out anytime with `defaults write dev.local.CopilotMeter disableUpdateChecks 1`. ([#13](https://github.com/zhongjiechen/CopilotMeter/pull/13))
- **v0.1.6** — Distinguish VS Code Chat **Agent mode** from **Ask/Edit mode** in workspace transcripts. Sessions with `tool.execution_start` events (i.e. agentic tool use like `run_in_terminal`, `replace_string_in_file`) are now classified as `vscodeAgent` instead of `vscodeChat`. Includes a one-shot migration that retroactively reclassifies records ingested by v0.1.5. ([#12](https://github.com/zhongjiechen/CopilotMeter/pull/12))
- **v0.1.5** — **Big undercount fix for VS Code Copilot Chat users.** We now also scan per-workspace transcripts (`workspaceStorage/<wkHash>/GitHub.copilot-chat/transcripts/*.jsonl`) on both local and remote, since modern Copilot Chat (≥0.47) no longer fully mirrors them into the central session-store DB. One of my remotes went from showing 12 monthly requests to 249 after this fix. Works for both local Mac and SSH'd-into hosts. ([#11](https://github.com/zhongjiechen/CopilotMeter/pull/11))
- **v0.1.4** — Distinguish GitHub Cloud Agent (formerly "Coding Agent") sessions from terminal CLI. ([#9](https://github.com/zhongjiechen/CopilotMeter/pull/9))
- **v0.1.3** — **Now tracks remote machines too.** Check a host from your `~/.ssh/config` and CopilotMeter pulls its Copilot usage over SSH — typically < 3 MB per sync. ([#7](https://github.com/zhongjiechen/CopilotMeter/pull/7), [#8](https://github.com/zhongjiechen/CopilotMeter/pull/8))
- **v0.1.2** — Resilience fix for users whose VS Code Copilot Chat extension is installed but never opened. ([#6](https://github.com/zhongjiechen/CopilotMeter/pull/6))
- **v0.1.1** — Per-window USD cost estimates (GitHub overage + retail token equivalent). ([#1](https://github.com/zhongjiechen/CopilotMeter/pull/1))

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/zhongjiechen/CopilotMeter/main/Scripts/install.sh | bash
```

Or download `CopilotMeter.dmg` from the [latest release](https://github.com/zhongjiechen/CopilotMeter/releases/latest). The DMG is ad-hoc signed (not notarised), so if double-clicking gives *"Apple cannot verify..."*, run:

```bash
xattr -d com.apple.quarantine ~/Downloads/CopilotMeter.dmg
open ~/Downloads/CopilotMeter.dmg
```

Then drag CopilotMeter to `/Applications` and add it to **System Settings → General → Login Items**.

## Tracking remote machines (optional)

Open the popover → expand **Remote hosts** → tick any host from your `~/.ssh/config`. CopilotMeter pipes a small Python extractor over SSH and pulls only the token-relevant events:

| | First sync | Incremental |
|---|---|---|
| Network | ~3 MB | ~1 KB |
| Time | ~30 s | ~5 s |
| Local disk | 4 KB | (unchanged) |

No user prompts or assistant responses ever leave the remote. Auto-refreshes hourly.

## Data sources

| Source | Where | Token data? |
|---|---|---|
| Copilot CLI | `~/.copilot/session-state/<sid>/events.jsonl` | ✅ full |
| VS Code Agent (local) | same path — invoked by VS Code Chat in Agent mode | ✅ full |
| VS Code Agent (remote vscode-server) | `workspaceStorage/<wkHash>/GitHub.copilot-chat/transcripts/<sid>.jsonl` | ❌ count-only [^1] |
| VS Code Ask / Edit Chat | central `globalStorage/.../session-store.db` + transcripts | ❌ count-only [^1] |
| Cloud Agent (cloud-dispatched) | events.jsonl with `hostType=github` | ✅ full |
| Remote hosts | extracted over SSH from each remote's own data dirs | same per-source as above |
| Cache | `~/Library/Application Support/CopilotMeter/cache.db` | — |

[^1]: VS Code Copilot Chat marks token-bearing `assistant.usage` events as `ephemeral` and filters them out before writing to disk, so per-turn input/output token counts simply aren't available on the local filesystem. We can only count requests for those sources.

No network calls except the SSH to enabled remotes.

## Build from source

```bash
git clone https://github.com/zhongjiechen/CopilotMeter.git
cd CopilotMeter
make app             # builds & assembles CopilotMeter.app
make dmg             # builds & packages CopilotMeter.dmg
make install         # copies to /Applications
```

Requires Apple Silicon + Xcode CLT (Swift 5.9 +).

## License

MIT — see [LICENSE](LICENSE).
