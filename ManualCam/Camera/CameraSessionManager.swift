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
    @Published private(set) var availableLenses: [CameraLens] = []
    @Published private(set) var currentLens: CameraLens?
    @Published var setupError: String?

    private var isConfigured = false
    /// Mirrors `currentDevice`, but readable from `sessionQueue` without crossing
    /// through the `@Published` copy (which is only ever written from main).
    private var activeDevice: AVCaptureDevice?
    private var activeDeviceType: AVCaptureDevice.DeviceType?

    /// The three individual back lenses. Deliberately never the virtual multi-camera
    /// device (`.builtInTripleCamera` etc.) — see `CameraLens`'s doc comment for why.
    private static let backLensDeviceTypes: [AVCaptureDevice.DeviceType] = [
        .builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera,
    ]

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

    /// Switches to a different physical lens and/or zoom point. Swaps the session's
    /// `AVCaptureDeviceInput` only when the target is a different physical lens than
    /// the one currently active; either way, sets `videoZoomFactor` to the preset's
    /// own-device-relative value.
    func switchToLens(_ lens: CameraLens) {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            let device: AVCaptureDevice
            let didSwitchDevice = self.activeDeviceType != lens.deviceType

            if didSwitchDevice {
                guard let newDevice = AVCaptureDevice.default(lens.deviceType, for: .video, position: .back) else {
                    self.publishError("That lens isn't available.")
                    return
                }
                guard let newInput = try? AVCaptureDeviceInput(device: newDevice) else {
                    self.publishError("Unable to switch lens.")
                    return
                }
                self.session.beginConfiguration()
                for existingInput in self.session.inputs {
                    self.session.removeInput(existingInput)
                }
                if self.session.canAddInput(newInput) {
                    self.session.addInput(newInput)
                }
                self.session.commitConfiguration()
                device = newDevice
            } else if let existing = self.activeDevice {
                device = existing
            } else {
                return
            }

            do {
                try device.lockForConfiguration()
                let clamped = min(max(lens.ownZoomFactor, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
                device.videoZoomFactor = clamped
                device.unlockForConfiguration()
            } catch {
                // Configuration lock can fail transiently — safe to drop.
            }

            self.activeDevice = device
            self.activeDeviceType = lens.deviceType

            let rawSupported = !self.photoOutput.availableRawPhotoPixelFormatTypes.isEmpty
            let proRAWSupported = self.photoOutput.isAppleProRAWSupported

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if didSwitchDevice { self.currentDevice = device }
                self.currentLens = lens
                self.isRAWSupported = rawSupported
                self.isAppleProRAWSupported = proRAWSupported
            }
        }
    }

    /// Virtual multi-camera device types, queried *only* to read Apple's own exact
    /// per-lens zoom factors (never made the actual session input — see `CameraLens`'s
    /// doc comment for why).
    private static let virtualDeviceTypes: [AVCaptureDevice.DeviceType] = [
        .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera,
    ]

    /// Must be called on `sessionQueue`. Discovers every back lens this device actually
    /// has (never hardcoded — a device without a telephoto simply won't offer one), plus
    /// any secondary native crop zoom points each individual lens supports
    /// (`AVCaptureDeviceFormat.secondaryNativeResolutionZoomFactors`) — e.g. a telephoto's
    /// own extra native zoom beyond its base optical magnification, which is what
    /// surfaces something like an "8×"/200mm option without guessing at any device's specs.
    private func buildLensPresets() -> [CameraLens] {
        let backLenses = AVCaptureDevice.DiscoverySession(
            deviceTypes: Self.backLensDeviceTypes,
            mediaType: .video,
            position: .back
        ).devices

        // The virtual device reports each constituent lens's *exact* system-relative
        // zoom factor (e.g. 5.0 for a 5x tele) — far more precise than approximating via
        // a field-of-view ratio, which is what produced an imprecise "7.5x" for an "8x"
        // lens before.
        let virtualDevice = AVCaptureDevice.DiscoverySession(
            deviceTypes: Self.virtualDeviceTypes,
            mediaType: .video,
            position: .back
        ).devices.first
        let switchOverFactors = virtualDevice?.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) } ?? []
        let ultraWideSystemZoom = virtualDevice.map { CGFloat($0.minAvailableVideoZoomFactor) } ?? 1.0

        func systemBaseZoom(for deviceType: AVCaptureDevice.DeviceType) -> CGFloat {
            switch deviceType {
            case .builtInUltraWideCamera: return ultraWideSystemZoom
            case .builtInTelephotoCamera: return switchOverFactors.last ?? 1.0
            default: return 1.0
            }
        }

        var presets: [CameraLens] = []
        var usedMillimeters = Set<Int>()

        for device in backLenses {
            let baseZoom = systemBaseZoom(for: device.deviceType)
            let baseLens = CameraLens.make(deviceType: device.deviceType, ownZoomFactor: 1.0, systemZoom: baseZoom)
            presets.append(baseLens)
            usedMillimeters.insert(baseLens.millimeters)

            for factor in device.activeFormat.secondaryNativeResolutionZoomFactors {
                let ownZoom = CGFloat(truncating: factor as NSNumber)
                let lens = CameraLens.make(deviceType: device.deviceType, ownZoomFactor: ownZoom, systemZoom: baseZoom * ownZoom)
                guard !usedMillimeters.contains(lens.millimeters) else { continue }
                usedMillimeters.insert(lens.millimeters)
                presets.append(lens)
            }
        }
        return presets.sorted { $0 < $1 }
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

        // .quality explicitly opts into multi-frame fusion (Smart HDR/Deep Fusion-style
        // processing per Apple's own docs) — the fused output's EXIF can then reflect
        // whatever exposure the fusion pipeline actually blended, not the exact
        // ISO/shutter this app locked in. .speed forces a true single-exposure capture,
        // which is what a manual camera app's "what you dial in is what you get" needs.
        photoOutput.maxPhotoQualityPrioritization = .speed
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
        let lenses = buildLensPresets()
        let initialLens = lenses.first { $0.deviceType == device.deviceType && $0.ownZoomFactor == 1.0 } ?? lenses.first

        isConfigured = true
        activeDevice = device
        activeDeviceType = device.deviceType

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.currentDevice = device
            self.isRAWSupported = rawSupported
            self.isAppleProRAWSupported = proRAWSupported
            self.availableLenses = lenses
            self.currentLens = initialLens
        }
    }

    private func publishError(_ message: String) {
        DispatchQueue.main.async { [weak self] in self?.setupError = message }
    }
}
