#!/bin/zsh
# First-run engine setup for real, headless: EngineSetup (Sources/MossImage/Setup.swift) installs from the release
# payload (scripts/engine-payload.sh) into scratch roots, never ~/Library. Takes minutes and downloads ~1.5 GB per
# fresh root (the DMD adapter comes from the Hugging Face cache when it is there), so it is not part of tests.sh.
# Run: Tests/setup-e2e.sh [scratch dir]
set -euo pipefail
cd "$(dirname "$0")/.."
S=${1:-$(mktemp -d)}/"setup e2e"   # a space in the path, as in "Application Support"
rm -rf "$S"; mkdir -p "$S"
scripts/engine-payload.sh >/dev/null
PAYLOAD=$PWD/.build/engine

mkdir -p .build/setup-e2e
cat > .build/setup-e2e/main.swift <<'SWIFT'
// setup-e2e ROOT PAYLOAD [STEP]: runs EngineSetup, printing each state; STEP (python|packages|adapter) cancels
// 2 s into that step. Exit 0 = installed, 2 = cancelled, 1 = failed.
import Foundation
let a = CommandLine.arguments
Task { @MainActor in
    let setup = EngineSetup(root: a[1], payload: a[2])
    var cancelAt: Date?
    Task { @MainActor in
        var last = ""
        while true {
            let now = "\(setup.state)"
            if now != last { print("state", now); last = now; fflush(stdout) }
            if a.count > 3, now == "running(MossImage.EngineSetup.Step.\(a[3]))" || now.hasSuffix(".\(a[3]))") {
                if cancelAt == nil { cancelAt = Date().addingTimeInterval(2) } else if Date() > cancelAt! { setup.cancel() }
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }
    await setup.install()
    switch setup.state {
    case .done: print("installed"); exit(0)
    case .failed(let step, let message): print("failed at \(step): \(message)\nshown: \(setup.errorText)"); exit(1)
    default: print("cancelled"); exit(2)
    }
}
RunLoop.main.run()
SWIFT
swiftc -O -target arm64-apple-macosx14.0 -o .build/setup-e2e/drive .build/setup-e2e/main.swift \
  $(ls Sources/MossImage/*.swift | grep -v MossImageApp.swift) 2>&1 | grep -E "error" && exit 1
drive() { .build/setup-e2e/drive "$@" }
fail() { echo "FAIL $*"; exit 1 }
installed() { [[ -x "$1/engine/bin/moss-mlx" ]] }

echo "== 1. fresh install"
R1="$S/one/MOSS Image"
drive "$R1" "$PAYLOAD" || fail "fresh install"
installed "$R1" && [[ ! -e "$R1/engine.partial" && ! -e "$R1/cache" ]] || fail "engine/ in place, partial and cache gone"
help=$("$R1/engine/bin/moss-mlx" --help)
for f in --turbo --reference --rgba --control; do [[ $help == *"$f "* ]] || fail "moss-mlx --help lacks $f"; done
"$R1/engine/bin/python" -c 'import mlx_lm' || fail "mlx-lm (prompt enhancer) missing"
[[ $(stat -f %z "$R1/loras/MOSS-Image-SFT-8-steps-dmd.safetensors") -gt 1000000000 ]] || fail "DMD adapter in loras/"
grep -q '^relocatable = true' "$R1/engine/pyvenv.cfg" || fail "relocatable venv"
echo "ok   installed: moss-mlx --help lists the flags, mlx-lm imports, DMD $(du -h "$R1/loras/"*.safetensors | cut -f1)"

echo "== 2. cancelled midway, then a retry"
R2="$S/two/MOSS Image"
set +e; drive "$R2" "$PAYLOAD" packages; code=$?; set -e
[[ $code == 2 ]] || fail "cancel: exit $code"
[[ ! -e "$R2/engine" && ! -e "$R2/engine.partial" ]] || fail "a cancelled install leaves no engine"
echo "ok   cancelled: no engine/, no engine.partial/"
drive "$R2" "$PAYLOAD" || fail "retry"
installed "$R2" && "$R2/engine/bin/moss-mlx" --help >/dev/null || fail "retry installs a working engine"
echo "ok   the retry completes"

echo "== 3. a broken lockfile on top of a working engine"
B="$S/broken"; mkdir -p "$B"; cp "$PAYLOAD"/uv "$PAYLOAD"/*.whl "$B/"
sed -E 's/--hash=sha256:[0-9a-f]{8}/--hash=sha256:deadbeef/' "$PAYLOAD/requirements.lock" > "$B/requirements.lock"
set +e; out=$(drive "$R2" "$B"); code=$?; set -e
print -r -- "$out" | tail -3
[[ $code == 1 && $out == *"failed at packages"* && $out == *"Setup stopped with this message"* && $out == *[Hh]ash* ]] || fail "broken lock: exit $code"
installed "$R2" && [[ ! -e "$R2/engine.partial" ]] || fail "the failed reinstall keeps the old engine"
echo "ok   the lockfile's error is shown, the old engine stays"

echo "== 4. no network"
set +e; out=$(HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 drive "$S/four/MOSS Image" "$PAYLOAD"); code=$?; set -e
print -r -- "$out" | tail -3
[[ $code == 1 && $out == *"No internet connection"* ]] || fail "offline: exit $code"
echo "ok   offline gives the plain message"
echo "SETUP E2E PASSED ($S)"
