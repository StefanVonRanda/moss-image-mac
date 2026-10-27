#!/bin/zsh
# Builds the release files for the version in VERSION into dist/:
#   MossImage-<v>.zip (for install.sh), MossImage-<v>.dmg (app, /Applications link, Gatekeeper note), SHA256SUMS
# Runs scripts/check.sh first and builds nothing when it fails. Uploads nothing. Run: scripts/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/check.sh || { print -r -- "release.sh: scripts/check.sh failed, nothing was built." >&2; exit 1; }
V=$(<VERSION)
./build.sh --release
codesign --verify --deep --strict MossImage.app
D=dist; rm -rf "$D"; mkdir -p "$D"
ditto -c -k --keepParent MossImage.app "$D/MossImage-$V.zip"

stage=$(mktemp -d); trap 'rm -rf "$stage"' EXIT
ditto MossImage.app "$stage/MossImage.app"
ln -s /Applications "$stage/Applications"
cat > "$stage/If macOS says it can't be opened.txt" <<'NOTE'
MOSS Image is free and not signed with an Apple Developer ID, so the first time you open it
macOS may say it "can't be opened" or "could not verify" it. You only need to do this once.

1. Drag MOSS Image onto the Applications folder in this window.
2. Open MOSS Image from Applications. When the warning appears, click Done (or Cancel).
3. macOS 15 or newer: open System Settings > Privacy & Security, scroll down to
   "MOSS Image was blocked", click Open Anyway, and confirm with your password.
   macOS 14: Control-click (or right-click) MOSS Image in Applications, choose Open, then click Open.

To skip this step, install with the one-line Terminal command on the project page instead:
https://github.com/StefanVonRanda/moss-image-mac
NOTE
hdiutil create -quiet -volname "MOSS Image $V" -srcfolder "$stage" -format UDZO -ov "$D/MossImage-$V.dmg"

(cd "$D" && shasum -a 256 "MossImage-$V.zip" "MossImage-$V.dmg" > SHA256SUMS)
ls -lh "$D"
