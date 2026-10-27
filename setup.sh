#!/bin/zsh
# One-shot setup for MOSS Image for Mac.
#   ./setup.sh            installs into ~/moss-mlx (override with MOSS_HOME=/path ./setup.sh)
# Creates a Python venv, installs moss-image-mlx with the LoRA patches from ./patches, downloads the
# 8-step DMD adapter into the LoRA library and builds MossImage.app next to this script.
set -euo pipefail
cd "$(dirname "$0")"
MOSS_HOME="${MOSS_HOME:-$HOME/moss-mlx}"
UPSTREAM=https://github.com/felix-ab/moss-image-mlx.git
PIN=da75091341702bdd14c07bb2ce72705abc25724e   # moss-image-mlx 0.2.0; the patches apply to this commit

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

# moss-image-mlx at the pinned commit, with the patches applied. A patch whose subject is already in the
# checkout's history is skipped, so re-running brings an existing install up to date without re-applying.
if [[ ! -d "$MOSS_HOME/src/.git" ]]; then
  git clone -q "$UPSTREAM" "$MOSS_HOME/src"
  git -C "$MOSS_HOME/src" checkout -q "$PIN"
fi
applied=$(git -C "$MOSS_HOME/src" log --format=%s)
for p in "$PWD"/patches/*.patch; do
  grep -qxF -- "$(git mailinfo /dev/null /dev/null < "$p" | sed -n 's/^Subject: //p')" <<< "$applied" && continue
  git -C "$MOSS_HOME/src" -c user.name=setup -c user.email=setup@localhost am -q "$p" || {
    git -C "$MOSS_HOME/src" am --abort 2>/dev/null || true
    echo "Skipped ${p:t}: it does not apply to $MOSS_HOME/src (local changes?); that feature stays off."
  }
done
"${PIP[@]}" -e "$MOSS_HOME/src"
"${PIP[@]}" mlx-lm   # local prompt enhancer (optional at runtime; the chat model downloads on first use)

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
