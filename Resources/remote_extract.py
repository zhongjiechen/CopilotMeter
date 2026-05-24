#!/usr/bin/env python3
"""
CopilotMeter — remote-side usage extractor.

Streamed over SSH and run on the remote host. Reads two sources:

  1. ~/.copilot/session-state/<sid>/events.jsonl  (Copilot CLI / Agent)
  2. ~/.vscode-server/data/User/workspaceStorage/<wkh>/GitHub.copilot-chat/
       transcripts/<sid>.jsonl                    (VS Code Copilot Chat)

Emits one compact JSON line per token-relevant event so the host app can
re-hydrate UsageRecords.

Crucially:
  - We only open events.jsonl / transcripts/*.jsonl — never plan.md, files/,
    debug-logs/, or anything else.
  - We accept a JSON map of {key: byte_offset} on argv (base64-encoded JSON)
    and resume each file from that offset, so subsequent runs send only new
    bytes. Keys are `<sid>` for CLI files and `wsx:<workspaceHash>/<sid>`
    for transcript files.
  - For transcripts we DO NOT emit message content (prompt text never leaves
    the remote process). We only count user.message events.

Output format (one JSON object per line):
  # CLI / Agent events.jsonl —
  {"sid": "<sid>", "off": 12345}                        # progress marker
  {"sid": "...", "ts": "...", "t": "m", "model": "...",
   "mid": "...", "out": 200}                            # assistant.message
  {"sid": "...", "ts": "...", "t": "s", "model": "...",
   "in": 1234, "cr": 567, "cw": 0, "cost": 1.0,
   "aiu": 49014850000}                                  # session.shutdown rollup
                                                        # ("aiu" = totalNanoAiu, GitHub's
                                                        # native billing unit since 2026-06-01;
                                                        # 1 AIU = 10^9 nano-AIU = $0.01 USD)
  {"sid": "...", "ts": "...", "t": "init",
   "sm": "claude-opus-4.7"}                             # session.start
  {"sid": "...", "t": "end"}                            # session.shutdown seen

  # VS Code Chat workspace transcripts —
  {"okey": "wsx:<wkh>/<sid>", "off": 99999}             # transcript progress
  {"sid": "<sid>", "ts": "...", "t": "wt",
   "mid": "<event-uuid>"}                               # user.message (one per turn)

Robust to malformed JSON lines (skip), unknown event types (skip), and
files that are mid-write (truncated trailing line is ignored; the resume
offset only advances past complete newline-terminated lines).
"""
import json
import os
import sys
from glob import glob


def usage_dir() -> str:
    return os.path.join(os.path.expanduser("~"), ".copilot", "session-state")


def vscode_chat_workspace_root() -> str:
    return os.path.join(
        os.path.expanduser("~"),
        ".vscode-server", "data", "User", "workspaceStorage",
    )


