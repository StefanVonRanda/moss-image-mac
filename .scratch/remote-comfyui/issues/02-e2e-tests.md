# 02: End-to-end tests (stub server)

**What to build:** `./tests.sh`'s headless check harness gains end-to-end coverage of the remote backend without a real ComfyUI install: the checks spawn a stub server (local Python) speaking the four endpoints the backend uses (`/upload/image`, `/prompt`, `/history/{id}`, `/view`) and return a canned PNG. Checks drive the app's real run path and verify: t2i graph reaches the stub with KSampler seeded from the render; layout JSON passed through as the positive prompt; i2i graph carries LoadImage→VAEEncode with denoise=strength; box-inpaint adds mask+blur+SetLatentNoiseMask; LoRA specs parsed and forwarded; returned image bytes land at the render's output path with a CLI-shaped sidecar (parameters + loras + app) that reuse/re-render can restore. Graph-builder checks run without the stub (link integrity, node field mapping).

**Blocked by:** 01 (Remote generation core).

**Status:** done — awaiting reviewer sign-off (ticket 04)

- [x] Stub server in the harness; checks using it are skipped with a note if Python 3 is unavailable
- [x] Graph checks: t2i, layout passthrough, i2i, mask/inpaint, LoRA chain order, link integrity (no dangling refs)
- [x] Run-path e2e: upload once per file, submit, image lands at output path, sidecar restorable via the app's own restore()
- [x] `./tests.sh` green end to end
