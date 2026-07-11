import AVFoundation
import Combine

/// Single source of truth for manual camera controls (ISO, shutter, focus, white balance,
/// exposure bias) on the active `AVCaptureDevice`. Both on-screen sliders and the Camera
/// Control hardware dial (Task 12) drive their changes through this engine.
///
/// Opts out of the module's default MainActor isolation: device configuration is
/// dispatched onto the session queue, and only hops to main to publish UI-facing state.
nonisolated final class ManualControlEngine: ObservableObject {
    @Published private(set) var ranges = ManualControlRanges.fallback

    @Published var iso: Float = 100
    @Published var exposureDuration = CMTime(value: 1, timescale: 125)
    @Published var lensPosition: Float = 0.5
    @Published var whiteBalanceKelvin: Double = 5600
    @Published var exposureTargetBias: Float = 0

    private weak var device: AVCaptureDevice?
    private let queue: DispatchQueue

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    /// Call whenever the active device changes (initial configure, or app resume).
    func attach(device: AVCaptureDevice) {
        self.device = device
        refreshRanges(for: device)
    }

    func refreshRanges(for device: AVCaptureDevice) {
        let format = device.activeFormat
        let newRanges = ManualControlRanges(
            isoRange: format.minISO...format.maxISO,
            exposureDurationRange: format.minExposureDuration...format.maxExposureDuration,
            exposureTargetBiasRange: device.minExposureTargetBias...device.maxExposureTargetBias,
            maxWhiteBalanceGain: device.maxWhiteBalanceGain
        )
        DispatchQueue.main.async { [weak self] in self?.ranges = newRanges }
    }

    // MARK: - Setters

    /// Sets ISO while preserving the device's current shutter duration.
    func setISO(_ iso: Float) {
        let clamped = clampedISO(iso)
        self.iso = clamped
        queue.async { [weak self] in
            guard let self, let device = self.device else { return }
            self.applyExposure(on: device, iso: clamped, duration: nil)
        }
    }

    /// Sets shutter speed while preserving the device's current ISO.
    func setExposureDuration(_ duration: CMTime) {
        let clamped = clampedDuration(duration)
        self.exposureDuration = clamped
        queue.async { [weak self] in
            guard let self, let device = self.device else { return }
            self.applyExposure(on: device, iso: nil, duration: clamped)
        }
    }

    func setLensPosition(_ position: Float) {
        let clamped = min(max(position, ManualControlRanges.lensPositionRange.lowerBound), ManualControlRanges.lensPositionRange.upperBound)
        self.lensPosition = clamped
        queue.async { [weak self] in
            guard let self, let device = self.device else { return }
            self.withLockedConfiguration(on: device) {
                if device.isFocusModeSupported(.locked) {
                    device.setFocusModeLocked(lensPosition: clamped, completionHandler: nil)
                }
            }
        }
    }

    func setExposureTargetBias(_ bias: Float) {
        let clamped = min(max(bias, ranges.exposureTargetBiasRange.lowerBound), ranges.exposureTargetBiasRange.upperBound)
        self.exposureTargetBias = clamped
        queue.async { [weak self] in
            guard let self, let device = self.device else { return }
            self.withLockedConfiguration(on: device) {
                device.setExposureTargetBias(clamped, completionHandler: nil)
            }
        }
    }

    func setWhiteBalanceKelvin(_ kelvin: Double) {
        let clamped = min(max(kelvin, ManualControlRanges.kelvinRange.lowerBound), ManualControlRanges.kelvinRange.upperBound)
        self.whiteBalanceKelvin = clamped
        queue.async { [weak self] in
            guard let self, let device = self.device else { return }
            let gains = WhiteBalanceConverter.gains(forKelvin: clamped, device: device)
            self.withLockedConfiguration(on: device) {
                if device.isWhiteBalanceModeSupported(.locked) {
                    device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
                }
            }
        }
    }

    /// Restores a full set of persisted/default values in one pass (Task 11).
    func restore(_ state: PersistedCameraState) {
        iso = state.iso
        exposureDuration = state.exposureDuration
        lensPosition = state.lensPosition
        whiteBalanceKelvin = state.whiteBalanceKelvin
        exposureTargetBias = state.exposureTargetBias
        queue.async { [weak self] in
            guard let self, let device = self.device else { return }
            self.applyExposure(on: device, iso: state.iso, duration: state.exposureDuration)
            let gains = WhiteBalanceConverter.gains(forKelvin: state.whiteBalanceKelvin, device: device)
            self.withLockedConfiguration(on: device) {
                if device.isFocusModeSupported(.locked) {
                    device.setFocusModeLocked(lensPosition: state.lensPosition, completionHandler: nil)
                }
                if device.isWhiteBalanceModeSupported(.locked) {
                    device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
                }
                device.setExposureTargetBias(state.exposureTargetBias, completionHandler: nil)
            }
        }
    }

    var currentPersistedState: PersistedCameraState {
        PersistedCameraState(
            iso: iso,
            exposureDuration: exposureDuration,
            lensPosition: lensPosition,
            whiteBalanceKelvin: whiteBalanceKelvin,
            exposureTargetBias: exposureTargetBias,
            captureFormat: .heicOnly // caller overwrites with the actual current toggle value
        )
    }

    // MARK: - Device application (must run on `queue`)

    /// ISO and shutter share one call — read the device's current value for whichever side isn't changing.
    private func applyExposure(on device: AVCaptureDevice, iso: Float?, duration: CMTime?) {
        guard device.isExposureModeSupported(.custom) else { return }
        let finalISO = clampedISO(iso ?? device.iso)
        let finalDuration = clampedDuration(duration ?? device.exposureDuration)
        withLockedConfiguration(on: device) {
            device.setExposureModeCustom(duration: finalDuration, iso: finalISO, completionHandler: nil)
        }
    }

    private func withLockedConfiguration(on device: AVCaptureDevice, _ body: () -> Void) {
        do {
            try device.lockForConfiguration()
            body()
            device.unlockForConfiguration()
        } catch {
            // Configuration lock can fail transiently (e.g. device mid-reconfiguration) — safe to drop.
        }
    }

    private func clampedISO(_ value: Float) -> Float {
        min(max(value, ranges.isoRange.lowerBound), ranges.isoRange.upperBound)
    }

    private func clampedDuration(_ value: CMTime) -> CMTime {
        if value < ranges.exposureDurationRange.lowerBound { return ranges.exposureDurationRange.lowerBound }
        if value > ranges.exposureDurationRange.upperBound { return ranges.exposureDurationRange.upperBound }
        return value
    }
}
