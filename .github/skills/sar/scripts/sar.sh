#!/usr/bin/env bash
# sar.sh - dispatch one task brief to a headless GitHub Copilot CLI worker running a cheaper model.
#
# Usage:
#   sar.sh <agent> <name>.task.md [--ro] [--timeout <seconds>] [--session-id <uuid>] [--resume [<session-id>]] [--lock <name>] [--allow-images] [-- <extra copilot args>]
#   sar.sh ps [--all] [dir]
#   sar.sh status [--all] [dir]
#   sar.sh stop <name>.task.md
#   sar.sh verify <name>.task.md
#   sar.sh retry <name>.task.md [--as <agent>] [--why <text>] [-- <extra agent args>]
#   sar.sh agents
#
# Leaves these next to the task file:
#   <name>.progress.md  live subtask checklist the worker ticks as it goes
#   <name>.report.md    running journal the worker appends to after each subtask
#   <name>.result.md    the worker's final report (the file the orchestrator reads)
#   <name>.out          the worker's final stdout message
#   <name>.log          the worker's stderr
#   <name>.status       key=value record of the run
#   <name>.attemptN.*   an earlier attempt preserved by a --resume
#
# Prints exactly one line on stdout for a dispatch, so a background run costs the caller almost no context.

set -u

SELF="${BASH_SOURCE[0]:-$0}"

# Agent roster. To add an agent, add its name here and a model in agent_model below.
AGENTS="hk sn sol terra luna auto"

# The Copilot model behind each agent. Ids are what `copilot --model` accepts on a paid plan; `auto` lets Copilot
# pick and is the only choice on the free plan. Override any of them without editing this file through the
# environment: SAR_MODEL_HK=claude-haiku-4.5, SAR_MODEL_SOL=gpt-6-sol, and so on (agent name upper-cased).
agent_model() {
  case "$1" in
    hk)    echo claude-haiku-5.5 ;;
    sn)    echo claude-sonnet-5.5 ;;
    sol)   echo gpt-6.1-sol ;;
    terra) echo gpt-5.6-terra ;;
    luna)   echo gpt-5.6-luna ;;
    auto)  echo auto ;;
    *) return 1 ;;
  esac
}

# Agents whose model cannot take image input; a brief naming an image file is refused for them before the run starts.
# Empty by default because every roster model above is multimodal. Override with SAR_IMAGE_BLIND="luna hk".
IMAGE_BLIND="${SAR_IMAGE_BLIND:-}"

# Sets `launcher` to the command that starts the agent's CLI.
agent_launcher() {
  local m override
  m="$(agent_model "$1")" || return 1
  override="$(eval "printf '%s' \"\${SAR_MODEL_$(printf '%s' "$1" | tr 'a-z' 'A-Z'):-}\"")"
  [ -n "$override" ] && m="$override"
  launcher=(copilot --model "$m")
}

agent_via() {
  echo "${launcher[*]}"
}

# Where a failed run should go next. Reads <agent> <state>; empty means there is no stand-in.
retry_target() {
  local a="$1" st="$2"
  case "$st" in
    # Waiting is the fix for a quota refusal, so the task keeps its agent instead of moving to a stand-in.
    QUOTA | TIMEOUT) echo "$a" ;;
    CRASHED)
      case "$a" in hk) echo luna ;; luna | auto) echo sn ;; sn) echo terra ;; terra) echo sol ;; *) echo "" ;; esac ;;
    BLOCKED | FAILED)
      case "$a" in hk | luna | terra | auto) echo sn ;; sn) echo sol ;; *) echo "" ;; esac ;;
    *) echo "$a" ;;
  esac
}

usage="usage: sar.sh <agent> <name>.task.md [--ro] [--timeout <s>] [--session-id <uuid>] [--resume [<id>]] [--lock <name>] [--allow-images] [-- <args>] | ps|status [--all] [dir] | stop <task> | verify <task> | retry <task> [--as <agent>] [--why <text>] | agents"
die() { echo "sar: $*" >&2; exit 2; }

