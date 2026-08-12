import AVFoundation
import Combine
import CoreImage
import CoreVideo
import Metal
import UIKit

/// Grades the live camera feed with the selected film style, so the viewfinder shows the actual
/// grade rather than an approximation of it (`PORTRAIT_MODE.md` Task 4's "live low-cost preview").
///
/// **Replaces a SwiftUI blend-mode tint that didn't match the saved photo.** The previous approach
/// laid a translucent coloured rectangle over the preview layer; the user compared the two outputs
/// and correctly identified the mismatch — "the applied filter when saving might be Overscreen type
/// something and the view is only a overlay". This runs the *same* `FilmStyleGrade` the post-capture
/// renderer runs, so the colour in the viewfinder is the colour that gets saved.
///
/// Structured exactly like `FocusPeakingProcessor` and `DepthPreviewProcessor`: Metal-backed
/// `CIContext`, `nonisolated(unsafe)` state touched only on the video data output's serial queue, and
/// fully skippable when off — `.natural` is a passthrough style, so no frame work happens at all
/// unless a real grade is selected.
///
/// What it deliberately does **not** show is the bokeh: the spec puts a live full-quality blur out of
/// scope, so the preview matches the saved photo's colour but not its depth-of-field.
final class FilmStylePreviewProcessor: NSObject, ObservableObject {
    @Published private(set) var gradedImage: CGImage?

    /// Gates all work. Written from main (mode/style changes), read on the video queue.
    nonisolated(unsafe) var isEnabled: Bool = false {
        didSet {
            guard !isEnabled else { return }
            DispatchQueue.main.async { [weak self] in self?.gradedImage = nil }
        }
    }

    /// The style to grade with. `.natural` short-circuits the whole pipeline.
    nonisolated(unsafe) var style: FilmStyle = .natural {
        didSet {
            guard style.isPassthrough else { return }
            DispatchQueue.main.async { [weak self] in self?.gradedImage = nil }
        }
    }

    private let ciContext: CIContext

    override init() {
        guard let metalDevice = MTLCreateSystemDefaultDevice() else {
            preconditionFailure("Metal is required for the live film style preview.")
        }
        // Same working colour space as `PortraitRenderer`. This is not incidental: the grades
        // composite differently in linear light than in gamma space, so a mismatch here would
        // reintroduce exactly the preview-vs-saved discrepancy this type exists to remove.
        ciContext = CIContext(
            mtlDevice: metalDevice,
            options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB) as Any]
        )
        super.init()
    }
}

extension FilmStylePreviewProcessor: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let style = self.style
        guard isEnabled, !style.isPassthrough,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let input = CIImage(cvPixelBuffer: pixelBuffer)
        let graded = FilmStyleGrade.apply(style, to: input)
        guard let cgImage = ciContext.createCGImage(graded, from: input.extent) else { return }

        DispatchQueue.main.async { [weak self] in
            self?.gradedImage = cgImage
        }
    }
}
