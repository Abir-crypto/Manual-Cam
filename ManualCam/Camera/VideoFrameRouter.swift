import AVFoundation
import Foundation

/// Fans live video frames out to several consumers.
///
/// `AVCaptureVideoDataOutput` accepts exactly one sample-buffer delegate, but there are now two
/// independent per-frame pipelines — `FocusPeakingProcessor` and `FilmStylePreviewProcessor` — and
/// each is used in a different mode. This forwards to both rather than having either own the slot.
///
/// Each consumer gates its own work (both are fully skippable when disabled), so in practice at most
/// one is doing anything on a given frame: peaking in Manual, the film-style grade in Portrait.
///
/// Consumers are held **strongly**: `AVCaptureVideoDataOutput` does not retain its delegate, so this
/// router is what keeps the chain alive, and the router itself is retained by `CameraCoordinator`.
final class VideoFrameRouter: NSObject {
    private let consumers: [AVCaptureVideoDataOutputSampleBufferDelegate]

    init(consumers: [AVCaptureVideoDataOutputSampleBufferDelegate]) {
        self.consumers = consumers
        super.init()
    }
}

extension VideoFrameRouter: AVCaptureVideoDataOutputSampleBufferDelegate {
    /// Called on the video data output's serial queue. Forwarding is sequential, so the consumers run
    /// one after another on that same queue — which is what keeps each one's internal state safe
    /// without locks, exactly as it was when a single processor owned the delegate slot.
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        for consumer in consumers {
            // Optional protocol requirement, hence the `?`.
            consumer.captureOutput?(output, didOutput: sampleBuffer, from: connection)
        }
    }
}
