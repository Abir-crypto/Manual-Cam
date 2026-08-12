import AVFoundation
import Combine

/// Composition root wiring the session, manual controls, capture, peaking, and
/// persistence pieces together for the UI layer.
final class CameraCoordinator: ObservableObject {
    let sessionManager: CameraSessionManager
    let controlEngine: ManualControlEngine
    let captureService: PhotoCaptureService
    let peakingProcessor: FocusPeakingProcessor
    let settingsStore: AppSettingsStore
    let intervalometer: IntervalometerService
    let depthPreview: DepthPreviewProcessor
    let subjectMonitor: PortraitSubjectMonitor
    /// Grades the live feed with the selected film style, using the same `FilmStyleGrade` the
    /// post-capture render uses — so the viewfinder and the saved photo agree.
    let filmStylePreview: FilmStylePreviewProcessor
    /// Retained here because `AVCaptureVideoDataOutput` doesn't retain its delegate.
    private let videoFrameRouter: VideoFrameRouter

    /// Portrait's live depth-map debug view (`PORTRAIT_MODE.md` Task 3). Session-scoped rather
    /// than persisted — it's a diagnostic view, not a shooting preference, and shouldn't survive
    /// a relaunch into a mode where the preview looks broken.
    @Published var isDepthDebugEnabled = false {
        didSet {
            syncDepthPreviewEnabled()
            // The depth view replaces the preview entirely, so the grade would be invisible work.
            syncFilmStylePreview()
        }
    }

    /// Portrait's blur strength, 0…1 (`PORTRAIT_MODE.md` Task 4). Normalized rather than expressed
    /// as an f-number because `PortraitRenderer` maps it onto whatever aperture range
    /// `CIDepthBlurEffect` actually reports at runtime.
    @Published var portraitBlurIntensity: Double = 0.6
    /// Portrait's selected film style (Task 6). Session-scoped, like the depth-debug toggle —
    /// `PORTRAIT_MODE.md` only requires the *mode* itself to persist.
    @Published var portraitFilmStyle: FilmStyle = .natural {
        didSet { syncFilmStylePreview() }
    }

    /// The active top-level mode. Owned by `settingsStore` so it persists across launches;
    /// exposed here as the single read point for the UI and capture routing.
    var shootingMode: ShootingMode { settingsStore.shootingMode }

    /// Solely `settingsStore`-driven now — there's no separate top-bar session
    /// override to reconcile with a persisted "default" anymore.
    var captureFormat: CaptureFormat { settingsStore.defaultCaptureFormat }

    private var controlBarController: AnyObject?
    private var cancellables = Set<AnyCancellable>()
    private var hasCompletedInitialDeviceSetup = false
    private var hasAppliedInitialMode = false
    /// Last point `tapToFocus(at:)` was called with, in `AVCaptureDevice` point-of-interest
    /// space — lets the Camera Control light press re-lock at the point the user actually
    /// chose instead of always the center. Nil until the viewfinder is tapped.
    private var lastFocusDevicePoint: CGPoint?

