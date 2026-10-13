# What the port relies on in GitHub Copilot CLI

Checked against GitHub Copilot CLI 1.0.96 on macOS, 2026-10-13, with real runs. Re-check with `copilot --help` after an update.

## Flags the dispatcher sends

| Flag | Why |
|------|-----|
| `-p "<prompt>"` | Non-interactive: run one prompt, exit. Exit code is 0 on success, 1 on error. |
| `-s` | Only the agent's final message on stdout, which is what `.out` captures. |
| `--model <id>` | The agent's model. An id the plan does not offer fails before any work: `Error: Model "x" from --model flag is not available.` on stderr, exit 1. The dispatcher reports that as `CRASHED`; `retry` sends it to the stand-in. |
| `--allow-all-tools --allow-all-paths --no-ask-user` | Headless: no approval prompts, no path prompts, no `ask_user` tool. `--allow-all-tools` is required for `-p` anyway. |
| `--deny-tool=write` | Read-only mode. Denies the file-creating and file-editing tools; deny rules win over `--allow-all-tools`. The shell stays, so the worker can still tick its run files. Verified: the worker reports the edit tool as refused and `ls` still runs. |
| `--session-id <uuid>` | Starts a new session with that id. The session lands in `~/.copilot/session-state/<uuid>/` and `workspace.yaml` there records it. Verified. |
| `--resume <id>` | Continues that session, non-interactively, with its prior context. Verified: a resumed worker remembered the file it created in the first run. Also accepts the `-n` name and a 7+ character id prefix. |
| `-n sar-<agent>-<task>` | Names the session so it is easy to find in `copilot --resume`. Only sent on a fresh session. |
| `-C <project root>` | Working directory for the worker, so relative paths in the brief resolve. |

Pass-through examples for `-- <args>`: `--reasoning-effort high` (none, minimal, low, medium, high, xhigh, max), `--max-ai-credits 60` (soft cap per session, minimum 30), `--context long_context`.

## Environment

`SAR_WORKER=1` is exported into the worker process and reaches the shells it spawns (verified: a worker printed it). `sar.sh` refuses to dispatch when it is set, and SKILL.md tells a worker that sees it to do the task itself. That is the guard against a worker in the same repo discovering `.github/skills/sar` and fanning out.

`COPILOT_MODEL` would set a default model, but the dispatcher always passes `--model`, which overrides it.

## Model ids

Ids the CLI knows (from its own model catalog in the debug log). Which of them answer depends on the account's plan; `tests/smoke.sh` checks.

```
claude-haiku-5.5   claude-haiku-4.5   claude-sonnet-5.5   claude-sonnet-5   claude-opus-5.5   claude-opus-5   claude-fable-5.1   claude-fable-5
gpt-6.1-sol   gpt-6-sol   gpt-6-luna   gpt-6-astra   gpt-5.6-sol   gpt-5.6-terra   gpt-5.6-luna   gpt-5.5   gpt-5.4   gpt-5.4-mini   gpt-5.4-nano   gpt-5.3-codex
gemini-3.8-flash   gemini-3.7-flash   kimi-k3   mai-code-1.1-flash   auto
```

On a free account only `auto` works (it routed to GPT-5.6 Luna when tested); every explicit id returns "not available".

## Quota

Could not trigger an exhausted budget on purpose. The dispatcher treats a non-zero exit whose stdout or stderr matches any of `429`, `usage limit`, `rate limit`, `quota`, `too many requests`, `AI credit`, `premium request`, `limit reached` / `exceeded` or `budget` as `QUOTA`. If a real exhaustion message on your plan says something else, add it to the regex in `sar.sh` and to test 22.

## Skills

Discovered from `.github/skills/`, `.agents/skills/` or `.claude/skills/` in the project, and `~/.copilot/skills/` or `~/.agents/skills/` personally. `copilot skill list` shows them; `copilot skill add <dir|url>` installs one. Frontmatter needs `name` and `description`; the folder may ship `scripts/`.

## Status line

`~/.copilot/settings.json` takes `"statusLine": {"type": "command", "command": "<script>", "padding": 0}`. The script gets JSON on stdin with `cwd`, `workspace.current_dir`, `model`, `session_id`, `context_window` and more, and its stdout is shown. Repo-level settings cannot set it. `statusline/statusline-sar.sh` reads `cwd` (falling back to `workspace.current_dir`), the same keys the original read.

## Background runs from the orchestrator

The Copilot CLI shell tool can run a command as a background task (`/tasks` lists subagents and shell commands). SKILL.md tells the orchestrator to dispatch that way, or with `nohup ... &` if the tool offers no background mode in a given version, and to check `sar.sh ps` at natural pauses rather than polling.
