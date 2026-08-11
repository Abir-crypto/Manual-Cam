# Graph Report - .  (2026-07-18)

## Corpus Check
- Corpus is ~20,694 words - fits in a single context window. You may not need a graph.

## Summary
- 291 nodes · 541 edges · 14 communities
- Extraction: 94% EXTRACTED · 6% INFERRED · 0% AMBIGUOUS · INFERRED: 34 edges (avg confidence: 0.82)
- Token cost: 83,194 input · 0 output

## Community Hubs (Navigation)
- App Shell, Gallery & Permissions UI
- Camera Session & Lens Switching
- Coordinator, Capture Format & Settings
- Manual Control Engine & Tap-to-Reset
- Core Camera Files & Slider Design Rationale
- Photo Capture Service (HEIC/RAW)
- Persistence & Settings Storage
- Camera Preview & Tap Gesture
- Photo Library Album & Permissions
- Focus Peaking Pipeline
- Camera Control Hardware Bar & Spec Deviations
- Value Formatting Helpers
- White Balance Kelvin Conversion
- Project Docs (CLAUDE.md / SPEC.md)

## God Nodes (most connected - your core abstractions)
1. `ManualControlEngine` - 36 edges
2. `CameraSessionManager` - 25 edges
3. `PhotoCaptureService` - 25 edges
4. `CameraCoordinator` - 22 edges
5. `FocusPeakingProcessor` - 17 edges
6. `MainCameraView` - 16 edges
7. `PersistedCameraState` - 13 edges
8. `WheelSlider` - 13 edges
9. `CameraControlBarController` - 12 edges
10. `CameraLens` - 12 edges

## Surprising Connections (you probably didn't know these)
- `Deviation: exposure bias (EV) control removed entirely` --rationale_for--> `ManualControlEngine`  [EXTRACTED]
  CLAUDE.md → ManualCam/Camera/ManualControlEngine.swift
- `Task 5 — Photo Capture (RAW + HEIC twin capture)` --references--> `PhotoAlbumManager`  [INFERRED]
  SPEC.md → ManualCam/Camera/PhotoAlbumManager.swift
- `Confirmed bug: .speed (not .quality) prioritization required for manual exposure fidelity` --rationale_for--> `PhotoCaptureService`  [EXTRACTED]
  CLAUDE.md → ManualCam/Camera/PhotoCaptureService.swift
- `Task 4 — White Balance Kelvin/Tint Conversion` --references--> `WhiteBalanceConverter`  [INFERRED]
  SPEC.md → ManualCam/Camera/WhiteBalanceConverter.swift
- `Task 10 — Gallery Screen` --references--> `GalleryView`  [INFERRED]
  SPEC.md → ManualCam/Gallery/GalleryView.swift

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **CameraCoordinator forwards objectWillChange from all nested ObservableObjects** — manualcam_camera_cameracoordinator_cameracoordinator, manualcam_camera_camerasessionmanager_camerasessionmanager, manualcam_camera_manualcontrolengine_manualcontrolengine, manualcam_camera_photocaptureservice_photocaptureservice, manualcam_peaking_focuspeakingprocessor_focuspeakingprocessor, manualcam_settings_appsettingsstore_appsettingsstore [EXTRACTED 1.00]
- **On-screen sliders and hardware Camera Control both funnel through ManualControlEngine** — manualcam_camera_manualcontrolengine_manualcontrolengine, manualcam_camera_cameracontrolbarcontroller_cameracontrolbarcontroller, manualcam_ui_wheelslider_wheelslider, manualcam_ui_maincameraview_maincameraview [EXTRACTED 1.00]
- **Explicit user-driven deviations from SPEC.md's original design** — claude_md_capture_format_deviation, claude_md_photo_album_permission_deviation, claude_md_exposure_bias_removal_deviation, claude_md_task8_9_restructuring_deviation, claude_md_no_front_camera_deviation [INFERRED 0.85]

## Communities (14 total, 0 thin omitted)

### Community 0 - "App Shell, Gallery & Permissions UI"
Cohesion: 0.08
Nodes (22): App, GalleryThumbnail, GalleryView, PHAsset, String, UIImage, PhotoDetailView, CGFloat (+14 more)

### Community 1 - "Camera Session & Lens Switching"
Cohesion: 0.10
Nodes (22): Lens presets de-duplicated by rounded mm value to avoid duplicate zoom entries, Confirmed bug: .speed (not .quality) prioritization required for manual exposure fidelity, AVCaptureVideoDataOutput needs explicit videoRotationAngle via RotationCoordinator, Virtual multi-camera device rejected for lens switching: custom lens-position focus lock crashes on virtual devices, Equatable, CameraSessionManager, AVCaptureDevice, String (+14 more)

### Community 2 - "Coordinator, Capture Format & Settings"
Cohesion: 0.09
Nodes (24): AnyObject, CaseIterable, Deviation: CaptureFormat is mutually-exclusive .heic/.raw, no twin RAW+HEIC, CameraCoordinator forwards objectWillChange from every nested ObservableObject, Codable, Identifiable, CameraCoordinator, CGPoint (+16 more)

### Community 3 - "Manual Control Engine & Tap-to-Reset"
Cohesion: 0.16
Nodes (12): Confirmed bug fixed: tapToReset must wait for genuine KVO adjusting->settled transition, not instant not-adjusting check, DispatchQueue, AVCaptureDevice, ManualControlEngine, AVCaptureDevice, CGPoint, CMTime, DispatchQueue (+4 more)

