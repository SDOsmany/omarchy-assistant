#!/bin/bash
# Remove Omarchy Assistant: service, wake word, shortcuts, commands, the echo-cancel mic
# older versions added, and (if you agree) the downloaded models and your settings.
#   ./uninstall.sh [--yes]

set -uo pipefail

APP="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
PLUGIN_ID="io.github.sdosmany.assistant"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}/omarchy-assistant"
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy-assistant"
UNIT="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/omarchy-assistant.service"
PW="${XDG_CONFIG_HOME:-$HOME/.config}/pipewire/pipewire.conf.d/60-omarchy-assistant-echo-cancel.conf"
BINDINGS="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/bindings.lua"
BIN="$HOME/.local/bin"
yes=false
[[ ${1:-} == "--yes" || ${1:-} == "-y" ]] && yes=true
confirm() { $yes || gum confirm "$1"; }

systemctl --user disable --now omarchy-assistant 2>/dev/null
rm -f "$UNIT"
systemctl --user daemon-reload
echo "✓ Service removed"

omawake wake-word remove omarchy-assistant >/dev/null 2>&1 && echo "✓ Wake word removed"

if [[ -f $BINDINGS ]] && grep -q '>>> omarchy-assistant' "$BINDINGS"; then
  sed -i '/-- >>> omarchy-assistant/,/-- <<< omarchy-assistant/d' "$BINDINGS"
  hyprctl reload >/dev/null 2>&1
  echo "✓ Shortcuts removed"
fi

if [[ -f $PW ]]; then
  rm -f "$PW"
  systemctl --user restart pipewire pipewire-pulse wireplumber 2>/dev/null
  echo "✓ Echo-cancelled mic removed"
fi

for link in "$BIN"/*; do
  [[ -L $link && $(readlink -f "$link") == "$APP/bin/omarchy-assistant" ]] && rm -f "$link"
done
echo "✓ Commands removed"

if [[ -d $DATA ]] && confirm "Delete downloaded models and conversation history ($(du -sh "$DATA" | cut -f1))?"; then
  rm -rf "$DATA" && echo "✓ Models removed"
fi
if [[ -d $CONF_DIR ]] && confirm "Delete your settings (name, voice, access)?"; then
  rm -rf "$CONF_DIR" && echo "✓ Settings removed"
fi

omarchy plugin disable "$PLUGIN_ID" >/dev/null 2>&1
echo
echo "Done. omawake (the wake word engine) is still installed; remove it with: omarchy pkg remove omawake-bin"
echo "To remove the bar widget files too: omarchy plugin remove $PLUGIN_ID"
