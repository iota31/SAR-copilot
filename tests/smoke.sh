#!/usr/bin/env bash
# Not part of the deterministic suite. Asks the real Copilot CLI, on this account, whether each roster model answers.
# Each probe is one tiny request; a model this plan does not offer fails fast with "not available" and costs nothing.
# Usage: bash tests/smoke.sh            probe every roster agent
#        bash tests/smoke.sh sol hk     probe only these
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
S="${SAR_SH:-$HERE/../.github/skills/sar/scripts/sar.sh}"
command -v copilot >/dev/null 2>&1 || { echo "copilot not found on PATH" >&2; exit 1; }

agents="$*"
[ -n "$agents" ] || agents="$(bash "$S" agents | cut -f1 | tr '\n' ' ')"

for a in $agents; do
  model="$(bash "$S" agents | awk -F'\t' -v a="$a" '$1 == a {sub(/^copilot --model /, "", $2); print $2}')"
  [ -n "$model" ] || { printf '%-6s unknown agent\n' "$a"; continue; }
  (
    out="$(timeout 120 copilot -p "reply with the single word ok and nothing else" -s --model "$model" --allow-all-tools --no-ask-user 2>&1)"
    rc=$?
    case "$rc:$out" in
      0:*) printf '%-6s %-22s OK\n' "$a" "$model" ;;
      *"not available"*) printf '%-6s %-22s NOT ON THIS PLAN  (set SAR_MODEL_%s to one that is, or use auto)\n' "$a" "$model" "$(printf '%s' "$a" | tr 'a-z' 'A-Z')" ;;
      *) printf '%-6s %-22s FAILED (exit %s): %s\n' "$a" "$model" "$rc" "$(printf '%s' "$out" | head -1)" ;;
    esac
  ) &
done
wait
