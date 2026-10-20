# MOSS Image for Mac

Native SwiftUI front end for [moss-image-mlx](https://github.com/felix-ab/moss-image-mlx),
the Apple Silicon port of OpenMOSS's MOSS-Image text-to-image model.

![MOSS Image for Mac](docs/screenshot.png)

- Prompt, aspect ratio and pixel-budget presets (sizes are multiples of 16)
- LoRA library: import local `.safetensors`, download from Hugging Face, stack several adapters with
  per-adapter strength and trigger words that are added to the prompt only while the adapter is on
- Few-step DMD adapters (8 steps, no CFG) out of the box
- Advanced: steps, CFG, negative prompt, seed, model tier
- Preview with scroll-wheel zoom, drag pan, and a history strip of everything in the output folder

## Requirements

- macOS 14 or later, Apple Silicon
- Swift toolchain (Xcode or Command Line Tools)
- `moss-image-mlx` **with LoRA support** (`--lora PATH[:SCALE]`). Upstream 0.1.0 does not have it yet;
  until it lands, install the patched fork:

```bash
uv venv --python 3.12 ~/moss-mlx
git clone <your fork of moss-image-mlx> ~/moss-mlx/src
uv pip install --python ~/moss-mlx/bin/python -e ~/moss-mlx/src
```

The app calls `~/moss-mlx/bin/moss-mlx` by default. Change the path, the LoRA folder and the output folder
in Settings (⌘,).

## Build

```bash
./build.sh        # writes MossImage.app next to this file
open MossImage.app
```

The app icon is rendered from `icon/logo.svg` (the MOSS-Image mark) by `icon/make_icon.swift`:

```bash
swiftc -O icon/make_icon.swift -o icon/make_icon && ./icon/make_icon icon
iconutil -c icns icon/AppIcon.iconset -o icon/AppIcon.icns
```

## Use

1. Write a prompt, pick an aspect and a pixel budget. ⌘↩ generates.
2. In **LoRA**, toggle adapters on. Set a trigger word once per style adapter; it is prepended to the
   prompt automatically and removed again when the adapter is off.
3. **Download…** fetches any Hugging Face LoRA by repo id and filename. The known list sets steps and CFG
   for the lodestones 8-step DMD adapters.
4. Images and a JSON sidecar with the exact parameters land in `~/Pictures/MOSS Image`.

For docs, `MOSS_SCREENSHOT=/path/shot.png open MossImage.app` captures the window two seconds after
launch and quits.

Model weights download on first run to the Hugging Face cache (compact tier, 12 GB).
