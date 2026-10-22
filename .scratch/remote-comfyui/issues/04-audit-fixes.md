# 04: Audit fixes (review intake)

**What to build:** Fixes for whatever the review of tickets 01–02 turns up. Each finding: reproduce or reason it to a confirmed diagnosis, fix, re-run `./tests.sh`, note the fix on this issue. Closed when the reviewer signs off.

**Blocked by:** 03 (Docs & commit) — but findings may be logged here at any time; work starts when the review lands.

**Status:** all findings fixed and tested — awaiting reviewer sign-off

## Findings from the audit of session 1a16455 (user, 2026-10-22)

- **F1 — Node-ID collision at ≥10 LoRAs** (confirmed, high): `Comfy.swift:28` allocates LoRA chain ids `10+i`, colliding with fixed ids 20 (SLG) and 21–25 (i2i); a 10th adapter silently replaces the SLG node and a self-referencing graph is invisible to `validate` (it only checks missing targets).
  *Fixed:* LoRA chain ids move to a reserved range (100+i); `validate` gains self-reference detection; boundary checks for 0/1/10/15 adapters across slg/i2i shapes.
- **F2 — Server-side prompt failure hangs the run 30 min** (confirmed, high): `Generator.swift:653` waits only for outputs; nothing reads the history entry's `status.status_str`, so an errored prompt looks identical to a running one — the only fast-failure path is the WS, which reverse-proxy deployments typically lack.
  *Fixed:* `outputs()` throws with the server's error detail when `status_str == "error"`; the runner catches (no more `try?`), reports "ComfyUI: …", drains and unwinds; deadline becomes a named constant with a comment; stub gains an error mode with a fail-fast check.
- **F3 — Remote renders silently ignore the sidebar's LoRA selection** (confirmed, medium): `startComfy` took LoRAs solely from the free-text field; the sidebar's `loraState` was discarded, and the tests zeroed it — masking the divergence.
  *Fixed:* remote adapters derive from the sidebar's active set (same order/scales as the local `modelArgs`); the settings field becomes a translation layer: `localname=servername:strength` maps files, unmatched local names go 1:1 with the sidebar's scale, plain entries are explicit always-on extras. Settings text updated; tests extended to the sidebar-driven case.
- **F4 — WebSocket never exercised** (confirmed, medium): no `/ws` in the stub; `receiveComfy`/`ComfyEvents`/ETA untested.
  *Fixed:* `ComfyEvents.parse` unit checks for every event kind + malformed input; the stub speaks WS (`progress` and `execution_error` modes); a run-path check asserts progress/status strings arrive through the socket and the run still completes on polling alone.
- **F5 — batch progress possibly exceeding batchTotal** (unverified, low): left as a watch item — the WS progress filter matches only the current prompt id and ids are assigned per render, so a stale id cannot advance the counter while another prompt is queued.
- Hygiene: stub's no-op `sys.argv` line removed; 1800 s magic number named and commented.

- [x] Each review finding fixed or explicitly disposed of with a reason (F1–F4 fixed; F5 logged as a watch item with reasoning)
- [x] `./tests.sh` green after the last fix (all ~60 checks; suite also grew boundary + ws + fail-fast coverage)

## Fix notes (what landed beyond the diagnosis)

- All four fixes plus three-of-a-kind extras the fixes flushed out while running the new tests:
  - the runner's WebSocket session is batch-scoped and invalidated with the batch (side-effect hardening, kept after the root cause turned out to be a stale test server);
  - the harness now proves a fresh server via a per-run nonce in `/system_stats` before trusting it — a stale stub from a previous run also answers pings, which misdirected the first round of ws debugging;
  - a real receive path bug the new tests exposed: the stub emits **text** frames and the receive loop only handled `.data`, so text frames were treated as "connection closed" and silently stopped the stream; both frame kinds now feed the same consumer.
