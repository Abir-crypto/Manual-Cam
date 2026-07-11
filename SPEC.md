# Manual Camera App — SPEC.md

Personal-use iOS manual camera app. SwiftUI. Full manual control over ISO, shutter speed, focus, white balance, and exposure bias, with live focus peaking and Camera Control (iPhone 16+) hardware support.

## Target & Constraints

- **Min iOS: 18.0** (required for Camera Control bar APIs)
- **Devices:** iPhone only, back camera only (`.builtInWideAngleCamera`)
- **UI framework:** SwiftUI (camera preview bridges in via `UIViewRepresentable`)
- **Capture formats:** JPEG/HEIC + RAW (DNG / Apple ProRAW where supported), twin capture on every shutter press
- **No presets/profiles, no front camera, no zebra stripes** — explicitly deferred, do not build
- Camera Control hardware dial is **device-gated**: falls back gracefully to on-screen sliders on any device without it

---

## Task 1 — Project Setup & Permissions

- New SwiftUI iOS app, deployment target 18.0
- Add `NSCameraUsageDescription` and `NSPhotoLibraryAddUsageDescription` to Info.plist (add-only photo permission — do NOT request full library read access)
- Folder structure:
  ```
  /Camera        — session manager, capture, manual controls
  /Peaking       — live frame analysis pipeline
  /UI            — SwiftUI views
  /Settings      — settings sheet + UserDefaults persistence
  /Gallery       — in-app album grid
  /Models        — value types (CameraSettings, etc.)
  ```
- Request camera permission on first launch with a simple pre-permission explainer screen if denied, show a "Camera access needed" state with a button to open Settings

**Acceptance:** app launches, requests camera permission, shows black/placeholder screen if denied with a clear way to fix it.

---

## Task 2 — Camera Session Manager

Build `CameraSessionManager` (ObservableObject) wrapping `AVCaptureSession`:

- Discover back wide-angle camera via `AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)`
- Configure `AVCaptureDeviceInput`, add to session
- Add `AVCapturePhotoOutput` (configure `maxPhotoQualityPrioritization`, enable RAW capture support check via `availableRawPhotoPixelFormatTypes`, check `isAppleProRAWSupported`)
- Add `AVCaptureVideoDataOutput` for live frames (feeds focus peaking pipeline — Task 7), set a serial dispatch queue as its sample buffer delegate queue
- Session runs on a dedicated background queue, never on main thread
- Expose `@Published var isSessionRunning`, `@Published var currentDevice`
- On init, query and expose current device's manual control ranges (see Task 3) since they vary per device/lens

**Acceptance:** session starts, preview-worthy frames flow, no main-thread blocking warnings.

---

## Task 3 — Manual Control Engine

Build `ManualControlEngine` operating on the active `AVCaptureDevice`. Must lock device for configuration (`device.lockForConfiguration()`) before any change, unlock after.

For each control, expose: current value, min/max range (queried from device, NOT hardcoded), and a setter.

| Control | Query range from | Set via |
|---|---|---|
| ISO | `activeFormat.minISO` / `maxISO` | `setExposureModeCustom(duration:iso:)` |
| Shutter speed | `activeFormat.minExposureDuration` / `maxExposureDuration` | same call, `duration:` as `CMTime` |
| Focus | fixed 0.0–1.0 (normalized) | `setFocusModeLocked(lensPosition:)` |
| Exposure bias (EV) | `minExposureTargetBias` / `maxExposureTargetBias` | `setExposureTargetBias(_:)` |
| White balance | derived (see below) | `setWhiteBalanceModeLocked(with:)` |

Notes:
- ISO and shutter speed are set together in one call (`setExposureModeCustom`) — engine should support setting either independently while preserving the other's current value (read current duration when only setting ISO, and vice versa)
- All setters must switch the device into `.custom` mode for exposure and `.locked` for focus/white balance — verify current mode before applying, since interactions between auto/manual modes can throw
- Engine should re-query ranges whenever the active device changes (e.g. app resumes after backgrounding)

**Acceptance:** each control can be set independently, ranges reflect actual device capability, no crashes when rapidly switching between controls.

---

