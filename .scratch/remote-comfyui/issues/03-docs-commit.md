# 03: Docs & commit

**What to build:** The README documents the remote option: what the server needs (ComfyUI 0.42+ with MOSS-Image support, the three model files the app names: checkpoint / text encoder / VAE; LoRAs must be installed server-side), how the Settings section maps to them, and explicitly what stays local (everything except generation). Work committed to the current branch in reviewable commits: core backend, tests, docs.

**Blocked by:** 02 (End-to-end tests).

**Status:** done — awaiting reviewer sign-off under ticket 04

- [x] README section: remote option, server requirements, settings mapping, what stays local, i2i/LoRA notes
- [x] Commits on main: backend core / tests / docs, each green