# Image filenames a brief mentions. An IMAGE_BLIND agent's model fails on image input, so the dispatcher refuses those briefs.
brief_images() {
  grep -oiE '[^[:space:]`"'"'"'()<>]*\.(png|jpe?g|gif|webp|bmp|tiff?|heic)\b' "$1" 2>/dev/null | sort -u
}

# human-readable age of an epoch timestamp
age_of() {
  local secs=$(( $(date +%s) - $1 ))
  [ "$secs" -lt 0 ] && secs=0
  if   [ "$secs" -lt 60 ];   then printf '%ds' "$secs"
  elif [ "$secs" -lt 3600 ]; then printf '%dm' $((secs / 60))
  else                            printf '%dh%02dm' $((secs / 3600)) $(((secs % 3600) / 60))
  fi
}

# Serialise tasks that share a device or a build directory. The disjoint-files rule does not cover those, so a
# task can claim a named lock; a second claimant queues. macOS has no flock, so the lock is a directory, which
# mkdir creates atomically. A lock whose holder is gone is reclaimed, so a killed dispatcher cannot wedge the queue.
acquire_lock() {
  local name="$1" base="$2" dir holder i
  case "$name" in
    '' | *[!A-Za-z0-9._-]*) die "--lock name may only contain letters, digits, dot, dash and underscore" ;;
  esac
  dir="${TMPDIR:-/tmp}/sar-lock-$name"
  i=0
  while ! mkdir "$dir" 2>/dev/null; do
    holder="$(cat "$dir/pid" 2>/dev/null)"
    if [ -z "$holder" ]; then
      # A claimant won the mkdir but has not written its pid yet; give it a moment before suspecting it.
      kill -0 "$holder" 2>/dev/null && { sleep 1; continue; }
    fi
    if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
      echo "sar: lock '$name' was held by dead process $holder; reclaiming" >&2
      rm -rf "$dir"
      continue
    fi
    i=$((i + 1))
    [ "$i" -eq 1 ] && echo "sar: waiting for lock '$name' held by ${holder:-unknown} (another task is using it)" >&2
    sleep 2
  done
  echo "$$" >"$dir/pid"
  echo "$base" >"$dir/task"
  LOCK_DIR="$dir"
}

release_lock() {
  [ -n "${LOCK_DIR:-}" ] && rm -rf "$LOCK_DIR"
  LOCK_DIR=""
}

# Resolve <task>.task.md (or a bare slug in the current run) to an absolute task path.
resolve_task() {
  local t="$1" cand
  case "$t" in
    *.task.md) ;;
    *) for cand in .sar/*/"$t".task.md .sar/*/*/"$t".task.md; do
         [ -f "$cand" ] && { t="$cand"; break; }
       done ;;
  esac
  [ -f "$t" ] || die "task file not found: $t"
  (cd "$(dirname "$t")" && printf '%s/%s\n' "$PWD" "$(basename "$t")")
}

