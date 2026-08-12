# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project state

All 12 tasks in `SPEC.md` have an initial implementation in place (session manager,
manual control engine, white balance conversion, RAW+HEIC capture, live preview, focus
peaking, main UI, settings, gallery, persistence, Camera Control hardware bar).
**`SPEC.md` remains the source of truth** for intended behavior and acceptance criteria —
consult it before changing any of these areas, since tasks build on each other's types.

**Audit pass, 2026-08-11.** Re-reading `SPEC.md` against the code turned up five
requirements that were structurally "present" but not actually satisfied. All five are now
implemented; each is documented in place further down, and the summary here exists so a
future session doesn't re-derive them:
1. **Task 12 light press did nothing** — wired to a no-op self-assignment instead of
   focus/exposure lock at point. Now goes through `tapToReset(at:)`.
2. **Task 9's ProRAW setting needed a relaunch** — it was read exactly once at
   `CameraCoordinator.init`. Now driven by a `$defaultCaptureFormat` subscription, with the
   output-side change made on the session queue. (ProRAW later became a `CaptureFormat` case
   rather than its own toggle — see the format deviation below.)
3. **Task 11's persistence-*off* path applied hardcoded defaults**, not the "metered
   baseline" the spec asks for. Now calls `ManualControlEngine.resetToMeteredBaseline()`.
4. **Task 8's value readout omitted focus** despite "always shows all current values".
   Focus is now in `valueReadoutCapsule`.
5. **`TARGETED_DEVICE_FAMILY` still included iPad**, against the iPhone-only constraint.
   Now `1`.
Separately, four defects in the Multi-Shot Timer were fixed the same day — see its
implementation notes below.

**Builds are possible here — the long-standing note that they weren't was wrong.**
`xcode-select` points at Command Line Tools, so bare `xcodebuild` fails, but a full Xcode
is installed and works via its absolute path:

```
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild \
  -project ManualCam.xcodeproj -scheme ManualCam \
  -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

`-sdk iphonesimulator` + `CODE_SIGNING_ALLOWED=NO` avoids needing a signing identity.
**Compile-verify before reporting work as done** — as of 2026-08-11 the whole project
builds clean (BUILD SUCCEEDED, no errors). Cheap and worth it, because API signatures
written from memory *have* been wrong here repeatedly.

Two caveats on tooling:
- The **SourceKit diagnostics** shown while editing are noise: they resolve each file
  standalone against the **macOS** SDK, so every project type and even `UIApplication`
  reads as "cannot find in scope". Ignore them; run the build instead. (They're not
  *entirely* useless — a genuine type error did surface that way once, `[OSType]` vs
  `[NSNumber]` on `availableDepthDataTypes`. Verify any such hit against the real header
  before acting.)
- Building is **not** running: nothing here can exercise the camera. On-device behavior
  (depth delivery, matte generation, audio timing, overlay orientation) still needs the
  user's iPhone 17 Pro. A green build only rules out compile errors.

For API verification, the iOS SDK headers are readable at
`/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk/System/Library/Frameworks/`
— and for anything marked `NS_REFINED_FOR_SWIFT`, check the matching
`.swiftinterface` for the real Swift signature, since the ObjC header alone can mislead.

Folder structure (per `SPEC.md`):
```
/Camera        — CameraSessionManager, ManualControlEngine, WhiteBalanceConverter,
                 PhotoCaptureService, PhotoAlbumManager, CameraControlBarController,
                 CameraCoordinator (composition root)
/Peaking       — FocusPeakingProcessor (Metal-backed CIContext pipeline)
/UI            — RootView (permission gate), MainCameraView, CameraPreviewView,
                 SettingsView, PermissionView, CameraValueFormatting, WheelSlider
/Settings      — AppSettingsStore, CameraStatePersistenceStore (UserDefaults-backed)
/Gallery       — GalleryView, PhotoDetailView
/Models        — CaptureFormat, CameraLens, ManualControlRanges, ManualParameter,
                 PersistedCameraState
