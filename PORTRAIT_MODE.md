# Portrait Mode — SPEC.md

Depends on the base app in `SPEC.md` (CameraSessionManager, ManualControlEngine, PhotoCaptureService, CameraPreviewView). This file adds a new top-level shooting mode alongside Manual and Astro.

## Overview

Portrait Mode captures a depth map + subject matte alongside the photo, then renders a bokeh effect in post-capture processing (not live in preview). Manual controls are **hidden** in this mode — replaced with portrait-specific controls. No true relighting (Apple's Portrait Lighting styles use proprietary face-relighting ML not available to third-party apps) — styles here are matte-masked color grades and a custom swirl-bokeh render, which is an honest approximation, not a clone.

**Device requirement:** dual/triple-camera iPhone (`.builtInDualCamera`, `.builtInDualWideCamera`, or `.builtInTripleCamera`). Gate this mode's availability at runtime — hide/disable the Portrait entry in the mode switcher on unsupported devices (e.g. base non-Pro models with a single rear lens, if applicable to your device).

---

## Task 1 — Mode Switcher

- Add a top-level mode switcher UI (segmented control or tab bar): **Manual / Portrait / Astro**
- Switching to Portrait: hide the manual control tabs/sliders and readout strip from the base SPEC.md UI, replace with Portrait's own control bar (Task 4)
- Switching away: tear down Portrait-specific capture configuration (depth delivery, mattes) cleanly, restore manual controls
- Persist last-selected mode across launches (same UserDefaults pattern as base spec's persistence)

**Acceptance:** switching modes swaps the control UI correctly, no crashes, no leftover state from the previous mode.

---

## Task 2 — Depth & Matte Capture Configuration

Extend `CameraSessionManager` / `PhotoCaptureService` for Portrait mode:

- On entering Portrait mode, reconfigure the active `AVCaptureDevice` to the dual/triple virtual device if not already active
- On `AVCapturePhotoOutput`:
  - Check `isDepthDataDeliverySupported`, enable `isDepthDataDeliveryEnabled = true`
  - Check `isPortraitEffectsMatteDeliverySupported`, enable `isPortraitEffectsMatteDeliveryEnabled = true`
  - Enable semantic segmentation matte delivery for `.skin` type (`enabledSemanticSegmentationMatteTypes`) — needed for Task 6's baked-in skin smoothing
- In `AVCapturePhotoSettings` for Portrait captures: request depth data delivery, portrait effects matte, and the skin semantic matte alongside the normal HEIC output
- Handle the case where no person is detected (portrait matte delivery can silently fail per-shot) — if matte is missing, fall back to depth-only blur (still usable, just less precise subject edges) and surface a subtle on-screen warning before capture if no matte is currently being detected live (use `AVCaptureDevice` face detection metadata output as a lightweight live indicator, separate from the actual capture matte)

**Acceptance:** a Portrait capture returns image + depth data + portrait matte + skin matte when a person is present; degrades gracefully to depth-only when not.

---

## Task 3 — Depth-Map Debug Preview

- Toggle in Portrait's control bar (Task 4)
- When enabled, render the live depth map (grayscale, near=dark/far=light or similar convention) as an overlay replacing the normal live preview — lets you check subject detection quality before shooting
- Live depth preview can come from a lower-resolution continuous depth stream if available (`AVCaptureDepthDataOutput` on the video connection) rather than waiting for a full photo capture — this is a live debug aid, not the final-quality depth data used in Task 5's render
- Toggling off returns to normal live preview immediately

**Acceptance:** toggle shows/hides a live depth visualization with no more than a small perceptible lag.

---

## Task 4 — Portrait Control Bar UI

Replaces the manual control tabs/slider from the base spec when in Portrait mode:

```
┌─────────────────────────────────┐
│  🔍Depth Debug        ⚙️          │  ← top bar (depth debug toggle + settings)
│                                  │
│      Live preview                │
│      (or depth debug view)       │
│                                  │
│  [Natural][Golden Hour][Teal Frost][Noir]  │ ← film style picker
│  Blur: ▓▓▓▓▓▓░░░░░░  [value]    │  ← blur intensity slider + range bar
│                                  │
│  [thumbnail]    ( ● shutter )    │
└─────────────────────────────────┘
```

- **Film style picker:** horizontal selector, four options — Natural (no grade), Golden Hour, Teal Frost, Noir. Selecting one shows a live low-cost preview approximation (simple CIFilter color grade applied to the live preview feed is fine and cheap — full-quality grade only needs to happen at final render, Task 6)
- **Blur intensity slider:** same slider style as base spec (numeric + range bar), controls aperture/blur strength for the swirl bokeh render
- **Shutter button + thumbnail confirmation:** same pattern as base spec (Task 8 of SPEC.md) — capture triggers Task 5/6 processing before the thumbnail appears, so there will be a brief "processing" state on the thumbnail (spinner or similar) since this isn't instant like a normal HEIC capture

**Acceptance:** UI matches this layout, all controls functional, live film-style preview updates responsively.

---

## Task 5 — Swirl Bokeh Render Pipeline

Custom render, since only Swirl-style bokeh is in scope (no separate "Classic" mode to also support):

- Base blur: `CIFilter(name: "CIDepthBlurEffect")` fed the captured image + depth/disparity data (convert depth to disparity via `AVDepthData.converting(toDepthDataType: kCVPixelFormatType_DisparityFloat32)` if needed) + portrait matte + calibration data. Aperture parameter driven by the blur intensity slider (Task 4)
- Swirl character: apply a radial twist distortion (`CITwirlDistortion` or a custom Core Image kernel) to the **background region only** (masked using the portrait/depth matte, inverted so the subject stays untouched), with twist angle increasing toward the frame edges — this produces the vintage-lens "swirl" look concentrated at the periphery rather than a uniform twist
- Order of operations: depth blur first, then swirl distortion on the blurred background, then composite subject back on top using the matte as the final mask (keeps subject edges crisp)

**Acceptance:** rendered output shows background blur with a visible swirl character increasing toward frame edges, subject remains sharp and cleanly separated from background.

---

## Task 6 — Film Style Grades + Baked-In Subject Refinement

- Implement the three film style grades as Core Image filter chains (color matrix / curves adjustments, not full 3D LUTs unless you want to go that far):
  - **Golden Hour** — warm white balance shift, lifted shadows, gentle contrast reduction
  - **Teal Frost** — cool/teal color cast, increased contrast
  - **Noir** — full desaturation + increased contrast + subtle grain (simple noise overlay at low opacity)
  - **Natural** — no grade applied (passthrough)
- Apply the selected style to the **final composited image** (post swirl-bokeh render from Task 5), not just the background — these are full-image grades
- **Skin smoothing** (baked in, no UI toggle): using the skin semantic segmentation matte from Task 2, apply a soft blur blended at a fixed low opacity (e.g. 30–40% blend) only within the skin matte region
- **Edge softness** (baked in, no UI toggle): apply a small fixed-radius blur to the portrait matte itself before using it as the compositing mask, softening the subject cutout edge by a sensible fixed amount (avoid a harsh cutout look, avoid over-softening that eats into subject detail)
- These two "baked-in" steps should run automatically on every Portrait capture regardless of film style selected

**Acceptance:** each film style produces a visually distinct, consistent grade; skin looks subtly smoothed without looking artificial; subject edge transition looks natural, not cut-and-pasted.

---

## Task 7 — Save Behavior

- Save the final processed (blurred + graded) image as HEIC to the app's dedicated photo album (same album as base spec, Task 5 of SPEC.md)
- Also save the original unprocessed capture (pre-blur, pre-grade) alongside it — consistent with the app's general philosophy of keeping originals archived (as established for Astro Mode's RAW frames) in case you want to re-process later with different blur/style settings
- Post-capture thumbnail (Task 4) reflects the final processed result, not the raw original

**Acceptance:** each Portrait shot produces two files in the album — final styled image and the original unprocessed capture.

---

## Explicitly out of scope for this file

- True Portrait Lighting relighting (Apple's proprietary face-relighting ML)
- Bladed/hexagonal bokeh shapes
- Live full-quality swirl-bokeh preview (final render is post-capture only)
- User-facing skin smoothing / edge softness controls (baked in, fixed values only)