# One line per dispatch: state, subtask progress, age. Reads only the small .status and .progress.md files, never the logs.
cmd_status() {
  local all=0 dir="" roots=() d root st base agent state started total done pid live now line
  while [ $# -gt 0 ]; do
    case "$1" in
      --all) all=1 ;;
      -*) die "unknown option for status: $1" ;;
      *) dir="$1" ;;
    esac
    shift
  done

  if [ -n "$dir" ]; then
    roots=("$dir/.sar")
  else
    d="$PWD"
    while [ -n "$d" ] && [ "$d" != "/" ]; do
      [ -d "$d/.sar" ] && roots+=("$d/.sar")
      d="$(dirname "$d")"
    done
  fi
  [ ${#roots[@]} -gt 0 ] || return 0

  now=$(date +%s)
  for root in "${roots[@]}"; do
    for st in $(ls -t "$root"/*/*.status 2>/dev/null); do
      [ -f "$st" ] || continue
      base="${st%.status}"
      agent="$(sed -n 's/^agent=//p' "$st" | head -1)"
      state="$(sed -n 's/^state=//p' "$st" | head -1)"
      started="$(sed -n 's/^started=//p' "$st" | head -1)"
      total="$(sed -n 's/^subtasks=//p' "$st" | head -1)"
      pid="$(sed -n 's/^pid=//p' "$st" | head -1)"
      done=$(grep -c '^- \[[xX]\]' "$base.progress.md" 2>/dev/null)
      case "$total" in '' | *[!0-9]*) total=0 ;; esac
      case "$done"  in '' | *[!0-9]*) done=0 ;; esac
      case "$started" in '' | *[!0-9]*) started=$now ;; esac
      live=0
      if [ "$state" = RUNNING ] && [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then live=1; fi
      if [ "$state" = RUNNING ] && [ "$live" = 0 ]; then state=STALLED; fi
      [ "$all" = 1 ] || [ "$state" = RUNNING ] || [ "$state" = STALLED ] || continue
      if [ "$total" -gt 0 ]; then line="$done/$total subtasks"; else line="no checklist"; fi
      printf '%s %s %s %s %s progress: %s report: %s\n' \
        "$agent" "$(basename "$base")" "$state" "$line" "$(age_of "$started")" \
        "$base.progress.md" "$base.report.md"
    done
  done
}

# Stop a live dispatch by signalling the dispatcher, whose trap tears the worker down cleanly.
cmd_stop() {
  [ $# -ge 1 ] || die "usage: sar.sh stop <name>.task.md"
  local task base dpid state
  task="$(resolve_task "$1")"
  base="${task%.task.md}"
  [ -f "$base.status" ] || die "no status file for $(basename "$base")"
  state="$(sed -n 's/^state=//p' "$base.status" | head -1)"
  [ "$state" = RUNNING ] || die "$(basename "$base") is $state, not RUNNING"
  dpid="$(sed -n 's/^dpid=//p' "$base.status" | head -1)"
  [ -n "$dpid" ] || die "no dispatcher pid recorded for $(basename "$base")"
  kill -TERM "$dpid" 2>/dev/null || die "dispatcher $dpid is already gone; nothing to stop"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$dpid" 2>/dev/null || break
    sleep 1
  done
  state="$(sed -n 's/^state=//p' "$base.status" | head -1)"
  echo "sar stop $(basename "$base"): $state"
}

# Run the brief's "## Done when" fenced blocks and report pass/fail. One command for the whole verification step.
cmd_verify() {
  [ $# -ge 1 ] || die "usage: sar.sh verify <name>.task.md"
  local task base root tmp i n pass fail out rc block
  task="$(resolve_task "$1")"
  base="${task%.task.md}"
  # Run the checks from the repo root when the task lives under .sar/, so relative paths in the brief resolve.
  root="${task%%/.sar/*}"
  [ -d "$root" ] || root="$(pwd)"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sar-verify.XXXXXX")"
  # Expand the path while `tmp` still exists: an EXIT trap runs after this function returns, when the
  # local is gone, and under set -u that made the trap itself fail and leak the directory every run.
  trap "rm -rf $(printf '%q' "$tmp")" EXIT

  awk -v dir="$tmp" '
    /^##+[[:space:]]*Done when/ {inb = 1; next}
    inb && /^##+[[:space:]]/ {inb = 0}
    inb && /^```/ {
      if (fence) { close(f); i++; fence = 0 } else { i++; f = sprintf("%s/%02d.sh", dir, i); fence = 1 }
      next
    }
    inb && fence {print > f}
  ' "$task"

  n=$(ls "$tmp"/*.sh 2>/dev/null | wc -l | tr -d ' ')
  if [ "$n" -eq 0 ]; then
    echo "sar verify $(basename "$base"): no fenced checks under '## Done when'" >&2
    exit 2
  fi

  pass=0; fail=0; i=0
  for block in "$tmp"/*.sh; do
    i=$((i + 1))
    out="$(cd "$root" && bash "$block" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ]; then
      pass=$((pass + 1))
    else
      fail=$((fail + 1))
      echo "sar verify: check $i FAILED (exit $rc)"
      printf '%s\n' "$out" | tail -5 | sed 's/^/    /'
    fi
  done
  # Belt and braces: an EXIT trap is unreliable here, so clean up on the way out too.
  rm -rf "$tmp"
  trap - EXIT
  echo "sar verify $(basename "$base"): $pass passed, $fail failed"
  [ "$fail" -eq 0 ]
}

# Create the next attempt's brief file with the earlier attempt recorded in it, then dispatch it.
cmd_retry() {
  local task="" as="" why="" extra=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --as) [ $# -ge 2 ] || die "--as needs an agent"; as="$2"; shift ;;
      --why) [ $# -ge 2 ] || die "--why needs text"; why="$2"; shift ;;
      --) shift; extra=("$@"); break ;;
      -*) die "unknown option for retry: $1" ;;
      *) task="$1" ;;
    esac
    shift
  done
  [ -n "$task" ] || die "usage: sar.sh retry <name>.task.md [--as <agent>] [--why <text>]"
  task="$(resolve_task "$task")"
  local base name status result progress report agent state session target newname newfile title n
  base="${task%.task.md}"; name="$(basename "$base")"
  status="$base.status"
  if [ -f "$status" ]; then
    agent="$(sed -n 's/^agent=//p' "$status" | head -1)"
    state="$(sed -n 's/^state=//p' "$status" | head -1)"
  else
    agent=""; state=""
  fi
  case "$state" in
    DONE) die "$name is DONE; write a new task file for follow-up work instead of retrying" ;;
    RUNNING | STALLED) die "$name is $state; stop it first with: sar.sh stop $task" ;;
  esac
  result="$base.result.md"; progress="$base.progress.md"; report="$base.report.md"
  session="$(sed -n 's/^session=//p' "$status" 2>/dev/null | head -1)"

  target="$as"
  if [ -z "$target" ]; then
    target="$(retry_target "${agent:-hk}" "${state:-FAILED}")"
    [ -n "$target" ] || die "no stand-in for ${agent:-unknown} after $state; bring $result to the user"
  fi

  n=2
  while [ -e "$base-r$n.task.md" ]; do n=$((n + 1)); done
  newname="$name-r$n"
  newfile="$base-r$n.task.md"
  title="$(grep -m1 '^# ' "$task" | sed 's/^# *//')"
  [ -n "$title" ] || title="$name"
  {
    printf '# %s - retry %d\n\n' "$title" "$n"
    printf '## Retry context\n'
    printf 'This is retry %d of `%s`, handed to you after the previous attempt by `%s` ended `%s`.\n\n' "$n" "$(basename "$task")" "${agent:-unknown}" "${state:-unknown}"
    [ -n "$why" ] && printf 'Reason: %s\n\n' "$why"
    printf -- '- Previous report: %s\n' "$result"
    printf -- '- Previous journal (what it did, step by step): %s\n' "$report"
    printf -- '- Previous checklist (ticked items are already done): %s\n' "$progress"
    [ -n "$session" ] && printf -- '- Previous session id (inspect with `copilot --resume %s`): %s\n' "$session" "$session"
    printf '\nStart by reading the previous report and journal. Do not redo what is already finished; verify it if the brief lets you, then carry on from the first unfinished item.\n\n---\n\n'
    awk 'n == 0 && /^# / {n = 1; next} {print}' "$task"
  } >"$newfile"
  echo "sar retry $name: wrote $(basename "$newfile"), dispatching to $target" >&2
  exec bash "$SELF" "$target" "$newfile" ${extra[@]+"${extra[@]}"}
}

[ $# -ge 1 ] || die "$usage"

case "$1" in
  agents)
    for a in $AGENTS; do
      agent_launcher "$a"
      printf '%s\t%s\n' "$a" "$(agent_via "$a")"
    done
    exit 0
    ;;
  ps | status)
    shift
    cmd_status "$@"
    exit 0
    ;;
  stop)
    shift
    cmd_stop "$@"
    exit 0
    ;;
  verify)
    shift
    cmd_verify "$@"
    exit $?
    ;;
  retry)
    shift
    cmd_retry "$@"
    ;;
