import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// The film style colour grades (`PORTRAIT_MODE.md` Task 6), as one shared implementation.
///
/// **This exists specifically so the live preview and the saved photo can't drift apart.** They used
/// to be two unrelated things: the render applied these Core Image chains, while the viewfinder faked
/// the look with a translucent SwiftUI rectangle in `.softLight` blend mode. The user spotted it
/// immediately — "the photo shown in the view finder and the saved images are not same … the view is
/// only a overlay" — which was exactly right. Both paths now call these functions, so a change to a
/// grade automatically shows up in both.
///
/// `nonisolated` and stateless: every entry point runs off the main actor, on either
/// `PhotoCaptureService.renderQueue` (post-capture) or the video data output queue (live).
///
/// One difference between the two paths is expected and correct: the render grades the *blurred and
/// composited* frame, while the live preview grades the raw camera frame — the spec puts a live bokeh
/// preview explicitly out of scope. So the colour matches; the blur only appears in the saved photo.
nonisolated enum FilmStyleGrade {
    /// Apply a style's grade. `.natural` is a genuine passthrough, so callers can skip all work for it.
    static func apply(_ style: FilmStyle, to image: CIImage) -> CIImage {
        switch style {
        case .natural: return image
        case .goldenHour: return applyGoldenHour(to: image)
        case .tealFrost: return applyTealFrost(to: image)
        case .noir: return applyNoir(to: image)
        }
    }

    /// Warm white balance shift, lifted shadows, gentle contrast reduction.
    private static func applyGoldenHour(to image: CIImage) -> CIImage {
        var result = image

        let temperature = CIFilter.temperatureAndTint()
        temperature.inputImage = result
        // Declaring the source as cooler than neutral is what warms the result.
        temperature.neutral = CIVector(x: 5500, y: 0)
        temperature.targetNeutral = CIVector(x: 4300, y: 12)
        result = temperature.outputImage ?? result

        // Lifting the black point is the "lifted shadows" half; the flattened top end is the
        // gentle contrast reduction.
        let curve = CIFilter.toneCurve()
        curve.inputImage = result
        curve.point0 = CGPoint(x: 0.0, y: 0.06)
        curve.point1 = CGPoint(x: 0.25, y: 0.30)
        curve.point2 = CGPoint(x: 0.5, y: 0.54)
        curve.point3 = CGPoint(x: 0.75, y: 0.78)
        curve.point4 = CGPoint(x: 1.0, y: 0.96)
        result = curve.outputImage ?? result

        let controls = CIFilter.colorControls()
        controls.inputImage = result
        controls.saturation = 1.08
        controls.contrast = 0.96
        result = controls.outputImage ?? result

        return result
    }

    /// Cool/teal cast with increased contrast.
    private static func applyTealFrost(to image: CIImage) -> CIImage {
        var result = image

        let temperature = CIFilter.temperatureAndTint()
        temperature.inputImage = result
        temperature.neutral = CIVector(x: 5500, y: 0)
        temperature.targetNeutral = CIVector(x: 7200, y: -14)
        result = temperature.outputImage ?? result

        // Pushes blue/green in the shadows specifically, which is what reads as "teal" rather
        // than simply "cold".
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = result
        matrix.rVector = CIVector(x: 0.94, y: 0, z: 0, w: 0)
        matrix.gVector = CIVector(x: 0, y: 1.01, z: 0, w: 0)
        matrix.bVector = CIVector(x: 0, y: 0, z: 1.05, w: 0)
        matrix.biasVector = CIVector(x: 0, y: 0.012, z: 0.028, w: 0)
        result = matrix.outputImage ?? result

        let controls = CIFilter.colorControls()
        controls.inputImage = result
        controls.contrast = 1.12
        controls.saturation = 1.05
        result = controls.outputImage ?? result

        return result
    }

    /// Full desaturation and increased contrast.
    ///
    /// **Deviation from `PORTRAIT_MODE.md` Task 6: no grain.** The spec asks for "subtle grain (simple
    /// noise overlay at low opacity)". Two problems, both found on device and then reproduced by
    /// rendering a real photo through the chain:
    /// 1. **The original was a hard bug** — the noise was mapped to a dim grey with **alpha 1** and
    ///    composited with `CISourceOverCompositing`. An opaque foreground over source-over *replaces*
    ///    the background, so Noir output was the noise layer itself. Device report: "the noir isn't
    ///    working, it just shows grey pixels."
    /// 2. **Fixing the alpha didn't rescue the look.** `CIRandomGenerator` is full-range, spatially
    ///    uncorrelated white noise, and source-over pulls everything toward its bright mean — so even
    ///    at 6–8% alpha, with the noise pre-blurred to soften it, every shadow lifted into grey
    ///    speckle and the contrast the grade had just built was destroyed. Verified by rendering
    ///    side-by-side comparisons; the grain-free version was plainly better.
    ///
    /// Doing this properly needs zero-mean noise added in linear light, which Core Image's compositing
    /// filters make awkward (addition compositing ignores a zero-alpha layer and mis-handles negative
    /// values) — realistically a small `CIColorKernel`. Worth it only if grain is actually wanted;
    /// **don't re-add an opacity-based noise overlay, it has been tried twice.**
    private static func applyNoir(to image: CIImage) -> CIImage {
        var result = image

        let mono = CIFilter.photoEffectMono()
        mono.inputImage = result
        result = mono.outputImage ?? result

        let controls = CIFilter.colorControls()
        controls.inputImage = result
        controls.contrast = 1.22
        controls.saturation = 0
        result = controls.outputImage ?? result

        return result
    }

}