### Community 4 - "Core Camera Files & Slider Design Rationale"
Cohesion: 0.11
Nodes (18): AVFoundation, ISO/shutter fed through log2/exp2 transform so stops are evenly spaced on a linear slider, WheelSlider design went through three iterations to reach fixed-center-marker/scrolling-background design, Combine, CoreGraphics, CoreImage, Gesture, CGFloat (+10 more)

### Community 5 - "Photo Capture Service (HEIC/RAW)"
Cohesion: 0.12
Nodes (15): AVCapturePhoto, AVCapturePhotoCaptureDelegate, AVCapturePhotoOutput, AVCaptureResolvedPhotoSettings, Confirmed bug: RAW PHAsset resource must be added via file URL, not Data, Data, Int64, AVCaptureVideoDataOutputSampleBufferDelegate (+7 more)

### Community 6 - "Persistence & Settings Storage"
Cohesion: 0.13
Nodes (11): CoreMedia, Foundation, PersistedCameraState, CMTime, Double, Float, Keys, CameraStatePersistenceStore (+3 more)

### Community 7 - "Camera Preview & Tap Gesture"
Cohesion: 0.15
Nodes (14): AnyClass, AVCaptureVideoPreviewLayer, AVKit, Context, CameraPreviewView, Coordinator, PreviewUIView, AVCaptureSession (+6 more)

### Community 8 - "Photo Library Album & Permissions"
Cohesion: 0.15
Nodes (15): Min iOS 18.0, iPhone only, no iPad/Vision Pro handling constraint, Deviation: .readWrite Photos permission instead of .addOnly, Error, LocalizedError, AlbumError, accessDenied, creationFailed, PhotoAlbumManager (+7 more)

### Community 9 - "Focus Peaking Pipeline"
Cohesion: 0.16
Nodes (12): AVCaptureConnection, AVCaptureOutput, AVCaptureVideoDataOutputSampleBufferDelegate, CGImage, CIContext, CIImage, MainActor-default concurrency model with nonisolated camera classes, Two CIColorMatrix bugs fixed: black overlay (bias.x) and washed-out alpha (inputAVector.w) (+4 more)

### Community 10 - "Camera Control Hardware Bar & Spec Deviations"
Cohesion: 0.20
Nodes (11): AVCaptureSessionControlsDelegate, Camera Control hardware bar must be additive, runtime device-gated, single source of truth via ManualControlEngine, Deviation: exposure bias (EV) control removed entirely, Deviation: Task 8 top bar and Task 9 top-bar-toggle model removed; capture format/peaking moved to Settings only, CameraControlBarController, AVCaptureSession, Task 12 — Camera Control Hardware Bar Integration, Task 3 — Manual Control Engine (+3 more)

### Community 11 - "Value Formatting Helpers"
Cohesion: 0.29
Nodes (5): CameraValueFormatting, CMTime, Double, Float, String

### Community 12 - "White Balance Kelvin Conversion"
Cohesion: 0.42
Nodes (5): AVCaptureDevice, Double, Float, WhiteBalanceConverter, Task 4 — White Balance Kelvin/Tint Conversion

### Community 13 - "Project Docs (CLAUDE.md / SPEC.md)"
Cohesion: 0.67
Nodes (3): CLAUDE.md (ManualCam project guidance), No front camera by explicit user request, despite an earlier iteration adding it, SPEC.md (Manual Camera App spec)

## Knowledge Gaps
- **18 isolated node(s):** `accessDenied`, `creationFailed`, `UniformTypeIdentifiers`, `CoreGraphics`, `heic` (+13 more)
  These have ≤1 connection - possible missing edges or undocumented components.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `ManualControlEngine` connect `Manual Control Engine & Tap-to-Reset` to `Camera Session & Lens Switching`, `Coordinator, Capture Format & Settings`, `Core Camera Files & Slider Design Rationale`, `Photo Capture Service (HEIC/RAW)`, `Persistence & Settings Storage`, `Focus Peaking Pipeline`, `Camera Control Hardware Bar & Spec Deviations`, `White Balance Kelvin Conversion`?**
  _High betweenness centrality (0.242) - this node is a cross-community bridge._
- **Why does `CameraCoordinator` connect `Coordinator, Capture Format & Settings` to `App Shell, Gallery & Permissions UI`, `Camera Session & Lens Switching`, `Manual Control Engine & Tap-to-Reset`, `Core Camera Files & Slider Design Rationale`, `Photo Capture Service (HEIC/RAW)`, `Persistence & Settings Storage`, `Focus Peaking Pipeline`, `Camera Control Hardware Bar & Spec Deviations`?**
  _High betweenness centrality (0.228) - this node is a cross-community bridge._
- **Why does `MainCameraView` connect `Coordinator, Capture Format & Settings` to `App Shell, Gallery & Permissions UI`, `Core Camera Files & Slider Design Rationale`, `Persistence & Settings Storage`, `Camera Preview & Tap Gesture`, `Camera Control Hardware Bar & Spec Deviations`?**
  _High betweenness centrality (0.192) - this node is a cross-community bridge._
- **Are the 2 inferred relationships involving `CameraSessionManager` (e.g. with `AVCapturePhotoOutput` and `ManualControlRanges`) actually correct?**
  _`CameraSessionManager` has 2 INFERRED edges - model-reasoned connections that need verification._
- **What connects `accessDenied`, `creationFailed`, `UniformTypeIdentifiers` to the rest of the system?**
  _18 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `App Shell, Gallery & Permissions UI` be split into smaller, more focused modules?**
  _Cohesion score 0.0784313725490196 - nodes in this community are weakly interconnected._
- **Should `Camera Session & Lens Switching` be split into smaller, more focused modules?**
  _Cohesion score 0.0967741935483871 - nodes in this community are weakly interconnected._