esac

# Workers are full agents and can see this skill too; stop them fanning out.
[ -z "${SAR_WORKER:-}" ] || die "refusing to dispatch from inside a sar worker"

[ $# -ge 2 ] || die "$usage"
agent="$1"; task="$2"; shift 2

agent_launcher "$agent" || die "unknown agent '$agent' (available: $AGENTS)"
[ -f "$task" ] || die "task file not found: $task"
case "$task" in *.task.md) ;; *) die "task file must be named <name>.task.md" ;; esac

mode=rw
timeout=1800
extra=()
opt_session=""
resume=""
resuming=0
lock=""
allow_images=0
while [ $# -gt 0 ]; do
  case "$1" in
    --ro) mode=ro ;;
    --timeout) [ $# -ge 2 ] || die "--timeout needs a value"; timeout="$2"; shift ;;
    --session-id) [ $# -ge 2 ] || die "--session-id needs a value"; opt_session="$2"; shift ;;
    --lock) [ $# -ge 2 ] || die "--lock needs a name"; lock="$2"; shift ;;
    --allow-images) allow_images=1 ;;
    --resume)
      resuming=1
      # Bare --resume takes the session id from the task's own .status file.
      if [ $# -ge 2 ]; then case "$2" in -*) ;; *) resume="$2"; shift ;; esac; fi
      ;;
    --) shift; extra=("$@"); break ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done