    init(settingsStore: AppSettingsStore = AppSettingsStore()) {
        let sessionManager = CameraSessionManager()
        self.sessionManager = sessionManager
        self.controlEngine = ManualControlEngine(queue: sessionManager.sessionQueue)
        self.captureService = PhotoCaptureService(photoOutput: sessionManager.photoOutput)
        self.peakingProcessor = FocusPeakingProcessor()
        self.settingsStore = settingsStore
        self.intervalometer = IntervalometerService()
        let depthPreview = DepthPreviewProcessor()
        self.depthPreview = depthPreview
        let subjectMonitor = PortraitSubjectMonitor()
        self.subjectMonitor = subjectMonitor
        let filmStylePreview = FilmStylePreviewProcessor()
        self.filmStylePreview = filmStylePreview
        // One delegate slot, two per-frame pipelines — see `VideoFrameRouter`.
        let videoFrameRouter = VideoFrameRouter(consumers: [peakingProcessor, filmStylePreview])
        self.videoFrameRouter = videoFrameRouter

        sessionManager.setVideoDataOutputDelegate(videoFrameRouter)
        // Both delegates are attached once here; their outputs are only *in* the session while
        // Portrait is active, so nothing is delivered in other modes.
        sessionManager.setDepthDataOutputDelegate(depthPreview)
        sessionManager.setMetadataObjectsDelegate(subjectMonitor)

        // ProRAW is now a `CaptureFormat` case rather than its own toggle, so the output-level flag
        // follows the format picker. Has to take effect immediately: it was once read a single time
        // here, so changing it did nothing until the next launch (silently giving plain RAW when
        // ProRAW was asked for). Note the closure uses the *emitted* value rather than reading
        // `settingsStore.defaultCaptureFormat` — `@Published` fires on `willSet`, so the property
        // still holds the old value inside the sink.
        settingsStore.$defaultCaptureFormat
            .sink { [weak self] format in self?.applyAppleProRAWSetting(format.prefersAppleProRAW) }
            .store(in: &cancellables)

        // Peaking on/off is persisted in AppSettingsStore (Settings sheet) rather than a
        // live-only coordinator flag — apply the restored value immediately, then keep
        // the processor in sync with every subsequent change.
        peakingProcessor.isEnabled = settingsStore.isPeakingEnabled
        settingsStore.$isPeakingEnabled
            .sink { [weak self] enabled in self?.peakingProcessor.isEnabled = enabled }
            .store(in: &cancellables)

        // SwiftUI views only observe `coordinator` itself (@ObservedObject), not these
        // nested ObservableObjects — forward their changes so the UI actually re-renders
        // when e.g. ManualControlEngine's ISO/shutter/etc., or a Settings toggle, change.
        for childPublisher in [sessionManager.objectWillChange, controlEngine.objectWillChange, captureService.objectWillChange, peakingProcessor.objectWillChange, settingsStore.objectWillChange, intervalometer.objectWillChange, depthPreview.objectWillChange, subjectMonitor.objectWillChange, filmStylePreview.objectWillChange] {
            childPublisher
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }

        // A timer run freezes the manual controls for its whole duration
        // (`MULTI_SHOT_TIMER.md`, Task 1). Driving the lock off `isRunning` rather than
        // setting it by hand in `startTimer` means every exit path — finished, cancelled,
        // cancelled-on-background — releases it, with no way to leave the controls stuck.
        intervalometer.$isRunning
            .sink { [weak self] isRunning in self?.controlEngine.setLocked(isRunning, for: .captureRun) }
            .store(in: &cancellables)

        sessionManager.$currentDevice
            .compactMap { $0 }
            .sink { [weak self] device in
                self?.handleDeviceAttached(device)
            }
            .store(in: &cancellables)
    }

    func start() {
        sessionManager.configureAndStart()
    }

    func stop() {
        sessionManager.stop()
    }

    /// The user-initiated shutter — on-screen button and the Camera Control full press.
    /// Ignored during a timer run: the on-screen shutter is already covered by the
    /// countdown overlay, but a hardware full press reaches this directly and would
    /// otherwise inject an unscheduled extra frame into the run (giving N+1 photos, one of
    /// them off-interval). The run's own shots go through `performCapture()` instead.
    func capturePhoto() {
        guard !intervalometer.isRunning else { return }
        performCapture()
    }

    private func performCapture() {
        switch shootingMode {
        case .portrait:
            captureService.capturePortraitPhoto(blurIntensity: portraitBlurIntensity, style: portraitFilmStyle)
        case .manual, .astro:
            // The zoom goes with the request because Bayer RAW is only legal at 1.0 — the selected
            // preset's own factor is the value actually applied to the device by `switchToLens(_:)`.
            captureService.capturePhoto(
                format: captureFormat,
                videoZoomFactor: sessionManager.currentLens?.ownZoomFactor ?? 1.0
            )
        }
    }

    // MARK: - Shooting mode

    /// Switch top-level mode (`PORTRAIT_MODE.md` Task 1). Persists the choice, reconfigures the
    /// session, and moves the manual-control freeze in or out of Portrait.
    func setMode(_ mode: ShootingMode) {
        guard mode != shootingMode else { return }
        // The Multi-Shot Timer is Manual-only; leaving Manual mid-run would keep firing shots
        // into a session being reconfigured underneath it. Shots already taken stay saved.
        intervalometer.cancel()
        settingsStore.shootingMode = mode
        applyMode(mode)
    }

