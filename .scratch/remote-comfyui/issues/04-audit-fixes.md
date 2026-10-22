# 04: Audit fixes (review intake)

**What to build:** Fixes for whatever the review of tickets 01–02 turns up. Each finding: reproduce or reason it to a confirmed diagnosis, fix, re-run `./tests.sh`, note the fix on this issue. Closed when the reviewer signs off.

**Blocked by:** 03 (Docs & commit) — but findings may be logged here at any time; work starts when the review lands.

**Status:** closed — reviewer sign-off 2026-10-23 (F1–F5 fix notes + F6–F8 live-server round: all fixed, `./tests.sh` green, no /tmp leaks)

## Findings from the audit of session 1a16455 (user, 2026-10-22)

- **F1 — Node-ID collision at ≥10 LoRAs** (confirmed, high): `Comfy.swift:28` allocates LoRA chain ids `10+i`, colliding with fixed ids 20 (SLG) and 21–25 (i2i); a 10th adapter silently replaces the SLG node and a self-referencing graph is invisible to `validate` (it only checks missing targets).
  *Fixed:* LoRA chain ids move to a reserved range (100+i); `validate` gains self-reference detection; boundary checks for 0/1/10/15 adapters across slg/i2i shapes.
- **F2 — Server-side prompt failure hangs the run 30 min** (confirmed, high): `Generator.swift:653` waits only for outputs; nothing reads the history entry's `status.status_str`, so an errored prompt looks identical to a running one — the only fast-failure path is the WS, which reverse-proxy deployments typically lack.
  *Fixed:* `outputs()` throws with the server's error detail when `status_str == "error"`; the runner catches (no more `try?`), reports "ComfyUI: …", drains and unwinds; deadline becomes a named constant with a comment; stub gains an error mode with a fail-fast check.
- **F3 — Remote renders silently ignore the sidebar's LoRA selection** (confirmed, medium): `startComfy` took LoRAs solely from the free-text field; the sidebar's `loraState` was discarded, and the tests zeroed it — masking the divergence.
  *Fixed:* remote adapters derive from the sidebar's active set (same order/scales as the local `modelArgs`); the settings field becomes a translation layer: `localname=servername:strength` maps files, unmatched local names go 1:1 with the sidebar's scale, plain entries are explicit always-on extras. Settings text updated; tests extended to the sidebar-driven case.
- **F4 — WebSocket never exercised** (confirmed, medium): no `/ws` in the stub; `receiveComfy`/`ComfyEvents`/ETA untested.
  *Fixed:* `ComfyEvents.parse` unit checks for every event kind + malformed input; the stub speaks WS (`progress` and `execution_error` modes); a run-path check asserts progress/status strings arrive through the socket and the run still completes on polling alone.
- **F2 tradeoff, kept deliberately** (reviewer note, 2026-10-22): since the try? was removed, any outputs() error fails the batch immediately — including a transient proxy 5xx that the next poll would once have ridden out. Correct for genuinely dead prompts, harsh on one-second blips. If `history HTTP 5xx` ever shows up in the field, a single in-place retry before propagating the failure is the agreed softening point.
- **F5 — batch progress possibly exceeding batchTotal** (unverified, low): left as a watch item — the WS progress filter matches only the current prompt id and ids are assigned per render, so a stale id cannot advance the counter while another prompt is queued.
- Hygiene: stub's no-op `sys.argv` line removed; 1800 s magic number named and commented.

## Findings from the live-server review (user, 2026-10-22)

- **F6 — app-side featherMask did not implement the CLI's contract** (confirmed, high): the commit claimed parity with `moss_image_mlx/pipeline.py load_mask`, but the shipped feather only gaussian-blurred with the full radius and never dilated — PIL gets `MaxFilter` (dilate by `feather` px) then `blur(feather/2)`. Measured on the CLI's own fixture: a 24 px box regenerated at 46 % strength with the default feather 12, diluting every small edit proportionally (a `SetLatentNoiseMask` mask value is the per-step blend factor, so small boxes read as "the edit barely took").
  *Fixed:* `Generator.featherMask` now mirrors `load_mask` — binarize at 50 %, `CIMorphologyMaximum(radius)` (the MaxFilter), then `CIGaussianBlur(radius/2)` and a final clamp. `UploadedTracker.mask` routes all masks through it (radius 0 still binarizes, as the CLI does). Temp plumbing unchanged.
- **F7 — test asserted only that featherMask returns a PNG** (confirmed, medium): no mask-value checks, so the F6 semantic regression passed silently. The CLI's own test (`src/tests/test_i2i.py::test_mask_feather`) is now ported verbatim — interior opaque, dilated edge > 0.8, mid-ramp at +4 px, zero at +24 px, and feather 0 still binarizes. Two port notes: the CLI indexes numpy `[row, col]` and CG samples `(x: col, y: row)` (the first port swapped them and probed painted pixels where the CLI probes the outside ramp); and CoreImage's truncated gaussian kernel floors interiors at ~0.98 where PIL saturates uint8 to exactly 1.0 — the port tolerates ≥ 0.97, ~25 points above the F6 failure mode (~0.64).
  *Fix footnote:* the first fixture was built with `NSBitmapImageRep.setColor`, which silently writes nothing in this headless harness (every colorAt read back all-zero, so the *correct* mask also failed) — the fixture now fills `bitmapData` bytes directly, with the finding recorded in the test comment.
- **F8 — minor, test-harness temp leak** (confirmed, low): the feather check called `featherMask` directly and leaked one `/tmp/moss-feather-*.png` per run. Fixed with the same `defer`-remove pattern the production `UploadedTracker.mask` uses; production path was already clean.
- [x] F6/F7/F8 fixed; `./tests.sh` green after the last fix (all checks, no /tmp leak on a full run)

- [x] Each review finding fixed or explicitly disposed of with a reason (F1–F4 fixed; F5 logged as a watch item with reasoning)
- [x] `./tests.sh` green after the last fix (all ~60 checks; suite also grew boundary + ws + fail-fast coverage)

## Fix notes (what landed beyond the diagnosis)

- All four fixes plus three-of-a-kind extras the fixes flushed out while running the new tests:
  - the runner's WebSocket session is batch-scoped and invalidated with the batch (side-effect hardening, kept after the root cause turned out to be a stale test server);
  - the harness now proves a fresh server via a per-run nonce in `/system_stats` before trusting it — a stale stub from a previous run also answers pings, which misdirected the first round of ws debugging;
  - a real receive path bug the new tests exposed: the stub emits **text** frames and the receive loop only handled `.data`, so text frames were treated as "connection closed" and silently stopped the stream; both frame kinds now feed the same consumer.