case "$timeout" in '' | *[!0-9]*) die "--timeout must be a number of seconds" ;; esac

# An image-blind model fails on image input. Refuse the brief up front instead of burning a run on it.
case " $IMAGE_BLIND " in
  *" $agent "*)
    if [ "$allow_images" = 0 ]; then
      img="$(brief_images "$task")"
      if [ -n "$img" ]; then
        die "refusing to send images to $agent: $(echo "$img" | tr '\n' ' ')
  $agent's model fails on image input. Send only the image paths, or send it to sol to judge the images and hk to capture them. Use --allow-images to override."
      fi
    fi
    ;;
esac

command -v copilot >/dev/null 2>&1 || die "copilot not found on PATH; install GitHub Copilot CLI (brew install copilot-cli, or npm install -g @github/copilot)"

task="$(cd "$(dirname "$task")" && pwd)/$(basename "$task")"
base="${task%.task.md}"
name="$(basename "$base")"
result="$base.result.md"
out="$base.out"
log="$base.log"
status="$base.status"
progress="$base.progress.md"
report="$base.report.md"

timedout="$base.timedout"
started=$(date +%s)

# A resumed run keeps the same session, so a stopped worker can pick up where it left off instead of starting over.
if [ "$resuming" = 1 ] && [ -z "$resume" ]; then
  resume="$(sed -n 's/^session=//p' "$status" 2>/dev/null | head -1)"
  [ -n "$resume" ] || die "no session recorded for $name; pass --resume <session-id>"
fi
if [ -n "$resume" ]; then
  session="$resume"
elif [ -n "$opt_session" ]; then
  session="$opt_session"
else
  session="$(uuidgen | tr 'A-Z' 'a-z')"
fi

# Attempt numbering. `attempt` is this run, `prev` is the run being archived; each resume archives the run it replaces.
archives=0
for f in "$base".attempt*.status; do [ -e "$f" ] && archives=$((archives + 1)); done
if [ "$resuming" = 1 ]; then
  prev=$((archives + 1))
  attempt=$((archives + 2))
else
  prev=0
  attempt=$((archives + 1))
fi

# Claim the resource lock before any run files are created, so a queued task does not look like it has started.
LOCK_DIR=""
if [ -n "$lock" ]; then
  acquire_lock "$lock" "$base"
fi

