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

    /// Solely `settingsStore`-driven now — there's no separate top-bar session
    /// override to reconcile with a persisted "default" anymore.
    var captureFormat: CaptureFormat { settingsStore.defaultCaptureFormat }

    private var controlBarController: AnyObject?
    private var cancellables = Set<AnyCancellable>()
    private var hasCompletedInitialDeviceSetup = false

    init(settingsStore: AppSettingsStore = AppSettingsStore()) {
        let sessionManager = CameraSessionManager()
        self.sessionManager = sessionManager
        self.controlEngine = ManualControlEngine(queue: sessionManager.sessionQueue)
        self.captureService = PhotoCaptureService(photoOutput: sessionManager.photoOutput)
        self.peakingProcessor = FocusPeakingProcessor()
        self.settingsStore = settingsStore

        sessionManager.setVideoDataOutputDelegate(peakingProcessor)
        captureService.setAppleProRAWEnabled(settingsStore.appleProRAWEnabled)

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
        for childPublisher in [sessionManager.objectWillChange, controlEngine.objectWillChange, captureService.objectWillChange, peakingProcessor.objectWillChange, settingsStore.objectWillChange] {
            childPublisher
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }

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

    func capturePhoto() {
        captureService.capturePhoto(format: captureFormat)
    }

    /// Switches to a different zoom/lens preset (ultra wide/wide/telephoto/etc).
    func switchLens(_ lens: CameraLens) {
        sessionManager.switchToLens(lens)
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
        controlEngine.attach(device: device)

        guard !hasCompletedInitialDeviceSetup else { return }
        hasCompletedInitialDeviceSetup = true

        if settingsStore.persistLastUsedValues, let saved = CameraStatePersistenceStore.load() {
            controlEngine.restore(saved)
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
