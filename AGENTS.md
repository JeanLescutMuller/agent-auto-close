# agent-auto-close

**Closing Claude sessions: by hand (`close`, was `asm close`) and the rule for closing idle ones (`idle`), each leaving the Claude session resumable in its tmux pane.** Part of agent-tracker v1 (`/Users/jeanlescut/dev/agent-tracker/DESIGN.md` §10, `IMPLEMENTATION.md` §5).

## Rules

- **Never send a signal or keys to anything a test did not start.** Tests run only in the sandbox of `tests/run_tests.sh`: `HOME`, `CLAUDE_CONFIG_DIR`, `AGENT_AUTO_CLOSE_HOME`, `TMUX_TMPDIR` inside `mktemp -d`, with `TMUX` unset (else tmux talks to the user's default server). Never run `install.sh` / `uninstall.sh` with the real `HOME` unless the user asks.
- **Every safety check runs before anything is captured or signalled** (`check_closeable` in `src/agent-auto-close`): not self (`CLAUDE_CODE_SESSION_ID`, or the Claude process is an ancestor of this command), not busy, kind `interactive`, in tmux, pid alive, pid start time = the sessions file's `procStart`, the pane exists and holds the pid. A new check goes there, never after the capture.
- **SIGTERM only, never SIGKILL**: Claude Code flushes its transcript on SIGTERM. If it has not exited after 5 s, leave the pane untouched and exit 1.
- **The pid, status and kind come only from `$CLAUDE_CONFIG_DIR/sessions/<pid>.json`.** `agent-tracker now --json` (when on the PATH) only adds the last prompt, the pane and the transcript path.
- **No scheduler**: when `idle` runs is not decided (the user, 2026-11-07). Do not add a trigger without the user; when one is added, follow skill `jobs-and-services`.
- `close` is a faithful port of `asm close` (agent-session-manager `src/asm` v4.7, lines 1538-1750): keep its behavior unless the user changes it.

## Commands

| | |
|---|---|
| test | `bash tests/run_tests.sh` (sandbox; ~30 s; one line per failure, full log path printed) |
| deploy | `bash install.sh` (→ `~/opt/agent-auto-close/bin/`, link `~/.local/bin/agent-auto-close`); remove: `bash ~/opt/agent-auto-close/uninstall.sh` |

## Vocabulary

The only words for these concepts, in every file and when talking to the user. A new word is added here first, with the user's agreement.

| Word | Means | Never say |
|---|---|---|
| **Claude session** | one running Claude Code process, known by its uuid and its `sessions/<pid>.json` | conversation, instance |
| **close** | capture the pane, SIGTERM the Claude process, write the screen file, pre-type `claude --resume <uuid>` in the pane | kill, stop, terminate (for the whole act) |
| **screen file** | `data/close-screens/<uuid>.txt`: the pane's last screen, cat back into the pane after the close | tombstone (asm's word) |
| **busy** / **idle** | the `status` Claude Code writes in `sessions/<pid>.json` | active, inactive |
| **last prompt** | the time of the transcript's last `user` entry that is not a tool result | last activity, last message |
| **pane** | a tmux pane, addressed by its `%id` | terminal, tab |

## Where to look

| | |
|---|---|
| the code (one file) | `src/agent-auto-close` |
| the fake Claude used by tests | `tests/fake_claude.py` |
| the contract with agent-tracker and agent-resume | `/Users/jeanlescut/dev/agent-tracker/IMPLEMENTATION.md` §3-§5 |
