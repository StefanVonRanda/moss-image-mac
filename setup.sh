#!/bin/zsh
# One-shot setup for MOSS Image for Mac.
#   ./setup.sh            installs into ~/moss-mlx (override with MOSS_HOME=/path ./setup.sh)
# Creates a Python venv, installs moss-image-mlx with the LoRA patches from ./patches, downloads the
# 8-step DMD adapter into the LoRA library and builds MossImage.app next to this script.
set -euo pipefail
cd "$(dirname "$0")"
MOSS_HOME="${MOSS_HOME:-$HOME/moss-mlx}"
UPSTREAM=https://github.com/felix-ab/moss-image-mlx.git
PIN=f451d2e03a3c3b51ae8f0b1941f7f765302c6506   # moss-image-mlx 0.1.0; the patches apply to this commit

[[ "$(uname -m)" == arm64 ]] || { echo "Apple Silicon required"; exit 1; }
command -v swift >/dev/null || { echo "Swift toolchain missing: xcode-select --install"; exit 1; }

# Python 3.11+ venv
if command -v uv >/dev/null; then
  [[ -x "$MOSS_HOME/bin/python" ]] || uv venv --python 3.12 "$MOSS_HOME"
  PIP=(uv pip install --python "$MOSS_HOME/bin/python")
else
  PY=$(command -v python3.12 || command -v python3.11 || true)
  [[ -n "$PY" ]] || { echo "Python 3.11+ required (brew install python@3.12, or install uv)"; exit 1; }
  [[ -x "$MOSS_HOME/bin/python" ]] || "$PY" -m venv "$MOSS_HOME"
  PIP=("$MOSS_HOME/bin/python" -m pip install)
fi

# moss-image-mlx at the pinned commit, with LoRA support applied
if [[ ! -d "$MOSS_HOME/src/.git" ]]; then
  git clone -q "$UPSTREAM" "$MOSS_HOME/src"
  git -C "$MOSS_HOME/src" checkout -q "$PIN"
  git -C "$MOSS_HOME/src" -c user.name=setup -c user.email=setup@localhost am -q "$PWD"/patches/*.patch
fi
"${PIP[@]}" -e "$MOSS_HOME/src"

# default LoRA library with the 8-step DMD adapter (1.2 GB)
mkdir -p "$MOSS_HOME/loras"
if [[ ! -f "$MOSS_HOME/loras/MOSS-Image-SFT-8-steps-dmd.safetensors" ]]; then
  "$MOSS_HOME/bin/python" -c 'import sys, shutil; from huggingface_hub import hf_hub_download
shutil.copyfile(hf_hub_download("lodestones/MOSS-Image-SFT-8-steps-dmd", "lora.safetensors"), sys.argv[1])' \
    "$MOSS_HOME/loras/MOSS-Image-SFT-8-steps-dmd.safetensors"
fi

./build.sh
echo
echo "Done. open $PWD/MossImage.app"
[[ "$MOSS_HOME" == "$HOME/moss-mlx" ]] || echo "Set the moss-mlx path to $MOSS_HOME/bin/moss-mlx and the LoRA folder to $MOSS_HOME/loras in Settings (⌘,)."
echo "The compact model (12 GB) downloads on the first generation."
