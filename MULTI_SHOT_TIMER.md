# Multi-Shot Timer — SPEC.md

Depends on the base app in `SPEC.md` (ManualControlEngine, PhotoCaptureService, CameraPreviewView). This is a standalone shooting aid usable **only in Manual mode** — not Portrait, not Astro (Astro has its own capture-run mechanics per ASTRO_MODE.md).

## Overview

An intervalometer: user sets an initial countdown delay, a number of shots, and the interval between subsequent shots, then starts the sequence and can step away from the phone (e.g. to get into frame). Each shot is captured and saved as its own **separate** photo using the existing Manual-mode capture pipeline — this is not a stacking feature, no blending happens.

---

## Task 1 — Timer Configuration UI

- Add a timer icon to Manual mode's top bar (alongside the existing RAW/HEIC toggle, peaking toggle, and gear icon from base spec Task 8)
- Tapping it opens a sheet with three inputs:
  - **Initial delay** — seconds before the first shot fires (stepper or text field, reasonable range e.g. 0–60s)
  - **Shot count** — number of shots to take (stepper, e.g. 1–50)
  - **Interval between shots** — seconds between each subsequent shot after the first (stepper, e.g. 1–60s)
- A "Start" button in the sheet begins the sequence and dismisses the sheet, returning to the live camera view with an active countdown overlay (Task 2)
- Current manual settings (ISO/shutter/focus/WB/EV) are **locked at the moment Start is tapped** and used unchanged for every shot in the sequence — consistent exposure across the set, same locking principle as Astro's stacking runs

**Acceptance:** sheet takes all three inputs, Start begins the sequence with current manual settings frozen for its duration.

---

## Task 2 — Countdown Execution & On-Screen Feedback

Build `IntervalometerService` (ObservableObject) driving the sequence:

- State: `idle → counting down (shot 1) → capturing → counting down (shot 2) → capturing → ... → done`
- On-screen: a visible countdown (large numeral or ring countdown) during each delay period, and a brief flash/indicator at the moment each shot fires
- Show progress throughout: "Shot 2 of 5", so it's clear how far through the sequence you are even if you glance at the phone from a distance
- A **cancel** button visible throughout the sequence, stops immediately, any shots already taken remain saved

**Acceptance:** visible countdown and progress state accurately reflects the current point in the sequence; cancel stops cleanly without affecting already-saved shots.

---

## Task 3 — Audio Cues

- Play an audible beep before **every** shot in the sequence (not just the first) — since the user may be away from the phone repeatedly throughout a multi-shot run, not just at the start
- Suggested pattern: a rising sequence of short beeps in the last ~3 seconds before each capture (e.g. beep-beep-beep, faster near the end), giving a "get ready" cue each time, followed by a distinct shutter sound at the moment of capture
- Respect system silent switch / mute state as a normal iOS camera app would (shutter sound conventions), but the countdown beeps specifically should still play even in silent mode if feasible (this is a functional cue, not a notification) — flag if this needs an explicit in-app override toggle instead of fighting the system silent switch
- Audio session configured to not fight with any music/audio playing elsewhere on the device unnecessarily — use a transient, mixable audio session category

**Acceptance:** a beep sequence plays before every shot in a multi-shot run, not just the first; capture sound is distinct from the countdown beeps.

---

## Task 4 — Capture & Save Behavior

- Each shot in the sequence uses the existing `PhotoCaptureService` (base spec Task 5) exactly as a normal Manual-mode capture would — same RAW/HEIC twin behavior based on the current top-bar toggle setting, same album save destination
- Each shot saved as its own independent photo — no merging, no relation between shots beyond having been part of the same run
- Post-sequence: no special summary screen needed: base spec's existing thumbnail-confirmation (Task 8) firing after each shot is sufficient feedback, or optionally suppress the individual per-shot thumbnail flash during a run and just show one summary at the very end (implementer's choice — either is acceptable, pick whichever is simpler to build cleanly)

**Acceptance:** running a 5-shot sequence produces 5 independent photos in the album, each respecting the RAW/HEIC setting active when Start was tapped.

---

## Explicitly out of scope for this file

- Any interaction with Astro Mode's stacking engine (fully separate feature, per earlier decision)
- Blending/combining shots from a timer run
- Remote/external trigger support (e.g. Apple Watch, Bluetooth shutter)
