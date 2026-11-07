#!/usr/bin/env bash
# tests/run_tests.sh - agent-auto-close's tests, in a sandbox only.
#
# Sandbox: S=$(mktemp -d); HOME, CLAUDE_CONFIG_DIR, AGENT_AUTO_CLOSE_HOME and TMUX_TMPDIR all point inside it,
# so tmux is a separate server (never the user's default one) and install.sh writes only under $S/home.
# Fake Claude sessions = tests/fake_claude.py, started by this script in panes of the sandbox tmux server;
# only processes this script started are ever signalled.
#
# Usage: bash tests/run_tests.sh            prints one line per failure and the totals; details in $S/test.log
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAKE="$REPO/tests/fake_claude.py"
S=$(cd "$(mktemp -d)" && pwd -P)   # the real path: tmux reports its socket by it
REAL_HOME=$HOME
LOG="$S/test.log"
PY_DIR=$(dirname "$(command -v python3)")
TMUX_DIR=$(dirname "$(command -v tmux)")

# -- The sandbox: every path the tool or tmux uses is under $S ----------------
unset TMUX TMUX_PANE CLAUDE_CODE_SESSION_ID AGENT_AUTO_CLOSE_HOME
export SANDBOX="$S" HOME="$S/home" CLAUDE_CONFIG_DIR="$S/home/.claude" TMUX_TMPDIR="$S/tmux" JR_MACHINE_NAME=test-machine
export AGENT_TRACKER_HOME="$S/home/opt/agent-tracker" AGENT_RESUME_HOME="$S/home/opt/agent-resume"
export PATH="$S/bin:$S/home/.local/bin:$PY_DIR:$TMUX_DIR:/usr/bin:/bin:/usr/sbin:/sbin"
mkdir -p "$HOME" "$CLAUDE_CONFIG_DIR/sessions" "$CLAUDE_CONFIG_DIR/projects/-sandbox" "$TMUX_TMPDIR" "$S/bin"
SOCK="$TMUX_TMPDIR/tmux-$(id -u)/default"   # where tmux puts its socket under TMUX_TMPDIR
mkdir -p -m 700 "$(dirname "$SOCK")"
tmx() { tmux -S "$SOCK" "$@"; }
for v in HOME CLAUDE_CONFIG_DIR TMUX_TMPDIR; do
    [[ "${!v}" == "$S"/* ]] || { echo "ABORT: $v=${!v} is not in the sandbox" >&2; exit 2; }
done
command -v agent-tracker >/dev/null && { echo "ABORT: an agent-tracker outside the sandbox is on the PATH" >&2; exit 2; }

AAC="$HOME/.local/bin/agent-auto-close"
TERM_LOG="$S/term.log"; touch "$TERM_LOG"
PASS=0; FAIL=0
L_STARTED=()          # pids of the fake Claude sessions and helpers this script started

ok()   { PASS=$((PASS + 1)); echo "PASS $1" >> "$LOG"; }
bad()  { FAIL=$((FAIL + 1)); echo "FAIL $1" | tee -a "$LOG"; }
check() { local name=$1; shift; if "$@" >> "$LOG" 2>&1; then ok "$name"; else bad "$name"; fi; }
alive() { kill -0 "$1" 2>/dev/null; }
dead()  { ! kill -0 "$1" 2>/dev/null; }
has()   { grep -qF -- "$2" "$1"; }

ours() {   # true only if pid is still one of the processes this script started (guards against pid reuse)
    [[ -n "$1" ]] && ps -o command= -p "$1" 2>/dev/null | grep -qE "fake_claude\.py|^sleep 300"
}
kill_ours() { local sig=$1 p=$2; ours "$p" && kill "$sig" "$p" 2>/dev/null; }

cleanup() {
    local p
    for p in "${L_STARTED[@]:-}"; do kill_ours -9 "$p"; done
    [[ -S "$SOCK" ]] && tmx kill-server 2>/dev/null
}
trap cleanup EXIT

uuid_of() { python3 -c 'import uuid,sys; print(sys.argv[1] + str(uuid.uuid4())[len(sys.argv[1]):])' "${1:-}"; }

pid_of() {   # the pid in the sessions file of a uuid
    python3 - "$1" <<'PY'
import glob, json, os, sys
for p in glob.glob(os.path.join(os.environ["CLAUDE_CONFIG_DIR"], "sessions", "*.json")):
    d = json.load(open(p))
    if d.get("sessionId") == sys.argv[1]:
        print(d["pid"]); break
PY
}

wait_for_session() {   # until the fake has written its sessions file (5 s max)
    local i
    for i in $(seq 50); do [[ -n "$(pid_of "$1")" ]] && return 0; sleep 0.1; done
    echo "fake Claude session $1 did not start" >> "$LOG"; return 1
}

start_fake() {   # start_fake <uuid> <status> [fake_claude args…]: in a new window of the sandbox tmux server; sets FAKE_PANE
    local uuid=$1 status=$2; shift 2
    FAKE_PANE=$(tmx new-window -d -P -F '#{pane_id}' -c "$S" "bash --norc --noprofile")
    tmx send-keys -t "$FAKE_PANE" "PS1='$ '; python3 $FAKE --uuid $uuid --status $status --term-file $TERM_LOG $*" Enter
    wait_for_session "$uuid" && L_STARTED+=("$(pid_of "$uuid")")
}

write_transcript() {   # write_transcript <uuid> <hours since the last prompt>: a prompt, then a newer tool result
    python3 - "$1" "$2" "$CLAUDE_CONFIG_DIR/projects/-sandbox/$1.jsonl" <<'PY'
import json, sys, time
from datetime import datetime, timezone
uuid, h, path = sys.argv[1], float(sys.argv[2]), sys.argv[3]
iso = lambda t: datetime.fromtimestamp(t, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
now = time.time()
rows = [
    {"type": "user", "message": {"role": "user", "content": "an older prompt"}, "timestamp": iso(now - h * 3600 - 600)},
    {"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": "the last prompt"}]}, "timestamp": iso(now - h * 3600)},
    {"type": "assistant", "message": {"role": "assistant", "content": "working"}, "timestamp": iso(now - h * 3600 + 10)},
    {"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t1", "content": "ok"}]}, "timestamp": iso(now - 60)},
    {"type": "assistant", "message": {"role": "assistant", "content": "done"}, "timestamp": iso(now - 30)},
]
with open(path, "w") as f:
    for r in rows:
        f.write(json.dumps({"sessionId": uuid, **r}) + "\n")
PY
}

run() {   # run <outfile> <args…>: agent-auto-close's exit code in $RC, its output in <outfile>
    local out=$1; shift
    "$AAC" "$@" > "$out" 2>&1; RC=$?
    { echo "--- agent-auto-close $* (exit $RC)"; cat "$out"; } >> "$LOG"
}

stop_fake() {   # SIGTERM one fake this script started, and wait for it
    local pid=$1 i
    kill_ours -TERM "$pid"
    for i in $(seq 30); do ours "$pid" || return 0; sleep 0.1; done
    kill_ours -9 "$pid"
}

echo "sandbox: $S" > "$LOG"

# -- 1. install.sh, only with HOME=<sandbox> ---------------------------------------
# The real install (the tool is deployed since 2026-11-07): its files and link must not change during the suite.
real_install_fp() { { find "$REAL_HOME/opt/agent-auto-close" -type f -exec md5 -q {} \; 2>/dev/null; readlink "$REAL_HOME/.local/bin/agent-auto-close"; } | md5 -q; }
REAL_FP_BEFORE=$(real_install_fp)
bash "$REPO/install.sh" >> "$LOG" 2>&1; check "install exits 0" test $? -eq 0
check "install: link in ~/.local/bin points into ~/opt/agent-auto-close" test "$(readlink "$AAC")" = "$HOME/opt/agent-auto-close/bin/agent-auto-close"
check "install: deployed copy runs" "$AAC" --version
bash "$REPO/install.sh" >> "$LOG" 2>&1; check "install: re-run is idempotent" test $? -eq 0 -a -L "$AAC"
check "install: nothing written in the real HOME" test "$(real_install_fp)" = "$REAL_FP_BEFORE"

# -- 2. the sandbox tmux server ---------------------------------------------------------
tmx new-session -d -s test -x 200 -y 50 -c "$S" "bash --norc --noprofile"
check "tmux: the server's socket is the sandbox one (or tmux_guard's)" test "$(tmux display -p '#{socket_path}')" = "${TMUX_GUARD_SOCKET:-$SOCK}"
PANE0=$(tmx display -p -t test:0 '#{pane_id}')

# -- 3. refusals: nothing is signalled ------------------------------------------------
O="$S/out.txt"
run "$O" close "$(uuid_of)"
check "unknown uuid: refused" test $RC -eq 1
check "unknown uuid: says so" has "$O" "no running Claude session matches"

U_BUSY=$(uuid_of b0); start_fake "$U_BUSY" busy ; P_BUSY=$(pid_of "$U_BUSY")
run "$O" close "$U_BUSY"
check "busy: refused" test $RC -eq 1
check "busy: says busy" has "$O" "busy (mid-task)"
check "busy: still running" alive "$P_BUSY"

U_SELF=$(uuid_of 5e); start_fake "$U_SELF" idle ; P_SELF=$(pid_of "$U_SELF")
CLAUDE_CODE_SESSION_ID="$U_SELF" "$AAC" close "$U_SELF" > "$O" 2>&1; RC=$?; cat "$O" >> "$LOG"
check "self (CLAUDE_CODE_SESSION_ID): refused" test $RC -eq 1
check "self (CLAUDE_CODE_SESSION_ID): says so" has "$O" "running from"
check "self (CLAUDE_CODE_SESSION_ID): still running" alive "$P_SELF"

U_ANC=$(uuid_of a0); start_fake "$U_ANC" idle --exec-after "'$AAC close $U_ANC'" --exec-out "$S/anc.txt" ; P_ANC=$(pid_of "$U_ANC")
for i in $(seq 50); do has "$S/anc.txt" "ERROR" 2>/dev/null && break; sleep 0.1; done
cat "$S/anc.txt" >> "$LOG" 2>/dev/null
check "self (run from inside the Claude session's process tree): refused" has "$S/anc.txt" "running from"
check "self (process tree): still running" alive "$P_ANC"

U_NOTMUX=$(uuid_of 70)
( cd "$S" && exec python3 "$FAKE" --uuid "$U_NOTMUX" --status idle --term-file "$TERM_LOG" > /dev/null ) &
L_STARTED+=("$!"); P_NOTMUX=$!; wait_for_session "$U_NOTMUX"
run "$O" close "$U_NOTMUX"
check "not in tmux: refused" test $RC -eq 1
check "not in tmux: says so" has "$O" "no tmux pane"
check "not in tmux: still running" alive "$P_NOTMUX"

U_KIND=$(uuid_of 6d); start_fake "$U_KIND" idle --kind sdk ; P_KIND=$(pid_of "$U_KIND")
run "$O" close "$U_KIND"
check "kind not interactive: refused" has "$O" "not 'interactive'"

# a sessions file whose pid has exited
( exit 0 ) & P_GONE=$!; wait "$P_GONE"
U_STALE=$(uuid_of 5a)
echo "{\"pid\":$P_GONE,\"sessionId\":\"$U_STALE\",\"kind\":\"interactive\",\"status\":\"idle\",\"tmux\":\"test:@0.$PANE0\"}" > "$CLAUDE_CONFIG_DIR/sessions/stale.json"
run "$O" close "$U_STALE"
check "stale pid: refused" has "$O" "is not running"

# a sessions file whose pid is running but is another process (wrong start time)
sleep 300 & P_SLEEP=$!; disown; L_STARTED+=("$P_SLEEP")
U_REUSE=$(uuid_of 7e)
echo "{\"pid\":$P_SLEEP,\"sessionId\":\"$U_REUSE\",\"kind\":\"interactive\",\"status\":\"idle\",\"procStart\":\"Thu Jan  1 00:00:00 2026\",\"tmux\":\"test:@0.$PANE0\"}" > "$CLAUDE_CONFIG_DIR/sessions/reuse.json"
run "$O" close "$U_REUSE"
check "reused pid: refused" has "$O" "the pid was reused"
check "reused pid: the other process is not signalled" alive "$P_SLEEP"

U_GONEPANE=$(uuid_of 9a); start_fake "$U_GONEPANE" idle --tmux-override "test:@0.%999" ; P_GONEPANE=$(pid_of "$U_GONEPANE")
run "$O" close "$U_GONEPANE"
check "pane gone: refused" has "$O" "no longer exists"

U_WRONGPANE=$(uuid_of 9b); start_fake "$U_WRONGPANE" idle --tmux-override "test:@0.$PANE0" ; P_WRONGPANE=$(pid_of "$U_WRONGPANE")
run "$O" close "$U_WRONGPANE"
check "pane does not hold the pid: refused" has "$O" "does not hold pid"
check "pane does not hold the pid: still running" alive "$P_WRONGPANE"
check "pane does not hold the pid: no key sent to that pane" bash -c "! tmux -S '$SOCK' capture-pane -p -t '$PANE0' | grep -q 'claude --resume'"

U_AMB1=$(uuid_of abcd1); U_AMB2=$(uuid_of abcd2)
start_fake "$U_AMB1" idle ; start_fake "$U_AMB2" idle
run "$O" close abcd
check "ambiguous uuid prefix: refused" has "$O" "several running Claude sessions match"
check "ambiguous uuid prefix: both still running" alive "$(pid_of "$U_AMB1")"

check "refusals: no SIGTERM was sent" test ! -s "$TERM_LOG"
check "refusals: logged" test "$(grep -c '"event": "refused"' "$HOME/opt/agent-auto-close/logs/close.jsonl")" -eq 9

# -- 4. the close itself ---------------------------------------------------------------
verify_closed() {   # verify_closed <label> <uuid> <pid> <pane>
    local label=$1 uuid=$2 pid=$3 pane=$4 screen="$HOME/opt/agent-auto-close/data/close-screens/$2.txt"
    sleep 0.5
    check "$label: exit 0" test $RC -eq 0
    check "$label: process ended" dead "$pid"
    check "$label: ended by SIGTERM" has "$TERM_LOG" "SIGTERM $pid"
    check "$label: sessions file gone" test -z "$(pid_of "$uuid")"
    check "$label: screen file has the captured screen" has "$screen" "FAKE-CLAUDE-SCREEN $uuid"
    check "$label: screen file has the CLOSED header" has "$screen" "───── CLOSED "
    tmx capture-pane -p -S - -t "$pane" > "$S/pane.txt"   # with the scrollback: the screen file is taller than the pane; cat "$S/pane.txt" >> "$LOG"
    check "$label: pane shows the screen file" has "$S/pane.txt" "FAKE-CLAUDE-SCREEN $uuid"
    check "$label: 'claude --resume <uuid>' pre-typed, not run" test "$(grep -v '^ *$' "$S/pane.txt" | tail -1)" = "\$ claude --resume $uuid"
    check "$label: logged" has "$HOME/opt/agent-auto-close/logs/close.jsonl" "\"event\": \"close\", \"by\": \"hand\", \"uuid\": \"$uuid\""
}

U_C1=$(uuid_of); start_fake "$U_C1" idle; PANE_C1=$FAKE_PANE; P_C1=$(pid_of "$U_C1")
run "$O" close "${U_C1:0:8}"
verify_closed "close by uuid prefix" "$U_C1" "$P_C1" "$PANE_C1"

U_C2=$(uuid_of); start_fake "$U_C2" idle; PANE_C2=$FAKE_PANE; P_C2=$(pid_of "$U_C2")
run "$O" close "$PANE_C2"
verify_closed "close by %pane" "$U_C2" "$P_C2" "$PANE_C2"

U_STUCK=$(uuid_of); start_fake "$U_STUCK" idle --ignore-term; PANE_STUCK=$FAKE_PANE; P_STUCK=$(pid_of "$U_STUCK")
run "$O" close "$U_STUCK"
check "no exit after SIGTERM: fails" test $RC -eq 1
check "no exit after SIGTERM: says so" has "$O" "did not exit within"
check "no exit after SIGTERM: process not SIGKILLed" alive "$P_STUCK"
check "no exit after SIGTERM: pane left untouched" bash -c "! tmux -S '$SOCK' capture-pane -p -t '$PANE_STUCK' | grep -q 'claude --resume'"
kill_ours -9 "$P_STUCK"

check "log rows start with ts then dt" python3 -c '
import json, sys
for l in open(sys.argv[1]):
    k = list(json.loads(l))[:2]
    assert k == ["ts", "dt"], k' "$HOME/opt/agent-auto-close/logs/close.jsonl"

# -- 5. idle --over <hours> -------------------------------------------------------------------
for p in "$P_BUSY" "$P_SELF" "$P_ANC" "$P_NOTMUX" "$P_KIND" "$P_GONEPANE" "$P_WRONGPANE" "$(pid_of "$U_AMB1")" "$(pid_of "$U_AMB2")"; do stop_fake "$p"; done
mkdir -p "$S/set-aside"   # files moved out of the way (never deleted: the sandbox is kept for reading)
mv "$CLAUDE_CONFIG_DIR/sessions/stale.json" "$CLAUDE_CONFIG_DIR/sessions/reuse.json" "$CLAUDE_CONFIG_DIR/sessions/$P_STUCK.json" "$S/set-aside/"
: > "$TERM_LOG"

U_I1=$(uuid_of 11); write_transcript "$U_I1" 30; start_fake "$U_I1" idle; PANE_I1=$FAKE_PANE; P_I1=$(pid_of "$U_I1")
U_I2=$(uuid_of 22); write_transcript "$U_I2" 2;  start_fake "$U_I2" idle ; P_I2=$(pid_of "$U_I2")
U_I3=$(uuid_of 33); write_transcript "$U_I3" 48; start_fake "$U_I3" busy ; P_I3=$(pid_of "$U_I3")
U_I4=$(uuid_of 44);                               start_fake "$U_I4" idle ; P_I4=$(pid_of "$U_I4")

run "$O" idle --over 24 --dry-run
check "idle dry run: exit 0" test $RC -eq 0
check "idle dry run: counts 1 of 4" has "$O" "1 of 4 running Claude sessions"
check "idle dry run: picks the 30 h one" has "$O" "${U_I1:0:8}  last prompt 1d6h ago"
check "idle dry run: would close it" has "$O" "would close (pane $PANE_I1)"
check "idle dry run: not the 2 h one (the newer tool result is not a prompt)" bash -c "! grep -q '${U_I2:0:8}  last' '$O'"
check "idle dry run: not the busy one" bash -c "! grep -q '${U_I3:0:8}' '$O'"
check "idle dry run: says the one without a transcript is skipped" has "$O" "skipped ${U_I4:0:8}"
check "idle dry run: nothing closed" alive "$P_I1"

run "$O" idle --over 24
check "idle: exit 0" test $RC -eq 0
sleep 0.5
check "idle: the 30 h one ended by SIGTERM" has "$TERM_LOG" "SIGTERM $P_I1"
check "idle: the 30 h one has its resume pre-typed" bash -c "tmux -S '$SOCK' capture-pane -p -t '$PANE_I1' | grep -v '^ *\$' | tail -1 | grep -qxF '\$ claude --resume $U_I1'"
check "idle: logged with the rule" has "$HOME/opt/agent-auto-close/logs/close.jsonl" "\"by\": \"idle --over 24\", \"uuid\": \"$U_I1\""
check "idle: the 2 h one still running" alive "$P_I2"
check "idle: the busy one still running" alive "$P_I3"
check "idle: the one without a transcript still running" alive "$P_I4"

run "$O" idle --over 1 --dry-run
check "idle --over 1: picks the 2 h one" has "$O" "${U_I2:0:8}  last prompt 2h0m ago"

run "$O" idle --over 0
check "idle --over 0: rejected" test $RC -eq 2

# agent-tracker now --json, when installed, gives the last prompt
cat > "$S/bin/agent-tracker" <<EOF
#!/bin/sh
[ "\$1 \$2" = "now --json" ] || exit 1
echo '[{"uuid":"$U_I2","pane":"test:1.0","status":"idle","last_prompt":{"ts":$(( $(date +%s) - 50 * 3600 )),"dt":"x"}}]'
EOF
chmod +x "$S/bin/agent-tracker"
run "$O" idle --over 24 --dry-run
check "agent-tracker's last prompt is used" has "$O" "${U_I2:0:8}  last prompt 2d2h ago"
mv "$S/bin/agent-tracker" "$S/set-aside/"

# -- 6. uninstall.sh ------------------------------------------------------------------------
bash "$HOME/opt/agent-auto-close/uninstall.sh" >> "$LOG" 2>&1; check "uninstall exits 0" test $? -eq 0
check "uninstall: link removed" test ! -e "$AAC" -a ! -L "$AAC"
check "uninstall: deployed copy removed" test ! -e "$HOME/opt/agent-auto-close/bin/agent-auto-close"
check "uninstall: screen files and log kept" test -s "$HOME/opt/agent-auto-close/logs/close.jsonl" -a -d "$HOME/opt/agent-auto-close/data/close-screens"

echo "agent-auto-close tests: $PASS passed, $FAIL failed (log: $LOG)"
[[ $FAIL -eq 0 ]]