def emit(obj):
    json.dump(obj, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")


def emit_session_init(path: str, sid: str) -> None:
    """Reads only the FIRST line of an events.jsonl file and re-emits the
    `session.start` metadata as an init event. This is intentionally
    independent of the resume offset so that long-running sessions whose
    session.start sits before the offset still get their `selectedModel`
    propagated to the host on every sync — without that, older CLI versions
    (which don't include `model` on each assistant.message) leave records
    stuck at model="unknown" forever.
    """
    try:
        with open(path, "rb") as f:
            first = f.readline()
    except OSError:
        return
    if not first:
        return
    try:
        evt = json.loads(first)
    except (json.JSONDecodeError, UnicodeDecodeError):
        return
    if not isinstance(evt, dict) or evt.get("type") != "session.start":
        return
    ts = evt.get("timestamp")
    d = evt.get("data") or {}
    sm = d.get("selectedModel")
    host_type = (d.get("context") or {}).get("hostType")
    if not (sm or host_type):
        return
    obj_out = {"sid": sid, "ts": ts, "t": "init"}
    if sm:
        obj_out["sm"] = sm
    if host_type:
        obj_out["ht"] = host_type
    emit(obj_out)


def process_file(path: str, sid: str, start_offset: int) -> int:
    """Reads `path` from byte offset `start_offset`. Returns the byte offset
    after the last complete line consumed (so the caller can resume cleanly
    next time)."""
    try:
        size = os.path.getsize(path)
    except OSError:
        return start_offset
    # File rotation / truncation safeguard.
    if start_offset > size:
        start_offset = 0
    if start_offset >= size:
        return start_offset
    try:
        with open(path, "rb") as f:
            f.seek(start_offset)
            data = f.read()
    except OSError:
        return start_offset

    # Process complete newline-terminated lines only.
    lines = data.split(b"\n")
    consumed = 0  # bytes of `data` we've accepted as complete lines
    for i, raw in enumerate(lines):
        is_last = i == len(lines) - 1
        if is_last:
            # Partial trailing line (after the final newline). Don't consume.
            break
        consumed += len(raw) + 1  # +1 for the newline
        if not raw:
            continue
        try:
            evt = json.loads(raw)
        except (json.JSONDecodeError, UnicodeDecodeError):
            continue
        kind = evt.get("type")
        ts = evt.get("timestamp")
        d = evt.get("data") or {}
        if kind == "assistant.message":
            emit({
                "sid": sid, "ts": ts, "t": "m",
                "mid": d.get("messageId"),
                "model": d.get("model"),
                "out": int(d.get("outputTokens") or 0),
            })
        elif kind == "session.start":
            sm = d.get("selectedModel")
            host_type = (d.get("context") or {}).get("hostType")
            if sm or host_type:
                obj_out = {"sid": sid, "ts": ts, "t": "init"}
                if sm:
                    obj_out["sm"] = sm
                if host_type:
                    obj_out["ht"] = host_type
                emit(obj_out)
        elif kind == "session.shutdown":
            mm = d.get("modelMetrics") or {}
            for model, m in mm.items():
                usage = m.get("usage") or {}
                req = m.get("requests") or {}
                cost_val = req.get("cost")
                row = {
                    "sid": sid, "ts": ts, "t": "s", "model": model,
                    "in": int(usage.get("inputTokens") or 0),
                    "cr": int(usage.get("cacheReadTokens") or 0),
                    "cw": int(usage.get("cacheWriteTokens") or 0),
                }
                if cost_val is not None:
                    try:
                        row["cost"] = float(cost_val)
                    except (TypeError, ValueError):
                        pass
                # totalNanoAiu is GitHub's authoritative AI-Credit value
                # for the model in this session (1 AIU = 10^9 nano-AIU =
                # $0.01 USD post-2026-06-01). Only emitted by newer CLI
                # builds; older builds force the host to estimate from
                # tokens × per-million-token rates.
                aiu_val = m.get("totalNanoAiu")
                if aiu_val is not None:
                    try:
                        row["aiu"] = int(aiu_val)
                    except (TypeError, ValueError):
                        pass
                emit(row)
            emit({"sid": sid, "t": "end"})
    return start_offset + consumed


def process_transcript(path: str, sid: str, start_offset: int) -> tuple:
    """Reads a VS Code Copilot Chat transcript file from `start_offset`.

    Emits one `wt` event per `user.message` line. Deliberately does NOT
    emit the message content.

    Also tracks whether this run saw any `tool.execution_start` event for
    the session — Agent mode's calling card. The caller emits a separate
    `wagent` marker per Agent session so the host can classify those
    sessions distinctly from pure Ask/Edit chats. Returns
    `(new_byte_offset, saw_tool_call)`.
    """
    try:
        size = os.path.getsize(path)
    except OSError:
        return start_offset, False
    # File rotation / truncation safeguard.
    if start_offset > size:
        start_offset = 0
    if start_offset >= size:
        return start_offset, False
    try:
        with open(path, "rb") as f:
            f.seek(start_offset)
            data = f.read()
    except OSError:
        return start_offset, False

    lines = data.split(b"\n")
    consumed = 0
    saw_tool = False
    for i, raw in enumerate(lines):
        is_last = i == len(lines) - 1
        if is_last:
            break
        consumed += len(raw) + 1
        if not raw:
            continue
        try:
            evt = json.loads(raw)
        except (json.JSONDecodeError, UnicodeDecodeError):
            continue
        if not isinstance(evt, dict):
            continue
        etype = evt.get("type")
        if etype == "tool.execution_start":
            saw_tool = True
            continue
        if etype != "user.message":
            continue
        ts = evt.get("timestamp")
        mid = evt.get("id")
        if not mid:
            continue
        emit({
            "sid": sid, "ts": ts, "t": "wt", "mid": mid,
        })
    return start_offset + consumed, saw_tool


def main():
    # Resume offsets come in via a single base64-encoded JSON arg, so we
    # don't fight ssh/shell quoting and don't share stdin with the script
    # source. Empty / missing → start from byte 0 for every file.
    offsets = {}
    if len(sys.argv) >= 2 and sys.argv[1]:
        try:
            import base64
            offsets = json.loads(base64.b64decode(sys.argv[1])) or {}
        except Exception:
            offsets = {}

    # 1. Copilot CLI / Agent — events.jsonl files.
    base = usage_dir()
    if os.path.isdir(base):
        for events_path in sorted(glob(os.path.join(base, "*", "events.jsonl"))):
            sid = os.path.basename(os.path.dirname(events_path))
            # Always re-emit session.start metadata first so the host can
            # backfill selectedModel even when the resume offset is past
            # the session.start line. Cheap (reads only the first line).
            emit_session_init(events_path, sid)
            start = int(offsets.get(sid, 0))
            new_off = process_file(events_path, sid, start)
            emit({"sid": sid, "off": new_off})

    # 2. VS Code Copilot Chat — per-workspace transcripts.
    wks_root = vscode_chat_workspace_root()
    if os.path.isdir(wks_root):
        pattern = os.path.join(
            wks_root, "*", "GitHub.copilot-chat", "transcripts", "*.jsonl"
        )
        for tx_path in sorted(glob(pattern)):
            # …/workspaceStorage/<workspaceHash>/GitHub.copilot-chat/transcripts/<sid>.jsonl
            sid = os.path.splitext(os.path.basename(tx_path))[0]
            wkh = os.path.basename(
                os.path.dirname(os.path.dirname(os.path.dirname(tx_path)))
            )
            okey = "wsx:" + wkh + "/" + sid
            start = int(offsets.get(okey, 0))
            new_off, saw_tool = process_transcript(tx_path, sid, start)
            if saw_tool:
                # Stamps this session as Agent mode (has tool calls). The
                # host will re-classify any existing user.message records
                # for this session from .vscodeChat to .vscodeAgent.
                emit({"sid": sid, "t": "wagent"})
            emit({"okey": okey, "off": new_off})


if __name__ == "__main__":
    main()
