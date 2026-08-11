# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project state

All 12 tasks in `SPEC.md` have an initial implementation in place (session manager,
manual control engine, white balance conversion, RAW+HEIC capture, live preview, focus
peaking, main UI, settings, gallery, persistence, Camera Control hardware bar).
**`SPEC.md` remains the source of truth** for intended behavior and acceptance criteria —
consult it before changing any of these areas, since tasks build on each other's types.

None of this has been build-verified: this environment has no full Xcode install
(`xcodebuild` unavailable, Command Line Tools only), so the code has only been checked
by hand against AVFoundation/Photos/SwiftUI API shape. Treat the first build in Xcode as
the real correctness check — expect to fix compile errors, especially around exact
AVFoundation API names/signatures (`AVCaptureSlider`, `AVCaptureEventInteraction`,
`AVCapturePhotoOutput` RAW/ProRAW APIs) which were written from memory.

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

Three additional spec files live at the repo root and extend the base `SPEC.md`. Multi-Shot
Timer is now implemented (details below); Portrait and Astro are **not yet implemented**. Treat
each file as the source of truth for its feature, the same way `SPEC.md` is for the base app,
and consult the file itself before building/changing any of it. Key decisions and constraints,
so they persist across sessions:

- **`PORTRAIT_MODE.md`** — a new top-level shooting mode (Manual / **Portrait** / Astro).
  Captures depth map + portrait matte + `.skin` semantic segmentation matte alongside a
  HEIC, then renders bokeh in **post-capture** processing (never live). Manual controls are
  **hidden** in this mode, replaced by a Portrait control bar (depth-debug toggle, film-style
  picker, blur-intensity slider, shutter). Device-gated to dual/triple-camera iPhones
  (`.builtInDualCamera`/`.builtInDualWideCamera`/`.builtInTripleCamera`) — hide the entry on
  unsupported devices. Render pipeline: `CIDepthBlurEffect` (depth+matte+calibration, aperture
  from slider) → radial swirl twist on the **background only** (matte-inverted, twist rising
  toward edges) → composite subject back on top via matte. Four film styles — Natural
  (passthrough), Golden Hour, Teal Frost, Noir — as Core Image grade chains applied to the
  **final composite**. Baked-in (no UI toggle): skin smoothing via the skin matte (~30–40%
  blend) and edge softness (small fixed blur on the matte before compositing). Saves **two**
  files per shot: final styled HEIC + the original unprocessed capture. Degrade to depth-only
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
    Each shot calls the **same** `CameraCoordinator.capturePhoto()` the manual shutter uses (via
    a closure passed to `start`), so RAW/HEIC + album destination are respected and there's no
    duplicate capture path. "Settings frozen for the run" is achieved implicitly — the countdown
    overlay covers the controls, and the app is always in manual `.custom` mode anyway, so no
    extra engine lock was added. Sets `UIApplication.shared.isIdleTimerDisabled` for the run so
    the screen doesn't sleep while the user steps away. `cancel()` stops immediately; shots
    already taken stay saved.
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
    starts the run.

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

No CLI Xcode toolchain is installed in this environment (`xcode-select` points at
Command Line Tools only, not a full Xcode install) — `xcodebuild` is not available here.
Builds/runs must happen in Xcode itself (open `ManualCam.xcodeproj`). There is no test
target yet.

## Non-negotiable constraints (from SPEC.md)

These are explicit product decisions — don't "improve" past them:

- **Min iOS 18.0**, iPhone only. No iPad/Vision Pro-specific handling despite the Xcode
  template defaulting `TARGETED_DEVICE_FAMILY` to include iPad/Vision.
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
  explicit user request ("I don't need them together"), `CaptureFormat` is now two
  mutually exclusive modes — `.heic` and `.raw` — not a combined one; there is no
  "RAW+HEIC" option anymore. `PhotoCaptureService.capturePhoto(format:)` builds either a
  plain `AVCapturePhotoSettings()` (HEIC) or a RAW-only `AVCapturePhotoSettings
  (rawPixelFormatType:)` (no `processedFormat` — not a twin shot) accordingly, falling
  back to HEIC if the current lens doesn't support RAW.
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
  the persisted-value restore and Camera Control hardware bar setup to only run once, on
  the very first device.
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
  actively dragging (not at rest, to keep the idle look clean) — needed because Focus
  isn't shown anywhere else, unlike ISO/shutter/WB which are always visible in the value
  readout strip above.
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
    centered capsule into an `HStack` with the ISO/shutter/WB capsule
    (`valueReadoutCapsule`) on the left, a `Spacer()`, and a new `captureOptionsButton`
    (⋯) on the right — a `Capsule`, not a `Circle` (64×36pt, wider than tall per user
    request), to stand apart from the circular gear/thumbnail buttons elsewhere on
    screen. Tapping it presents `CaptureOptionsSheet` — a small bottom sheet
    (`.presentationDetents([.height(150)])`, drag indicator hidden — shrunk from an
    initial 260pt to closely hug the tile row's own height, per user request) laid
    out as a centered `HStack` of icon-over-label tiles (no `maxHeight: .infinity`/
    trailing `Spacer`, so the sheet doesn't stretch past the tiles; replaced an
    earlier `LazyVGrid` version that spread tiles edge-to-edge instead of grouping
    them in the middle) listing capture mode placeholders (Timer,
    Portrait, Astro) as no-op buttons, same
    wire-up-later pattern as `topCornerButtons`.
