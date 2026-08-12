import AVFoundation
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation
import Metal

/// Post-capture Portrait render: depth blur → subject composited back on top → baked-in refinement
/// → film style grade → HEIC (`PORTRAIT_MODE.md` Tasks 5, 6 and the encode half of 7).
///
/// Task 5's periphery swirl was removed at the user's request — see `applyBokeh`.
///
/// Post-capture by design, never live — the spec puts a full-quality bokeh preview explicitly out
/// of scope. `nonisolated` because every entry point runs on
/// `PhotoCaptureService`'s render queue: this is seconds of Core Image work per shot and must
/// never touch main.
nonisolated final class PortraitRenderer {
    private let ciContext: CIContext

    /// `CIDepthBlurEffect`'s aperture range is read from the filter's own `attributes` rather than
    /// hardcoded — same "query, don't assume" rule this project applies to device ranges. Used only
    /// if the filter stops reporting slider bounds; the values match what it reports today
    /// (`CIAttributeSliderMin` 1, `CIAttributeSliderMax` 22 — note its `CIAttributeDefault` of 0 is
    /// below the slider minimum and appears to mean "no blur", so it's deliberately not used).
    private static let fallbackApertureRange: ClosedRange<Double> = 1.0...22.0

    /// Fixed, deliberately not user-facing (Task 6: "baked in, no UI toggle").
    private static let skinSmoothingBlurRadius: Double = 6.0
    private static let skinSmoothingBlend: Double = 0.35

    /// `CIEdgePreserveUpsample` tuning. Spatial sigma controls how far the guide's structure reaches;
    /// luma sigma how strongly a brightness edge in the guide is treated as a real boundary. Kept
    /// conservative — too high and the map starts tracking texture rather than subject edges.
    private static let upsampleSpatialSigma: Float = 3.0
    private static let upsampleLumaSigma: Float = 0.15

    init() {
        guard let metalDevice = MTLCreateSystemDefaultDevice() else {
            preconditionFailure("Metal is required for the Portrait render pipeline.")
        }
        // Working space matters here: the depth blur and grades composite far more predictably in
        // linear light than in sRGB gamma space.
        ciContext = CIContext(mtlDevice: metalDevice, options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB) as Any])
    }

    /// The encoded result plus what the pipeline was actually able to do, so the caller can report
    /// a silently-degraded render rather than presenting it as a success.
    struct Result {
        var data: Data
        var didApplyBokeh: Bool
    }

    /// Renders a finished Portrait frame and encodes it as HEIC, or returns nil if the capture
    /// carried nothing usable.
    ///
    /// Degrades in the order the spec asks for: with depth but no portrait matte it still blurs
    /// (Task 2's "depth-only blur, just less precise subject edges"); with no depth at all there's
    /// no bokeh to render, so it grades the image and returns that rather than failing the shot.
    func render(photo: AVCapturePhoto, blurIntensity: Double, style: FilmStyle) -> Result? {
        guard let inputs = extractInputs(from: photo) else { return nil }

        var image = inputs.image
        var didApplyBokeh = false
        if let disparity = inputs.disparity {
            let blurred = applyBokeh(
                to: image,
                disparity: disparity,
                matte: inputs.portraitMatte,
                calibrationData: inputs.calibrationData,
                blurIntensity: blurIntensity
            )
            // `applyBokeh` returns the input unchanged if `CIDepthBlurEffect` couldn't produce an
            // output, so identity here means the blur silently did nothing.
            didApplyBokeh = blurred !== image
            image = blurred
        }
        if let skinMatte = inputs.skinMatte {
            image = applySkinSmoothing(to: image, skinMatte: skinMatte)
        }
        image = applyStyle(style, to: image)

        guard let data = encodeHEIC(image, sourceColorSpace: inputs.image.colorSpace) else { return nil }
        return Result(data: data, didApplyBokeh: didApplyBokeh)
    }

    // MARK: - Inputs

    private struct RenderInputs {
        var image: CIImage
        var disparity: CIImage?
        var portraitMatte: CIImage?
        var skinMatte: CIImage?
        var calibrationData: AVCameraCalibrationData?
    }

    /// Pulls the photo, depth, and mattes into one shared coordinate space.
    ///
    /// **Orientation is the subtle part.** The image is decoded with `.applyOrientationProperty`
    /// so Core Image consumes its EXIF orientation, while depth and the mattes are rotated
    /// explicitly with `applyingExifOrientation(_:)` — they arrive in the sensor's own orientation
    /// and would otherwise be applied sideways to an upright image, putting the blur and the
    /// subject cutout in the wrong places. If a rendered shot ever comes out rotated or mirrored,
    /// this method is the knob.
    private func extractInputs(from photo: AVCapturePhoto) -> RenderInputs? {
        guard let data = photo.fileDataRepresentation(),
              let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            return nil
        }

        let exifOrientation = (photo.metadata[kCGImagePropertyOrientation as String] as? UInt32)
            .flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .up

        var inputs = RenderInputs(image: image)

        if let depthData = photo.depthData {
            let oriented = depthData.applyingExifOrientation(exifOrientation)
            // `CIDepthBlurEffect` expects disparity, not metric depth.
            let disparityType = kCVPixelFormatType_DisparityFloat32
            let disparityData: AVDepthData?
            if oriented.depthDataType == disparityType {
                disparityData = oriented
            } else if oriented.availableDepthDataTypes.contains(disparityType) {
                // Availability is checked first because this raises an Objective-C exception on an
                // unsupported type, which `try?` cannot catch.
                disparityData = oriented.converting(toDepthDataType: disparityType)
            } else {
                disparityData = nil
            }
            if let disparityData {
                inputs.disparity = CIImage(cvPixelBuffer: disparityData.depthDataMap)
                inputs.calibrationData = disparityData.cameraCalibrationData
            }
        }

        if let matte = photo.portraitEffectsMatte {
            let oriented = matte.applyingExifOrientation(exifOrientation)
            inputs.portraitMatte = CIImage(cvPixelBuffer: oriented.mattingImage)
        }

        if let skinMatte = photo.semanticSegmentationMatte(for: .skin) {
            let oriented = skinMatte.applyingExifOrientation(exifOrientation)
            inputs.skinMatte = CIImage(cvPixelBuffer: oriented.mattingImage)
        }

        return inputs
    }

    /// Brings an auxiliary image (disparity, portrait matte, skin matte) up to the main image's
    /// extent, **guided by the photo itself** so its edges land on real edges in the scene.
    ///
    /// Every auxiliary input needs resizing at all because Core Image composites by extent: a
    /// lower-resolution map left at its native size doesn't line up with the photo, silently
    /// producing an effect unrelated to the subject.
    ///
    /// *How* it's resized turned out to matter just as much. These maps are roughly 576×768 against
    /// a 3024×4032 photo — a 5× magnification — so a plain affine transform resamples them
    /// bilinearly and leaves visible faceting, with each facet a slightly different value. Feed that
    /// to `CIDepthBlurEffect` and every facet gets its own blur radius; the result reads as patches
    /// of differently-blurred colour, which on device looked "like an oil painting … someone used a
    /// brush to paint it with blurry colour".
    ///
    /// `CIEdgePreserveUpsample` is the right tool: a joint-bilateral upsample that uses the
    /// full-resolution image as a guide, so the map's transitions snap to actual subject edges
    /// instead of interpolating across them. Falls back to the affine path if the filter can't
    /// produce output, since a correctly-aligned map beats no map.
    private func scaled(_ image: CIImage, to extent: CGRect, guidedBy guide: CIImage? = nil) -> CIImage {
        let stretched = affineScaled(image, to: extent)
        guard let guide else { return stretched }

        let upsample = CIFilter.edgePreserveUpsample()
        upsample.inputImage = guide
        upsample.smallImage = stretched
        upsample.spatialSigma = Self.upsampleSpatialSigma
        upsample.lumaSigma = Self.upsampleLumaSigma
        return upsample.outputImage?.cropped(to: extent) ?? stretched
    }

    /// Plain stretch to the target extent. Also the geometry step `CIEdgePreserveUpsample` needs,
    /// since it expects its small image already in the guide's coordinate space.
    private func affineScaled(_ image: CIImage, to extent: CGRect) -> CIImage {
        let source = image.extent
        guard source.width > 0, source.height > 0 else { return image }
        let transform = CGAffineTransform(
            scaleX: extent.width / source.width,
            y: extent.height / source.height
        )
        let scaledImage = image.transformed(by: transform)
        // Scaling moves a non-zero origin too, so the offset is computed from where the origin
        // actually landed rather than assuming it stayed at zero. (Pixel-buffer-backed images are
        // origin-zero in practice, but the main image's extent need not be.)
        return scaledImage.transformed(by: CGAffineTransform(
            translationX: extent.minX - scaledImage.extent.minX,
            y: extent.minY - scaledImage.extent.minY
        ))
    }

    // MARK: - Task 5 — depth bokeh

    /// Straight depth-based bokeh: blur by depth, then put the sharp subject back on top through the
    /// softened matte.
    ///
    /// **Deviation from `PORTRAIT_MODE.md`, per explicit user request (2026-08-11):** Task 5's
    /// periphery swirl is gone — "I want the swirly effect out of here, it's not the kind I was
    /// looking for, let's go back to basic portrait effect". The whole of that task's radial twist
    /// (a `CITwirlDistortion` blended through a `CIRadialGradient` so the twist rose toward the frame
    /// edges) has been removed rather than left dead or disabled behind a flag. Recoverable from git
    /// history if a vintage-lens look is ever wanted again; don't reintroduce it as a default.
    ///
    /// **The subject is no longer re-composited over the blur.** `CIDepthBlurEffect` already receives
    /// the portrait matte and does its own subject-aware compositing with a properly feathered edge;
    /// layering a second composite on top of that was actively harmful. It cross-faded the *original
    /// sharp* image back over the filter's output through a coarse, 5×-upscaled mask, so wherever the
    /// matte held mid-values — hair, shoulders, any soft boundary — two images that differ in
    /// sharpness got mixed in irregular patches. That's the other half of the "oil painting" look
    /// reported on device, and dropping it is both the fix and a simplification.
    ///
    /// It was originally there to protect the subject from the periphery swirl, which no longer
    /// exists. If subject edges ever come out too soft, the lever is `CIEdgePreserveUpsample`'s sigmas
    /// or the matte itself — not a second composite.
    private func applyBokeh(
        to image: CIImage,
        disparity: CIImage,
        matte: CIImage?,
        calibrationData: AVCameraCalibrationData?,
        blurIntensity: Double
    ) -> CIImage {
        depthBlurred(
            image: image,
            disparity: disparity,
            matte: matte,
            calibrationData: calibrationData,
            blurIntensity: blurIntensity
        ) ?? image
    }

    private func depthBlurred(
        image: CIImage,
        disparity: CIImage,
        matte: CIImage?,
        calibrationData: AVCameraCalibrationData?,
        blurIntensity: Double
    ) -> CIImage? {
        guard let filter = CIFilter(name: "CIDepthBlurEffect") else { return nil }
        filter.setValue(image, forKey: kCIInputImageKey)
        // **Auxiliary images must be scaled to the main image's extent.** Depth and mattes arrive at
        // a far lower resolution than the photo (roughly 768×576 against ~4032×3024), and Core Image
        // aligns images by extent, not by relative size — so an unscaled disparity map only covers a
        // small corner of the frame and reads as "no measurement" everywhere else. On device that
        // looked like a blur with no relationship to the subject, even though the depth data itself
        // was perfect (the debug preview confirmed it).
        // Both are upsampled with the photo as a guide so their transitions sit on real scene edges —
        // a bilinear stretch leaves faceting, and the filter turns each facet into its own blur
        // radius. See `scaled(_:to:guidedBy:)`.
        filter.setValue(scaled(disparity, to: image.extent, guidedBy: image), forKey: "inputDisparityImage")
        if let matte {
            filter.setValue(scaled(matte, to: image.extent, guidedBy: image), forKey: "inputMatteImage")
        }
        if let calibrationData {
            filter.setValue(calibrationData, forKey: "inputCalibrationData")
        }
        filter.setValue(aperture(for: blurIntensity, filter: filter), forKey: "inputAperture")
        return filter.outputImage?.cropped(to: image.extent)
    }

    /// Maps the UI's 0…1 blur intensity onto the filter's own aperture scale, **inverted and
    /// geometrically**: a small f-number is a wide aperture, i.e. more blur, so intensity 1 lands
    /// on the range's minimum.
    ///
    /// The geometric curve is the important part, and getting it wrong is what made the bokeh look
    /// broken on device. `inputAperture` is an f-number (the filter reports slider bounds 1…22),
    /// and f-numbers are **stops** — f/1, 1.4, 2, 2.8, 4, 5.6, 8, 11, 16, 22 is a geometric
    /// series, not a linear one. A linear interpolation put 60% blur at f/9.4 and spent roughly
    /// 85% of the slider's travel in the f/8–f/22 region, where every value looks identically
    /// sharp; only the last sliver did anything visible.
    ///
    /// Interpolating the *ratio* instead gives equal stops per unit of slider travel, so 50% is
    /// ~f/4.7 and 60% is ~f/3.4 — visibly blurred, and evenly responsive across the whole range.
    /// Exactly the reasoning behind feeding ISO and shutter through `log2` in `MainCameraView`.
    private func aperture(for blurIntensity: Double, filter: CIFilter) -> Double {
        let attributes = filter.attributes["inputAperture"] as? [String: Any]
        let widest = (attributes?[kCIAttributeSliderMin] as? Double) ?? Self.fallbackApertureRange.lowerBound
        let narrowest = (attributes?[kCIAttributeSliderMax] as? Double) ?? Self.fallbackApertureRange.upperBound
        // Guard the ratio: a degenerate or zero range would make `pow` produce NaN, and the filter
        // silently renders nothing useful when handed one.
        guard widest > 0, narrowest > widest else { return widest }
        let clamped = min(max(blurIntensity, 0), 1)
        return narrowest * pow(widest / narrowest, clamped)
    }

    // Task 6's baked-in **edge softness** no longer has its own step. It existed to feather *our*
    // compositing mask, and there is no longer a second composite to feather — `CIDepthBlurEffect`
    // handles the subject boundary itself from the matte it's given, and that matte now arrives via a
    // guided upsample whose transitions already follow real scene edges. A fixed 2.5px Gaussian on a
    // 5×-upscaled mask was, in any case, narrower than a single native matte pixel: it couldn't smooth
    // the faceting it was meant to hide.

    // MARK: - Task 6 — baked-in skin smoothing

    /// A soft blur blended at a fixed low opacity, only inside the skin matte. No UI toggle, per
    /// the spec — and kept subtle on purpose: the failure mode of skin smoothing is looking
    /// artificial, not looking insufficient.
    private func applySkinSmoothing(to image: CIImage, skinMatte: CIImage) -> CIImage {
        let extent = image.extent
        let blur = CIFilter.gaussianBlur()
        // Clamped for the same reason as the matte blur: an unclamped Gaussian darkens the frame
        // edges, which would show anywhere skin reaches the border.
        blur.inputImage = image.clampedToExtent()
        blur.radius = Float(Self.skinSmoothingBlurRadius)
        guard let smoothed = blur.outputImage?.cropped(to: extent) else { return image }

        // Guided upsample here too. A faceted skin mask blends the blurred copy in irregular patches,
        // which is the textbook "beauty filter" oil-paint artifact — the same visual complaint,
        // arriving by a different route than the depth map.
        let scaledMatte = scaled(skinMatte, to: extent, guidedBy: image)

        // Scaling the mask's brightness is what produces a *partial* blend: the mask drives how
        // much of the blurred version shows through, so a 0.35 mask is a 35% effect.
        let attenuate = CIFilter.colorMatrix()
        attenuate.inputImage = scaledMatte
        let weight = CGFloat(Self.skinSmoothingBlend)
        attenuate.rVector = CIVector(x: weight, y: 0, z: 0, w: 0)
        attenuate.gVector = CIVector(x: 0, y: weight, z: 0, w: 0)
        attenuate.bVector = CIVector(x: 0, y: 0, z: weight, w: 0)
        attenuate.aVector = CIVector(x: 0, y: 0, z: 0, w: weight)
        guard let mask = attenuate.outputImage?.cropped(to: extent) else { return image }

        let blend = CIFilter.blendWithMask()
        blend.backgroundImage = image
        blend.inputImage = smoothed
        blend.maskImage = mask
        return blend.outputImage?.cropped(to: extent) ?? image
    }

    // MARK: - Task 6 — film style grades

    /// Delegates to `FilmStyleGrade`, which the live preview also uses — one implementation, so the
    /// viewfinder and the saved photo can't drift apart. See that type for why.
    private func applyStyle(_ style: FilmStyle, to image: CIImage) -> CIImage {
        FilmStyleGrade.apply(style, to: image)
    }

    // MARK: - Encode

    /// HEIC, to match the app's normal capture format and the album's other assets.
    ///
    /// **The output colour space follows the source, not a hardcoded sRGB — confirmed defect, fixed
    /// 2026-08-11.** Inspecting a real render showed `ProfileName: sRGB` on a frame captured by an
    /// iPhone 17 Pro, whose captures are Display P3: the encode step was quietly clipping every
    /// saturated colour in the shot. Falls back to Display P3 rather than sRGB when the source doesn't
    /// declare a space, since that's what these cameras actually produce.
    private func encodeHEIC(_ image: CIImage, sourceColorSpace: CGColorSpace?) -> Data? {
        let colorSpace = sourceColorSpace
            ?? CGColorSpace(name: CGColorSpace.displayP3)
            ?? CGColorSpace(name: CGColorSpace.sRGB)
        guard let colorSpace else { return nil }
        return ciContext.heifRepresentation(
            of: image,
            format: .RGBA8,
            colorSpace: colorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.95]
        )
    }
}
