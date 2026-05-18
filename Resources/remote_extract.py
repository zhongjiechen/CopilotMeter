#!/usr/bin/env python3
"""
CopilotMeter — remote-side usage extractor.

Streamed over SSH and run on the remote host. Reads
~/.copilot/session-state/<sid>/events.jsonl files, emits one compact JSON
line per token-relevant event (assistant.message, session.shutdown,
session.start).

Crucially:
  - Only events.jsonl is opened (we never touch plan.md, files/, etc.)
  - We accept a JSON map of {session_id: byte_offset} on stdin and resume
    each file from that offset, so subsequent runs send only new bytes.
  - Output is bounded: a 200 MB session-state directory typically yields
    a ~3 MB extract.

Output format (one JSON object per line):
  {"sid": "<session-id>", "off": 12345}                 # progress marker, final entry per session
  {"sid": "...", "ts": "...", "t": "m", "model": "...",
   "mid": "...", "out": 200}                            # assistant.message
  {"sid": "...", "ts": "...", "t": "s", "model": "...",
   "in": 1234, "cr": 567, "cw": 0, "cost": 1.0}         # session.shutdown rollup
  {"sid": "...", "ts": "...", "t": "init",
   "sm": "claude-opus-4.7"}                             # session.start (selectedModel)
  {"sid": "...", "t": "end"}                            # marks session.shutdown was seen

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


def emit(obj):
    json.dump(obj, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")


def process_file(path: str, sid: str, start_offset: int) -> int:
    """Reads `path` from byte offset `start_offset`. Returns the byte offset
    after the last complete line consumed (so the caller can resume cleanly
    next time)."""
    try:
        size = os.path.getsize(path)
    except OSError:
        return start_offset
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
                emit(row)
            emit({"sid": sid, "t": "end"})
    return start_offset + consumed


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

    base = usage_dir()
    if not os.path.isdir(base):
        return

    for events_path in sorted(glob(os.path.join(base, "*", "events.jsonl"))):
        sid = os.path.basename(os.path.dirname(events_path))
        start = int(offsets.get(sid, 0))
        new_off = process_file(events_path, sid, start)
        emit({"sid": sid, "off": new_off})


if __name__ == "__main__":
    main()
