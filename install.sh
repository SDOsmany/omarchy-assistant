#!/bin/bash
# Omarchy Assistant setup wizard.
#
#   ./install.sh                 interactive (re-run any time to change settings)
#   ./install.sh --yes [opts]    unattended, defaults for anything not given
#
# Options: --name NAME  --voice VOICE  --stt superwhisper|whisper  --access safe|full
#          --model sonnet|opus|haiku  --talk-key "SUPER + ALT + A"  --no-keys

set -euo pipefail

APP="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
PLUGIN_ID="io.github.sdosmany.assistant"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}/omarchy-assistant"
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy-assistant"
CONF="$CONF_DIR/config.json"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
BINDINGS="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/bindings.lua"
BIN="$HOME/.local/bin"
KOKORO_URL="https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0"
KOKORO_MODEL_SHA="7d5df8ecf7d4b1878015a32686053fd0eebe2bc377234608764cc0ef3636a6c5"
KOKORO_VOICES_SHA="bca610b8308e8d99f32e6fe4197e7ec01679264efed0cac9140fe9c29f1fbf7d"

VOICES=(
  "af_heart|Heart: warm, natural (American, female)"
  "af_bella|Bella: bright, upbeat (American, female)"
  "af_nicole|Nicole: soft, calm (American, female)"
  "af_sarah|Sarah: clear, friendly (American, female)"
  "am_michael|Michael: relaxed, deep (American, male)"
  "am_fenrir|Fenrir: confident (American, male)"
  "am_puck|Puck: lively (American, male)"
  "bf_emma|Emma: polished (British, female)"
  "bf_isabella|Isabella: elegant (British, female)"
  "bm_george|George: the butler (British, male)"
  "bm_fable|Fable: storyteller (British, male)"
)

yes=false name="" voice="" stt="" access="" model="" talk_key="" keys=true
while (($#)); do
  case "$1" in
    --yes | -y) yes=true ;;
    --name) name=$2; shift ;;
    --voice) voice=$2; shift ;;
    --stt) stt=$2; shift ;;
    --access) access=$2; shift ;;
    --model) model=$2; shift ;;
    --talk-key) talk_key=$2; shift ;;
    --no-keys) keys=false ;;
    -h | --help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

