# MOSS Image for Mac

A native macOS app for generating images with [MOSS-Image](https://github.com/OpenMOSS/MOSS-Image),
OpenMOSS's 5B text-to-image model with strong text rendering, running locally on Apple Silicon through
[moss-image-mlx](https://github.com/felix-ab/moss-image-mlx).

![MOSS Image for Mac](docs/screenshot.png)

No ComfyUI, no CUDA. A 1024×1024 image takes about 40 seconds on an M4 Pro with the 8-step adapter,
and the compact model needs about 7 GB of memory.

## What it does

- Prompt, aspect ratio (1:1 to 21:9) and pixel budget presets. Sizes are always valid multiples of 16.
- Two tabs: **Text to image** and **Image to image**, each with a **Layout** view.
- **Layout control.** MOSS-Image's distinctive feature: draw boxes on the canvas, move and resize them, mark
  each as object, character or text, type the exact text, and the model places it there. In image-to-image the
  boxes sit over the source picture. The app compiles them to the model's JSON layout format; the prompt field
  is the summary caption.
- **Prompt enhancer.** One click expands a short idea into a detailed caption, or into a full layout with boxes
  in layout mode. Runs locally through mlx-lm (Qwen3 4B by default, about 4 s per prompt once downloaded), or
  through the Claude API with your own key. Revert with one click.
- **Image to image and inpainting.** Drop a source image, set a strength, paint a mask over the parts to
  regenerate in the Mask view. Untouched pixels stay identical.
- **LoRA library.** Search the Hugging Face Hub inside the app, or add local files. Several adapters can be
  active at once, each with its own strength and trigger word. Trigger words are added to the prompt only while
  the adapter is on.
- **Variations and queue.** Right-click an image for four more seeds or a 2 MP re-render of the same seed.
  Press ⌘↩ while a render runs to queue another. Queued renders share one model load.
- Few-step rendering with the [lodestones 8-step DMD adapter](https://huggingface.co/lodestones/MOSS-Image-SFT-8-steps-dmd)
  installed by default: 8 steps, no CFG, roughly 12× faster than the stock 50-step sampler.
- Advanced: steps, CFG, negative prompt, seed, model tier, negative-branch block skipping, skip-layer guidance.
- Preview with scroll-wheel zoom, drag to pan, double-click to toggle fit. History strip of every image in the
  output folder. Every PNG gets a JSON sidecar with the exact settings.

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
5. Layout: open the **Layout** view. Drag on empty space to draw a box, drag a box to move it, drag a corner to
   resize. Pick Text for lettering and type the exact words in the inspector. Or write a short idea, tick
   **Layout** in the sidebar, and press **Enhance** to have the model draft the boxes.
6. Image to image: switch to the **Image to image** tab, drop a file on the Source view or right-click a result
   and choose "Use as source image". Strength 0.3 keeps the picture, 0.8 keeps only the composition. In the
   **Mask** view, paint the area to change; everything else stays pixel-identical.
7. Enhance uses a local MLX chat model by default (set in Settings, ⌘,; first use downloads it). Switch the
   backend to Claude there if you prefer, with an Anthropic API key kept in your keychain.

Tips for MOSS-Image prompts, layout JSON and text rendering are in the
[MOSS-Image user guide](https://github.com/OpenMOSS/MOSS-Image/blob/main/USERGUIDE.md).

## The moss-image-mlx patches

moss-image-mlx 0.1.0 has no adapter loading and no image input. `patches/` adds:

- `--lora PATH[:SCALE]`, repeatable. Adapters are applied unmerged beside the quantized base weights, in
  fp32, which is what the few-step DMD adapters need (their deltas are smaller than bf16 rounding and vanish
  if merged). kohya and diffusers/PEFT key formats are both read. Upstream PR:
  [felix-ab/moss-image-mlx#2](https://github.com/felix-ab/moss-image-mlx/pull/2).
- `--init PATH --strength F --mask PATH`: an MLX port of the Flux2 VAE encoder (weights fetched from the
  official OpenMOSS repo on first use, 237 MB), flow-matching image-to-image, and per-step latent blending for
  inpainting. Encoder parity against the PyTorch VAE: max abs diff 0.024 on fp32 latents, 40.8 dB round trip.

`setup.sh` applies the patches to the pinned upstream commit.

## Build from source

```bash
./build.sh          # swift build + app bundle, writes MossImage.app
./tests.sh          # headless checks compiled against the app sources (see below)
```

`tests.sh` builds `Tests/checks/main.swift` together with the app's non-UI sources and runs 43 checks:
layout compilation against the documented example, enhancer draft parsing, the batch JSON the app
sends versus the fields the CLI accepts, trigger-word merging, size presets, source-aspect matching,
mask-from-boxes pixels, the empty-text-box guard, a real two-image batch through the queue, the local
enhancer, and Hub search. The live checks need the venv from `setup.sh` and the cached model.

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
