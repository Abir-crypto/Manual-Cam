import AVFoundation
import Combine
import CoreImage
import CoreVideo
import Metal
import UIKit

/// Live grayscale depth-map visualization for Portrait mode (`PORTRAIT_MODE.md` Task 3): a
/// debug aid for checking subject separation *before* shooting, not the final-quality depth
/// used by Task 5's render.
///
/// Consumes the continuous, lower-resolution stream from `AVCaptureDepthDataOutput` (as the
/// spec asks) rather than waiting on a photo capture. Structured to mirror
/// `FocusPeakingProcessor` deliberately — same Metal-backed `CIContext`, same
/// `nonisolated(unsafe)` treatment of state touched by AVFoundation's delegate queue, same
/// "fully skippable when off" rule (no conversion, no normalization scan, no filter work when
/// disabled — not merely a hidden overlay).
///
/// Lives in `/Peaking` because that's this project's home for live per-frame analysis
/// pipelines, even though it isn't focus peaking itself.
final class DepthPreviewProcessor: NSObject, ObservableObject {
    @Published private(set) var depthImage: CGImage?

    /// Gates all work. Read on the depth output's background queue, written from main (the
    /// Portrait control bar's toggle); the pipeline below only ever runs serially on that
    /// background queue, so a plain flag is safe.
    nonisolated(unsafe) var isEnabled: Bool = false {
        didSet {
            guard !isEnabled else { return }
            DispatchQueue.main.async { [weak self] in self?.depthImage = nil }
        }
    }

    /// `CIContext` is `Sendable`, so an immutable `let` needs no isolation escape hatch — unlike
    /// `FocusPeakingProcessor`, which still marks its equivalent `nonisolated(unsafe)` and draws a
    /// compiler warning for it. `CIFilter` is *not* Sendable and does need the annotation.
    private let ciContext: CIContext
    nonisolated(unsafe) private let colorMatrixFilter = CIFilter(name: "CIColorMatrix")!

    /// Every Nth pixel is inspected when finding the frame's disparity range. Depth buffers
    /// are already small (a few hundred thousand floats at most), and this is a preview
    /// visualization — a strided scan is far cheaper than a full one and moves the displayed
    /// contrast imperceptibly.
    private static let normalizationSampleStride = 4

    override init() {
        guard let metalDevice = MTLCreateSystemDefaultDevice() else {
            preconditionFailure("Metal is required for the live depth preview.")
        }
        ciContext = CIContext(mtlDevice: metalDevice)
        super.init()
    }

    /// Maps the frame's own disparity range onto black→white. Per-frame normalization is
    /// necessary because disparity is in reciprocal-distance units with no fixed useful range:
    /// a fixed scale would render an indoor scene as almost-flat gray and blow out a close-up.
    ///
    /// Convention follows the spec's "near=dark/far=light": disparity is *high* for near
    /// subjects, so the mapping is deliberately inverted.
    nonisolated private func makeVisualization(from disparity: CIImage, range: (min: Float, max: Float)) -> CIImage {
        let span = max(range.max - range.min, .leastNormalMagnitude)
        // outputChannel = dot(input, channelVector) + bias. Reading only the input's red
        // channel (disparity buffers are single-channel) into all three of R/G/B produces
        // gray. Negative scale plus a +max/span bias inverts, so near reads dark.
        let scale = CGFloat(-1 / span)
        let bias = CGFloat(range.max / span)

        colorMatrixFilter.setValue(disparity, forKey: kCIInputImageKey)
        colorMatrixFilter.setValue(CIVector(x: scale, y: 0, z: 0, w: 0), forKey: "inputRVector")
        colorMatrixFilter.setValue(CIVector(x: scale, y: 0, z: 0, w: 0), forKey: "inputGVector")
        colorMatrixFilter.setValue(CIVector(x: scale, y: 0, z: 0, w: 0), forKey: "inputBVector")
        // Alpha comes purely from the bias — the input's alpha channel is meaningless here,
        // and the overlay must be fully opaque to replace the normal preview.
        colorMatrixFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputAVector")
        colorMatrixFilter.setValue(CIVector(x: bias, y: bias, z: bias, w: 1), forKey: "inputBiasVector")
        return colorMatrixFilter.outputImage ?? disparity
    }

    /// Strided min/max over a `DisparityFloat32` buffer, skipping non-finite and zero samples
    /// (both mean "no measurement here", and a zero would otherwise anchor the range to the
    /// far extreme and wash the image out). Returns nil when the frame carries no usable
    /// spread — a flat frame has nothing to visualize.
    nonisolated private func disparityRange(of pixelBuffer: CVPixelBuffer) -> (min: Float, max: Float)? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let sampleStride = Self.normalizationSampleStride

        var minimum = Float.greatestFiniteMagnitude
        var maximum = -Float.greatestFiniteMagnitude

        for y in stride(from: 0, to: height, by: sampleStride) {
            let row = baseAddress.advanced(by: y * bytesPerRow).assumingMemoryBound(to: Float32.self)
            for x in stride(from: 0, to: width, by: sampleStride) {
                let value = row[x]
                guard value.isFinite, value > 0 else { continue }
                minimum = min(minimum, value)
                maximum = max(maximum, value)
            }
        }

        guard maximum > minimum else { return nil }
        return (minimum, maximum)
    }
}

extension DepthPreviewProcessor: AVCaptureDepthDataOutputDelegate {
    nonisolated func depthDataOutput(
        _ output: AVCaptureDepthDataOutput,
        didOutput depthData: AVDepthData,
        timestamp: CMTime,
        connection: AVCaptureConnection
    ) {
        guard isEnabled else { return }

        // Disparity rather than depth: it's the representation `CIDepthBlurEffect` wants in
        // Task 5, and it normalizes into a visualization more evenly than metric depth, whose
        // far values run to infinity.
        //
        // `converting(toDepthDataType:)` raises `NSInvalidArgumentException` for a type the
        // frame can't provide — an Objective-C exception, which `try?` cannot catch — so
        // availability is checked against `availableDepthDataTypes` first rather than attempted
        // and recovered from.
        let disparityType = kCVPixelFormatType_DisparityFloat32
        let disparityData: AVDepthData
        if depthData.depthDataType == disparityType {
            disparityData = depthData
        } else if depthData.availableDepthDataTypes.contains(disparityType) {
            disparityData = depthData.converting(toDepthDataType: disparityType)
        } else {
            return
        }

        let pixelBuffer = disparityData.depthDataMap
        guard let range = disparityRange(of: pixelBuffer) else { return }

        let disparityImage = CIImage(cvPixelBuffer: pixelBuffer)
        let visualization = makeVisualization(from: disparityImage, range: range)
        guard let cgImage = ciContext.createCGImage(visualization, from: disparityImage.extent) else { return }

        DispatchQueue.main.async { [weak self] in
            self?.depthImage = cgImage
        }
    }
}