write_status() {
  {
    echo "agent=$agent"
    echo "via=$(agent_via "$agent")"
    echo "mode=$mode"
    echo "state=$1"
    echo "exit=$2"
    echo "seconds=$3"
    echo "started=$started"
    echo "pid=${pid:-}"
    echo "dpid=$$"
    echo "session=$session"
    echo "resumed=${resume:-}"
    echo "attempt=$attempt"
    echo "subtasks=${total:-0}"
    echo "task=$task"
    echo "result=$result"
    echo "progress=$progress"
    echo "report=$report"
    echo "log=$log"
    echo "lock=${lock:-}"
  } >"$status"
}

# Every dispatch keeps its own files; a retry gets a new task file, and --resume is the explicit way to continue one.
already="$name was already dispatched; pass --resume to continue it, or sar.sh retry for a fresh attempt"
if [ "$resuming" = 1 ]; then
  # Keep the interrupted attempt visible instead of destroying it.
  [ -e "$status" ] && mv -f "$status" "$base.attempt$prev.status"
  [ -e "$result" ] && mv -f "$result" "$base.attempt$prev.result.md"
else
  [ ! -e "$result" ] && [ ! -e "$out" ] || die "$already"
  (set -C; : >"$status") 2>/dev/null || die "$already"
fi

# The brief's ## Subtasks checklist becomes the live progress file the worker ticks.
# Seeded in read-only mode too: the checklists are dispatcher-owned files, so a --ro worker can tick them
# even though it may not touch the project. Long reviews need progress more than short edits do.
# A resume must leave both files exactly as the interrupted attempt left them: the ticks are its memory of what is done.
total=0
if [ "$resuming" = 1 ] && [ -s "$progress" ]; then
  total=$(grep -c '^- \[[ xX]\]' "$progress")
  sed -i '' -e 's/^state=[A-Z_]*/state=RUNNING/' "$progress" 2>/dev/null || sed -i -e 's/^state=[A-Z_]*/state=RUNNING/' "$progress"
else
  awk '
    /^##+[[:space:]]*Subtasks/ {inb = 1; next}
    inb && /^##+[[:space:]]/ {inb = 0}
    inb && /^- \[[ xX]\]/ {line = $0; sub(/^[[:space:]]*/, "", line); sub(/- \[[ xX]\]/, "- [ ]", line); print line}
  ' "$task" >"$progress.body"
  if [ -s "$progress.body" ]; then
    total=$(grep -c '^- \[ \]' "$progress.body")
    { echo "# $name progress"
      echo "agent=$agent state=RUNNING subtasks=$total"
      cat "$progress.body"
    } >"$progress"
  else
    # No checklist: still keep a heartbeat file so the status line can show this run's age.
    { echo "# $name progress"
      echo "agent=$agent state=RUNNING subtasks=0"
      echo "No subtask checklist in the brief; see $report for the running journal."
    } >"$progress"
  fi
  rm -f "$progress.body"
fi
# The journal survives resumes; never start it over.
if [ "$resuming" != 1 ]; then
  echo "# $name report" >"$report"
  echo "agent=$agent session=$session" >>"$report"
  echo >>"$report"
fi

write_status RUNNING - -

