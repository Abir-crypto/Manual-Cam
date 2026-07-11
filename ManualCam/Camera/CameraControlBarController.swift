import AVFoundation
import CoreMedia

/// Registers the four Camera Control hardware dial sliders (ISO/Shutter/EV/Focus) on the
/// session and wires them to the same `ManualControlEngine` setters the on-screen sliders
/// use — single source of truth, no duplicate control logic (Task 12).
///
/// Device-gated: `session.supportsControls` is false on any hardware without Camera
/// Control (or below iOS 18), in which case this is a no-op and the app behaves exactly
/// as it does with only on-screen controls.
@available(iOS 18.0, *)
final class CameraControlBarController: NSObject {
    private var hasConfiguredControls = false

    func configureControlsIfNeeded(
        session: AVCaptureSession,
        ranges: ManualControlRanges,
        sessionQueue: DispatchQueue,
        engine: ManualControlEngine
    ) {
        guard !hasConfiguredControls else { return }
        hasConfiguredControls = true

        sessionQueue.async { [weak self, weak engine] in
            guard let self, session.supportsControls else { return }

            // A controls delegate is required for AVCaptureControls to become active.
            session.setControlsDelegate(self, queue: sessionQueue)

            let isoSlider = AVCaptureSlider("ISO", symbolName: "camera.aperture", in: ranges.isoRange)
            isoSlider.setActionQueue(sessionQueue) { value in
                DispatchQueue.main.async { engine?.setISO(value) }
            }

            let shutterRange = Float(ranges.exposureDurationRange.lowerBound.seconds)...Float(ranges.exposureDurationRange.upperBound.seconds)
            let shutterSlider = AVCaptureSlider("Shutter Speed", symbolName: "timer", in: shutterRange)
            shutterSlider.setActionQueue(sessionQueue) { value in
                let duration = CMTime(seconds: Double(value), preferredTimescale: 1_000_000)
                DispatchQueue.main.async { engine?.setExposureDuration(duration) }
            }

            let evSlider = AVCaptureSlider("Exposure Bias", symbolName: "plusminus", in: ranges.exposureTargetBiasRange)
            evSlider.setActionQueue(sessionQueue) { value in
                DispatchQueue.main.async { engine?.setExposureTargetBias(value) }
            }

            let focusSlider = AVCaptureSlider("Focus", symbolName: "viewfinder", in: ManualControlRanges.lensPositionRange)
            focusSlider.setActionQueue(sessionQueue) { value in
                DispatchQueue.main.async { engine?.setLensPosition(value) }
            }

            // Sliders must have an action + action queue set before being added (SDK docs),
            // and addControl may be called on an already-running session.
            for control in [isoSlider, shutterSlider, evSlider, focusSlider] {
                if session.canAddControl(control) {
                    session.addControl(control)
                }
            }
        }
    }
}

@available(iOS 18.0, *)
extension CameraControlBarController: AVCaptureSessionControlsDelegate {
    nonisolated func sessionControlsDidBecomeActive(_ session: AVCaptureSession) {}
    nonisolated func sessionControlsWillEnterFullscreenAppearance(_ session: AVCaptureSession) {}
    nonisolated func sessionControlsWillExitFullscreenAppearance(_ session: AVCaptureSession) {}
    nonisolated func sessionControlsDidBecomeInactive(_ session: AVCaptureSession) {}
}
