# Testing agent-auto-close

```bash
bash /Users/jeanlescut/dev/agent-auto-close/tests/run_tests.sh
```

Runs in a sandbox (`mktemp -d`): its own `HOME`, `CLAUDE_CONFIG_DIR` and a separate tmux server (`TMUX_TMPDIR`, `TMUX` unset); install.sh and uninstall.sh run with that `HOME`. Fake Claude sessions are `tests/fake_claude.py` processes started in the sandbox's tmux panes. It prints one line per failure and the totals; the full log is `<sandbox>/test.log` (path printed). Takes about 30 s (one test waits the 5 s SIGTERM timeout).

| Part | Checks |
|---|---|
| install / uninstall | the link points into `~/opt/agent-auto-close`, re-run is idempotent, nothing in the real HOME, uninstall keeps data and logs |
| refusals | unknown uuid, busy, self (env and process tree), not in tmux, kind not interactive, pid gone, pid reused, pane gone, pane not holding the pid, ambiguous prefix; none sends a signal |
| close | by uuid prefix and by `%pane`: ended by SIGTERM, screen file, screen shown in the pane, `claude --resume <uuid>` typed but not run, log row; no exit after SIGTERM leaves the pane untouched |
| idle | picks idle + last prompt older than N h only (a newer tool result is not a prompt), dry run closes nothing, uses `agent-tracker now --json`'s last prompt when installed |