# Keep run artifacts out of commits without touching tracked files.
case "$task" in
  */.sar/*)
    if gitdir="$(git rev-parse --git-dir 2>/dev/null)"; then
      mkdir -p "$gitdir/info"
      grep -qxF '.sar/' "$gitdir/info/exclude" 2>/dev/null || echo '.sar/' >>"$gitdir/info/exclude"
    fi
    ;;
esac

resume_note=""
if [ "$resuming" = 1 ]; then
  resume_note=" This is a resumed run of the same task: read $report and $progress first to see what earlier attempts did, then continue from the first unfinished subtask. Do not redo finished subtasks."
fi
if [ "$mode" = ro ]; then
  report_note="This is a read-only task. Do not create, edit or delete any file under the project. The only exception is the two run files the dispatcher made for you, $progress and $report: you may edit those and nothing else. Give your full report as your final message, starting with the STATUS line."
  live=" Keep the run observable while you work: $progress is the checklist from the brief and $report is the journal. After each subtask, change its line in $progress from '- [ ]' to '- [x]' and append a short section to $report (what you did, what you verified, what comes next). Never delete anything already in $report. Even inside one long subtask, append a journal section at least every few minutes so the orchestrator can see you are alive. If you have to stop early, change state=RUNNING to state=BLOCKED on the line under the heading in $progress and say why in $report."
else
  report_note="When finished, write your report to $result in exactly this shape, then make your final message a single line: the status and that path."
  live=" Keep the run observable while you work: $progress is the checklist from the brief and $report is the journal. After each subtask, change its line in $progress from '- [ ]' to '- [x]' and append a short section to $report (what you did, what you verified, what comes next). Never delete anything already in $report. Even inside one long subtask, append a journal section at least every few minutes so the orchestrator can see you are alive. If you have to stop early, change state=RUNNING to state=BLOCKED on the line under the heading in $progress and say why in $report."
fi

schema="The report's first line must be exactly one of:
'STATUS: DONE' - the work is finished and verified.
'STATUS: DONE_WITH_NOTES' - the work is finished but something needs a human decision; you MUST include a '## Resolution' section saying what.
'STATUS: BLOCKED' - you could not finish; include '## Resolution' saying what is needed to unblock.
'STATUS: FAILED' - the work is wrong or impossible as briefed.
Then these sections:
'## Checks' - one line per 'Done when' command, each starting with PASS or FAIL, followed by the command and what it printed.
'## Resolution' - required for DONE_WITH_NOTES and BLOCKED.
'## Files' - the files you changed.
'## Notes' - anything left open."

prompt="You are a worker agent dispatched by an orchestrator. The orchestrator reads only your report, not this conversation. Your task brief is the file $task. Read it first and follow it exactly.$resume_note$live $report_note $schema Nobody can answer questions during this run, so if something is ambiguous take the most reasonable reading, say which reading you took in the report, and keep going. Do not delegate to other agents: no subagents, no fleet mode, and never run sar.sh yourself."

# Workers run from the project root so relative paths in the brief resolve the same way they do for the orchestrator.
root="${task%%/.sar/*}"
[ -d "$root" ] || root="$(dirname "$task")"

# A headless run has nobody to approve tool calls, so the worker gets every tool and path; --deny-tool wins over
# --allow-all-tools, which is what read-only mode relies on. --no-ask-user stops it pausing for a question nobody will answer.
args=(-s --allow-all-tools --allow-all-paths --no-ask-user -C "$root")
if [ "$resuming" = 1 ]; then
  args+=(--resume "$resume")
else
  args+=(--session-id "$session" -n "sar-$agent-$name")
fi
# write covers the file-creating and file-editing tools; the shell stays, so the worker can still tick its own run files.
[ "$mode" = ro ] && args+=(--deny-tool=write)

# copilot has shell children of its own.
tree_pids() {
  local child
  for child in $(pgrep -P "$1" 2>/dev/null); do tree_pids "$child"; done
  echo "$1"
}

# TERM the worker and everything under it, then KILL whatever ignored that. The pids are collected first because children are reparented once the worker dies and could no longer be found through it.
kill_worker() {
  local pids
  pids="$(tree_pids "$pid")"
  kill -TERM $pids 2>/dev/null
  sleep "${1:-10}"
  kill -KILL $pids 2>/dev/null
}

SAR_WORKER=1 "${launcher[@]}" "${args[@]}" ${extra[@]+"${extra[@]}"} -p "$prompt" </dev/null >"$out" 2>"$log" &
pid=$!
write_status RUNNING - -
# `&&` matters: when stop_watchdog kills the sleep, nothing after it may run.
(sleep "$timeout" && : >"$timedout" && kill_worker) >/dev/null 2>&1 &
watchdog=$!

stop_watchdog() {
  pkill -P "$watchdog" 2>/dev/null
  kill "$watchdog" 2>/dev/null
  wait "$watchdog" 2>/dev/null
}
# Stopping the dispatcher must not leave a worker editing files unattended.
trap 'stop_watchdog; kill_worker 2; release_lock; write_status CANCELLED 130 $(($(date +%s) - started)); echo "sar $agent $name: CANCELLED  continue with: sar.sh $agent $task --resume"; exit 130' INT TERM

wait "$pid" 2>/dev/null
code=$?
# Once the watchdog has fired, let it finish its KILL pass before moving on.
if [ -e "$timedout" ]; then wait "$watchdog" 2>/dev/null; else stop_watchdog; fi
trap - INT TERM
secs=$(($(date +%s) - started))

# A worker that never wrote its report still said something on stdout.
if [ ! -s "$result" ] && [ -s "$out" ]; then cp "$out" "$result"; fi

if [ -e "$timedout" ]; then
  rm -f "$timedout"
  state=TIMEOUT
elif [ "$code" -ne 0 ]; then
  # A usage-limit refusal is not a broken agent. The CLI exits non-zero and says so on stdout or stderr
  # (a 429, a rate limit, or an exhausted AI credit or premium request budget), so recognise it here rather
  # than reporting CRASHED and sending the task to a stand-in that will not help.
  if grep -qiE '(^|[^0-9])429([^0-9]|$)|usage limit|rate.?limit|quota|too many requests|ai credit|premium request|limit (has been |was )?(reached|exceeded)|budget' "$out" "$log" 2>/dev/null; then
    state=QUOTA
  else
    state=CRASHED
  fi
elif [ ! -s "$result" ]; then
  state=NO_REPORT
else
  state="$(head -5 "$result" | grep -m1 -oE '^STATUS: *(DONE_WITH_NOTES|DONE|BLOCKED|FAILED)([^A-Za-z_]|$)' | sed -E 's/^STATUS: *([A-Z_]+).*/\1/')"
  [ -n "$state" ] || state=UNMARKED
  # A DONE_WITH_NOTES claim is only accepted with the section that says what the human must decide.
  if [ "$state" = DONE_WITH_NOTES ] && ! grep -q '^##[[:space:]]*Resolution' "$result"; then
    state=UNMARKED
    schema_note="claimed DONE_WITH_NOTES without a '## Resolution' section"
  fi
