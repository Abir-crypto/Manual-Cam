import AVFoundation
import Combine

/// Owns the `AVCaptureSession` lifecycle: device discovery, inputs/outputs, and
/// start/stop. All session mutation happens on `sessionQueue` — never on main.
///
/// Opts out of the module's default MainActor isolation: this type is background-queue
/// driven by design, and only hops to main explicitly to publish `@Published` state.
nonisolated final class CameraSessionManager: ObservableObject {
    let session = AVCaptureSession()
    let photoOutput = AVCapturePhotoOutput()
    let videoDataOutput = AVCaptureVideoDataOutput()

    /// Serial queue all session and device configuration happens on.
    let sessionQueue = DispatchQueue(label: "com.manualcam.sessionQueue")
    private let videoDataOutputQueue = DispatchQueue(label: "com.manualcam.videoDataOutputQueue")

    @Published private(set) var isSessionRunning = false
    @Published private(set) var currentDevice: AVCaptureDevice?
    @Published private(set) var isRAWSupported = false
    @Published private(set) var isAppleProRAWSupported = false
    @Published var setupError: String?

    private var isConfigured = false

    func configureAndStart() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.isConfigured {
                self.configureSession()
            }
            if !self.session.isRunning {
                self.session.startRunning()
            }
            let running = self.session.isRunning
            DispatchQueue.main.async { self.isSessionRunning = running }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
            DispatchQueue.main.async { self.isSessionRunning = false }
        }
    }

    /// Attach the delegate that receives live frames for focus peaking (Task 7).
    func setVideoDataOutputDelegate(_ delegate: AVCaptureVideoDataOutputSampleBufferDelegate?) {
        sessionQueue.async { [weak self] in
            self?.videoDataOutput.setSampleBufferDelegate(delegate, queue: self?.videoDataOutputQueue)
        }
    }

    /// Must be called on `sessionQueue`.
    private func configureSession() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .photo

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            publishError("No back wide-angle camera available on this device.")
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                publishError("Unable to add camera input.")
                return
            }
            session.addInput(input)
        } catch {
            publishError("Unable to open camera: \(error.localizedDescription)")
            return
        }

        photoOutput.maxPhotoQualityPrioritization = .quality
        guard session.canAddOutput(photoOutput) else {
            publishError("Unable to add photo output.")
            return
        }
        session.addOutput(photoOutput)

        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        videoDataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        if session.canAddOutput(videoDataOutput) {
            session.addOutput(videoDataOutput)
        }

        let rawSupported = !photoOutput.availableRawPhotoPixelFormatTypes.isEmpty
        let proRAWSupported = photoOutput.isAppleProRAWSupported

        isConfigured = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.currentDevice = device
            self.isRAWSupported = rawSupported
            self.isAppleProRAWSupported = proRAWSupported
        }
    }

    private func publishError(_ message: String) {
        DispatchQueue.main.async { [weak self] in self?.setupError = message }
    }
}
