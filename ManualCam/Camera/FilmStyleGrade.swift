import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// The film style colour grades (`PORTRAIT_MODE.md` Task 6), as one shared implementation.
///
/// **This exists specifically so the live preview and the saved photo can't drift apart.** They used
/// to be two unrelated things: the render applied Core Image chains, while the viewfinder faked the
/// look with a translucent SwiftUI rectangle in `.softLight` blend mode. The user spotted it
/// immediately — "the photo shown in the view finder and the saved images are not same … the view is
/// only a overlay" — which was exactly right. Both paths now call this, so a change to a grade
/// automatically shows up in both.
///
/// **Grades are 3D LUTs now, not hand-written filter chains** (2026-08-19). The user supplied `.cube`
/// files and asked for them in place of the hand-tuned Golden Hour / Teal Frost / Noir grades, which
/// are deleted. A LUT is the better mechanism regardless of who authored the look: it is the same
/// primitive real colourists deliver, adding a style is dropping a file in `/ManualCam/Luts` plus a
/// case in `FilmStyle`, and one texture lookup replaces a three-or-four-filter chain per frame.
///
/// `nonisolated` and stateless: every entry point runs off the main actor, on either
/// `PhotoCaptureService.renderQueue` (post-capture) or the video data output queue (live).
///
/// One difference between the two paths is expected and correct: the render grades the *blurred and
/// composited* frame, while the live preview grades the raw camera frame — the spec puts a live bokeh
/// preview explicitly out of scope. So the colour matches; the blur only appears in the saved photo.
nonisolated enum FilmStyleGrade {
    /// Apply a style's grade. `.natural` is a genuine passthrough, so callers can skip all work for it.
    ///
    /// Degrades to a passthrough if the LUT can't be loaded, rather than substituting some other look:
    /// an ungraded photo is an obvious, self-explaining failure, where a stand-in grade would look
    /// deliberate and get shipped.
    static func apply(_ style: FilmStyle, to image: CIImage) -> CIImage {
        guard let name = style.lutResourceName,
              let lut = CubeLUTStore.lut(named: name),
              let colorSpace = lutColorSpace else { return image }

        // Built per call rather than cached: `CIFilter` is mutable and has no documented thread
        // safety, and this is reached from two queues. See `CubeLUTStore` — the expensive part (the
        // parsed table) is what's cached.
        let filter = CIFilter.colorCubeWithColorSpace()
        filter.inputImage = image
        filter.cubeDimension = Float(lut.dimension)
        filter.cubeData = lut.data
        filter.colorSpace = colorSpace
        // Out-of-gamut colours get extrapolated through the table instead of clamped to its edge.
        // This matters here specifically: the camera captures Display P3, the LUTs are applied in
        // sRGB (see `lutColorSpace`), and any colour outside the sRGB gamut therefore encodes to a
        // component outside 0…1. Without extrapolation every such colour — saturated foliage, deep
        // reds, neon — would flatten onto the cube's boundary, which is the same class of silent
        // colour clipping that the hardcoded-sRGB bug in `PortraitRenderer.encodeHEIC` caused.
        filter.extrapolate = true

        return filter.outputImage ?? image
    }

    /// Warms the LUT cache. Called when Portrait is entered, so the first frame after a style is
    /// picked isn't the one that pays for parsing a 33³ table on the video queue.
    static func prewarmLUTs() {
        CubeLUTStore.prewarm(FilmStyle.allLUTResourceNames)
    }

    /// The colour space the LUT tables are defined in — i.e. the space the image is converted into
    /// before the lookup and back out of afterwards.
    ///
    /// **sRGB, not the working space and not Display P3.** These are display-referred film LUTs
    /// authored against Rec.709/sRGB, so sRGB is the encoding in which their tables mean what their
    /// authors intended. Applying them in Display P3 instead would avoid the gamut question entirely
    /// but feed every pixel — skin included — a different input than the table was built for, since
    /// the same colour has different coordinates in the two spaces. Faithfulness to the look wins,
    /// and `extrapolate` handles the wide-gamut edge case above.
    ///
    /// Note this is *not* the `CIContext` working space (`extendedLinearSRGB` in both callers). Passing
    /// a space here is exactly what `CIColorCubeWithColorSpace` is for over plain `CIColorCube`: it
    /// does the linear→gamma round trip, so the lookup happens on gamma-encoded values as the format
    /// assumes rather than on linear light, where the table would land completely wrong.
    private static let lutColorSpace = CGColorSpace(name: CGColorSpace.sRGB)
}
