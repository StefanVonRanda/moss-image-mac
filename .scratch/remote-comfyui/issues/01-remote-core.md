# 01: Remote generation core (ComfyUI)

**What to build:** From Settings (⌘,), "Generate on" gains two choices: "This Mac (moss-mlx)" (default, unchanged) and "ComfyUI server". With a server + its model filenames configured, Generate, right-click variations, re-render and ⌘↩ queueing execute on the remote server, both text-to-image and layout prompts (the app's compiled layout JSON is the model's prompt format). Images land in the local output folder with the same JSON sidecars local renders get, so history, reuse and re-render work identically. Cancel stops the remote prompt. I2I and box-inpaint renders also flow through this core (shapes verified further in ticket 02). Generation never falls back silently: connection problems surface as a status message.

**Blocked by:** None (can start immediately).

**Status:** done — awaiting reviewer sign-off (ticket 04)

- [x] Settings section: backend picker, server URL, optional token in keychain, checkpoint/text-encoder/VAE/LoRA fields, Test connection button
- [x] API-format workspace graph builder covering t2i, layout (prompt passthrough), i2i, mask, LoRA chain, SLG
- [x] Runner: ping, uploads (dedup per batch), sequential submit, WebSocket progress, output fetch to the render's path, sidecar write + app merge
- [x] Cancel interrupts the server-side prompt and drains the queue
- [x] Project builds; app runs; no regressions on the local path (backend default remains local)
- [x] LoRA list parsing "name:scale, name" → ordered specs
