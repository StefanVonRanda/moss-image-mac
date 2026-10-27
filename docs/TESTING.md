# MOSS Image 1.0.0: test on a clean Mac

Thank you for testing. The point is a Mac that has **never** had MOSS Image installed. You need about
45 minutes, most of it waiting for downloads (roughly 14 GB in total).

## Before you start

- Apple Silicon Mac (M1 or newer), macOS 14 or newer, 16 GB of memory, 16 GB of free disk.
- Internet. No Terminal experience needed except where this sheet says so.
- Do the DMG test on a **second** fresh Mac or user account if you can; otherwise uninstall between the
  two install tests (see the end of this sheet).

## 1. Install with the one-line command

Open Terminal (Applications → Utilities → Terminal) and paste:

```bash
curl -fsSL https://raw.githubusercontent.com/StefanVonRanda/moss-image-mac/main/install.sh | zsh -s -- 1.0.0
```

- [ ] It prints "Downloading MOSS Image 1.0.0…", then "is installed in /Applications".
- [ ] No password prompt and no `sudo`.
- [ ] `MOSS Image` appears in Applications and opens **without** a Gatekeeper warning.
- [ ] Run the same command a second time: it should finish successfully again and replace the copy.
- [ ] If anything else happens, copy the Terminal text into your report.

## 2. First run

- [ ] A setup window appears and checks the Mac (Apple Silicon, macOS, memory, disk).
- [ ] It downloads about 1.5 GB with a progress bar. Time it: ______.
- [ ] It says the engine is installed; the image model will download with the first picture.
- [ ] Quit and reopen the app: the setup window does **not** appear again.

## 3. First image

- [ ] Type `a red ceramic teapot on a wooden table, morning light`, leave 1:1 and 1 MP, press ⌘↩.
- [ ] The model downloads 12 GB with progress. Time the whole first render: ______.
- [ ] An image appears and is saved in `~/Pictures/MOSS Image` (Finder → Pictures).
- [ ] Render one more image: it should take about 40 seconds (M-series Pro) and show a blurred live preview.

## 4. Layout and text

- [ ] Press **Layout**, drag a box on the picture, choose **Text**, type `MOSS` and set a colour.
- [ ] Generate: the letters appear inside the box, spelled correctly.

## 5. Edit

- [ ] Switch to the **Edit** tab, drop a photo or illustration in.
- [ ] Type `make the background deep teal` and Generate. The first edit downloads an adapter.
- [ ] The subject and style are kept; the result becomes the new picture. Hold Space to compare.
- [ ] Generate a second edit on top of the result (`make it night time`): edits chain.

## 6. Quit and reopen

- [ ] Quit (⌘Q), reopen: the history strip still shows your images, and the Edit tab still has its picture.
- [ ] Settings (⌘,) → Engine shows the location and version, not "not installed".

## 7. Uninstall

Follow the README's Uninstall section, then check:

- [ ] The app is gone from Applications.
- [ ] `~/Library/Application Support/MOSS Image` is gone.
- [ ] Reinstalling with the one-line command starts from scratch again (setup window appears).

## 8. DMG (only if you did not do this on another Mac)

Download `MossImage-1.0.0.dmg` from the release, open it, drag **MOSS Image** to Applications.

- [ ] The first launch is blocked, as described in the README.
- [ ] The README's "Open Anyway" steps work on your macOS version (say which one).
- [ ] After that, the app opens normally every time.

## What to send back

1. This sheet, with the boxes ticked and the two timings filled in.
2. Screenshots of: the setup window, the first image, the Layout result, the Edit result.
3. The log: after a render, click **Log** above the status bar, **Copy**, and paste it into an email or
   a text file. For setup problems, **Copy Log** in the setup window.
4. Your Mac model and memory (Apple menu → About This Mac), and the macOS version.
5. Anything that was confusing, slow, or looked wrong. Blunt is useful.

If something fails, stop and send the log; do not try to fix it.
