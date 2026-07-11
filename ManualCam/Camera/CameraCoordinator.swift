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

        sessionManager.$currentDevice
            .compactMap { $0 }
            .first()
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

    /// Call on backgrounding/scene changes so a force-quit doesn't lose in-progress adjustments.
    func persistCurrentStateIfNeeded() {
        guard settingsStore.persistLastUsedValues else { return }
        var state = controlEngine.currentPersistedState
        state.captureFormat = captureFormat
        CameraStatePersistenceStore.save(state)
    }

    private func handleDeviceAttached(_ device: AVCaptureDevice) {
        controlEngine.attach(device: device)

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
