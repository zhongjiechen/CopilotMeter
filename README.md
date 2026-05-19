# CopilotMeter

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
  - `api.github.com` once every 6 h to check `releases/latest` for a new version (no auth, no payload, no identifying headers; disable with `defaults write dev.local.CopilotMeter disableUpdateChecks 1`).
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

- **v0.1.7** — **In-app update notifications.** CopilotMeter now polls GitHub Releases at most once every 6 h and shows an orange banner in the popover (plus a dot on the menu-bar icon) when a newer version is available. Click "Open" to view the release notes & DMG. Opt out anytime with `defaults write dev.local.CopilotMeter disableUpdateChecks 1`. ([#13](https://github.com/zhongjiechen/CopilotMeter/pull/13))
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