# ---- helpers -------------------------------------------------------------------
say_step() { gum style --bold --foreground 4 "› $*"; }
ok() { gum style --foreground 2 "  ✓ $*"; }
warn() { gum style --foreground 3 "  ! $*"; }
die() { gum style --foreground 1 "  ✗ $*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
spin() { # title cmd...
  local title=$1; shift
  if [[ -t 1 ]]; then gum spin --title "$title" -- "$@"; else "$@" >/dev/null; fi
}
current() { jq -r --arg k "$1" '.[$k] // empty' "$CONF" 2>/dev/null || true; }

ask_input() { # prompt default
  if $yes; then echo "$2"; else gum input --prompt "$1 " --value "$2" --width 60; fi
}
ask_choose() { # header default options...
  local header=$1 def=$2; shift 2
  if $yes; then echo "$def"; else gum choose --header "$header" --selected "$def" "$@"; fi
}
ask_confirm() { # prompt default(yes|no)
  if $yes; then [[ $2 == yes ]]; else
    if [[ $2 == yes ]]; then gum confirm "$1"; else gum confirm --default=false "$1"; fi
  fi
}

fetch() { # url dest sha256
  local url=$1 dest=$2 sha=$3
  if [[ -f $dest ]] && echo "$sha  $dest" | sha256sum -c --status; then return 0; fi
  curl -fL --retry 3 -o "$dest.part" "$url"
  echo "$sha  $dest.part" | sha256sum -c --status || { rm -f "$dest.part"; die "Checksum mismatch for $(basename "$dest")"; }
  mv "$dest.part" "$dest"
}

preview_voice() { # voice text
  "$DATA/venv/bin/python" - "$DATA/voices" "$1" "$2" <<'EOF' 2>/dev/null
import sys, subprocess, tempfile, soundfile as sf
from kokoro_onnx import Kokoro
d, voice, text = sys.argv[1:]
k = Kokoro(f"{d}/kokoro-v1.0.onnx", f"{d}/voices-v1.0.bin")
s, sr = k.create(text, voice=voice, lang="en-gb" if voice.startswith("b") else "en-us")
with tempfile.NamedTemporaryFile(suffix=".wav") as f:
    sf.write(f.name, s, sr)
    subprocess.run(["pw-play", f.name])
EOF
}

# ---- welcome -------------------------------------------------------------------
clear 2>/dev/null || true
gum style --border rounded --padding "1 3" --margin "0 0 1 0" --border-foreground 4 \
  "$(gum style --bold 'Omarchy Assistant')" \
  "A voice assistant for your desktop: say its name, ask anything." \
  "" "This sets up the wake word, a natural voice and the background service."

# ---- 1. dependencies -----------------------------------------------------------
say_step "Checking what's installed"

if ! have claude; then
  warn "Claude Code isn't installed. It's the assistant's brain."
  echo "  Install it and sign in with:  omarchy default agent claude"
  echo "  (or Super + Space → Setup → Default agent → Claude Code), then run setup again."
  exit 1
fi
ok "Claude Code"

pkgs=()
have omawake || pkgs+=(omawake-bin)
have uv || pkgs+=(uv)
have parecord || pkgs+=(libpulse)
have curl || pkgs+=(curl)
if ((${#pkgs[@]})); then
  echo "  Installing: ${pkgs[*]}"
  omarchy pkg add "${pkgs[@]}" || die "Couldn't install ${pkgs[*]}"
fi
ok "Wake word engine (omawake), uv, audio tools"

# ---- 2. python environment and voice model -------------------------------------
say_step "Setting up the voice engine"
mkdir -p "$DATA/voices" "$CONF_DIR" "$BIN"
if [[ ! -x $DATA/venv/bin/python ]]; then
  spin "Creating Python environment…" uv venv -q --python 3.12 "$DATA/venv"
fi
spin "Installing voice engine…" \
  uv pip install -q --python "$DATA/venv/bin/python" -r "$APP/daemon/requirements.txt"
ok "Voice engine"
echo "  Downloading the Kokoro voice model (about 350 MB, once)…"
fetch "$KOKORO_URL/kokoro-v1.0.onnx" "$DATA/voices/kokoro-v1.0.onnx" "$KOKORO_MODEL_SHA"
fetch "$KOKORO_URL/voices-v1.0.bin" "$DATA/voices/voices-v1.0.bin" "$KOKORO_VOICES_SHA"
ok "Voice model"

# ---- 3. name ---------------------------------------------------------------------
say_step "Name your assistant"
$yes || echo "  This is also the wake word. Two or three syllables work best; avoid everyday words."
name=${name:-$(ask_input "Name:" "$(current name || true)")}
name=${name:-Jarvis}
name=$(echo "$name" | tr -s ' ' | sed 's/^ //; s/ $//')
[[ $name =~ ^[[:alpha:]][[:alpha:]\ \'-]{1,30}$ ]] || die "Use letters only for the name."
ok "Name: $name"

# ---- 4. voice --------------------------------------------------------------------
say_step "Pick a voice"
def_voice=$(current voice); def_voice=${voice:-${def_voice:-af_heart}}
if ! $yes; then
  labels=(); for v in "${VOICES[@]}"; do labels+=("${v#*|}"); done
  while true; do
    def_label=""; for v in "${VOICES[@]}"; do [[ ${v%%|*} == "$def_voice" ]] && def_label=${v#*|}; done
    pick=$(gum choose --header "Choose a voice (you'll hear it next)" --selected "$def_label" "${labels[@]}")
    for v in "${VOICES[@]}"; do [[ ${v#*|} == "$pick" ]] && voice=${v%%|*}; done
    preview_voice "$voice" "Hi, I'm $name. Just say my name whenever you need me."
    def_voice=$voice
    ask_confirm "Use this voice?" yes && break
  done
fi
voice=${voice:-$def_voice}
ok "Voice: $voice"

# ---- 5. speech to text -------------------------------------------------------------
say_step "Speech recognition"
def_stt=$(current stt)
if [[ -z $stt ]]; then
  if have superwhisper; then
    pick=$(ask_choose "How should it understand you?" "${def_stt:-superwhisper}" superwhisper whisper)
    stt=$pick
  else
    stt=whisper
  fi
fi
if [[ $stt == whisper ]]; then
  spin "Installing local Whisper…" \
    uv pip install -q --python "$DATA/venv/bin/python" -r "$APP/daemon/requirements-whisper.txt"
  spin "Downloading Whisper model…" "$DATA/venv/bin/python" -c "
from faster_whisper import WhisperModel
WhisperModel('base.en', device='cpu', compute_type='int8', download_root='$DATA/whisper')"
  ok "Local Whisper (runs on this computer)"
else
  ok "Superwhisper"
fi

# ---- 6. access -----------------------------------------------------------------------
say_step "What may the assistant do?"
if [[ -z $access ]]; then
  if ! $yes; then
    gum style --faint "  Safe: answers questions and searches the web. Can't touch your computer." \
      "  Full: opens apps and sites, reads email and calendar, runs commands, all without" \
      "        asking. It still asks out loud before deleting, sending or buying anything." \
      "        Anyone near your mic, or a video playing, can give it orders."
  fi
  def_access=$(current access)
  access=$(ask_choose "Access level" "${def_access:-safe}" safe full)
fi
ok "Access: $access"
model=${model:-$(current model)}; model=${model:-sonnet}

# ---- 7. config -----------------------------------------------------------------------
tmp=$(mktemp)
{ [[ -f $CONF ]] && cat "$CONF" || echo '{}'; } | jq \
  --arg name "$name" --arg voice "$voice" --arg stt "$stt" --arg access "$access" --arg model "$model" \
  '. + {name: $name, voice: $voice, stt: $stt, access: $access, model: $model}' >"$tmp"
mv "$tmp" "$CONF"
ok "Saved settings to ${CONF/#$HOME/\~}"

# ---- 8. wake word ----------------------------------------------------------------------
say_step "Teaching it its name"
model_name=$(omawake config get model.name 2>/dev/null || echo moonshine-streaming-tiny-q8_0-silero-v6.2.1)
if ! omawake setup check 2>&1 | grep -q '^ok model '; then
  spin "Downloading wake word model (about 60 MB)…" omawake setup model --download "$model_name"
fi
omawake wake-word remove omarchy-assistant >/dev/null 2>&1 || true
omawake wake-word add --id omarchy-assistant --phrase "$name" -- "$APP/bin/omarchy-assistant" wake >/dev/null
omawake wake-word add-alias omarchy-assistant "Hey $name" >/dev/null 2>&1 || true
[[ -f $UNIT_DIR/omawake.service ]] || omawake setup systemd --no-start >/dev/null
systemctl --user reset-failed omawake 2>/dev/null || true
systemctl --user enable omawake >/dev/null 2>&1 || true
systemctl --user restart omawake
ok "Listening for \"$name\""

# ---- 9. service and command -------------------------------------------------------------
say_step "Starting the assistant"
mkdir -p "$UNIT_DIR"
sed "s|@APP@|$APP|g" "$APP/systemd/omarchy-assistant.service" >"$UNIT_DIR/omarchy-assistant.service"
systemctl --user daemon-reload
systemctl --user enable omarchy-assistant >/dev/null 2>&1
systemctl --user restart omarchy-assistant
ln -sfn "$APP/bin/omarchy-assistant" "$BIN/omarchy-assistant"
short=$(echo "$name" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z-')
if [[ -n $short ]] && { [[ -L $BIN/$short ]] || ! have "$short"; }; then
  ln -sfn "$APP/bin/omarchy-assistant" "$BIN/$short"
  ok "Command: $short (or omarchy-assistant)"
else
  ok "Command: omarchy-assistant"
fi

# ---- 10. keybindings ---------------------------------------------------------------------
if $keys && [[ -f $BINDINGS ]]; then
  existing=$(sed -n '/-- >>> omarchy-assistant/,/-- <<< omarchy-assistant/p' "$BINDINGS" | grep -o '"SUPER[^"]*"' | head -1 | tr -d '"' || true)
  talk_key=${talk_key:-${existing:-SUPER + ALT + A}}
  if [[ -n $existing ]] || ask_confirm "Add keyboard shortcuts? ($talk_key talk, SUPER + ALT + ESCAPE stop, SUPER + ALT + M mute)" yes; then
    sed -i '/-- >>> omarchy-assistant/,/-- <<< omarchy-assistant/d' "$BINDINGS"
    cat >>"$BINDINGS" <<EOF
-- >>> omarchy-assistant (managed by its setup; edit the keys here, they're kept on re-run)
o.bind("$talk_key", "Talk to $name", "$APP/bin/omarchy-assistant toggle")
o.bind("SUPER + ALT + ESCAPE", "Stop $name", "$APP/bin/omarchy-assistant stop")
o.bind("SUPER + ALT + M", "Mute $name", "$APP/bin/omarchy-assistant toggle-mute")
-- <<< omarchy-assistant
EOF
    hyprctl reload >/dev/null 2>&1 || true
    errs=$(hyprctl configerrors 2>/dev/null || true)
    [[ -z $errs || $errs == *"no errors"* ]] || warn "Hyprland reported: $errs"
    ok "Shortcuts: $talk_key talk, SUPER + ALT + ESCAPE stop, SUPER + ALT + M mute"
  fi
fi

# ---- 11. bar widget ------------------------------------------------------------------------
plugins="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins"
if [[ $APP != "$plugins/"* && ! -e $plugins/$PLUGIN_ID ]]; then
  mkdir -p "$plugins"
  ln -s "$APP" "$plugins/$PLUGIN_ID"          # running from a clone: link it in
fi
omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
for _ in 1 2 3 4 5; do
  omarchy plugin enable "$PLUGIN_ID" right >/dev/null 2>&1 && break
  sleep 1
done
if omarchy plugin list 2>/dev/null | grep -q "^$PLUGIN_ID .*enabled"; then
  ok "Bar widget"
else
  warn "Couldn't enable the bar widget. Enable it with: omarchy plugin enable $PLUGIN_ID right"
fi

# ---- done ------------------------------------------------------------------------------------
for _ in $(seq 1 40); do
  "$APP/bin/omarchy-assistant" status >/dev/null 2>&1 && break
  sleep 0.5
done
"$APP/bin/omarchy-assistant" say "All set. I'm $name. Just say my name whenever you need me." >/dev/null 2>&1 || true

echo
gum style --border rounded --padding "1 3" --border-foreground 2 \
  "$(gum style --bold "$name is ready.")" "" \
  "Say \"$name\", wait for the chime, then ask." \
  "Say \"thanks\" or stay quiet to end the conversation." "" \
  "Bar icon: click to talk · right-click to mute · middle-click for the log" \
  "Change anything: omarchy-assistant setup"
if [[ $access == full ]] && ! $yes; then
  echo
  gum style --faint "Tip: for email and calendar, connect Gmail and Google Calendar at claude.ai → Settings → Connectors."
fi
