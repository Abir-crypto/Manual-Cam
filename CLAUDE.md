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
                 SettingsView, PermissionView, CameraValueFormatting
/Settings      — AppSettingsStore, CameraStatePersistenceStore (UserDefaults-backed)
/Gallery       — GalleryView, PhotoDetailView
/Models        — CaptureFormat, ManualControlRanges, ManualParameter, PersistedCameraState
```

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

- **Min iOS 18.0**, iPhone only, back camera only (`.builtInWideAngleCamera`). No front
  camera, no iPad/Vision Pro-specific handling despite the Xcode template defaulting
  `TARGETED_DEVICE_FAMILY` to include iPad/Vision.
- Every capture is a **twin RAW (DNG/ProRAW) + HEIC** shot (when RAW is enabled) —
  one `AVCapturePhotoSettings` call, not two separate captures.
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

## Architecture (per SPEC.md)

- **`CameraSessionManager`** (`ObservableObject`) owns the `AVCaptureSession` lifecycle,
  device discovery, and outputs (`AVCapturePhotoOutput`, `AVCaptureVideoDataOutput`).
  Session must run on a dedicated background queue — never main thread.
- **`ManualControlEngine`** is the single point of control for ISO, shutter speed,
  focus, exposure bias, and white balance on the active `AVCaptureDevice`. Always
  `lockForConfiguration()`/unlock around changes; ranges are queried live from the
  device (never hardcoded) and re-queried whenever the active device changes. ISO and
  shutter share one underlying call (`setExposureModeCustom(duration:iso:)`) — setting
  one must read-and-preserve the other's current value.
  - White balance is modeled as a single Kelvin value at the UI/engine layer, converted
    to device gains via `temperatureAndTintValues`/`deviceWhiteBalanceGains(for:)`, and
    clamped to `maxWhiteBalanceGain` before every apply (out-of-range gains crash).
- **`PhotoCaptureService`** wraps `AVCapturePhotoOutput` capture + `AVCapturePhotoCaptureDelegate`,
  builds the twin RAW+HEIC settings, and writes to the app's dedicated `PHPhotoLibrary`
  album (created on first launch, identifier persisted).
- **`FocusPeakingProcessor`** consumes `CMSampleBuffer`s from the video data output on
  a serial queue, using a **Metal-backed `CIContext`** (not CPU/software) for real-time
  edge-detection + threshold + colored overlay. Must be fully skippable (not just
  hidden/zero-opacity) when peaking is toggled off, to avoid burning GPU cycles.
  Overlay composites in a SwiftUI `ZStack` above `CameraPreviewView`.
- **`CameraPreviewView`** is a `UIViewRepresentable` around an `AVCaptureVideoPreviewLayer`
  (`.resizeAspectFill`); layer frame must be kept in sync with view bounds in `updateUIView`.
- UI, settings persistence (`UserDefaults`), and the gallery (`PHAsset` fetch scoped to
  the app's own `PHAssetCollection`) are straightforward SwiftUI layers on top of the above.
- Cross-cutting rule: hardware Camera Control inputs (Task 12) and on-screen sliders must
  both funnel through `ManualControlEngine` and stay in sync live in both directions.
