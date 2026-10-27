#!/bin/zsh
# Shared build preflight. This app uses SwiftUI's macros (@State and friends); their compiler plugin
# ships with Xcode, not with the Command Line Tools. Under CLT alone swiftc fails deep in the build with
# "plugin for module 'SwiftUIMacros' not found", so pick Xcode for this run, or say how to.
[[ -n ${MOSS_TOOLCHAIN_READY:-} ]] && return 0
if [[ -z ${DEVELOPER_DIR:-} && "$(xcode-select -p 2>/dev/null)" == /Library/Developer/CommandLineTools ]]; then
  if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    print -r -- "note: using Xcode's toolchain (SwiftUI macros need Xcode, not the Command Line Tools)" >&2
  else
    print -r -- "error: building this app needs full Xcode, not just the Command Line Tools." >&2
    print -r -- "       Install Xcode from the App Store, then run:" >&2
    print -r -- "       sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
    exit 1
  fi
fi
export MOSS_TOOLCHAIN_READY=1
