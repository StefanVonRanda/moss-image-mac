# MOSS Image for Mac

A native macOS app for generating images with [MOSS-Image](https://github.com/OpenMOSS/MOSS-Image),
OpenMOSS's 5B text-to-image model with strong text rendering, running locally on Apple Silicon through
[moss-image-mlx](https://github.com/felix-ab/moss-image-mlx).

![MOSS Image for Mac](docs/screenshot.png)

No ComfyUI, no CUDA. A 1024×1024 image takes about 40 seconds on an M4 Pro with the 8-step adapter,
and the compact model needs about 7 GB of memory.

## What it does

- Prompt, aspect ratio (1:1 to 21:9) and pixel budget presets. Sizes are always valid multiples of 16.
- LoRA library. Add local `.safetensors` files or download any adapter from Hugging Face by repo id.
  Several adapters can be active at once, each with its own strength.
- Trigger words. Set one per style adapter; it is added to the prompt while the adapter is on and
  removed when it is off. Your prompt text stays clean.
- The [lodestones 8-step DMD adapter](https://huggingface.co/lodestones/MOSS-Image-SFT-8-steps-dmd)
  is installed by default: 8 steps, no CFG, roughly 12× faster than the stock 50-step sampler.
- Advanced: steps, CFG, negative prompt, seed, compact or 8-bit model.
- Preview with scroll-wheel zoom, drag to pan, double-click to toggle fit. History strip of every
  image in the output folder. Every PNG gets a JSON sidecar with the exact settings.

## Requirements

- Apple Silicon Mac with 16 GB or more. 24 GB for the 8-bit model.
- macOS 14 or later.
- Swift toolchain: `xcode-select --install` is enough, Xcode is not required.
- Python 3.11 or later, or [uv](https://docs.astral.sh/uv/) (used automatically if present).
- About 15 GB of disk: 12 GB model, 1.2 GB adapter, build artifacts.

## Install

```bash
git clone https://github.com/StefanVonRanda/moss-image-mac.git
cd moss-image-mac
./setup.sh
open MossImage.app
```

`setup.sh` creates a Python environment in `~/moss-mlx`, installs moss-image-mlx with the LoRA patches
from `patches/`, downloads the 8-step adapter into `~/moss-mlx/loras`, and builds the app. Run it again
any time; finished steps are skipped. To install somewhere else: `MOSS_HOME=/path ./setup.sh`, then set
the paths in the app's Settings (⌘,).

The model itself (12 GB) downloads from Hugging Face the first time you generate.

## Use

1. Type a prompt. Pick an aspect and a pixel budget. Press ⌘↩ or click Generate.
2. Images land in `~/Pictures/MOSS Image`. Right-click the preview to copy it, reveal it in Finder, or
   reuse its prompt and seed.
3. To add a style LoRA: **Download…** and enter the Hugging Face repo id and filename, or **Add file…**
   for a local file. Toggle it on, set its strength, and paste its trigger word if it has one.
4. For the stock sampler instead of the 8-step adapter: turn the DMD adapter off and set steps 50,
   CFG 3 under **Advanced**.

Tips for MOSS-Image prompts, layout JSON and text rendering are in the
[MOSS-Image user guide](https://github.com/OpenMOSS/MOSS-Image/blob/main/USERGUIDE.md).

## The LoRA patches

moss-image-mlx 0.1.0 has no adapter loading. `patches/` adds `--lora PATH[:SCALE]`, repeatable:
adapters are applied unmerged beside the quantized base weights, in fp32, which is what the few-step
DMD adapters need (their deltas are smaller than bf16 rounding and vanish if merged). kohya and
diffusers/PEFT key formats are both read. `setup.sh` applies the patches to the pinned upstream
commit; they will be dropped once upstream ships its own LoRA support.

## Build from source

```bash
./build.sh          # swift build + app bundle, writes MossImage.app
```

The icon is rendered by `icon/make_icon.swift`:

```bash
swiftc -O icon/make_icon.swift -o icon/make_icon && ./icon/make_icon icon
iconutil -c icns icon/AppIcon.iconset -o icon/AppIcon.icns
```

For documentation screenshots, `MOSS_SCREENSHOT=/path/shot.png open MossImage.app` captures the
window two seconds after launch and quits.

## License

Apache-2.0. Not affiliated with OpenMOSS. MOSS-Image is their model and trademark; this app only
drives it.
