#!/bin/zsh
# Builds the engine payload the release app installs from, in .build/engine/:
#   uv (pinned release, checksum checked), moss_image_mlx-*.whl (PIN from setup.sh + patches/*), requirements.lock
# engine/requirements.lock is committed; a rerun keeps its pins (uv prefers the versions already in the output file).
# Downloads and the patched clone are cached in .build/engine-cache/, so a second run is quick.
set -euo pipefail
cd "$(dirname "$0")/.."
UV_VERSION=0.13.0
UV_SHA256=a9c1b29002cf3c83f07fa9cd8a887a3be0107d90e23189721221e7257db8e3d6   # uv-aarch64-apple-darwin.tar.gz
PIN=$(sed -n 's/^PIN=\([0-9a-f]*\).*/\1/p' setup.sh)
UPSTREAM=$(sed -n 's/^UPSTREAM=//p' setup.sh)
OUT=$PWD/.build/engine CACHE=$PWD/.build/engine-cache
mkdir -p "$OUT" "$CACHE"
export UV_NO_CONFIG=1 UV_CACHE_DIR="$CACHE/uv" MACOSX_DEPLOYMENT_TARGET=14.0   # the app's minimum macOS; mlx has no macOS 13 wheels

# uv
tgz="$CACHE/uv-$UV_VERSION.tar.gz"
[[ -f "$tgz" ]] || { curl -fsSL -o "$tgz.part" \
  "https://github.com/astral-sh/uv/releases/download/$UV_VERSION/uv-aarch64-apple-darwin.tar.gz"; mv "$tgz.part" "$tgz"; }
[[ "$(shasum -a 256 "$tgz" | cut -d' ' -f1)" == "$UV_SHA256" ]] || { rm -f "$tgz"; echo "uv download: checksum mismatch"; exit 1; }
tar -xzf "$tgz" -C "$OUT" --strip-components 1 uv-aarch64-apple-darwin/uv
UV="$OUT/uv"

# moss-image-mlx wheel: PIN + patches applied with git am in a scratch clone; rebuilt only when either changes
src="$CACHE/src"
key=$({ echo "$PIN"; cat patches/*.patch } | shasum -a 256 | cut -c1-16)
if [[ "$(cat "$CACHE/wheel.key" 2>/dev/null)" != "$key" || -z "$(echo "$OUT"/*.whl(N))" ]]; then
  [[ -d "$CACHE/upstream.git" ]] || git clone -q --bare "$UPSTREAM" "$CACHE/upstream.git"
  git -C "$CACHE/upstream.git" cat-file -e "$PIN^{commit}" 2>/dev/null ||
    git -C "$CACHE/upstream.git" fetch -q "$UPSTREAM" '+refs/heads/*:refs/heads/*'
  rm -rf "$src" "$OUT"/*.whl(N)
  git clone -q "$CACHE/upstream.git" "$src"
  git -C "$src" checkout -q --detach "$PIN"
  git -C "$src" -c user.name=payload -c user.email=payload@localhost am -q "$PWD"/patches/*.patch
  "$UV" build -q --wheel --out-dir "$OUT" "$src"
  echo "$key" > "$CACHE/wheel.key"
fi
echo "moss-image-mlx tree $(git -C "$src" rev-parse 'HEAD^{tree}')"

# lockfile: the wheel's dependencies (mlx-lm among them, also used by the prompt enhancer), hash-pinned
(cd "$src" && "$UV" pip compile -q pyproject.toml --python-version 3.12 --python-platform aarch64-apple-darwin \
  --generate-hashes --custom-compile-command scripts/engine-payload.sh -o "$OLDPWD/engine/requirements.lock")
cp engine/requirements.lock "$OUT/"
ls -1 "$OUT"
