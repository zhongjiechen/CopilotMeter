# CopilotMeter

A tiny native macOS menu-bar app that tracks **how much you're actually using GitHub Copilot** — even when your subscription is "unlimited" and the built-in indicator stays stuck at 0 %.

<p align="center">
  <img src="docs/overview.png" alt="CopilotMeter popover" width="420">
</p>

Today / 7-day / 30-day breakdown, cache-hit rate, per-model split, estimated USD cost. Swift + SwiftUI, Apple Silicon native, runs 100 % locally.

## 📣 News

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

| Source | Path |
|---|---|
| Copilot CLI / VS Code Agent | `~/.copilot/session-state/<sid>/events.jsonl` |
| VS Code Copilot Chat | `~/Library/.../github.copilot-chat/session-store.db` |
| Remote hosts | extracted over SSH from each remote's own `~/.copilot/` |
| Cache | `~/Library/Application Support/CopilotMeter/cache.db` |

No network calls except the SSH/rsync to enabled remotes.

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