## Task 4 — White Balance Kelvin/Tint Conversion

- Expose white balance as a single Kelvin value (e.g. 2000K–10000K slider range — reasonable general bounds, most iPhones support roughly this span)
- Convert Kelvin (+ fixed neutral tint) to device gains using `device.temperatureAndTintValues(forDeviceWhiteBalanceGains:)` and the inverse `deviceWhiteBalanceGains(for:)`
- Clamp computed gains to `device.maxWhiteBalanceGain` before applying — out-of-range gains will crash `setWhiteBalanceModeLocked`
- Apply via `setWhiteBalanceModeLocked(with:)`

**Acceptance:** dragging the WB slider produces a visible, monotonic color temperature shift live in preview.

---

## Task 5 — Photo Capture (RAW + HEIC twin capture)

- Build `PhotoCaptureService` wrapping `AVCapturePhotoOutput`
- On capture request, build `AVCapturePhotoSettings`:
  - If RAW available and user's current mode includes it: use `AVCapturePhotoSettings(rawPixelFormatType:processedFormat:)` for a twin RAW+HEIC capture in one shot
  - Otherwise: HEIC-only `AVCapturePhotoSettings()`
  - Respect Apple ProRAW when supported and enabled in settings (Task 9)
- Implement `AVCapturePhotoCaptureDelegate`, handle both file representations in `didFinishProcessingPhoto`
- Save both outputs to a **dedicated app-created photo album** (not camera roll root) via `PHPhotoLibrary.shared().performChanges` — create the album on first launch if it doesn't exist, store its identifier
- On successful save, publish the resulting thumbnail image for the UI's capture confirmation (Task 8)

**Acceptance:** tapping shutter saves both RAW (DNG) and HEIC to the app's own album, confirmed by checking Photos app.

---

## Task 6 — Live Preview View

- `CameraPreviewView: UIViewRepresentable` wrapping a `UIView` whose backing layer is `AVCaptureVideoPreviewLayer`
- Layer's `session` set from `CameraSessionManager`
- `videoGravity = .resizeAspectFill`
- Handle safe frame layout updates in `updateUIView` (layer frame must match view bounds on rotation/resize)
- This view sits at the base of the z-stack; focus peaking overlay (Task 7) renders on top of it

**Acceptance:** smooth full-bleed live preview, correctly sized on all iPhone screen sizes.

---

## Task 7 — Focus Peaking Pipeline

- `FocusPeakingProcessor` consumes `CMSampleBuffer`s from the `AVCaptureVideoDataOutput` delegate (Task 2)
- Use a **Metal-backed `CIContext`** (`CIContext(mtlDevice:)`), not CPU/software context — required for real-time performance
- Pipeline: sample buffer → `CIImage` → edge-detection filter (`CIEdges` as a starting point; tune `intensity` for sensitivity) → threshold the result → render as a colored (single fixed color, e.g. red) overlay image
- Output overlay as a texture/image published to the UI at video frame rate, composited via SwiftUI `ZStack` on top of `CameraPreviewView`
- Peaking processing should be skippable entirely (not just hidden) when the toggle is off — don't waste GPU cycles running the filter with 0 opacity

**Acceptance:** toggling peaking on shows real-time edge highlighting on in-focus areas as focus is adjusted; toggling off stops the video-data pipeline from doing peaking work; no visible frame lag on preview.

---

## Task 8 — Main Camera Screen UI

Build the primary SwiftUI screen composing everything above:

```
┌─────────────────────────────────┐
│  RAW/HEIC   ⚡Peaking   ⚙️        │  ← top bar
│                                  │
│      Live preview                │
│      (+ peaking overlay)         │  ← ZStack: CameraPreviewView, peaking overlay
│                                  │
│  ISO 100 · 1/125 · 5600K · +0.3 │  ← always-visible value readout strip
│                                  │
│ [ISO][SHUTTER][FOCUS][WB][EV]   │  ← tab selector, one active at a time
│  ▓▓▓▓▓░░░░░░░░░░░░░░░░ [value]  │  ← horizontal slider + numeric + range bar
│                                  │
│  [thumbnail]    ( ● shutter )    │  ← capture button + post-capture thumbnail
└─────────────────────────────────┘
```

