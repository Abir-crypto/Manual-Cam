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

    @Published var captureFormat: CaptureFormat
    @Published var isPeakingEnabled = false {
        didSet { peakingProcessor.isEnabled = isPeakingEnabled }
    }

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
        self.captureFormat = settingsStore.defaultCaptureFormat

        sessionManager.setVideoDataOutputDelegate(peakingProcessor)
        captureService.setAppleProRAWEnabled(settingsStore.appleProRAWEnabled)

        // SwiftUI views only observe `coordinator` itself (@ObservedObject), not these
        // nested ObservableObjects — forward their changes so the UI actually re-renders
        // when e.g. ManualControlEngine's ISO/shutter/etc. change.
        for childPublisher in [sessionManager.objectWillChange, controlEngine.objectWillChange, captureService.objectWillChange, peakingProcessor.objectWillChange] {
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
        var state = controlEngine.currentPersistedState
        state.captureFormat = captureFormat
        CameraStatePersistenceStore.save(state)
    }

    /// The back camera input is a single virtual multi-camera device for the whole
    /// session lifetime (lens switching is a `videoZoomFactor` change, not a device
    /// swap — see `CameraSessionManager.switchToLens(_:)`), so this fires once, at
    /// launch. Kept non-`.first()`-gated defensively in case that ever changes.
    private func handleDeviceAttached(_ device: AVCaptureDevice) {
        controlEngine.attach(device: device)

        guard !hasCompletedInitialDeviceSetup else { return }
        hasCompletedInitialDeviceSetup = true

        if settingsStore.persistLastUsedValues, let saved = CameraStatePersistenceStore.load() {
            controlEngine.restore(saved)
            captureFormat = saved.captureFormat
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
