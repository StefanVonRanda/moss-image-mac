# Contributing

Thanks for taking a look. This is a small native app around someone else's model and engine, so most
changes are either SwiftUI in `Sources/MossImage/` or a patch to the engine in `patches/`.

## What you need

- An Apple Silicon Mac on macOS 14 or newer.
- **Full Xcode**, not just the Command Line Tools: this app uses SwiftUI's macros (`@State` and friends),
  and the Command Line Tools' SDK does not ship their plugin. Check with `xcode-select -p`; it should
  point into `Xcode.app`. If it does not, select it once:

  ```bash
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
  ```

- For the engine: Python 3.11+ or [uv](https://docs.astral.sh/uv/). `setup.sh` sets up a venv, applies
  `patches/` to the pinned [moss-image-mlx](https://github.com/felix-ab/moss-image-mlx) commit, and
  builds the app.

## Build and test

```bash
./build.sh        # release build into MossImage.app
./tests.sh        # headless checks of the app's logic, no GUI
scripts/check.sh  # the release gate: build, tests, script syntax, patches, engine lock
```

`scripts/check.sh` is what must pass before a release; `scripts/release.sh` refuses to build when it
fails. There is no cloud CI on purpose, so run it locally before opening a pull request.

Tests live in `Tests/checks/main.swift` and compile against the app's sources minus `MossImageApp.swift`,
so they can call app types directly. The live checks need the venv from `setup.sh` and the cached
model; they say which check failed.

## The engine patches

The engine is not vendored. `setup.sh` clones moss-image-mlx at the commit in `PIN` and applies every
`patches/*.patch` with `git am`, in filename order. A patch whose subject is already in the install's
history is skipped, so re-running `setup.sh` brings an existing install up to date.

- Add a new feature as the **next numbered patch**, crafted on top of the current `PIN` and the
  patches before it. Do not rewrite existing patches unless you are re-porting the series to a new
  upstream commit (`PIN` changes too, in the same commit).
- The commit subject becomes the identity `setup.sh` matches on; keep it stable once released.
- `scripts/check.sh` applies all patches to a fresh clone, and `scripts/release.sh` rebuilds the
  engine payload from them. If either fails, the patch series is not shippable.

## Style

Follow the surrounding code: small focused views, comments that say *why* (not what), no new
dependencies without a reason. The app deliberately has no package dependencies beyond the standard
frameworks; the engine is the only Python.

## Reporting a bug

Use the issue template (app version, macOS, Mac model and RAM, what you did, the log). The log is the
**Log** button above the status bar: open it, press **Copy**, and paste it into the issue.