- **Top bar:** RAW/HEIC toggle (persists to UserDefaults per Task 11), peaking on/off toggle, gear icon opening Settings sheet (Task 9)
- **Value readout strip:** always shows all 5 current values regardless of which tab is active — updates live as sliders move
- **Parameter tabs:** tapping a tab swaps the active slider below to that parameter; slider shows numeric value + a filled range bar indicating position within min↔max
- **Slider bounds:** pulled live from `ManualControlEngine`'s queried ranges (Task 3), not hardcoded
- **Shutter button:** triggers `PhotoCaptureService` capture; on success, show a small thumbnail in the corner (from Task 5's published thumbnail) that fades in and is tappable to jump into Gallery (Task 10)
- Handle device rotation: lock UI to portrait for v1 (simplifies preview layer orientation handling) unless you want landscape — flag if so

**Acceptance:** full manual shooting workflow works end-to-end: adjust any control, see live preview change, capture, see confirmation thumbnail.

---

## Task 9 — Settings Sheet

Sheet presented from the gear icon, containing:
- **Default capture format** picker (JPEG/HEIC only vs JPEG/HEIC+RAW) — sets the top bar toggle's default state on next launch
- **Apple ProRAW toggle** (only shown/enabled if `isAppleProRAWSupported` is true for current device)
- **"Persist last-used values"** toggle (default: on) — controls whether Task 11's persistence is active
- App version/build number footer

**Acceptance:** settings persist across app restarts via UserDefaults, defaults apply correctly to main screen state.

---

## Task 10 — Gallery Screen

- Simple grid (`LazyVGrid`) fetching assets from the app's **dedicated album only** (from Task 5), via `PHAsset` fetch scoped to that album's `PHAssetCollection`
- Tap a thumbnail to view full-screen (basic zoomable image view is fine, no editing needed)
- Accessible via a swipe or button from the main camera screen, and via the post-capture thumbnail tap

**Acceptance:** grid shows only photos taken by this app, scrollable, tappable to view full size.

---

## Task 11 — Value Persistence

- `UserDefaults`-backed store for: last-used ISO, shutter duration, focus lens position, WB Kelvin, EV bias, RAW/HEIC toggle state
- On app launch, if "persist last-used values" is enabled (Task 9), restore these into `ManualControlEngine` before the first frame renders
- If disabled, fall back to device's auto-exposure/auto-focus defaults on launch, letting the user start from a metered baseline

**Acceptance:** force-quitting and relaunching the app restores exact prior manual settings when persistence is enabled.

---

## Task 12 — Camera Control Hardware Bar Integration (iPhone 16+, iOS 18+)

Device-gated enhancement — must not affect devices without the Camera Control element.

- Check availability at runtime (Camera Control presence, not just OS version — API surface itself no-ops gracefully on unsupported hardware, but confirm via testing)
- **Shutter behavior:** `AVCaptureEventInteraction` — light press event triggers focus/exposure lock at tap point (or center if no explicit point), full press event triggers the same capture path as the on-screen shutter button (Task 5)
- **Dial behavior:** register four `AVCaptureSlider` controls on the session (`session.addControl(_:)`), one each for ISO, Shutter Speed, EV, Focus, using the same ranges from `ManualControlEngine` (Task 3). Light press on the bar cycles between them; slide gesture adjusts the active one
- Wire each slider's value-changed closure to call the same `ManualControlEngine` setters the on-screen sliders use — single source of truth, no duplicate control logic
- Changes made via hardware dial should reflect live in the on-screen value readout strip (Task 8) and vice versa

**Acceptance:** on iPhone 16-series running iOS 18+, the Camera Control bar cycles through ISO/Shutter/EV/Focus and adjusts them with visible live effect; on any other device/OS, app functions identically using only on-screen controls, no crashes or dead UI elements.

---

## Explicitly deferred (do not build now)

- Zebra stripes (peaking pipeline is structured in Task 7 to make this an easy add-on later — a second filter branch, not a new pipeline)
- Presets/profiles system
- Front camera support
- Landscape orientation (unless flagged otherwise)
