import AVFoundation
import Combine

/// Live "is there a subject in frame?" signal for Portrait mode, from `AVCaptureMetadataOutput`
/// face detection.
///
/// This is `PORTRAIT_MODE.md` Task 2's requirement to "surface a subtle on-screen warning
/// before capture if no matte is currently being detected live — use face detection metadata
/// as a lightweight live indicator, separate from the actual capture matte".
///
/// Face detection is only a **proxy**, and intentionally so: the portrait effects matte is
/// produced by a different pipeline at capture time and can fail (or succeed) independently of
/// whether a face is currently tracked. The point is to warn before the shutter that a shot is
/// likely to land on Task 2's depth-only fallback path — not to predict the matte exactly.
/// `PortraitCaptureDiagnostics` reports what a shot *actually* delivered.
final class PortraitSubjectMonitor: NSObject, ObservableObject {
    @Published private(set) var isSubjectDetected = false

    /// Called when leaving Portrait mode, so a stale "subject detected" doesn't persist into
    /// the next Portrait session before any metadata has arrived.
    func reset() {
        isSubjectDetected = false
    }
}

extension PortraitSubjectMonitor: AVCaptureMetadataOutputObjectsDelegate {
    /// Lands on the queue handed to `setMetadataObjectsDelegate` (the session queue), not
    /// main — hence the hop, matching the rest of the app's rule that `@Published` mutations
    /// originate on main. Only publishes on an actual change, since this fires at frame rate.
    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        let detected = metadataObjects.contains { $0 is AVMetadataFaceObject }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isSubjectDetected != detected else { return }
            self.isSubjectDetected = detected
        }
    }
}