    /// Applies a mode to the pieces that care. Separate from `setMode` because launch also needs
    /// this path (restoring a persisted mode) without re-persisting or cancelling anything.
    private func applyMode(_ mode: ShootingMode) {
        let isPortrait = mode == .portrait

        // Freeze the manual engine for Portrait's duration. This is the guard that keeps the
        // Camera Control dial and light press — neither of which the UI can hide — from pushing
        // manual values at the virtual multi-camera device, where locking focus at a custom lens
        // position throws (see `CameraLens` and `ManualControlEngine.LockReason`).
        controlEngine.setLocked(isPortrait, for: .portraitMode)

        if !isPortrait {
            isDepthDebugEnabled = false
            subjectMonitor.reset()
        }
        syncDepthPreviewEnabled()
        syncFilmStylePreview()
        sessionManager.configure(for: mode)
    }

    /// The live grade runs only in Portrait, only for a style that actually changes anything, and not
    /// while the depth-debug view is covering the preview — same "skip the work entirely" rule the
    /// other per-frame pipelines follow.
    private func syncFilmStylePreview() {
        filmStylePreview.style = portraitFilmStyle
        filmStylePreview.isEnabled = shootingMode == .portrait && !isDepthDebugEnabled
    }

    /// Restores the persisted mode, once, as soon as the session reports a device — the earliest
    /// point at which `isPortraitModeSupported` is known. A persisted Portrait mode on hardware
    /// that can't serve it falls back to Manual rather than leaving the UI in a dead mode.
    private func applyInitialModeIfNeeded() {
        guard !hasAppliedInitialMode else { return }
        hasAppliedInitialMode = true

        if settingsStore.shootingMode.requiresMultiCameraDevice, !sessionManager.isPortraitModeSupported {
            settingsStore.shootingMode = .manual
        }
        // Manual needs no reconfiguration — it's what `configureSession()` already built.
        guard settingsStore.shootingMode != .manual else { return }
        applyMode(settingsStore.shootingMode)
    }

    /// The depth pipeline only runs when Portrait is active *and* the debug view is on — Task 3's
    /// "toggling off returns to normal live preview immediately", and the same "skip the work
    /// entirely, don't just hide it" rule the peaking pipeline follows.
    private func syncDepthPreviewEnabled() {
        depthPreview.isEnabled = shootingMode == .portrait && isDepthDebugEnabled
    }

    /// Start a Multi-Shot Timer run with the given configuration (Manual mode only). The
    /// config is remembered for next time, and each shot goes through the same capture
    /// path the manual shutter uses — so the RAW/HEIC setting and album are respected, and
    /// the manual ISO/shutter/focus/WB locked in when Start was tapped carry across the
    /// run (`controlEngine` is frozen for its duration — see the `isRunning` subscription
    /// in `init`).
    func startTimer(config: TimerConfiguration) {
        settingsStore.timerConfiguration = config
        intervalometer.start(config: config) { [weak self] in
            self?.performCapture()
        }
    }

    /// Stop an in-progress timer run. Shots already captured stay saved. Called by the
    /// overlay's Cancel button and when the app leaves the foreground (see `RootView`) —
    /// a suspended app can't fire captures, so a run that survived backgrounding would
    /// silently produce fewer photos than the user asked for.
    func cancelTimerRun() {
        intervalometer.cancel()
    }

    /// Switches to a different zoom/lens preset (ultra wide/wide/telephoto/etc).
    func switchLens(_ lens: CameraLens) {
        sessionManager.switchToLens(lens)
    }

    /// Switches Portrait's lens. Distinct from `switchLens(_:)` because Portrait runs on the virtual
    /// multi-camera device: the lens changes by setting `videoZoomFactor` and letting the device pick
    /// the constituent camera, rather than swapping the session's input — which must not happen while
    /// depth delivery is configured.
    func setPortraitZoom(_ option: PortraitZoomOption) {
        sessionManager.setPortraitZoom(option.zoomFactor)
    }

    /// "Tap to auto-focus/expose/white-balance at a point, then keep it as the new
    /// manual baseline" (point-and-shoot behavior on top of the always-manual control
    /// model). `devicePoint` must already be in `AVCaptureDevice` point-of-interest
    /// space — `CameraPreviewView` converts the raw tap location before calling this.
    func tapToFocus(at devicePoint: CGPoint) {
        lastFocusDevicePoint = devicePoint
        controlEngine.tapToReset(at: devicePoint)
    }

