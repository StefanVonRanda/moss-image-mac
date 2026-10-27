#!/bin/zsh
# Installs MOSS Image from its GitHub release. Run:
#   curl -fsSL https://raw.githubusercontent.com/StefanVonRanda/moss-image-mac/main/install.sh | zsh
#   ... | zsh -s -- 1.0.0      a given version instead of the latest
# Checks the download against the release's SHA256SUMS, installs into /Applications (~/Applications when that is
# not writable; never sudo) and replaces an older copy only after the check. Safe to run again.
# Testing: MOSS_RELEASES_URL replaces the GitHub API base (…/releases; `latest` and `tags/v<v>` under it),
# MOSS_APPS_DIR the Applications folder.
set -euo pipefail
API=${MOSS_RELEASES_URL:-https://api.github.com/repos/StefanVonRanda/moss-image-mac/releases}
die() { print -r -- "$*" >&2; exit 1 }

[[ $(uname -m) == arm64 ]] || die "MOSS Image needs a Mac with Apple Silicon (M1 or newer). This Mac has an Intel processor."
os=$(sw_vers -productVersion)
(( ${os%%.*} >= 14 )) || die "MOSS Image needs macOS 14 (Sonoma) or newer. This Mac has macOS $os: update it in System Settings > General > Software Update, then run this again."

# the release: its tag and asset links from the GitHub API (one field per match, so line breaks don't matter)
if [[ -n ${1:-} ]]; then
  json=$(curl -fsSL "$API/tags/v${1#v}") || die "Could not find MOSS Image version ${1#v}. Check the version number and your internet connection."
else
  json=$(curl -fsSL "$API/latest") || die "Could not reach GitHub to find the latest MOSS Image. Check your internet connection and try again."
fi
field() { print -r -- "$json" | { grep -o "\"$1\": *\"[^\"]*\"" || true } | sed 's/.*"\([^"]*\)"$/\1/' }
v=$(field tag_name); v=${v#v}
asset() { field browser_download_url | grep -m1 "/$1\$" || true }
zip_url=$(asset "MossImage-$v.zip"); sums_url=$(asset SHA256SUMS)
[[ -n $v && -n $zip_url && -n $sums_url ]] || die "The MOSS Image release on GitHub is missing its files. Please try again later."

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
print "Downloading MOSS Image $v…"
curl -fsSL -o "$tmp/app.zip" "$zip_url" && curl -fsSL -o "$tmp/SHA256SUMS" "$sums_url" ||
  die "The download stopped. Check your internet connection and run this again."
want=$(awk -v f="MossImage-$v.zip" '$2 == f { print $1 }' "$tmp/SHA256SUMS")
got=$(shasum -a 256 "$tmp/app.zip" | cut -d' ' -f1)
[[ -n $want && $got == $want ]] || die "The download does not match its published checksum (damaged or changed), so nothing was installed. Run this again; if it keeps happening, please report it."
ditto -x -k "$tmp/app.zip" "$tmp/x"
codesign --verify --deep --strict "$tmp/x/MossImage.app" 2>/dev/null || die "The downloaded app failed its signature check, so nothing was installed."

if [[ -n ${MOSS_APPS_DIR:-} ]]; then dest=$MOSS_APPS_DIR
elif [[ -w /Applications ]]; then dest=/Applications
else dest=$HOME/Applications; fi
mkdir -p "$dest"
app="$dest/MossImage.app"
pgrep -qf "$app/Contents/MacOS/" && die "MOSS Image is open. Quit it (⌘Q), then run this again."
xattr -dr com.apple.quarantine "$tmp/x/MossImage.app" 2>/dev/null || true
# copy next to the old one first, then swap, so a failed copy never leaves you without an app
rm -rf "$app.new"; ditto "$tmp/x/MossImage.app" "$app.new"
rm -rf "$app"; mv "$app.new" "$app"

print "\nMOSS Image $v is installed in $dest."
print "Next: open it from $dest (or run: open \"$app\")."
print "On first start it sets up its image engine (about 1.5 GB download); the image model (12 GB) downloads with your first picture."
