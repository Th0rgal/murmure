#!/bin/bash
# Install voiced, the shared Cohere Transcribe daemon, as a socket-activated
# LaunchAgent. One model per Mac, shared by Murmure, Orb and anything else
# that speaks protocol v1 on the socket.
#
#   scripts/install-voiced.sh                 # reuse Orb's venv when present
#   scripts/install-voiced.sh --own-venv      # always build a dedicated venv
#   scripts/install-voiced.sh --download-model
#   scripts/install-voiced.sh --uninstall
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOME_DIR="${VOICED_HOME:-$HOME/Library/Application Support/md.thomas.voice}"
LABEL="md.thomas.voiced"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
ORB_PY="$HOME/Library/Application Support/Orb/voice/.venv/bin/python"
MODEL_REPO="MarkChen1214/cohere-transcribe-03-2026-MLX-Mixed-2bit3bit4bit"
MODEL_REVISION="553445e84959f9ec3fcd43443bce75ea05c400f3"
OWN=0 DOWNLOAD=0 UNINSTALL=0
for a in "$@"; do
  case "$a" in
    --own-venv) OWN=1 ;;
    --download-model) DOWNLOAD=1 ;;
    --uninstall) UNINSTALL=1 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
if [ "$UNINSTALL" = 1 ]; then
  rm -f "$PLIST"
  echo "voiced removed (venv and logs left in $HOME_DIR)"
  exit 0
fi

[ "$(uname -m)" = arm64 ] || { echo "voiced needs Apple Silicon (MLX)" >&2; exit 1; }
mkdir -p "$HOME_DIR/runtime" "$HOME_DIR/logs"
chmod 700 "$HOME_DIR"

if [ "$OWN" = 0 ] && [ -x "$ORB_PY" ]; then
  PY="$ORB_PY"
  echo "Reusing Orb's voice venv: $PY"
else
  PY="$HOME_DIR/.venv/bin/python"
  if [ ! -x "$PY" ]; then
    BASE=""
    for c in python3.11 /opt/homebrew/bin/python3.11 python3.12 /opt/homebrew/bin/python3.12 python3; do
      if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys; sys.exit(0 if (3,10) <= sys.version_info[:2] <= (3,13) else 1)'; then BASE="$(command -v "$c")"; break; fi
    done
    [ -n "$BASE" ] || { echo "Need Python 3.10–3.13 (brew install python@3.11)" >&2; exit 1; }
    "$BASE" -m venv "$HOME_DIR/.venv"
  fi
  "$PY" -m pip install --quiet --upgrade pip
  "$PY" -m pip install --quiet -r "$ROOT/voiced/requirements.txt"
fi

if [ "$DOWNLOAD" = 1 ]; then
  "$PY" -c "from huggingface_hub import snapshot_download as s; print(s('$MODEL_REPO', revision='$MODEL_REVISION'))"
fi
MODEL_DIR="$("$PY" -c "import sys; sys.path.insert(0, '$ROOT/voiced'); import worker; print(worker.resolve_model_dir())")"
[ -f "$MODEL_DIR/model.safetensors" ] || echo "WARNING: model missing at $MODEL_DIR (rerun with --download-model)" >&2

cp "$ROOT/voiced/voiced.py" "$ROOT/voiced/worker.py" "$ROOT/voiced/mlx_audio_cohere_quant_patch.py" "$HOME_DIR/runtime/"

esc() { printf '%s' "$1" | sed -e 's/[&|]/\\&/g'; }
mkdir -p "$(dirname "$PLIST")"
sed -e "s|@PYTHON@|$(esc "$PY")|g" -e "s|@HOME_DIR@|$(esc "$HOME_DIR")|g" -e "s|@MODEL_DIR@|$(esc "$MODEL_DIR")|g" \
  "$ROOT/voiced/md.thomas.voiced.plist.in" > "$PLIST"
plutil -lint "$PLIST" >/dev/null
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "voiced installed"
echo "  socket: $HOME_DIR/voiced.sock (started on first connection)"
echo "  python: $PY"
echo "  model:  $MODEL_DIR"
echo "  log:    $HOME_DIR/logs/voiced.log"