```

### Planned feature specs

Three additional spec files live at the repo root and extend the base `SPEC.md`. Multi-Shot Timer
and **Portrait are both fully implemented**; Astro is **not started** (its mode switcher
prerequisite now exists, though — see `ShootingMode`, which already has an `.astro` case gated
behind `isImplemented`). Treat
each file as the source of truth for its feature, the same way `SPEC.md` is for the base app,
and consult the file itself before building/changing any of it. Key decisions and constraints,
so they persist across sessions:

- **`PORTRAIT_MODE.md`** — ✅ **All 7 tasks implemented (2026-08-11).** Built in two passes: the
  capture foundation (Tasks 1–3) first so depth delivery could be confirmed on real hardware, then
  the render pipeline (Tasks 4–7). Implementation notes:
  - **The virtual-device conflict is the whole risk of this feature, and it's handled in three
    places — don't undo any of them.** Depth only comes from the virtual multi-camera device
    (`.builtInDualCamera`/`.builtInDualWideCamera`/`.builtInTripleCamera`), which is precisely
    the device the rest of this app refuses to use because
    `isLockingFocusWithCustomLensPositionSupported` is false there and
    `setFocusModeLocked(lensPosition:)` throws `NSInvalidArgumentException` (see `CameraLens`).
    Portrait is safe on it *only* because it never applies manual values: (1)
    `CameraSessionManager.enterPortraitConfiguration()` puts the device in continuous
    auto focus/exposure/white balance; (2) `CameraCoordinator.handleDeviceAttached` **skips
    `controlEngine.attach(device:)` entirely while the mode is Portrait**, so no manual value —
    including that focus call — is ever pushed at the virtual device; (3) the engine is frozen
    via `ManualControlEngine.LockReason.portraitMode`, which also blocks the Camera Control
    hardware dial and light press, neither of which any hidden-UI approach can stop.
  - **`ManualControlEngine.isLocked` became a set of `LockReason`s** rather than a Bool, because
    Portrait and a Multi-Shot Timer run are independent owners of the same freeze — with a
    shared Bool, a timer run ending would unfreeze controls that Portrait still needed frozen.
    `setLocked(_:for:)` inserts/removes; the controls stay frozen until every owner releases.
  - **Leaving Portrait must republish `currentDevice`** — `exitPortraitConfiguration()` swaps
    back to the discrete lens stored in `activeLens` and publishes it, and *that publish* is what
    makes the coordinator re-attach the engine and restore manual values. Without it the manual
    controls would point at a device no longer in the session. Ordering inside that method is
    also load-bearing: depth/matte delivery is disabled **before** the virtual input is removed,
    since those properties can only be set while still supported.
  - **`maxPhotoQualityPrioritization` is raised to `.quality` while Portrait is active** and
    restored to `.speed` on exit. This is *not* a reversal of the base app's `.speed` rule —
    that rule exists to stop multi-frame fusion from corrupting dialed-in manual exposure, and
    Portrait is auto-exposed. Note per-shot settings may never exceed the output's max or the
    capture throws, which is why the two move together.
  - **Portrait's outputs are added and removed with the mode**, not left in the session:
    `AVCaptureDepthDataOutput` (Task 3's live stream) and `AVCaptureMetadataOutput` (Task 2's
    face indicator). Their delegates are attached once at startup — harmless, since no frames
    arrive while the outputs aren't in the session.
  - **`DepthPreviewProcessor`** (`/Peaking`, alongside `FocusPeakingProcessor` and modeled on it
    — same Metal `CIContext`, same `nonisolated(unsafe)` delegate-queue state, same
    fully-skippable-when-off rule) converts each frame to `DisparityFloat32` and normalizes it
    per frame via a strided min/max scan. Per-frame normalization isn't optional: disparity is
    in reciprocal-distance units with no fixed useful range, so a fixed scale renders an indoor
    scene as flat gray. Conversion availability is checked against `availableDepthDataTypes`
    first, because `converting(toDepthDataType:)` raises an **Objective-C** exception that
    `try?` cannot catch. Follows the spec's near=dark/far=light convention, which means
    deliberately *inverting* disparity (disparity is high for near subjects).
  - **`PortraitCaptureDiagnostics`** (`/Models`) publishes what each shot actually delivered
    (depth ✓/✗, matte ✓/✗, skin ✓/✗, **blur ✓/✗**) into the Portrait bar. `didApplyBokeh` is
    separate from `hasDepthData` on purpose: depth can be delivered and still be unusable (e.g. the
    frame won't convert to `DisparityFloat32`), in which case the renderer skips the blur and emits
    a graded-but-sharp image that looks exactly like a broken effect. `hasDepthButNoBokeh` renders
    red — it means the fault is in the render, not the capture. This exists because Task 2's
    acceptance criterion is unverifiable from source, matte delivery can fail per-shot, and
    Task 5 branches on exactly these three inputs. `PortraitSubjectMonitor`'s face detection is
    a separate, deliberately approximate *pre*-capture warning — faces and mattes come from
    different pipelines and can disagree.
  - **`PortraitRenderer`** (`/Camera`, `nonisolated`) is the whole of Tasks 5–6, run on
    `PhotoCaptureService.renderQueue` — seconds of full-resolution Core Image work that must never
    touch main. Pipeline order is the spec's and each step depends on it: `CIDepthBlurEffect`
    (disparity + matte + calibration, aperture from the slider) → periphery swirl on the blurred
    result → subject composited back over it through the softened matte → skin smoothing → film
    grade → HEIC. Notes worth keeping:
    - **Aperture is queried, not hardcoded.** The renderer reads `kCIAttributeSliderMin`/`Max` from
      `CIDepthBlurEffect`'s own `attributes` and maps the UI's 0…1 blur onto it, **inverted** (a
      small f-number is a wide aperture, i.e. more blur). `fallbackApertureRange` only applies if
      the filter stops reporting bounds. Same "query, don't assume" rule used for device ranges.
      The filter currently reports `inputAperture` as slider **1…22**, `CIAttributeMin` 0, and
      `CIAttributeDefault` **0** — that default sits *below* the slider minimum and appears to mean
      "no blur", so it's deliberately never used. (These values are checkable without a device:
      CoreImage is cross-platform, so a few lines of Swift run against the macOS toolchain will dump
      any filter's `attributes` and `inputKeys`. Far better than guessing at an undocumented scale.)
    - **The aperture mapping must be geometric, not linear — confirmed bug, fixed 2026-08-11.**
      First device test reported "the bokeh is not working". Root cause: `aperture(for:filter:)`
      interpolated f-numbers *linearly*, so 60% blur landed on f/9.4 and roughly 85% of the
      slider's travel sat in f/8–f/22, where every value looks identically sharp — only the very top
      did anything visible. f-numbers are **stops** (f/1, 1.4, 2, 2.8, 4, 5.6, 8, 11, 16, 22 is a
      geometric series), so the fix interpolates the *ratio*: `narrowest * pow(widest/narrowest, t)`.
      50% is now ~f/4.7 and 60% ~f/3.4. This is the same class of bug as the linear shutter slider
      that wasted 80% of its length — **if another photographic quantity gets a 0…1 control, map it
      geometrically from the start.**
    - **Every auxiliary image must be scaled to the main image's extent — confirmed bug, fixed
      2026-08-11.** Depth and both mattes arrive far smaller than the photo (~768×576 against
      ~4032×3024), and **Core Image aligns images by extent, not by relative size**, so an unscaled
      disparity map covers only a corner of the frame and reads as "no measurement" everywhere else.
      Device symptom: a blur with "nothing to do with the subject", while the depth debug preview
      showed the subject detected perfectly — i.e. the capture was fine and the render was not. The
      mismatch is silent: no error, no nil, just a wrong result.
    - **…and scaled with `CIEdgePreserveUpsample`, not a bare affine transform — second confirmed
      bug, same day.** Device symptom: the blur "look[ed] really bad like an oil painting. Not
      unified, looks like someone used a brush to paint it with blurry colour." Cause: a plain
      `transformed(by:)` resamples bilinearly, and at ~5× magnification a low-res depth map comes out
      *faceted*. `CIDepthBlurEffect` then derives a slightly different blur radius per facet, so the
      frame breaks into patches of differently-blurred colour. `CIEdgePreserveUpsample` is a joint
      bilateral upsample that takes the full-resolution photo as a **guide**, so the map's transitions
      snap to real scene edges rather than interpolating across them. Applied to the disparity map, the
      depth-blur matte, and the skin matte (a faceted skin mask is the textbook beauty-filter
      oil-paint artifact — same complaint, different route). Sigmas are
      `upsampleSpatialSigma`/`upsampleLumaSigma`; too high and the map starts tracking texture instead
      of subject boundaries. **Never resize an auxiliary map here with a plain transform.**
    - **The sharp subject is no longer re-composited over the blur — third contributor, same day.**
      `CIDepthBlurEffect` already receives the matte and does its own feathered subject compositing;
      layering a second `CIBlendWithMask` on top cross-faded the *original sharp* image back over the
      filter's output through a coarse 5×-upscaled mask, mixing two images of different sharpness in
      irregular patches wherever the matte held mid-values (hair, shoulders, soft boundaries). That
      composite existed only to protect the subject from the periphery swirl, which is gone. **Don't
      reintroduce it** — if subject edges look too soft, adjust the upsample sigmas or the matte.
      Task 6's separate "edge softness" step went with it: a fixed 2.5px Gaussian on a 5×-upscaled
      mask was narrower than one native matte pixel, so it never smoothed the faceting it was meant
      to hide.
    - **The encode must not hardcode sRGB — confirmed defect, fixed 2026-08-11 by inspecting a real
      render.** `encodeHEIC` wrote `CGColorSpace.sRGB`, so every styled Portrait file came out tagged
      sRGB even though iPhone 17 Pro captures are Display P3 — quietly clipping saturated colour.
      It now uses `inputs.image.colorSpace` (the source's own space), falling back to Display P3
      rather than sRGB. Two related things this render also revealed and which are *not* yet
      addressed: the output is 8-bit `RGBA8` **with an alpha channel** (`HasAlpha: 1`, meaningless for
      a photo — `HEIF10RepresentationOfImage` would give 10-bit if wanted), and the **HDR gain map is
      dropped** (the original keeps it, the render doesn't), so styled files look flatter than the
      archived originals on an HDR display.
    - **How to tell a render from a capture when debugging a saved file** — this cost a wrong
      conclusion once. EXIF (`Make`, `Model`, `LensModel`, `Software`, ISO, exposure) **rides along
      from `CIImage(data:)` into `heifRepresentation`**, so full Apple camera metadata does *not* mean
      Apple produced the file. The reliable tells for a `CIContext` render are `HasAlpha: 1`, a
      hardcoded colour profile, no HDR gain map, and no depth/matte auxiliary images. Probe with
      `CGImageSourceCopyAuxiliaryDataInfoAtIndex` and `CGImageSourceCopyPropertiesAtIndex` — a few
      lines of Swift against the macOS toolchain reads any file on disk.
    - Dead end worth not re-walking: `AVCapturePhotoSettings.isDepthDataFiltered` (hole-filling, which
      the header notes "makes it more usable for applying effects") **defaults to YES**, so photo depth
      is already hole-filled and this was never the cause of the patchy blur. Only
      `AVCaptureDepthDataOutput.isFilteringEnabled` — the live stream — needs setting by hand.
    - **Deviation from `PORTRAIT_MODE.md` Task 6: Noir has no grain.** Confirmed bug plus a rejected
      fix, 2026-08-11. The original mapped `CIRandomGenerator` to a dim grey with **alpha 1** and used
      `CISourceOverCompositing` — an opaque foreground over source-over *replaces* the background, so
      Noir rendered as the noise layer itself. Device report: "the noir isn't working, it just shows
      grey pixels." Correcting the alpha still looked bad: full-range, spatially uncorrelated noise
      composited at 6–8% (even pre-blurred) lifts every shadow into grey speckle and undoes the
      contrast the grade just built — verified by rendering a real photo through both variants and
      comparing them side by side. Noir is now `photoEffectMono` + contrast, which looks genuinely
      good. Proper grain needs zero-mean noise added in linear light, which CI's compositing filters
      handle badly (addition compositing ignores a zero-alpha layer and mishandles negatives);
      realistically a small `CIColorKernel`. **Don't re-add an opacity-based noise overlay — it has
      been tried twice.**
    - **Rendering a real photo through the grade chain off-device is the fastest way to judge these.**
      CoreImage is cross-platform, so a short Swift script run against the macOS toolchain can load a
      HEIC, apply the same filter chain, and write a PNG (or a side-by-side comparison) to look at.
      That is how both the grain verdict and the sRGB colour-space defect were settled. Far better
      than reasoning about blend-mode semantics — several confident predictions about compositing
      neutrality in a linear working space turned out simply wrong when measured.
    - **Deviation from `PORTRAIT_MODE.md`: the periphery swirl is removed.** Task 5's whole premise
      is a "vintage-lens swirl" — a radial twist rising toward the frame edges — and the user
      rejected it after seeing it on device: "I want the swirly effect out of here. It's not the kind
      I was looking for so let's go back to basic portrait effect" (2026-08-11). Portrait is now
      plain depth bokeh: `CIDepthBlurEffect` → subject composited back through the softened matte.
      The `CITwirlDistortion` + `CIRadialGradient` code was **deleted**, not disabled behind a flag
      (recoverable from git history) — don't reintroduce a twist as a default. Note the spec file
      still describes the swirl as Task 5; this CLAUDE.md entry overrides it, same as the other
      base-app deviations.
      Two things learned there are worth keeping even though the code is gone: a **displacement or
      sampling filter must be `clampedToExtent()`** (unclamped, the twirl sampled outside the source
      extent, got transparent, and composited as the "black spots on the edges" seen on device — the
      Gaussian blurs were already clamped and the twirl was missed); and `CITwirlDistortion` twists
      hardest at its *centre*, i.e. backwards from a periphery swirl, which is why it needed a radial
      gradient blend rather than a bare twirl.
    - **The subject composite is kept, deliberately, now that the swirl is gone.** It existed partly
      to protect the subject from the twist, but it's independent of it and is what guarantees crisp
      subject edges. `CIDepthBlurEffect` is already matte-aware, so this is somewhat belt-and-braces
      — if a subject edge ever looks haloed or cut-out, dropping the composite and letting the filter
      handle the matte alone is the first thing to try.
    - **Orientation is the subtlest correctness risk.** The image is decoded with
      `.applyOrientationProperty` while depth and both mattes are rotated explicitly with
      `applyingExifOrientation(_:)` — they arrive in sensor orientation and would otherwise be
      applied sideways to an upright frame, putting the blur and subject cutout in the wrong
      places. `extractInputs` is the one knob if a render ever comes out rotated or mirrored.
    - Gaussian blurs are `clampedToExtent()` before blurring (both the matte softening and skin
      smoothing). Unclamped, a Gaussian samples past the source extent and fades/darkens the frame
      border — visible wherever a subject or skin reaches the edge.
    - `CIColorMatrix` on the skin matte is what makes the smoothing *partial*: `CIBlendWithMask`
      interpolates on mask luminance, so scaling the mask to 0.35 is what produces a 35% effect.
  - **Deviation from `PORTRAIT_MODE.md` Task 7: one asset per shot, not two.** The spec asks for the
    styled render *plus* the untouched original archived for later re-processing, and that's how it was
    built; per explicit user request (2026-08-11 — "save one photo for portrait images. Only the
    portrait image") only the finished Portrait photo is saved. Don't reinstate the archive without
    asking — it doubles the album's asset count, which is what the user was reacting to. The original
    frame is still held during the render purely as a **safety net**: if the render fails, the
    unprocessed capture is saved in its place with an explanatory error, because a broken effect must
    never cost the shot. Either way exactly one photo lands in the album, and the confirmation
    thumbnail shows whatever was actually saved. (`save(data:isRAW:)`'s `publishThumbnail` parameter
    existed only to suppress the archive's thumbnail and is gone with it.) The shutter stays disabled
    while `isRenderingPortrait` is true, since renders would otherwise silently queue.
  - **Task 4's live film-style preview runs the real grade — the blend-mode approximation is gone
    (replaced 2026-08-11).** It was originally a translucent SwiftUI rectangle in `.softLight` over the
    preview layer, on the reasoning that a hint conveying *direction* wasn't worth a CI preview
    pipeline. The user compared outputs and rejected it: "the photo shown in the view finder and the
    saved images are not same … the applied filter when saving might be Overscreen type something and
    the view is only a overlay" — correct on both counts. Now:
    - The four grades live in **`FilmStyleGrade`** (`/Camera`), a stateless `nonisolated` namespace
      called by *both* `PortraitRenderer.applyStyle` and the live preview. **Keep it that way** — one
      implementation is the only thing that stops the two drifting apart again.
    - **`FilmStylePreviewProcessor`** (`/Peaking`, modeled on the other two per-frame pipelines)
      grades video-data-output frames and publishes a `CGImage`, which `MainCameraView` draws
      **opaquely over** the preview layer. `CameraPreviewView` stays in the hierarchy underneath so
      the `AVCaptureEventInteraction` hardware press keeps working — the graded frame covers it
      rather than replacing it.
    - Its `CIContext` uses the **same `extendedLinearSRGB` working space** as `PortraitRenderer`. Not
      incidental: these grades composite differently in linear vs gamma space, so a mismatch there
      would silently reintroduce the very discrepancy this replaced.
    - **`VideoFrameRouter`** (`/Camera`) exists because `AVCaptureVideoDataOutput` allows exactly one
      sample-buffer delegate and there are now two per-frame consumers. It forwards to both (strongly
      held — the output doesn't retain its delegate; the router is retained by `CameraCoordinator`).
    - Gated to Portrait, a non-passthrough style, and depth-debug off, so nothing runs when the result
      wouldn't be visible.
    - **Expected and correct remaining difference:** the preview grades the *raw* frame while the
      render grades the *blurred and composited* one — a live bokeh preview is explicitly out of
      scope. So colour matches; depth-of-field only appears in the saved photo.
  - **Portrait has its own lens row (added 2026-08-11 on user request: "add lens options? Like 1x,
    2x, 4x. All the available lens that can capture depth").** Not in `PORTRAIT_MODE.md` at all —
    the spec's Task 4 bar has no lens control. `PortraitZoomOption` (`/Models`) +
    `CameraSessionManager.setPortraitZoom(_:)` + `MainCameraView.portraitLensPicker`. Points worth
    keeping straight:
    - **Device-relative zoom ≠ the user-facing multiplier — confirmed bug, fixed 2026-08-11.**
      `videoZoomFactor` on a virtual device is measured from its **widest** constituent lens, so on a
      device with an ultra-wide, device zoom 1.0 *is* the ultra-wide and the 24mm main sits at 2.0.
      Labelling buttons with the raw factor showed "the 24mm as 2x and 48mm as 4x" (user report).
      `PortraitZoomOption` now carries both: `zoomFactor` (raw, what gets assigned to the device) and
      `displayMultiplier` (normalized so the main lens is 1×, which is the convention every iPhone
      camera UI uses and what Manual's millimetre labels already follow). The divisor comes from
      `wideAngleBaseZoomFactor(for:)`, derived from `constituentDevices` + the SDK's guarantee that
      switch-over factors "progress in the same order as the devices listed in that property" — so
      lens *i* activates at factor *i − 1*, and a device whose widest lens already is the wide-angle
      (`.builtInDualCamera`) correctly yields 1.0 and is left alone. Verified against simulated
      triple-camera numbers: device 1/2/4/8 → 0.5×/1×/2×/4×. **Keep the two values distinct** — the
      raw one is the only thing safe to hand to `videoZoomFactor`, and the normalized one is the only
      thing safe to show a user. The same trap bit the "open at 1×" default, which was selecting the
      ultra-wide until it was switched to match on `displayMultiplier`.
    - **Portrait switches lenses by `videoZoomFactor`, not by swapping the session input.** It's
      already on the virtual device, which switches constituent cameras itself at its
      `virtualDeviceSwitchOverVideoZoomFactors`. Swapping the input here would tear down depth
      delivery — the opposite of Manual's `switchToLens(_:)`, which is why `switchToLens` early-returns
      while `isPortraitConfigured` and why these are two separate code paths rather than one.
    - **`AVCaptureDeviceFormat.supportedVideoZoomRangesForDepthDataDelivery` is the authority on
      "which lenses can capture depth"** — exactly the user's question, answered by the SDK rather
      than derived. It's `NS_REFINED_FOR_SWIFT`; the Swift face is `[ClosedRange<CGFloat>]` (checked in
      the `.swiftinterface`, not just the ObjC header). Available unconditionally at iOS 17.2+, which
      the 18.0 deployment target covers, so the deprecated `…ZoomFactors…` variant is unused.
    - **Setting an unsupported factor while depth delivery is on can raise an exception** (the header
      is explicit for discrete ranges like `[2..2], [4..4]`). Every factor therefore passes
      `isZoomFactorDepthCapable(_:on:)` first, then gets clamped to
      `min`/`maxAvailableVideoZoomFactor` — a *separate* constraint that throws `NSRangeException`.
      Don't add a pinch gesture or continuous slider here without re-checking both.
    - Options are the device's **native** points only (1×, the switch-over factors, the active
      format's `secondaryNativeResolutionZoomFactors` — the last of which is what surfaces "2×" on a
      48MP main — plus the device minimum for the ultra-wide), intersected with the depth ranges and
      de-duplicated by displayed value (a secondary factor can land on a constituent lens's own, and
      two "2×" buttons would be nonsense). Native-only also matters because with depth delivery on the
      SDK drops the upscale threshold to 1.0, making any non-native factor a digital crop.
    - Expect a stall on each switch: the SDK notes changing zoom under depth delivery causes "a
      disruptive reconfiguration of the capture render pipeline". That's why the row is discrete
      buttons rather than a smooth zoom.
    - Selection is compared with a 0.05 tolerance, since the device clamps the requested value and can
      report back something fractionally different. Zoom is session-scoped, resetting to 1× (or the
      widest depth-capable option) on each entry into Portrait.
  - **Blur uses `WheelSlider`, not the spec's slider + range bar**, matching the deviation that
    replaced every other slider in the app. Linear, not `log2` — blur isn't a stop-based value.
  - Blur intensity and film style are **session-scoped**, not persisted; `PORTRAIT_MODE.md` only
    requires the mode itself to persist. Easy to move into `AppSettingsStore` if wanted.
  - Known gaps to expect on first device run: the depth overlay's rotation relies on
    `applyRotation(to:for:)` accepting the depth connection; if it comes out sideways (as the
    peaking overlay once did), orient the `CIImage` in `DepthPreviewProcessor` instead. Entering
    Portrait will visibly hitch — the SDK warns that enabling depth/matte delivery "requires a
    lengthy reconfiguration of the capture render pipeline" and wants it set before
    `startRunning()`, which a runtime mode toggle can't do.
  Captures depth map + portrait matte + `.skin` semantic segmentation matte alongside a
  HEIC, then renders bokeh in **post-capture** processing (never live). Manual controls are
  **hidden** in this mode, replaced by a Portrait control bar (depth-debug toggle, film-style
  picker, blur-intensity slider, shutter). Device-gated to dual/triple-camera iPhones
  (`.builtInDualCamera`/`.builtInDualWideCamera`/`.builtInTripleCamera`) — hide the entry on
  unsupported devices. Render pipeline **as shipped**: `CIDepthBlurEffect`
  (depth+matte+calibration, aperture from slider) → composite subject back on top via matte. (The
  spec file's middle step — a radial swirl twist on the background, twist rising toward the edges —
  was built and then **removed at the user's request**; see the deviation note above.) Four film
  styles — Natural
  (passthrough), Golden Hour, Teal Frost, Noir — as Core Image grade chains applied to the
  **final composite**. Baked-in (no UI toggle): skin smoothing via the skin matte (~30–40%
  blend) and edge softness (small fixed blur on the matte before compositing). The spec asks for
  **two** files per shot (final styled HEIC + the original unprocessed capture) — **as shipped it
  saves one**, the styled photo only; see the Task 7 deviation above. Degrade to depth-only
  blur when no person/matte is detected. Honest approximation, **not** a clone of Apple
  Portrait Lighting (no true face-relighting ML). Out of scope: true relighting, bladed/hex
  bokeh shapes, live full-quality bokeh preview, user-facing skin/edge controls.

- **`ASTRO_MODE.md`** — a new top-level mode (Manual / Portrait / **Astro**). A **manual
  exposure-stacking** tool (real DSLR astro workflow), **not** an auto Night Mode — and it
  subsumes Night Mode (small shot count covers general low-light). Unlike Portrait, manual
  controls **stay visible and active**; Astro adds an **additional** panel on top (shot-count
  stepper, Average / Lighten-Max blend picker, Handheld / Tripod align picker, a "Start Stack"
  button replacing the shutter). Core module `StackCaptureEngine`: state machine `idle →
  capturing(N/total) → aligning → stacking → done`; fires `PhotoCaptureService` sequentially at
  the manual settings **locked at run start** (slider changes mid-run ignored); every RAW frame
  is archived to the album, but stacking math uses the **processed (HEIC) buffer**, not RAW
  (on-device demosaic of N frames is too heavy). Alignment via Vision — `VNHomographicImageRegistrationRequest`
  (Handheld) or cheaper `VNTranslationalImageRegistrationRequest` (Tripod), each frame aligned
  to the first. **Memory-safe incremental accumulation**: one 32-bit-float vImage accumulator
  sized to a single frame, blend each aligned frame in then release it — never hold all N;
  normalize once at end (Average). Blend modes: Average (running mean, noise reduction) and
  Lighten/Max (brightest-per-pixel, star trails). No live progressive preview; show progress
  only, reveal final on `done`. Cancel mid-run still stacks the frames captured so far. Optional
  CoreMotion tripod-stillness check = advisory warning after the run, never a hard gate. Out of
  scope: separate Night Mode UI, live stack preview, true plate-solving/per-star alignment,
  dark-frame subtraction, on-device RAW demosaic for the stack.

- **`MULTI_SHOT_TIMER.md`** — an intervalometer, a shooting aid usable **only in Manual mode**
  (not Portrait, not Astro). ✅ **Implemented** (not yet build-verified in Xcode — same
  Command-Line-Tools-only caveat as the rest of the app). Spec text on this feature predates two
  UI/behavior facts and was adapted accordingly (see the implementation notes below):
  it says "timer icon in Manual's top bar" (no top bar exists) and "RAW/HEIC **twin**
  based on the top-bar toggle" (format is now the single mutually-exclusive
  `settingsStore.defaultCaptureFormat`), and lists EV among the frozen settings (EV was removed).
  What the feature does: an initial delay (0–60s), shot count (1–50), interval (1–60s); "Start"
  freezes the current manual settings and runs a countdown overlay firing N independent captures.
  Out of scope (unchanged): any tie-in with Astro's stacking engine, blending timer shots,
  remote/external triggers (Watch, Bluetooth shutter).

  Implementation notes (decisions made with the user before building):
  - **Entry point** — no top bar, so the timer lives behind the existing capture-options (⋯)
    button next to `valueReadoutStrip`: tapping the **Timer tile** in `CaptureOptionsSheet`
    dismisses it and presents `TimerSetupSheet` (the two-sheet handoff is sequenced with a ~0.15s
    delay so the transitions don't collide). `CaptureOptionsSheet` gained an `onTimer` closure;
    its Portrait/Astro tiles stay no-op placeholders until those modes are built.
  - **`TimerConfiguration`** (`/Models`) — `initialDelay`/`shotCount`/`interval` with the ranges
    above + `.clamped()`. Last-used config is persisted in `AppSettingsStore.timerConfiguration`
    (three `UserDefaults` Int keys), seeding the setup sheet each open — same pattern as the rest
    of the store.
  - **`IntervalometerService`** (`/Camera`, `ObservableObject`, MainActor-default) — drives
    `idle → countdown → capture(flash) → countdown → … → done` with a 1 Hz `Timer` on the main
    run loop. Publishes `isRunning`/`currentShot`/`totalShots`/`secondsRemaining`/`isCapturing`.
    Each shot goes through the **same** capture path the manual shutter uses (via a closure
    passed to `start`), so RAW/HEIC + album destination are respected and there's no duplicate
    capture path. Sets `UIApplication.shared.isIdleTimerDisabled` for the run so the screen
    doesn't sleep while the user steps away. `cancel()` stops immediately; shots already taken
    stay saved.
  - **"Settings frozen for the run" is enforced, not implicit** — an earlier version relied on
    the countdown overlay covering the on-screen controls, which has a hole: the **Camera
    Control hardware bar** (base spec Task 12) and its light-press handler call
    `ManualControlEngine` setters *directly*, so on iPhone 16+/17 hardware a nudge of the dial
    mid-run changed exposure partway through the set — exactly what `MULTI_SHOT_TIMER.md` Task 1
    forbids. The freeze now lives in the engine itself: `ManualControlEngine.isLocked`
    (`@Published private(set)`, set via `setLocked(_:)`) makes `setISO`/`setExposureDuration`/
    `setLensPosition`/`setWhiteBalanceKelvin`/`tapToReset` no-op while a run is active, so it
    holds for *every* input path. `CameraCoordinator` drives it off a `intervalometer.$isRunning`
    sink rather than setting it by hand in `startTimer`, so finish/cancel/cancel-on-background
    all release it — the controls can't get stuck locked.
  - **Hardware shutter during a run** — `CameraCoordinator.capturePhoto()` (the *user*-initiated
    shutter: on-screen button + Camera Control full press) now early-returns while
    `intervalometer.isRunning`, because a hardware full press bypasses the overlay and would
    inject an unscheduled extra frame (N+1 photos, one off-interval). The run's own shots call
    the private `performCapture()`, which is unguarded — don't wire the intervalometer back to
    `capturePhoto()` or the guard will swallow every shot in the run.
  - **Backgrounding cancels the run** — `RootView`'s `scenePhase` `.background` branch calls
    `coordinator.cancelTimerRun()` before persisting state. A suspended app's run-loop timers
    don't fire and its capture session is interrupted, so a surviving run would silently produce
    fewer photos than requested; shots already taken are independent and stay saved.
  - **Audio** (`TimerAudioCuePlayer`, `/Camera`) — **respects the silent switch** (explicit user
    choice): `AVAudioSession` category `.ambient` + `.mixWithOthers` (iOS silences ambient on
    mute and mixes rather than interrupting other audio). No bundled sound assets — three cues
    (beep 880 Hz, higher "final" beep 1320 Hz at 1s-to-go, distinct lower shutter 320 Hz) are
    **synthesized sine tones** written to in-memory 16-bit PCM WAV `Data` and played via
    `AVAudioPlayer`. Rising beeps play in the last 3 s before **every** shot.
  - **Countdown UI** (`IntervalometerOverlay`, `/UI`) — big center numeral + "Shot X of N" +
    always-visible Cancel, over a translucent scrim (viewfinder shows through) that captures taps
    so the controls beneath are locked; a white full-screen pulse flashes at each shot fire.
  - **Per-shot feedback** — per user choice, the normal per-shot thumbnail flash is **suppressed
    during a run** (`MainCameraView`'s `lastCaptureThumbnail` `onChange` early-returns while
    `intervalometer.isRunning`); one thumbnail is revealed at the end via an `onChange` on
    `isRunning` flipping false.
  - **Coordinator wiring** — `CameraCoordinator` owns `intervalometer`, forwards its
    `objectWillChange` (added to the nested-`ObservableObject` forwarding list — required or the
    overlay wouldn't re-render), and exposes `startTimer(config:)` which persists the config then
    starts the run, plus `cancelTimerRun()`.
  - **Sheet → run handoff is delayed** — `MainCameraView`'s `TimerSetupSheet` `onStart` closure
    starts the run after ~0.35 s (`TimerSetupSheet` itself calls `dismiss()` *before* `onStart`),
    so the countdown's first numeral and first audio cue land on the live viewfinder instead of
    behind a sheet that's still animating away — worst case (initial delay 0) the first shot fired
    while the sheet still covered the screen. Same idiom as the ⋯ → timer two-sheet handoff.

Note: these three spec files predate some base-app deviations recorded below and still reference
features the shipped app has since changed — e.g. a RAW+HEIC "twin" capture (now two mutually
exclusive modes) and an EV/exposure-bias control (removed entirely). When implementing, follow
the base-app deviations in this CLAUDE.md over the specs' stale assumptions on those specific
points.

### Concurrency model

The project sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — every type is implicitly
`@MainActor` unless it opts out. `CameraSessionManager` and `ManualControlEngine` are
declared `nonisolated` at the class level (they're background-queue-driven by design:
AVFoundation session/device configuration must never run on main). `PhotoCaptureService`
and `FocusPeakingProcessor` stay MainActor-default but mark their AVFoundation delegate
callback methods and the specific state those callbacks touch (`nonisolated`/
`nonisolated(unsafe)`) since those callbacks land on AVFoundation-internal queues, not
main. Any state shared between a nonisolated callback and MainActor-default code (e.g.
`PhotoCaptureService.inFlightCaptures`) is protected by an explicit `NSLock` — don't
remove the lock when touching that code. All `@Published` mutations from background
contexts go through `DispatchQueue.main.async`, matching Combine/SwiftUI's requirement
that published changes originate on main.

## Build & run

`xcode-select` points at Command Line Tools, so **bare `xcodebuild` fails** — but a full
Xcode is installed and building from the command line works via its absolute path. See the
verified invocation in "Project state" above; use it to compile-check changes before
reporting them done. Running the app (and anything camera-related) still has to happen on
a real device from Xcode. There is no test target yet.

## Non-negotiable constraints (from SPEC.md)

These are explicit product decisions — don't "improve" past them:

- **Min iOS 18.0**, iPhone only. `TARGETED_DEVICE_FAMILY` is now `1` (iPhone) in both
  Debug and Release — it had been left at the Xcode template's `"1,2"` (iPhone + iPad),
  which contradicted the constraint and advertised an iPad build the app has no layout
  for. Don't let a project-settings edit put iPad back.
- **Deviation from spec**: SPEC.md says back camera only, no front camera — that part is
  unchanged (no front camera; the user explicitly asked for it to be removed after an
  earlier iteration added it). What SPEC.md didn't anticipate: there's now a lens
  switcher (`MainCameraView.lensTabBar`, an always-visible tab row above the
  ISO/SHUTTER/FOCUS/WB tabs — originally a menu button bottom-right of the shutter, moved
  per the Task 8/9 restructuring deviation further below) covering every zoom point the
  connected iPhone's back lenses actually report — not just three fixed physical lenses,
  but also any extra native zoom point a given lens exposes (e.g. an "8×" telephoto
  crop). See `CameraLens`/`CameraSessionManager` below.
- **Deviation from spec**: SPEC.md's twin RAW+HEIC-in-one-shot capture is gone. Per
  explicit user request ("I don't need them together"), `CaptureFormat` is a set of
  mutually exclusive modes, not a combined one; there is no "RAW+HEIC" option anymore.
  `PhotoCaptureService.capturePhoto(format:videoZoomFactor:)` builds either a plain
  `AVCapturePhotoSettings()` (HEIC) or a RAW-only `AVCapturePhotoSettings
  (rawPixelFormatType:)` (no `processedFormat` — not a twin shot) accordingly, falling
  back to HEIC when no legal RAW format exists for the current lens/zoom.
- **ProRAW is a `CaptureFormat` case, not a separate toggle** (changed 2026-08-11 on user
  request). The format picker is a single three-way choice: **HEIC / RAW / ProRAW**. It used
  to be a two-way picker plus an independent `AppSettingsStore.appleProRAWEnabled` switch
  shown beside it, which the user found genuinely confusing — "there is 2 raw settings that
  I'm seeing … I don't know the difference" — and rightly so, because the toggle only meant
  anything while RAW was selected and was completely inert in HEIC mode. Notes:
  - `isRAW` (either flavour) vs `prefersAppleProRAW` (ProRAW only) are both on `CaptureFormat`.
    **Use `.isRAW` rather than `== .raw`** for "is this a RAW capture", or ProRAW silently
    takes the HEIC branch.
  - The old UserDefaults key is read once at launch (`Keys.legacyAppleProRAWEnabled`) to
    migrate `RAW` + toggle-on into `.appleProRAW`, then removed — so an existing ProRAW
    preference isn't silently demoted to Bayer. The migrated value is written explicitly
    because `didSet` doesn't fire for assignments inside `init`.
  - `SettingsView` filters ProRAW out of the picker on hardware without support (as the
    toggle used to hide itself) and carries a per-format footer explaining the difference,
    including that plain RAW can't be used on the cropped zoom lenses.
- Photos save to a **dedicated app-created photo album**, never the camera roll root.
  **Deviation from spec**: SPEC.md calls for add-only photo access only. In practice,
  `PHPhotoLibrary.requestAuthorization(for: .addOnly)` combined with the
  `PHAssetCollection`/`PHAsset` fetches this app needs (cross-launch album lookup in
  `PhotoAlbumManager`, and the Gallery screen) is a documented crash source — confirmed
  against real-world reports (Apple Developer Forums, third-party issue trackers), not
  just guessed. `PhotoAlbumManager` requests `.readWrite` instead, and Info.plist carries
  both `NSPhotoLibraryAddUsageDescription` and `NSPhotoLibraryUsageDescription` (the
  latter is required for any fetch-based Photos API regardless of the granted access
  level, or the app crashes with "attempted to access privacy-sensitive data without a
  usage description" on the first fetch call). Don't revert this to `.addOnly` without
  redesigning the album lookup and Gallery to avoid `PHAssetCollection`/`PHAsset` fetches
  entirely.
- Portrait-only for v1.
- Explicitly out of scope — do not build: zebra stripes, presets/profiles, front
  camera, landscape orientation. (Focus peaking should still be structured so zebra
  stripes could later be added as a second filter branch, not a new pipeline.)
- Camera Control hardware bar (Task 12, iPhone 16+) must be additive and device-gated:
  check for actual Camera Control hardware presence at runtime, not just OS version,
  and every hardware control must drive the *same* `ManualControlEngine` setters as the
  on-screen sliders — single source of truth, no duplicate control logic.
  The **light press** half of `AVCaptureEventInteraction` (Task 12's "focus/exposure lock
  at tap point, or center if no explicit point") goes through
  `CameraCoordinator.lockFocusAndExposureAtCurrentPoint()` → the same
  `ManualControlEngine.tapToReset(at:)` the on-screen tap uses, aimed at
  `coordinator.lastFocusDevicePoint` (whatever the user last tapped) or
  `ManualControlEngine.centerPointOfInterest` if they haven't tapped this session. It had
  been wired to `setLensPosition(controlEngine.lensPosition)` — writing back the value the
  engine already held, so light press silently did nothing at all.
- **Deviation from spec**: SPEC.md lists exposure bias (EV) as a fifth manual control.
  It's been removed entirely (no `ManualParameter.exposureBias`, no
  `ManualControlEngine.exposureTargetBias`/`setExposureTargetBias`, no hardware EV
  slider) because `AVCaptureDevice.setExposureTargetBias` only affects the actual image
  in auto-exposure modes — confirmed from the SDK header itself: "When the exposure mode
  is `AVCaptureExposureModeCustom`, it will only affect metering." Since this app always
  runs the device in `.custom` mode (for manual ISO/shutter), EV would only move an
  internal metering number with zero visible effect — confirmed by the user seeing no
  change in preview/capture. Manual controls are ISO, shutter, focus, white balance only.

## Architecture (per SPEC.md)

- **`CameraSessionManager`** (`ObservableObject`) owns the `AVCaptureSession` lifecycle,
  device discovery, and outputs (`AVCapturePhotoOutput`, `AVCaptureVideoDataOutput`).
  Session must run on a dedicated background queue — never main thread.
  The back camera input is always a **discrete individual physical lens**
  (`.builtInUltraWideCamera`/`.builtInWideAngleCamera`/`.builtInTelephotoCamera`) —
  deliberately never the virtual multi-camera device (`.builtInTripleCamera` etc). An
  earlier version of the lens switcher used the virtual device so zoom could span all
  lenses via a single `videoZoomFactor`, but that crashed the moment manual focus was
  touched: `AVCaptureDevice.isLockingFocusWithCustomLensPositionSupported` is false on
  virtual devices, and `setFocusModeLocked(lensPosition:completionHandler:)` throws
  `NSInvalidArgumentException` if you call it with an explicit lens position when that's
  false (the correct guard — confirmed against the SDK header — is
  `isLockingFocusWithCustomLensPositionSupported`, not `isFocusModeSupported(.locked)`,
  which only confirms focus-lock-at-*current*-position is possible). So: `switchToLens(_:)`
  swaps the session's `AVCaptureDeviceInput` when moving to a different physical lens
  (same begin/removeInput/addInput/commitConfiguration pattern as adding the initial
  input), then sets that lens's own `videoZoomFactor`. `buildLensPresets()` derives every
  selectable zoom point directly from the connected device via `AVCaptureDevice
  .DiscoverySession` — never hardcoded — one preset per discovered lens (its own native
  1.0), plus one extra preset per entry in that lens's
  `activeFormat.secondaryNativeResolutionZoomFactors` (an extra native crop point some
  lenses expose beyond their base optical magnification — this is what surfaces something
  like an "8×"/200mm telephoto option without guessing at any specific device's marketing
  specs). Presets are labeled by their approximate 35mm-equivalent focal length in mm
  (`CameraLens.make`, `systemZoom * 24` — 24mm being the conventional iPhone wide-lens
  equivalent), not a plain zoom multiplier or fixed lens name.
  Getting the underlying `systemZoom` number right took two iterations: the first used a
  field-of-view ratio (`wideFOV / lensFOV` from `AVCaptureDeviceFormat.videoFieldOfView`)
  as an approximation, which was imprecise enough to show "7.5×" for a lens Apple markets
  as 8×. `buildLensPresets()` now separately discovers the *virtual* multi-camera device
  (`.builtInTripleCamera` etc — queried only for its numbers, never used as the actual
  input, per the crash above) and reads its exact `virtualDeviceSwitchOverVideoZoomFactors`
  (each lens's true native system-relative zoom) and `minAvailableVideoZoomFactor`
  (ultra wide's). Presets are also de-duplicated by their rounded mm value
  (`usedMillimeters`) — some lenses report a `secondaryNativeResolutionZoomFactors` entry
  that lands right on the same mm value as that lens's own base preset (e.g. an extra
  "1x"-equivalent entry duplicating "Wide"), which must be skipped or the picker shows two
  entries for what is visibly the same lens.
  Known gap: the Camera Control hardware bar's `AVCaptureSlider` ranges (Task 12) are for
  ISO/shutter/focus only and are unrelated to/unaffected by this zoom switcher.
- **`ManualControlEngine`** is the single point of control for ISO, shutter speed,
  focus, and white balance on the active `AVCaptureDevice` (no exposure bias — see
  deviation above). Always `lockForConfiguration()`/unlock around changes; ranges are
  queried live from the device (never hardcoded) and re-queried whenever the active
  device changes. ISO and shutter share one underlying call
  (`setExposureModeCustom(duration:iso:)`) — setting one must read-and-preserve the
  other's current value. `attach(device:)` runs on every device change — initial launch
  *and* every lens switch that moves to a different physical lens (not a same-lens
  secondary-zoom preset) — re-querying ranges then re-applying the engine's current
  in-memory values (clamped to the new lens's ranges) via `applyCurrentValues(to:)`, so
  switching lenses carries your current ISO/shutter/focus/WB forward instead of silently
  reverting to that lens's own auto-exposure state. `CameraCoordinator` separately guards
  the persisted-value restore, initial ProRAW apply, and Camera Control hardware bar setup
  to only run once, on the very first device.
  - **`isLocked` / `setLocked(_:)`** freezes every public setter (`setISO`,
    `setExposureDuration`, `setLensPosition`, `setWhiteBalanceKelvin`, `tapToReset`) for the
    duration of a capture run — see the Multi-Shot Timer notes for why this lives in the
    engine and not the UI. `attach`/`restore`/`applyCurrentValues` are deliberately *not*
    gated, so a lens switch mid-run still carries the frozen values to the new lens.
  - **`resetToMeteredBaseline()`** is `tapToReset(at: centerPointOfInterest)`: let the
    device meter the scene with its own auto modes, then lock wherever it settled in as the
    manual starting point. This is what `SPEC.md` Task 11 means by "if persistence is
    disabled, fall back to the device's auto-exposure/auto-focus defaults on launch, letting
    the user start from a metered baseline" — `attach(device:)` unconditionally applies the
    engine's in-memory values, so without this, launching with persistence off (or on but
    with nothing saved yet, i.e. the first ever launch) always started at a hardcoded
    ISO 100 / 1÷125 / lens 0.5 / 5600K regardless of the actual scene. Called from
    `CameraCoordinator.handleDeviceAttached`'s one-time setup, in the `else` of the
    persisted-restore branch.
  - White balance is modeled as a single Kelvin value at the UI/engine layer, converted
    to device gains via `temperatureAndTintValues`/`deviceWhiteBalanceGains(for:)`, and
    clamped to `maxWhiteBalanceGain` before every apply (out-of-range gains crash).
  - **`tapToReset(at devicePoint:)`** is tap-to-focus/expose/white-balance, point-and-shoot
    style, layered on top of the always-manual model per user request ("tap to reset my
    focus, iso, shutter speed, White balance for that point then change anything that I
    want from that point"). It does not switch the app into an auto mode permanently: it
    sets `focusPointOfInterest`/`exposurePointOfInterest` to the tapped point and flips
    focus/exposure/white balance to their one-shot auto modes (`.autoFocus`/
    `.autoExpose`/`.autoWhiteBalance`), waits for the device to finish adjusting, then
    reads back wherever it settled (`device.iso`/`.exposureDuration`/`.lensPosition`/
    `.deviceWhiteBalanceGains` → Kelvin via `WhiteBalanceConverter`) and immediately
    re-locks the device to those exact values via the same `.custom`/`.locked` calls the
    sliders use — so the tap becomes a new manual baseline, not a standing auto mode.
    "Waits for the device to finish adjusting" is real KVO, not a fixed delay: observes
    `isAdjustingFocus`/`isAdjustingExposure`/`isAdjustingWhiteBalance` (all three
    KVO-observable per the SDK header) for a genuine adjusting → settled transition.
    **Confirmed bug, fixed**: the first version treated "not currently adjusting" as
    "already settled" the instant the observers attached, and called that its signal
    to read back and lock in values. But the hardware doesn't flip these flags to
    `true` synchronously the moment the auto modes are set — there's a brief real-world
    delay before a scan actually starts — so that check almost always won the race
    before anything had moved, silently re-locking the exact pre-tap values. Symptom:
    tapping showed the reticle but nothing about focus/exposure/white balance or the
    sliders ever actually changed. Fixed by waiting for at least one of the three to
    report `true` (adjusting) and then fall back to `false`, with a 0.35s grace period
    to settle immediately if nothing ever starts adjusting (e.g. point-of-interest
    unsupported at that position, or the scene needs no correction), plus a 2s hard
    safety-net timeout in case a started scan never fully settles (e.g. low-light
    exposure hunting). KVO change handlers can land on an arbitrary AVFoundation
    thread, not `queue`, so the observation tokens are guarded by a dedicated `NSLock`
    and the actual read-back/relock
    always hops back onto `queue` before touching the device again.
- **`PhotoCaptureService`** wraps `AVCapturePhotoOutput` capture + `AVCapturePhotoCaptureDelegate`,
  builds HEIC-or-RAW settings (mutually exclusive — see the `CaptureFormat` deviation
  above), and writes the result to the app's dedicated `PHPhotoLibrary` album (created
  on first launch, identifier persisted). Every capture yields exactly one
  `didFinishProcessingPhoto` callback now (never a separate RAW + processed pair), so
  `InFlightCapture` just tracks one `(data, isRAW)` pair per `uniqueID`.
  In `save(data:isRAW:)`, a RAW result is written to a temp file and added to the asset
  via `addResource(with:fileURL:options:)` with `options.shouldMoveFile = true` (cleaned
  up manually on failure, since `shouldMoveFile` only consumes the file on success) —
  **not** `addResource(with:data:options:)` like HEIC uses. Confirmed bug: adding a RAW
  resource from `Data` is a documented-broken path in PhotoKit — asset creation reliably
  fails with `PHPhotosErrorChangeNotSupported` (`PHPhotosErrorDomain` code 3300, "the
  change request is not supported as configured") when RAW is added from `Data`, and
  reliably succeeds when added from a file URL instead. Don't revert the RAW resource to
  the `Data` overload for "simplicity" — it will reintroduce this exact failure. Also
  note the resource type: a RAW capture's file is added as `.photo` (the asset's
  *primary* resource), not `.alternatePhoto` — `.alternatePhoto` only makes sense as a
  secondary form alongside a primary `.photo`, which no longer exists now that HEIC and
  RAW are mutually exclusive.
  **RAW pixel-format selection is governed by `RAWPixelFormatRule` (`/Models`) — confirmed crash,
  fixed 2026-08-11.** User report: "any zoom lens selected in Manual mode with Apple ProRAW enabled
  crashes if I click photo … 2x and 8x where we use sensor crop." Root cause, from
  `AVCapturePhotoOutput.capturePhoto(with:delegate:)`'s documented validation rules:
  - **The `videoZoomFactor == 1.0` requirement is a *Bayer RAW* rule, not a ProRAW rule.** Bayer RAW
    additionally requires `photoQualityPrioritization == .speed` (which this app always uses in
    Manual). Apple ProRAW has **no** zoom restriction. Violating any rule throws
    `NSInvalidArgumentException` — a hard crash, not an error callback.
  - **`availableRawPhotoPixelFormatTypes` lists ProRAW formats *after* Bayer ones** (SDK: "These
    formats will be added to -availableRawPhotoPixelFormatTypes after any existing Bayer RAW
    formats"), so `.first` is the **Bayer** format whenever one exists. The old code was
    `first(where: isAppleProRAWPixelFormat) ?? first` — that `??` handed a *Bayer* format to a
    zoomed capture whenever ProRAW wasn't on offer in a sensor-crop mode, which is exactly the
    2×/8× case. The same fallback made plain (non-ProRAW) RAW crash at those presets too; the user
    only happened to hit it with ProRAW on.
  - The rule now lives in one place used by **both** the capture path and the UI, so they can't
    disagree: ProRAW if requested and offered; otherwise Bayer only when unzoomed; otherwise nil,
    and the capture falls back to HEIC instead of throwing.
  - `CameraSessionManager.isRAWAvailableAtCurrentLens` publishes the same verdict (re-evaluated on
    every lens switch *and* after a ProRAW toggle, since both change the answer), and
    `MainCameraView.rawUnavailableNotice` warns before the shutter rather than letting a silent
    HEIC substitution surprise the user. **This is a structural limitation, not a bug to fix
    later:** the app's secondary-native-zoom presets (the 2×/8× sensor crops that
    `buildLensPresets` surfaces) are fundamentally incompatible with Bayer RAW. ProRAW is the only
    way to get a RAW file at those focal lengths.

  **Apple ProRAW is applied in two halves, both driven by
  `CameraCoordinator.applyAppleProRAWSetting(_:)`** — don't collapse them back together:
  `CameraSessionManager.setAppleProRAWEnabled(_:)` owns the `photoOutput
  .isAppleProRAWEnabled` write (session state: it happens on `sessionQueue` inside a
  `beginConfiguration`/`commitConfiguration` batch, because it changes which formats
  `availableRawPhotoPixelFormatTypes` reports and must be settled before the next capture
  reads that list; it's also guarded on `isAppleProRAWSupported`, which raises
  `NSInvalidArgumentException` if violated), while `PhotoCaptureService
  .setAppleProRAWEnabled(_:)` now only records the preference that
  `preferredRawPixelFormatType()` consults. It used to do both from main, which was the
  wrong queue for an output change.
  Two ordering traps this pass had to work around, worth keeping in mind for any similar
  live setting: (a) the initial apply can't happen in `CameraCoordinator.init`, because the
  photo output isn't attached to the session yet and `isAppleProRAWSupported` still reads
  false there — it's re-applied from `handleDeviceAttached` once a device is live; (b) the
  `$defaultCaptureFormat` sink must use its **emitted** value, not read
  `settingsStore.defaultCaptureFormat`, since `@Published` fires on `willSet` and the property
  still holds the *old* value inside the closure.
  Since ProRAW became a format case, `PhotoCaptureService` no longer keeps its own copy of the
  preference — the per-capture choice comes from `CaptureFormat.prefersAppleProRAW` at shutter
  time, so there's only one source of truth and nothing to keep in sync.
  Both `CameraSessionManager.photoOutput.maxPhotoQualityPrioritization` and each capture's
  `AVCapturePhotoSettings.photoQualityPrioritization` are `.speed`, not `.quality` —
  confirmed bug: `.quality` opts into Apple's multi-frame fusion (Smart HDR/Deep
  Fusion-style processing, per the SDK header's own description of
  `maxPhotoQualityPrioritization`), and the fused processed (HEIC) output's EXIF can
  then reflect whatever exposure the fusion pipeline blended from several frames, not
  the exact ISO/shutter this app locked in via `ManualControlEngine` — even though the
  live preview and RAW capture (single-frame, unaffected by fusion) correctly show the
  manually-set values throughout. `.speed` forces a true single-exposure capture, which
  a manual camera app's "what you dial in is what you get" premise requires. Don't
  revert to `.quality` for "better" photos — it directly undermines manual exposure.
- **`FocusPeakingProcessor`** consumes `CMSampleBuffer`s from the video data output on
  a serial queue, using a **Metal-backed `CIContext`** (not CPU/software) for real-time
  edge-detection + threshold + colored overlay. Must be fully skippable (not just
  hidden/zero-opacity) when peaking is toggled off, to avoid burning GPU cycles.
  Overlay composites in a SwiftUI `ZStack` above `CameraPreviewView`.
  Two real bugs were caught and fixed on later review, both in the `CIColorMatrix` step
  in `makeOverlay(from:)` (not caught earlier since this pipeline was never actually
  exercised on a device until now):
  1. `inputBiasVector` had `x: 0` — since R/G/B's input weight vectors are all zero, the
     output red channel is `0 (dot product) + bias.x`. With `bias.x = 0` the overlay was
     **solid black**, not red as the doc comment and Task 7 both intend. Fixed to
     `bias.x = 1`, which makes output red a constant 1.0 regardless of input.
  2. `inputAVector` included the input alpha channel (`w: 1`). Camera frames are opaque
     (alpha ≈ 1 everywhere), so that added a constant +1 to every pixel's computed alpha
     regardless of edge strength — the `threshold` (0.2) barely mattered, since even flat
     non-edge regions landed around alpha 0.8. Fixed to `w: 0` so alpha is purely
     `(inputR + inputG + inputB) - threshold`: near 0 in flat regions (clamped to
     invisible), high at real edges.
  Separately, **`AVCaptureVideoDataOutput` needed an explicit rotation angle** —
  `CameraSessionManager.applyVideoDataOutputRotation(for:)` sets the connection's
  `videoRotationAngle` via the modern `AVCaptureDevice.RotationCoordinator` (iOS 17+),
  since (unlike `AVCaptureVideoPreviewLayer`, which auto-rotates its own contents) video
  data output delivers frames in the sensor's native landscape orientation by default —
  without this the peaking overlay would render sideways relative to the portrait
  preview it's composited over. Must run before `session.startRunning()` per the SDK
  docs (video data output physically rotates buffers, unlike other output types) — done
  once in `configureSession()`, and reapplied inside the same begin/commit batch in
  `switchToLens(_:)` whenever the physical lens changes, since swapping the session
  input recreates the output's connection and resets this angle.
  After both fixes above, the user still reported "nothing visible" — root cause turned
  out to be UI, not the pipeline: the peaking toggle used a bolt/flash-shaped icon in a
  crowded top bar and was easy to never notice, so it was simply never turned on.
  Temporary on-screen diagnostics (`debugFramesSeen`/`debugLastFailureReason` on
  `FocusPeakingProcessor`, `debugVideoDataOutputAdded`/`debugVideoRotationApplied` on
  `CameraSessionManager`, a debug HUD in `MainCameraView`) were added and then removed
  once this was confirmed — the underlying pipeline was fine all along. The whole top
  bar is gone now anyway (see the Task 8/9 restructuring deviation below), so this
  specific discoverability failure mode can't recur, but if peaking ever silently does
  nothing again, that diagnostics pattern (proven to work) is the fastest way back to a
  root cause — re-add it rather than guessing from source alone.
- **`CameraPreviewView`** is a `UIViewRepresentable` around an `AVCaptureVideoPreviewLayer`;
  layer frame must be kept in sync with view bounds in `updateUIView`. **Deviation from
  spec**: uses `.resizeAspect`, not `.resizeAspectFill` as Task 6 specifies — the user
  wants the viewfinder boxed to the sensor's real 4:3 capture ratio (not full-bleed
  cropped/stretched), with the rest of the screen staying black. `MainCameraView`
  constrains the preview to `.aspectRatio(3.0/4.0, contentMode: .fit)` rather than
  `.ignoresSafeArea()`, and the surrounding controls (value strip, lens tabs, parameter
  tabs, slider, capture bar) sit in the black space around that box in a plain vertical
  stack, rather than overlaid on top of a full-bleed preview. The viewfinder is the
  topmost element on screen — see the Task 8/9 restructuring deviation below for why
  there's no top bar above it anymore.
  A `UITapGestureRecognizer` on the wrapped `PreviewUIView` (bridged via a
  `UIViewRepresentable` `Coordinator`, since UIKit target/action needs an `NSObject` to
  target) drives tap-to-focus: on tap, it converts the tap location via
  `videoPreviewLayer.captureDevicePointConverted(fromLayerPoint:)` into
  `AVCaptureDevice` point-of-interest space and passes both that device-space point and
  the raw view-local point out through `onTap`. `MainCameraView` uses the device point
  to call `CameraCoordinator.tapToFocus(at:)` → `ManualControlEngine.tapToReset(at:)`
  (see above), and the view-local point purely to position a brief `FocusReticle`
  (cosmetic feedback only — the actual reset works identically whether or not the
  reticle is ever seen).
- **`WheelSlider`** (replaces Task 8's plain `Slider` + numeric + range-bar spec) is a
  custom horizontal tick-ruler control per user request, styled from a reference
  screenshot (thin compact ticks, red fixed-center marker, no permanently visible
  number). Went through three iterations before landing here — worth knowing before
  "improving" it again:
  1. Endless-scrolling ruler under a fixed center marker, unbounded — you could never
     see where the min/max actually were. Also had the drag direction backwards.
  2. Swung the other way: whole range mapped onto the fixed visible width (leftmost tick
     = `range.lowerBound`, rightmost = `range.upperBound`), with the *marker* sliding to
     an absolute position along a static ruler. Correctly showed the bounds, but the
     user wanted the marker back at a fixed center with the background moving instead.
  3. **Current design**: fixed center marker (as in #1) + background scrolls beneath it
     (ticks move *with* the finger — dragging right shifts content right, so the value
     under the marker decreases, since smaller values were off-screen to the left) + the
     scroll is bounded to the real tick range (as in #2's spirit): `TickRuler` only ever
     draws indices `0...tickCount`, so once index 0 (`range.lowerBound`) or `tickCount`
     (`range.upperBound`) reaches center, ticks stop appearing beyond it — you can see
     and feel hitting the actual limit instead of scrolling forever.
  `tickCount` (40) only controls visual/haptic density — `value` itself stays continuous
  (ticks are a `UISelectionFeedbackGenerator.selectionChanged()` haptic guide per tick
  crossed, not a hard snap grid). `valueText` only renders as a floating label while
  actively dragging (not at rest, to keep the idle look clean) — it gives the parameter
  being dragged a large readout under the finger. (This used to be Focus's *only* readout
  anywhere; the value strip now carries focus too — see the Task 8 readout fix below — so
  the floating label is a convenience now, not the sole display.)
  `WheelSlider` itself has no idea what the values it's showing *mean* — it's a plain
  linear ruler over whatever `(value, range)` it's given. **ISO and shutter are fed
  `log2`-transformed values/ranges** by `MainCameraView.parameterSlider`, converting back
  with `exp2(_:)` in `onChange` — both are used in photographic *stops* (ISO
  50/100/200/400/800..., shutter 1/8/1/15/1/30...), each stop a doubling/halving, so a
  linear slider wastes most of its length on one end (confirmed by the user: ~80% of a
  linear shutter slider sat between 1/8 and 1s, cramming the entire 1/45–1/12000 range
  into a sliver). In log2 space every tick is an equal proportional step regardless of
  where you are in the range. Focus (already 0...1, not stop-based) and white balance
  (Kelvin — not stop-based either) stay linear. If another stop-based control is added
  later, feed it through the same `log2`/`exp2` pattern rather than inventing a new one.
- UI, settings persistence (`UserDefaults`), and the gallery (`PHAsset` fetch scoped to
  the app's own `PHAssetCollection`) are straightforward SwiftUI layers on top of the above.
- Cross-cutting rule: hardware Camera Control inputs (Task 12) and on-screen sliders must
  both funnel through `ManualControlEngine` and stay in sync live in both directions.
- **`CameraCoordinator`** forwards `objectWillChange` from every nested `ObservableObject`
  it owns (`sessionManager`, `controlEngine`, `captureService`, `peakingProcessor`,
  `settingsStore`) into its own `objectWillChange`. SwiftUI views only observe
  `coordinator` itself (`@ObservedObject`), so without this forwarding, changes to e.g.
  `ManualControlEngine.iso` never trigger a re-render — the underlying hardware call
  still applies (visible in the live preview/capture), but sliders and numeric readouts
  silently freeze. If you add a new nested `ObservableObject` to `CameraCoordinator`,
  add it to this forwarding list too. `settingsStore` was added late — it didn't matter
  while `MainCameraView` never displayed a settings-store value directly, but once the
  viewfinder started reading `settingsStore.isPeakingEnabled` live (see below), missing
  this would have made peaking silently never turn on from `MainCameraView`'s POV.
- **Deviation from spec**: Task 8's top bar and Task 9's "default format sets the
  top-bar toggle's starting state" model are both gone, per explicit user request.
  There's no more top bar at all — the viewfinder is the topmost element in
  `MainCameraView` — and capture format + focus peaking now live *only* in the Settings
  sheet, each backed directly by `AppSettingsStore` (`defaultCaptureFormat`,
  `isPeakingEnabled`) with no separate "live session override" concept layered on top.
  Concretely:
  - `CameraCoordinator.captureFormat` is now a plain computed property
    (`settingsStore.defaultCaptureFormat`), not an independent `@Published` value — there
    was never a reason for the two to diverge once the only way to change format is the
    Settings picker, and `PersistedCameraState.captureFormat` (a *second*, Task-11-driven
    persistence path for the same concept) was removed as redundant.
  - `AppSettingsStore.isPeakingEnabled` (persisted, default `false`) replaced
    `CameraCoordinator.isPeakingEnabled` (an unpersisted `@Published` flag) —
    `CameraCoordinator.init` applies the restored value to `peakingProcessor` immediately
    and subscribes to `settingsStore.$isPeakingEnabled` to keep it in sync afterward.
  - The capture bar's bottom-right lens `Menu` was replaced with a settings gear button;
    lens switching moved to its own always-visible tab row (`MainCameraView.lensTabBar`,
    styled identically to `parameterTabBar`) directly above the ISO/SHUTTER/FOCUS/WB tabs,
    collapsing to nothing on single-lens devices rather than showing a redundant row.
  - `MainCameraView.topCornerButtons` — two placeholder buttons (no-op, labeled
    "1"/"2") in the empty space flanking the notch/Dynamic Island, per user request,
    without pushing the viewfinder down or bringing back a top bar. Applied as an
    `.overlay(alignment: .top)` on the outer `ZStack` rather than a row inside the
    main `VStack` — an overlay doesn't participate in the `VStack`'s layout, so it
    can't affect the viewfinder's position. The overlay content itself uses
    `.ignoresSafeArea(edges: .top)` so it can sit level with the notch/island (which is
    physically *inside* the top safe area exclusion band) rather than being pushed
    below it like the rest of the screen's content. **Currently disabled** — per a
    later user request ("comment them out, I might need them in the future"), the
    `.overlay` call in `body` is commented out, but `topCornerButtons`/
    `topCornerButton(label:)` themselves are left in place as dead code rather than
    deleted, so re-enabling later is a one-line uncomment. Expect an "unused" build
    warning until then.
  - `MainCameraView.valueReadoutStrip` was restructured per user request from a single
    centered capsule into an `HStack` with the ISO/shutter/focus/WB capsule
    (`valueReadoutCapsule`) on the left, a `Spacer()`, and a new `captureOptionsButton`
    (⋯) on the right — a `Capsule`, not a `Circle` (64×36pt, wider than tall per user
    request), to stand apart from the circular gear/thumbnail buttons elsewhere on
    screen. Tapping it presents `CaptureOptionsSheet` — a small bottom sheet
    (`.presentationDetents([.height(150)])`, drag indicator hidden — shrunk from an
    initial 260pt to closely hug the tile row's own height, per user request) laid
    out as a centered `HStack` of icon-over-label tiles (no `maxHeight: .infinity`/
    trailing `Spacer`, so the sheet doesn't stretch past the tiles; replaced an
    earlier `LazyVGrid` version that spread tiles edge-to-edge instead of grouping
    them in the middle) holding three capture-mode tiles: **Timer** is wired (see the
    Multi-Shot Timer notes above), while Portrait and Astro remain no-op placeholders
    awaiting their modes — same wire-up-later pattern as `topCornerButtons`.
  - **Task 8 readout fix (2026-08-11)**: `valueReadoutCapsule` shows
    ISO · shutter · focus · WB. Focus had been missing, against Task 8's "always shows all
    current values regardless of which tab is active" — which made focus the one manual
    control with no at-rest readout anywhere on screen, since `WheelSlider`'s floating
    label only appears mid-drag and only on the FOCUS tab. Focus renders via
    `CameraValueFormatting.focusLabeled` ("FOC 45%"), labeled because the strip has no
    active-tab context to disambiguate a bare percentage; deliberately **not** shortened to
    "F", which reads as an f-number to a photographer (aperture is fixed on iPhone hardware
    and this app doesn't control it).
