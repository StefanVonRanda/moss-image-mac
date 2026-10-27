#!/bin/zsh
# The local release gate (no cloud CI): everything a release needs, stopping at the first failure.
# Run: scripts/check.sh   (scripts/release.sh runs it first)
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/toolchain.sh
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
step() { print -r -- "== $*" }
fail() { print -r -- "CHECK FAILED: $*" >&2; exit 1 }

step "swift build"
swift build -q >"$tmp/build.log" 2>&1 || { grep -E "error" "$tmp/build.log" | head -20; fail "swift build"; }

step "./tests.sh"
./tests.sh >"$tmp/tests.log" 2>&1 || { grep -E "FAIL|error" "$tmp/tests.log" | head -20; fail "./tests.sh"; }

step "zsh -n on every script"
for f in *.sh scripts/*.sh Tests/*.sh; do zsh -n "$f" || fail "zsh -n $f"; done

step "patches/ apply to PIN in a fresh clone"
PIN=$(sed -n 's/^PIN=\([0-9a-f]*\).*/\1/p' setup.sh)
UPSTREAM=$(sed -n 's/^UPSTREAM=//p' setup.sh)
mirror=.build/engine-cache/upstream.git   # scripts/engine-payload.sh's mirror, when there is one: no network
git clone -q "$([[ -d $mirror ]] && print $mirror || print $UPSTREAM)" "$tmp/src" || fail "could not clone $UPSTREAM"
git -C "$tmp/src" cat-file -e "$PIN^{commit}" 2>/dev/null || git -C "$tmp/src" fetch -q "$UPSTREAM" || fail "could not fetch $UPSTREAM"
git -C "$tmp/src" checkout -q --detach "$PIN" || fail "PIN $PIN (setup.sh) not found in $UPSTREAM"
for p in patches/*.patch; do
  git -C "$tmp/src" -c user.name=check -c user.email=check@localhost am -q "$PWD/$p" >"$tmp/am.log" 2>&1 ||
    fail "$p does not apply to PIN ${PIN:0:7} after the patches before it:"$'\n'"$(head -5 "$tmp/am.log")"
done

step "engine/requirements.lock matches the payload"
# engine-payload.sh recompiles the lock from the patched wheel (MACOSX_DEPLOYMENT_TARGET=14.0 is set there), keeping
# the committed pins; any change it makes means the committed lock no longer fits the payload.
scripts/engine-payload.sh >"$tmp/payload.log" 2>&1 || { tail -5 "$tmp/payload.log"; fail "scripts/engine-payload.sh"; }
git diff --quiet -- engine/requirements.lock ||
  fail "engine/requirements.lock no longer matches the payload; scripts/engine-payload.sh rewrote it. Review git diff engine/requirements.lock and commit it."

print "ALL RELEASE CHECKS PASSED"
