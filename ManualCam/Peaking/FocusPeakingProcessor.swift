import AVFoundation
import CoreImage
import Metal
import UIKit
import Combine

/// Consumes live frames from `AVCaptureVideoDataOutput` and renders a red edge-highlight
/// overlay of in-focus areas, using a Metal-backed `CIContext` for real-time performance
/// (Task 7). Fully skippable when disabled — no filter work runs, not just hidden output.
final class FocusPeakingProcessor: NSObject, ObservableObject {
    @Published private(set) var overlayImage: CGImage?

    /// Guards whether incoming frames are processed at all. Read on the video data
    /// output's background queue and written from the main thread (UI toggle) — the
    /// filter pipeline below only ever runs serially on that same background queue,
    /// so a plain flag is safe; it's exempted from actor isolation to allow that.
    nonisolated(unsafe) var isEnabled: Bool = false {
        didSet {
            if !isEnabled {
                DispatchQueue.main.async { [weak self] in self?.overlayImage = nil }
            }
        }
    }

    /// Tuned for visible highlighting of hard edges without excessive noise.
    nonisolated(unsafe) var edgeIntensity: Float = 8.0
    /// Post-`CIEdges` luminance threshold above which a pixel is considered "in focus".
    nonisolated(unsafe) var threshold: Float = 0.2

    nonisolated(unsafe) private let ciContext: CIContext
    nonisolated(unsafe) private let colorMatrixFilter = CIFilter(name: "CIColorMatrix")!
    nonisolated(unsafe) private let edgesFilter = CIFilter(name: "CIEdges")!

    override init() {
        guard let metalDevice = MTLCreateSystemDefaultDevice() else {
            preconditionFailure("Metal is required for real-time focus peaking.")
        }
        ciContext = CIContext(mtlDevice: metalDevice)
        super.init()
    }

    nonisolated private func makeOverlay(from image: CIImage) -> CIImage {
        edgesFilter.setValue(image, forKey: kCIInputImageKey)
        edgesFilter.setValue(edgeIntensity, forKey: kCIInputIntensityKey)
        let edges = edgesFilter.outputImage ?? image

        // Threshold to a hard red/transparent mask: colors above `threshold` become opaque red.
        colorMatrixFilter.setValue(edges, forKey: kCIInputImageKey)
        // outputR = dot(input, RVector) + bias.x, etc. Zeroing R/G/B's input weights
        // and setting bias.x = 1 makes outputR a *constant* 1.0 regardless of input —
        // i.e. pure red — while G/B stay 0. outputA sums only the input R/G/B channels
        // (not input alpha, which is ~1.0/opaque for a normal camera frame and would
        // otherwise swamp the threshold below with a constant +1), then subtracts
        // `threshold`: flat/non-edge regions (R+G+B ≈ 0) clamp to alpha 0 (invisible),
        // strong edges clamp toward alpha 1 (a solid red highlight).
        colorMatrixFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputRVector")
        colorMatrixFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputGVector")
        colorMatrixFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBVector")
        colorMatrixFilter.setValue(CIVector(x: 1, y: 1, z: 1, w: 0), forKey: "inputAVector")
        colorMatrixFilter.setValue(CIVector(x: 1, y: 0, z: 0, w: -CGFloat(threshold)), forKey: "inputBiasVector")
        return colorMatrixFilter.outputImage ?? edges
    }
}

extension FocusPeakingProcessor: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard isEnabled, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let inputImage = CIImage(cvPixelBuffer: pixelBuffer)
        let overlay = makeOverlay(from: inputImage)

        guard let cgImage = ciContext.createCGImage(overlay, from: inputImage.extent) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.overlayImage = cgImage
        }
    }
}
