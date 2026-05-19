# CopilotMeter

> **Built for GitHub Copilot Enterprise users.** Your seat says *Unlimited*, the official dashboard reports 0 % usage forever — and you have no idea how much you're actually spending in tokens, requests, or USD equivalents. CopilotMeter parses Copilot's local data files directly and gives you a real per-day / per-week / per-month breakdown the GitHub UI won't.

A tiny native macOS menu-bar app that tracks **how much you're actually using GitHub Copilot** — independent of whatever the in-product indicator shows.

<p align="center">
  <img src="docs/overview.png" alt="CopilotMeter popover" width="420">
</p>

Today / 7-day / 30-day breakdown, cache-hit rate, per-model split, estimated USD cost (both GitHub-billable premium-request units and equivalent retail Anthropic/OpenAI token cost). Swift + SwiftUI, Apple Silicon native, runs 100 % locally.

## Why does this exist?

GitHub Copilot **Pro / Pro+ / Business** users see their usage at <https://github.com/settings/billing/usage>. **Enterprise** users do not — the page caps out at "0 % of unlimited", and there is no API to retrieve per-turn token data. CopilotMeter fills that gap by reading the same `events.jsonl` + Chat-transcript files Copilot writes locally and aggregating them itself. It works for any plan, but Enterprise users are the ones who *need* it.

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

No background daemons, no helper tools, no telemetry. The whole app is one Swift binary linked against system frameworks (no Electron, no embedded Node/Python runtime — the small Python extractor we ship is only ever piped over SSH to remote hosts, never spawned locally).

## 📣 News

- **v0.1.6** — Distinguish VS Code Chat **Agent mode** from **Ask/Edit mode** in workspace transcripts. Sessions with `tool.execution_start` events (i.e. agentic tool use like `run_in_terminal`, `replace_string_in_file`) are now classified as `vscodeAgent` instead of `vscodeChat`. Includes a one-shot migration that retroactively reclassifies records ingested by v0.1.5. ([#12](https://github.com/zhongjiechen/CopilotMeter/pull/12))
- **v0.1.5** — **Big undercount fix for VS Code Copilot Chat users.** We now also scan per-workspace transcripts (`workspaceStorage/<wkHash>/GitHub.copilot-chat/transcripts/*.jsonl`) on both local and remote, since modern Copilot Chat (≥0.47) no longer fully mirrors them into the central session-store DB. One of my remotes went from showing 12 monthly requests to 249 after this fix. Works for both local Mac and SSH'd-into hosts. ([#11](https://github.com/zhongjiechen/CopilotMeter/pull/11))
- **v0.1.4** — Distinguish GitHub Coding Agent sessions from terminal CLI. ([#9](https://github.com/zhongjiechen/CopilotMeter/pull/9))
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
| Coding Agent (cloud-dispatched) | events.jsonl with `hostType=github` | ✅ full |
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