fi

# Count what the worker ticked off and what its checks claimed, so the one-line result carries the progress too.
done=$(grep -c '^- \[[xX]\]' "$progress" 2>/dev/null)
case "$done" in '' | *[!0-9]*) done=0 ;; esac
where="${done}/${total}"
[ "$total" -gt 0 ] || where="no checklist"
checks=""
if [ -s "$result" ]; then
  cp_n=$(grep -cE '^[[:space:]]*([*-][[:space:]]*)?PASS\b' "$result" 2>/dev/null)
  cf_n=$(grep -cE '^[[:space:]]*([*-][[:space:]]*)?FAIL\b' "$result" 2>/dev/null)
  case "$cp_n" in '' | *[!0-9]*) cp_n=0 ;; esac
  case "$cf_n" in '' | *[!0-9]*) cf_n=0 ;; esac
  [ $((cp_n + cf_n)) -gt 0 ] && checks=", checks: ${cp_n} PASS ${cf_n} FAIL"
fi
resume_hint=""
case "$state" in
  DONE) ;;
  QUOTA) resume_hint="  wait for the limit to reset, then: sar.sh $agent $task --resume" ;;
  *) resume_hint="  then: sar.sh retry $task   or: sar.sh $agent $task --resume" ;;
esac

write_status "$state" "$code" "$secs"
release_lock

if [ "$state" = DONE ] || [ "$state" = DONE_WITH_NOTES ]; then
  echo "sar $agent $name: $state (${secs}s, $where subtasks$checks) result: $result"
  exit 0
fi
[ -n "${schema_note:-}" ] && schema_note=" ($schema_note)"
echo "sar $agent $name: $state (exit $code, ${secs}s, $where subtasks$checks) result: $result log: $log${schema_note:-}$resume_hint"
exit 1
