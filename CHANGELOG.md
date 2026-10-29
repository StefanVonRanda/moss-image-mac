# Changelog

## Unreleased

**Local image models**
- The Model picker in Advanced gains a **Custom** choice. Pick a full MOSS-Image checkpoint as one
  `.safetensors` file (ComfyUI's `model.diffusion_model.` layout, fused q/k/v); the app converts it once
  into the engine's transformer layout, keeps the file untouched, and renders with the selected
  Compact/8-bit tier's text encoder, tokenizer and VAE. Switching back to a tier keeps the converted
  copy available under Custom. Named checkpoints are recorded in their sidecars so re-renders use the
  same one.
- LoRA files are still added through the LoRA library; a LoRA picked as a model is refused with a clear
  message instead of a failed render.
- The prompt enhancer's backend and model can be switched from **Advanced → Prompt enhancer** in the
  sidebar as well as Settings, and a gear button in the toolbar opens Settings without the keyboard.
  A local MLX model can be a repo ID or a folder chosen with the folder button (mlx-lm models are a
  directory of config, tokenizer and weight shards, not one file).

## 1.0.0 — 2026-10-27

First release: a native macOS app for [MOSS-Image](https://github.com/OpenMOSS/MOSS-Image) on Apple
Silicon, running locally through [moss-image-mlx](https://github.com/felix-ab/moss-image-mlx).

**Generate**
- Text to image with a prompt, aspect ratio, pixel budget and seed; queue renders while one runs.
- Layout editor on the canvas: Text, Object, Fill and Character boxes compiled to MOSS-Image's layout
  JSON, with Enhance drafting the boxes from a short idea.
- Image to image: whole-picture re-renders at a strength, box edits with feathered masks, Fill boxes,
  outpainting and canvas extension, and a history strip of every render.
- Live per-step preview while a local render runs.

**Edit**
- An Edit tab for instruction edits ("change the raincoat to deep teal") with MOSS Image Edit or
  Edit-HQ v5, chained edits, up to four pictures, and optional alpha preservation.
- Character reference (CharRef v2): the same character in a new scene, on the Text tab.

**Looks and adapters**
- Transparent background: a real alpha channel via paralaif's alpha LoRA and the RGBA VAE.
- Quality presets: Draft (8-step DMD adapter), Turbo (the engine's trained 15-pass sampler) and Full
  (50 steps, CFG 3, with the destripe adapter).
- Colour/depth control adapter, layout and image-to-image compatible.
- LoRA library with Hugging Face Hub search, local file import, stacking, per-adapter strengths and
  trigger words, and the 8-step DMD adapter installed by default.
- Prompt enhancer: a local MLX model (Qwen3 4B) or the Claude API with your own key.

**Backends**
- Local MLX engine, or a remote ComfyUI server (0.42+) with checkpoint/text-encoder/VAE names, LoRA
  name mapping and an optional bearer token. Remote renders keep history, the layout editor and the
  enhancer local; unsupported combinations are refused rather than faked.

**Install and release**
- The engine installs on first run from a bundled `uv`, a pre-patched moss-image-mlx wheel and a
  hash-pinned lockfile, into `~/Library/Application Support/MOSS Image/`.
- One-line installer (`install.sh`) with checksum verification, or a DMG. Both are ad-hoc signed and
  unsigned by Apple; the README covers Gatekeeper.
- `setup.sh` installs from source and keeps working; existing `~/moss-mlx` installs are used as they are.
- `scripts/check.sh` is the local release gate: build, headless checks, script syntax, patches, engine
  lock.

**Known limitations**
- macOS 14+ on Apple Silicon only; no Intel Macs.
- The app is not notarized. The one-line installer avoids Gatekeeper; the DMG needs "Open Anyway".
- Turbo makes new pictures only: edits, extensions, character references and control renders run as
  Draft.
- More than one reference picture on the Edit tab is experimental; both edit models were trained on
  single-picture edits.
- ComfyUI renders show step counts instead of the live preview, and ignore negative-branch skip layers.
- The alpha adapter is licensed for non-commercial research and evaluation only.
