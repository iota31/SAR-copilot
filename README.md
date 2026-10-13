# SAR for GitHub Copilot CLI - Smart Agent Routing

Route work out of an expensive orchestrating Copilot CLI session and into cheaper models that run headless in the background.

SAR is a [GitHub Copilot CLI](https://docs.github.com/copilot/how-tos/copilot-cli) skill plus a dispatcher script. Once invoked, the orchestrating session stops doing the work itself and instead decomposes, briefs, routes and verifies, while Claude Haiku, Claude Sonnet, GPT 6.1 Sol and the rest do the actual work in parallel, headless, each as its own `copilot -p` process.

Everything travels through files on disk, so a run survives context compaction, a crashed worker, a quota stop or a closed laptop.

This is a port of [SAR for Claude Code](https://github.com/prakersh/SAR) to the Copilot CLI. Same file contract, same subcommands, same states, same tests; the agent roster and the worker invocation are the parts that changed.

## Why

The session you are sitting in is the most expensive model in the loop, and most of what it is asked to do does not need it. Running a test suite, writing boilerplate, sweeping a codebase for a symbol: none of that needs the top model, and all of it burns the context window you would rather spend on the parts that do.

SAR moves that work to separate Copilot CLI processes, invoked with `-p` so they run non-interactively, in the background, on a cheaper model, writing to files rather than into the chat transcript.

Three properties matter more than the routing:

- **The transcript stops being the state.** Briefs go into `.task.md` files, answers come back in `.result.md` files. Nothing is lost to compaction, and any run can be read, resumed or audited later.
- **Long runs stay visible.** Each worker keeps a checked-off subtask list and appends to a journal as it goes, so a 25-minute task is not a black box.
- **Failures are recoverable.** A stopped run resumes with `--resume`, keeping its Copilot session, journal and progress; a broken one is handed to the next agent with `retry`, which carries its context forward.

## What it looks like

A dispatch prints exactly one line when it finishes, so a background run costs the orchestrator almost no context:

```
sar sn 01-token-store: DONE (212s, 4/4 subtasks, checks: 3 PASS 0 FAIL) result: /path/.sar/20261013-1210-auth-refresh/01-token-store.result.md
```

The optional status line segment, while a review and a test run are in flight:

```
sar ● sol:2/5 Read-only verification 12m   ● hk:7/7 all subtasks 4m
```

## Requirements

- **GitHub Copilot CLI** 1.0.96 or later, logged in (`copilot login`). Install with `brew install copilot-cli` or `npm install -g @github/copilot`.
- **A Copilot plan that offers model selection.** On the free plan only `--model auto` works; the `auto` agent in the roster covers that case.
- **`jq`**, only for the optional status line segment.

SAR ships no credentials and calls no API directly; every worker is a `copilot` process using whatever account the CLI is logged into.

## Install

As a personal skill, available in every project:

```bash
git clone https://github.com/iota31/SAR-copilot.git
cd SAR-copilot
bash install.sh              # copies the skill to ~/.copilot/skills/sar
bash install.sh --statusline # also copies the status line segment
```

Or per project: copy `.github/skills/sar/` into the repository, where Copilot CLI discovers it automatically.

Check the roster resolves on your account:

```bash
bash tests/smoke.sh
```

It sends one tiny prompt to each roster model and prints `OK` or `NOT ON THIS PLAN` per agent. A model your plan does not offer costs nothing: the CLI refuses it before any request is made.

## The roster

| Agent | Model | Role |
|-------|-------|------|
| `hk` | `claude-haiku-5.5` | Operator, default for fully specified work, cheapest |
| `sn` | `claude-sonnet-5.5` | Workhorse for work that needs judgement |
| `sol` | `gpt-6.1-sol` | Reviewer and final judge |
| `terra` | `gpt-5.6-terra` | Rare fallback for a fully specified edit |
| `gem` | `gemini-3.8-flash` | Backup operator when `hk` is down or out of quota |
| `auto` | `auto` | Copilot picks; the only choice on the free plan |

Swap any model without editing the script, through the environment:

```bash
export SAR_MODEL_HK=claude-haiku-4.5
export SAR_MODEL_SOL=gpt-6-sol
export SAR_IMAGE_BLIND="gem"        # agents whose model cannot take images
```

`bash .github/skills/sar/scripts/sar.sh agents` prints the roster with overrides applied. See [Adding an agent](#adding-an-agent) for a permanent change.

## Use

Invoke the skill in a Copilot CLI session:

```
/sar
```

Or just ask for it: "use sar", "smart agent routing", "route this to the agents", or any request to delegate or fan out work. From that point the session routes every task through SAR for the rest of the conversation, including after compaction. Say "stop using sar" to end it.

To dispatch by hand, without the skill:

```bash
bash ~/.copilot/skills/sar/scripts/sar.sh hk .sar/<run>/01-token-store.task.md
```

## The brief

The worker starts with no knowledge of your conversation, so the brief is everything it knows. Write one file per task under `.sar/<YYYYMMDD-HHMM>-<slug>/`:

````markdown
# Token store

## Goal
Persist refresh tokens so a 401 can be retried once.

## Context
Read `.sar/<run>/00-recon.result.md` first. The auth middleware is in `src/auth/`.

## Scope
`src/auth/` only.

## Subtasks
- [ ] Add the store
- [ ] Wire the middleware
- [ ] Write the test
- [ ] Run the suite and write the report

## Done when
```bash
pytest tests/auth
```

## Report
Anything odd you noticed in the existing middleware.
````

Two sections do double duty:

- **`## Subtasks`** is copied to `<task>.progress.md` at dispatch and ticked by the worker as it finishes. This is what the status line and `sar.sh ps` read.
- **`## Done when`** fenced commands are what `sar.sh verify <task>` runs, and they are quoted back in the worker's report as `PASS`/`FAIL` lines.

## Routing

| Agent | Send it | Do not send it |
|-------|---------|----------------|
| `hk` | Test suites, builds, installs, emulator or browser sessions, screenshot capture, mechanical edits and renames, lint fixes, locating code | Reviews, or anything asking its opinion on quality |
| `sn` | Multi-file features, refactors, root-causing, and text where someone must decide what matters | A long checklist in one brief |
| `sol` | Every review, including visual; architecture decisions; security- or data-sensitive changes | More than ~15 images in one task |
| `terra` | A fully specified edit the others cannot take | Anything needing judgement |
| `gem` | An `hk` task, only when `hk` has crashed or hit its quota | Anything while `hk` is up |
| `auto` | An `hk` task on a plan with no model selection | Anything on a plan where the named models work |

The short version: operating things and exact changes go to `hk`, judgement goes to `sn`, verdicts go to `sol`. When unsure between `hk` and `sn`, pick `sn`; a judgement task sent to `hk` costs a whole extra round.

Escalation is once per level: `hk` fails, then `sn`; `sn` fails, then `sol`; `sol` fails, then tell the user. `CRASHED` is treated as an agent problem, not a task problem, and goes to the stand-in instead.

## Watching a run

```bash
sar.sh ps                     # live runs in this project
sar.sh ps --all               # every run, finished ones too
sar.sh status --all           # same data, different name
sar.sh stop <task>            # TERM the worker tree, record CANCELLED
sar.sh verify <task>          # run the brief's Done-when checks
sar.sh retry <task>           # next attempt, routed, with context carried over
sar.sh agents                 # print the roster
```

Dispatch options worth knowing:

```bash
--ro                    # read-only: file-editing tools denied, but the run still has a checklist
--lock <name>           # serialise tasks that share a device or a build daemon
--resume [<id>]         # continue a stopped run in its own Copilot session
--allow-images          # let an SAR_IMAGE_BLIND agent take a brief that names image files
--timeout <seconds>     # default 1800
-- <copilot args>       # pass-through, e.g. -- --reasoning-effort high, or -- --max-ai-credits 60
```

`ps` output:

```
sol 04c-reel-sol RUNNING 2/5 subtasks 12m progress: .../04c-reel-sol.progress.md report: .../04c-reel-sol.report.md
```

The files a dispatch leaves beside the brief:

| File | What it is |
|------|------------|
| `<task>.task.md` | The brief |
| `<task>.progress.md` | Subtask checklist, ticked live, plus the run's state |
| `<task>.report.md` | Running journal, appended after each subtask |
| `<task>.result.md` | The final report the orchestrator reads |
| `<task>.status` | key=value record: agent, model, state, pid, session, timings |
| `<task>.out`, `<task>.log` | Worker stdout and stderr |
| `<task>.attemptN.*` | An earlier attempt kept by `--resume` |

States: `DONE`, `DONE_WITH_NOTES`, `BLOCKED`, `FAILED`, `QUOTA`, `UNMARKED`, `NO_REPORT`, `CRASHED`, `TIMEOUT`, `CANCELLED`, `STALLED`.

- `DONE_WITH_NOTES` means finished but a human decision is needed, and it is only accepted with a `## Resolution` section saying what.
- `QUOTA` means the account's AI credit or premium request budget is exhausted, or a rate limit hit, rather than the agent breaking. The fix is to wait, not to switch agents, and `retry` keeps the same one so a quota wall never sends a judging task to a stand-in.
- `CRASHED` with `Model "..." is not available` in the `.log` means this plan does not offer that model. Point the agent at one it does with `SAR_MODEL_<AGENT>`, or use `auto`.
- `STALLED` means the run still says RUNNING but its dispatcher process is gone.

## Recovering a stopped run

The journal and ticks survive in `<task>.report.md` and `<task>.progress.md`, and the Copilot session id in `<task>.status`. Two ways back:

```bash
# Continue the same session, with its own prior context:
sar.sh sol .sar/<run>/04-review.task.md --resume

# Or hand it to the next agent with the history quoted into a new brief:
sar.sh retry .sar/<run>/04-review.task.md --why "quota crash"
```

`--resume` is cheaper and is usually right when the worker crashed rather than failed. `retry` is for when the work itself needs a different model or a fresh reading of the brief. Resuming archives the previous attempt rather than overwriting it, so history stays readable.

Every worker session is also visible to the CLI itself: `copilot --resume sar-<agent>-<task>` reopens it interactively.

## Tests

The dispatcher is covered by a deterministic suite that uses a stub `copilot` binary, so it runs in seconds and calls no model:

```bash
bash tests/sar-test.sh
```

It covers dispatch, subtask seeding and ticking, resume identity and archiving, read-only mode with its checklist, timeout and cancellation, `stop`, `retry` routing including the `QUOTA` and `CRASHED` cases, `verify` exit codes and temp-dir cleanup, the `DONE_WITH_NOTES` gate, the image guard, lock serialisation and stale-lock reclaim, `ps`/`status` filtering, the roster and model overrides, the worker guard, and the exact flags handed to `copilot`. Point `SAR_SH` at a different dispatcher to test that instead.

`bash tests/smoke.sh` is the one test that talks to the real CLI: it checks which roster models answer on your account.

## Parallelism and locks

Tasks may run in parallel only when they touch disjoint sets of files, because all workers share one working tree. Disjoint files are not enough when a task drives something outside the tree: two tasks that both talk to the emulator, the device, the same database or the same Gradle daemon will interfere even though they edit nothing in common.

Give those tasks the same `--lock <name>` and they queue instead of colliding:

```bash
sar.sh hk .sar/<run>/05-emulator-tests.task.md --lock emulator-5560 &
sar.sh hk .sar/<run>/06-emulator-shots.task.md --lock emulator-5560 &
```

The second waits with a message naming the holder. Locks survive a killed dispatcher: a lock whose holder process is gone is reclaimed rather than blocking the queue forever.

## Adding an agent

Two edits in `.github/skills/sar/scripts/sar.sh` and one row in the routing table in `SKILL.md`:

1. Add the name to `AGENTS`.
2. Add an arm to `agent_model` returning the Copilot model id.

Then `sar.sh agents` should list it. The ids the CLI currently knows are listed in `docs/copilot-cli-notes.md`.

## Notes and limits

- Workers run with `--allow-all-tools --allow-all-paths --no-ask-user`, because a headless run has nobody to approve tool calls or answer questions. Every brief should state its `## Scope`; treat a brief as code you are choosing to run.
- `sar.sh verify` executes the `## Done when` commands from the brief on your machine, in the repo root, with your permissions. It runs only when you invoke it. The brief is your text, but it is arbitrary shell.
- Read-only mode denies the CLI's file-creating and file-editing tools (`--deny-tool=write`), and the worker is told it may edit only its two run files. The shell tool stays available, so a worker that ignores the instruction could still write through a redirect; `--ro` is a guard rail, not a sandbox.
- A worker is itself a Copilot session in the same project and will see this skill. The dispatcher exports `SAR_WORKER=1` into the worker, `sar.sh` refuses to dispatch when it is set, and the skill tells a worker that sees it to do the task itself.
- A long checklist in one brief can make a worker run for an hour and return nothing. Split long jobs into one file, language or section per task.
- `.sar/` is added to `.git/info/exclude` on first dispatch, so run artifacts stay out of commits without touching `.gitignore`.

## Layout

```
.github/skills/sar/SKILL.md            the skill: rules, routing, workflow
.github/skills/sar/scripts/sar.sh      the dispatcher and its subcommands
statusline/statusline-sar.sh           optional status line segment for ~/.copilot/settings.json
install.sh                             copies the skill (and optionally the segment) under ~/.copilot
tests/sar-test.sh                      deterministic suite against a stub copilot
tests/stub/bin/copilot                 the stub
tests/smoke.sh                         asks the real CLI which roster models this account can use
docs/copilot-cli-notes.md              the Copilot CLI flags and behaviours the port relies on, as verified
```
