#!/usr/bin/env bash
# Install or update the Alt / Win swap plugin from this checkout.
#
#   ./install.sh                install and put the widget in the bar
#   ./install.sh --no-enable    install only
#   ./install.sh --headless     run without a bar widget (removes it from the bar)
#
# Re-running is safe: files are replaced and the plugin is not enabled twice.

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ID="omarchy-swap-alt-win"
PLUGINS_DIR="$HOME/.config/omarchy/plugins"
DEST="$PLUGINS_DIR/$PLUGIN_ID"
MODE="bar"

usage() {
  sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
}

for arg in "$@"; do
  case "$arg" in
    --no-enable) MODE="none" ;;
    --headless) MODE="headless" ;;
    -h|--help) usage ;;
    *) echo "install.sh: unknown argument: $arg" >&2; exit 1 ;;
  esac
done

command -v jq >/dev/null 2>&1 || {
  echo "install.sh: jq is required (omarchy ships it)" >&2
  exit 1
}

mkdir -p "$PLUGINS_DIR"

if [[ "$(realpath "$SRC")" != "$(realpath -m "$DEST")" ]]; then
  mkdir -p "$DEST"
  tar -C "$SRC" -cf - \
    --exclude=.git \
    --exclude=tests \
    --exclude=.gitignore \
    . | tar -C "$DEST" -xf -
fi

omarchy plugin validate "$DEST"
omarchy-shell shell rescanPlugins >/dev/null

enabled=$(omarchy plugin list --json | jq -r --arg id "$PLUGIN_ID" \
  '.[] | select(.id == $id) | .enabled' 2>/dev/null || true)

case "$MODE" in
  bar)
    if [[ "$enabled" == "true" ]]; then
      echo "$PLUGIN_ID is already enabled"
    else
      omarchy plugin enable "$PLUGIN_ID" --section right
    fi
    ;;
  headless)
    shell_json="$HOME/.config/omarchy/shell.json"
    touch "$shell_json"
    tmp="$(mktemp)"
    jq --arg id "$PLUGIN_ID" '
      .plugins = ((.plugins // []) | if any(.id == $id) then . else . + [{id: $id}] end)
      | if (.bar.layout | type) == "object" then
          .bar.layout |= with_entries(.value |= (if type == "array" then map(select(.id != $id)) else . end))
        else . end
    ' "$shell_json" >"$tmp" && mv "$tmp" "$shell_json"
    echo "Mounted $PLUGIN_ID as a headless service (bar widget removed)"
    ;;
  none)
    echo "Installed to $DEST (not enabled)"
    ;;
esac

if [[ "$MODE" != "none" ]]; then
  sleep 2
  if ! omarchy-shell swap-alt-win status >/dev/null 2>&1; then
    omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
    sleep 2
  fi
  if omarchy-shell swap-alt-win status >/dev/null 2>&1; then
    echo "Service is running: $(omarchy-shell swap-alt-win status)"
  else
    echo "warning: the plugin service is not answering yet; run: omarchy restart shell" >&2
  fi
fi

cat <<EOF

Config:  ~/.config/omarchy/swap-alt-win.json   (created on first run)
Panel:   click the keyboard icon in the bar
Script:  omarchy-shell swap-alt-win status
EOF
