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
  - `~/Library/Application Support/Code/User/{globalStorage,workspaceStorage}/.../github.copilot-chat/...` — for detecting Chat sessions that do not expose local AI Credit data (prompt text is **never** loaded into the app's memory — see `VSCodeChatTranscriptsReader.swift` / `VSCodeChatReader.swift`)
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

- **v0.1.29** — **Stop the CLI/Cloud-Agent/VS-Code source flip-flop.** Terminal-resumed sessions kept reverting to VS Code Agent / Cloud Agent on incremental syncs because the `session.resume` marker sits before the byte offset and wasn't re-read. The resume signal is now persisted in a sticky `session_resume` table, and the VS Code session lookup excludes `agent_name = copilotcli` rows (the terminal CLI also registers there). A one-time rescan reclassifies existing data. Net effect: a large terminal-driven session no longer counts as Cloud Agent or VS Code Agent.

- **v0.1.28** — **Classify terminal-resumed sessions as CLI.** Sessions that originated in a GitHub-hosted agent environment but were later continued with `copilot --resume` in a terminal are now attributed to **Copilot CLI**, even when their original `session.start.context.hostType` is `github` or the session id also appears in the VS Code database. This keeps the source split aligned with how the work was actually driven locally.

- **v0.1.27** — **AI Credits only.** Removed the legacy GitHub bill / request-based billing column and all visible request-count stats. CopilotMeter now presents usage strictly in GitHub AI Credits plus the USD equivalent, while keeping token/cache details only where they explain AI Credit cost. Sources without local token or `totalNanoAiu` data are omitted from billing stats instead of falling back to request counts.

- **v0.1.26** — **Correct shutdown-resume accounting for AI Credits and cache hit rate.** Copilot CLI can write multiple real `session.shutdown` rollups into the same session file after `copilot --resume`; previous releases collapsed those rows by `(session, model, remote)`, undercounting AI Credits and making cache hit rates look far too low. Shutdown rows are now keyed by their stable event byte offset, old collapsed shutdown cache rows are rebuilt, and assistant-message output estimates no longer double-count sessions that already have authoritative `totalNanoAiu`.

- **v0.1.25** — **Remote AI-Credit backfill for hosts synced before `totalNanoAiu` support.** Older CopilotMeter builds could advance a remote host's extractor offsets past `session.shutdown` lines before reading GitHub's authoritative `totalNanoAiu`, leaving hosts like `l40` stuck on low token-based estimates. This release resets each remote extractor offset once, replays finished-session rollups, and backfills `ai_credits_nano` idempotently in the local cache.

- **v0.1.24** — **Per-host source breakdown in the *Remote hosts* tooltip + an inline note explaining how resumed `copilot --resume` sessions show up.** Hover any remote chip (e.g. `@host 211 AIU`) and you now see a per-source AI Credit decomposition instead of a single aggregated number. A new caption below the chip strip explains the most common point of confusion: when you run `copilot --resume` on a remote against an agent worktree (branch `agents/...`, cwd `.worktrees/agents-...`), the original GitHub Coding Agent session keeps emitting `context.hostType="github"` in its events.jsonl, so the resumed sessions classify as **Cloud Agent** rather than CLI — even though you typed `copilot` in your terminal. The classification is correct (the data does come from a Coding Agent session); the tooltip + caption now make that visible instead of leaving users to guess where their usage went. Added a joint `byWindowByRemoteSource` aggregate to back the breakdown; no pricing or ingestion change.

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
| VS Code Agent (remote vscode-server) | `workspaceStorage/<wkHash>/GitHub.copilot-chat/transcripts/<sid>.jsonl` | ❌ no local AI Credit data [^1] |
| VS Code Ask / Edit Chat | central `globalStorage/.../session-store.db` + transcripts | ❌ no local AI Credit data [^1] |
| Cloud Agent (cloud-dispatched) | events.jsonl with `hostType=github` | ✅ full |
| Remote hosts | extracted over SSH from each remote's own data dirs | same per-source as above |
| Cache | `~/Library/Application Support/CopilotMeter/cache.db` | — |

[^1]: VS Code Copilot Chat marks token-bearing `assistant.usage` events as `ephemeral` and filters them out before writing to disk, so per-turn input/output token counts and AI Credit values are not available on the local filesystem. CopilotMeter omits those sessions from AI Credit billing stats.

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
