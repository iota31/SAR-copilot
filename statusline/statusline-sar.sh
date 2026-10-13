#!/bin/bash
# SAR segment for the GitHub Copilot CLI status line: one entry per live worker dispatch in the current project's .sar tree.
# Reads only the small .status files and each run's .report.md tail, so it stays cheap on every repaint.
# Wire it in through ~/.copilot/settings.json: "statusLine": {"type": "command", "command": "~/.copilot/statusline-sar.sh"},
# or call it from an existing status line script with the same JSON on stdin. Prints nothing when no dispatch is live.

set -u
JSON_INPUT=$(cat)
CWD=$(printf '%s' "$JSON_INPUT" | jq -r '.cwd // .workspace.current_dir // "."' 2>/dev/null)
# Without jq, fall back to a crude read of the cwd field so the segment still renders.
[ -n "$CWD" ] || CWD=$(printf '%s' "$JSON_INPUT" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
[ -n "$CWD" ] || CWD="$PWD"

# Walk up from the workspace root to the nearest .sar run directory, the same way sar.sh status does.
root=""
d="$CWD"
while [ -n "$d" ] && [ "$d" != "/" ]; do
  if [ -d "$d/.sar" ]; then root="$d/.sar"; break; fi
  d="$(dirname "$d")"
done
[ -n "$root" ] || exit 0

DIM="\033[38;5;240m"; RESET="\033[0m"; BOLD="\033[1m"
TEAL="\033[38;5;80m"; LIME="\033[38;5;154m"; ORANGE="\033[38;5;208m"
RED="\033[31m"; GRAY="\033[38;5;250m"; GOLD="\033[38;5;220m"

now=$(date +%s)
line=""
shown=0
# Newest runs first; cap the display so a busy tree cannot flood the status line.
for st in $(ls -t "$root"/*/*.status 2>/dev/null | head -12); do
  [ -f "$st" ] || continue
  state="$(sed -n 's/^state=//p' "$st" | head -1)"
  [ "$state" = RUNNING ] || continue
  base="${st%.status}"
  agent="$(sed -n 's/^agent=//p' "$st" | head -1)"
  pid="$(sed -n 's/^pid=//p' "$st" | head -1)"
  started="$(sed -n 's/^started=//p' "$st" | head -1)"
  total="$(grep -c '^- \[[ xX]\]' "$base.progress.md" 2>/dev/null)"
  done_n="$(grep -c '^- \[[xX]\]' "$base.progress.md" 2>/dev/null)"
  case "$total" in '' | *[!0-9]*) total=0 ;; esac
  case "$done_n" in '' | *[!0-9]*) done_n=0 ;; esac
  case "$started" in '' | *[!0-9]*) started=$now ;; esac
  secs=$((now - started)); [ "$secs" -lt 0 ] && secs=0
  if [ "$secs" -lt 60 ]; then age="${secs}s"; elif [ "$secs" -lt 3600 ]; then age="$((secs / 60))m"; else age="$((secs / 3600))h$(((secs % 3600) / 60))m"; fi

  colour=$TEAL; mark="●"
  if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then colour=$RED; mark="✗"; fi
  if [ -f "$base.progress.md" ] && grep -q '^state=BLOCKED' "$base.progress.md"; then colour=$ORANGE; mark="◐"; fi

  # The worker's own last journal heading, so the line says what it is on, not just how far.
  step="$(grep '^## ' "$base.report.md" 2>/dev/null | tail -1 | sed -e 's/^## *//' -e 's/[[:cntrl:]]//g' | cut -c1-34)"
  [ -n "$step" ] || step="$(basename "$base")"

  seg="${colour}${mark}${RESET}${GRAY}${agent}${RESET}${DIM}:${RESET}${LIME}${done_n}/${total}${RESET}"
  [ "$total" -eq 0 ] && seg="${colour}${mark}${RESET}${GRAY}${agent}${RESET}"
  seg="${seg}${DIM} ${step} ${GOLD}${age}${RESET}"
  if [ "$shown" -eq 0 ]; then line="$seg"; else line="${line}   ${seg}"; fi
  shown=$((shown + 1))
done

[ "$shown" -gt 0 ] || exit 0
printf "${DIM}sar${RESET} %b\n" "$line"
