#!/usr/bin/env python3
"""A fake Claude Code process, for tests in a sandbox only.

Writes $CLAUDE_CONFIG_DIR/sessions/<own pid>.json the way Claude Code does (pid, sessionId, procStart,
kind, tmux "session:@window.%pane" from $TMUX_PANE, status, statusUpdatedAt), draws a marker on the
terminal's alternate screen, then sleeps. On SIGTERM: appends "SIGTERM <pid>" to --term-file, removes
its sessions file and exits 0 (unless --ignore-term). --exec-after runs a command as its own child
(to test "never close yourself"), writing its output to --exec-out.
"""
import argparse
import json
import os
import signal
import subprocess
import sys
import time

p = argparse.ArgumentParser()
p.add_argument("--uuid", required=True)
p.add_argument("--status", default="idle")
p.add_argument("--name", default="fake")
p.add_argument("--kind", default="interactive")
p.add_argument("--tmux-override", help="write this tmux value instead of the real pane")
p.add_argument("--term-file", required=True)
p.add_argument("--ignore-term", action="store_true")
p.add_argument("--exec-after")
p.add_argument("--exec-out")
args = p.parse_args()

pid = os.getpid()
config_dir = os.environ["CLAUDE_CONFIG_DIR"]
assert config_dir.startswith(os.environ["SANDBOX"]), "fake_claude runs only in the sandbox"
path = os.path.join(config_dir, "sessions", f"{pid}.json")

tmux = None
if os.environ.get("TMUX_PANE"):
    tmux = subprocess.run(["tmux", "display", "-p", "-t", os.environ["TMUX_PANE"],
                           "#{session_name}:#{window_id}.#{pane_id}"], capture_output=True, text=True).stdout.strip()
if args.tmux_override is not None:
    tmux = args.tmux_override or None
lstart = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)], capture_output=True, text=True,
                        env={**os.environ, "TZ": "UTC", "LC_ALL": "C"}).stdout.strip()
now_ms = int(time.time() * 1000)
doc = {"pid": pid, "sessionId": args.uuid, "cwd": os.getcwd(), "startedAt": now_ms, "procStart": lstart,
       "kind": args.kind, "entrypoint": "cli", "tmux": tmux, "name": args.name, "status": args.status,
       "updatedAt": now_ms, "statusUpdatedAt": now_ms - 3_600_000}
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path + ".tmp", "w") as f:
    json.dump(doc, f)
os.replace(path + ".tmp", path)


def on_term(signum, frame):
    with open(args.term_file, "a") as f:
        f.write(f"SIGTERM {pid}\n")
    if args.ignore_term:
        return
    try:
        os.remove(path)
    except OSError:
        pass
    sys.stdout.write("\033[?1049l")
    sys.stdout.flush()
    sys.exit(0)


signal.signal(signal.SIGTERM, on_term)
sys.stdout.write("\033[?1049h\033[H")   # alternate screen, like Claude Code
sys.stdout.write(f"FAKE-CLAUDE-SCREEN {args.uuid}\n> last answer of the fake Claude session\n")
sys.stdout.flush()
if args.exec_after:
    with open(args.exec_out, "w") as out:
        subprocess.run(args.exec_after, shell=True, stdout=out, stderr=subprocess.STDOUT)
while True:
    time.sleep(1)
