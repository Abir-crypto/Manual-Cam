# Astro Mode — SPEC.md

Depends on the base app in `SPEC.md` (CameraSessionManager, ManualControlEngine, PhotoCaptureService, CameraPreviewView). This file adds a new top-level shooting mode alongside Manual and Portrait.

## Overview

Astro Mode is a **manual exposure-stacking tool**, replicating the real DSLR/astrophotography workflow (shoot N frames at fixed manual settings, then blend them in software) — not an automatic "Night Mode" clone. Manual controls (ISO, shutter, focus, WB, EV) **remain fully active and user-controlled** in this mode, unlike Portrait Mode. Astro Mode adds a stacking layer on top of manual capture: user picks a shot count, locks in manual settings as usual, then starts a sequential capture run that gets aligned and blended into a single output image.

This mode also covers what would otherwise be "Night Mode" — a small shot count (e.g. 4–8) and short total duration works fine for general low-light noise reduction, so no separate Night Mode entry is needed.

---

## Task 1 — Mode Switcher Entry

- Add "Astro" to the top-level mode switcher (Manual / Portrait / Astro) alongside Task 1 of PORTRAIT_MODE.md
- Unlike Portrait, entering Astro mode does **not** hide the manual control tabs/sliders from the base spec — they stay exactly as-is, fully functional
- Astro mode adds its own **additional** control panel on top of (not replacing) the base manual controls

**Acceptance:** entering Astro mode shows the existing manual controls plus new Astro-specific controls (Task 3), all functional simultaneously.

---

## Task 2 — StackCaptureEngine (core module)

Build `StackCaptureEngine` as a standalone, reusable module — this is the shared engine referenced by this file (no separate Night Mode file needed since this covers both use cases):

**State machine:** `idle → capturing(frame N of total) → aligning → stacking → done`

**Capture loop:**
- Fires `PhotoCaptureService` (base spec Task 5) sequentially, `shotCount` times, using whatever manual settings (ISO/shutter/focus/WB/EV) are currently locked in via `ManualControlEngine` at the moment the run starts
- Settings are **locked for the duration of the run** — if the user adjusts a slider mid-run, ignore it until the run completes (avoid inconsistent frames mid-stack)
- Each frame captures RAW+HEIC twin as normal (base spec behavior) — **every individual RAW frame is saved to the album**, consistent with archiving originals for later desktop re-processing
- For the stacking math itself, use the **processed pixel buffer** (HEIC-quality image data), not the RAW — developing/demosaicing every RAW frame on-device for N frames would be too slow/memory-heavy; RAW frames are archived for optional external re-stacking, not used in the in-app stack

**Alignment:**
- Use Vision framework registration — `VNHomographicImageRegistrationRequest` by default (handles handheld drift: rotation + translation + slight perspective shift)
- Offer a **Handheld / Tripod** toggle (Task 3): Tripod mode uses the cheaper `VNTranslationalImageRegistrationRequest` (sufficient when the phone itself isn't moving — e.g. accounting for star drift from Earth's rotation, which is a uniform shift, not handheld shake)
- Align each new frame against the first frame (reference frame) before accumulating

**Incremental accumulation (memory-safe):**
- Do **not** hold all N frames in memory simultaneously
- Maintain a running accumulator buffer (32-bit float, via Accelerate/vImage) sized to one frame
- As each frame is captured and aligned, immediately blend it into the accumulator per the selected blend mode (Task 2b below), then release the original frame from memory
- Normalize (for Average mode) only once at the very end

**Blend modes (user-selectable, Task 3):**
- **Average** — running mean across all frames; standard noise-reduction stacking
- **Lighten/Max** — keep the brightest value per pixel across all frames seen so far; produces star-trail-style results (each star's path stays visible rather than blurring into a mean)

**Output:**
- Final stacked image saved as HEIC to the app's dedicated album (base spec Task 5's album)
- No live progressive preview during the run (per earlier decision) — show progress only (Task 4), reveal the final stacked result only once `done`

**Acceptance:** running a stack of N frames produces one final blended image, individual RAWs all present in the album, memory usage stays flat (not growing linearly) across large shot counts, Average and Lighten modes produce visibly different results on a starfield test shot.

---

## Task 3 — Astro Control Panel UI

Additional panel shown in Astro mode, alongside (not replacing) the base manual controls:

```
┌─────────────────────────────────┐
│  (existing top bar + manual     │
│   controls from base SPEC.md,   │
│   unchanged)                     │
│                                  │
│  Shots: [ - 12 + ]               │  ← shot count stepper
│  Blend: [Average][Lighten/Max]  │  ← blend mode picker
│  Align: [Handheld][Tripod]      │  ← alignment mode picker
│                                  │
│      ( ▶ Start Stack )           │  ← replaces normal shutter button
└─────────────────────────────────┘
```

- **Shot count stepper:** free user choice, no hard cap suggested in UI, but sanity-check extremely large values (e.g. warn above ~60 shots given time/battery cost) rather than blocking outright
- **Blend mode picker:** Average / Lighten-Max, as built in Task 2
- **Alignment mode picker:** Handheld / Tripod, as built in Task 2
- **Start Stack button:** replaces the normal shutter button while in Astro mode — tapping it locks current manual settings and begins the `StackCaptureEngine` run
- Manual control sliders (ISO/shutter/focus/WB/EV) remain visible and adjustable **before** starting a run, become read-only/disabled once a run is `capturing` (per the lock in Task 2), re-enabled once `done`

**Acceptance:** all controls present and functional per this layout; sliders correctly lock during an active run and unlock after.

---

## Task 4 — Progress UI

- While `StackCaptureEngine` is in `capturing` state: show "Shot X of N" progress (simple progress bar or counter text)
- While in `aligning` / `stacking` state: show an indeterminate "Processing…" indicator (this can take a few seconds for larger shot counts)
- On `done`: reveal the final stacked image directly (same thumbnail-confirmation pattern as base spec Task 8), no intermediate previews shown during the run
- Provide a **cancel** option during `capturing` — stopping early should still attempt to stack whatever frames were captured so far, rather than discarding the whole run

**Acceptance:** progress is clearly visible throughout a run; cancelling mid-run still produces a usable (if noisier) stacked result from partial frames.

---

## Task 5 — Tripod Stillness Check (optional but recommended)

- Using CoreMotion, monitor device stillness before/during a run when Alignment mode is set to "Tripod"
- If significant motion is detected mid-run (e.g. phone bumped), surface a non-blocking warning after the run completes ("Motion detected during capture — results may be affected") rather than interrupting the run itself
- This is advisory only, not a hard gate — do not block capture based on this check

**Acceptance:** a deliberately shaken run still completes and stacks, but surfaces the warning afterward.

---

## Explicitly out of scope for this file

- Separate Night Mode entry/UI (covered by using a smaller shot count in this same engine)
- Live progressive stack preview during capture
- True star-alignment/plate-solving (per-star registration) — Vision's general-purpose registration is used instead, not astronomy-specific alignment
- Dark-frame subtraction / hot-pixel calibration
- On-device RAW demosaicing for the stacking math itself (RAW frames are archived only, not used for in-app blending)