    /// Camera Control **light press** (Task 12: "light press event triggers focus/exposure
    /// lock at tap point, or center if no explicit point"). Re-meters and re-locks at the
    /// point the user last tapped, falling back to frame center if they haven't tapped one
    /// this session — the same `tapToReset` path the on-screen tap uses, so there's one
    /// implementation of "lock focus/exposure here", not two.
    ///
    /// Previously wired to `setLensPosition(controlEngine.lensPosition)` — writing back
    /// the value the engine already held, i.e. a no-op, so light press did nothing.
    func lockFocusAndExposureAtCurrentPoint() {
        controlEngine.tapToReset(at: lastFocusDevicePoint ?? ManualControlEngine.centerPointOfInterest)
    }

    /// Applies the ProRAW half of the selected format to the photo output. That's session state — it
    /// changes which RAW pixel formats the output offers — so `CameraSessionManager` performs it on the
    /// session queue inside a configuration batch rather than from main. The per-capture format choice
    /// is derived from `CaptureFormat.prefersAppleProRAW` at shutter time, so there's no second copy of
    /// the preference to keep in sync.
    private func applyAppleProRAWSetting(_ enabled: Bool) {
        sessionManager.setAppleProRAWEnabled(enabled)
    }

    /// Call on backgrounding/scene changes so a force-quit doesn't lose in-progress adjustments.
    func persistCurrentStateIfNeeded() {
        guard settingsStore.persistLastUsedValues else { return }
        CameraStatePersistenceStore.save(controlEngine.currentPersistedState)
    }

    /// Fires on initial launch *and* every subsequent lens switch that moves to a
    /// different physical lens (`CameraSessionManager.switchToLens(_:)` swaps the
    /// session's `AVCaptureDeviceInput` between discrete lenses — see its doc comment).
    /// `controlEngine.attach(device:)` always runs; the one-time setup below
    /// (persisted-value restore, Camera Control hardware bar) is separately guarded to
    /// only run once, on the very first device.
    private func handleDeviceAttached(_ device: AVCaptureDevice) {
        applyInitialModeIfNeeded()

        // **Portrait deliberately does not attach the manual engine.** It runs on the virtual
        // multi-camera device, where `isLockingFocusWithCustomLensPositionSupported` is false and
        // `setFocusModeLocked(lensPosition:)` throws — the documented crash this app avoids
        // everywhere else (see `CameraLens`). `attach(device:)` would immediately push manual
        // values, including that focus call, at exactly that device. Portrait uses the device's
        // own continuous auto modes instead; the engine re-attaches when
        // `exitPortraitConfiguration()` republishes a discrete lens on the way out, which is also
        // where the deferred one-time setup below finally runs if the app launched into Portrait.
        guard shootingMode != .portrait else { return }

        controlEngine.attach(device: device)

        guard !hasCompletedInitialDeviceSetup else { return }
        hasCompletedInitialDeviceSetup = true

        // Applied here rather than only from the subscription in `init`: at init time the
        // photo output isn't attached to the session yet, so `isAppleProRAWSupported` is
        // still false and the output-side change would be dropped. By the time a device is
        // published, `configureSession()` has run and the output is live.
        applyAppleProRAWSetting(settingsStore.defaultCaptureFormat.prefersAppleProRAW)

        if settingsStore.persistLastUsedValues, let saved = CameraStatePersistenceStore.load() {
            controlEngine.restore(saved)
        } else {
            // Task 11's other half: with persistence off — or on but nothing saved yet, i.e.
            // a first-ever launch — start from what the device meters for the scene in front
            // of it instead of the engine's hardcoded ISO 100 / 1÷125 / 5600K defaults.
            controlEngine.resetToMeteredBaseline()
        }

        if #available(iOS 18.0, *) {
            let controller = CameraControlBarController()
            controlBarController = controller
            controller.configureControlsIfNeeded(
                session: sessionManager.session,
                ranges: controlEngine.ranges,
                sessionQueue: sessionManager.sessionQueue,
                engine: controlEngine
            )
        }
    }
}
