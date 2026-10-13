#!/usr/bin/env bash
# Install the SAR skill for GitHub Copilot CLI as a personal skill, so it is available in every project.
# Usage: bash install.sh [--statusline]
set -eu
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
COPILOT_HOME="${COPILOT_HOME:-$HOME/.copilot}"

command -v copilot >/dev/null 2>&1 || {
  echo "copilot not found on PATH. Install GitHub Copilot CLI first: brew install copilot-cli, or npm install -g @github/copilot" >&2
  exit 1
}

mkdir -p "$COPILOT_HOME/skills"
rm -rf "$COPILOT_HOME/skills/sar"
cp -R "$HERE/.github/skills/sar" "$COPILOT_HOME/skills/sar"
chmod +x "$COPILOT_HOME/skills/sar/scripts/sar.sh"
echo "installed skill to $COPILOT_HOME/skills/sar"
echo "roster:"
bash "$COPILOT_HOME/skills/sar/scripts/sar.sh" agents | sed 's/^/  /'

if [ "${1:-}" = "--statusline" ]; then
  cp "$HERE/statusline/statusline-sar.sh" "$COPILOT_HOME/statusline-sar.sh"
  chmod +x "$COPILOT_HOME/statusline-sar.sh"
  echo "copied the status line segment to $COPILOT_HOME/statusline-sar.sh"
  echo "wire it in by adding this to $COPILOT_HOME/settings.json (or call it from your existing statusLine command):"
  echo '  "statusLine": { "type": "command", "command": "~/.copilot/statusline-sar.sh", "padding": 0 }'
fi

echo
echo "check the models on this account: bash tests/smoke.sh"
