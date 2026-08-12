import Foundation

/// What a Portrait capture actually delivered, per shot.
///
/// This is `PORTRAIT_MODE.md` Task 2's acceptance criterion made observable: "a Portrait
/// capture returns image + depth data + portrait matte + skin matte when a person is present;
/// degrades gracefully to depth-only when not". It's surfaced on screen rather than just
/// logged for two reasons: matte delivery can silently fail on a per-shot basis (so a single
/// success proves little), and Task 5's render pipeline branches on exactly these three
/// inputs — so this tells you up front which path a given shot would take.
struct PortraitCaptureDiagnostics: Equatable {
    var hasDepthData = false
    var hasPortraitMatte = false
    var hasSkinMatte = false
    /// Whether the render actually ran the depth-blur pass. Distinct from `hasDepthData` on
    /// purpose: depth can be delivered and still be unusable — if the frame can't be converted to
    /// `DisparityFloat32`, `PortraitRenderer` skips the bokeh and produces a graded-but-sharp
    /// image, which on screen is indistinguishable from a broken blur. Without this flag those two
    /// very different failures look identical.
    var didApplyBokeh = false

    /// True when the full set arrived — the depth + subject-matte + skin path.
    var isComplete: Bool { hasDepthData && hasPortraitMatte && hasSkinMatte }

    /// True when there's enough for a blur, but not the precise subject edges — Task 2's
    /// "fall back to depth-only blur" case.
    var isDepthOnly: Bool { hasDepthData && !hasPortraitMatte }

    var summary: String {
        [
            "depth \(hasDepthData ? "✓" : "✗")",
            "matte \(hasPortraitMatte ? "✓" : "✗")",
            "skin \(hasSkinMatte ? "✓" : "✗")",
            "blur \(didApplyBokeh ? "✓" : "✗")",
        ].joined(separator: "  ")
    }

    /// The case worth calling out loudly: depth arrived but no blur came out of it, which means the
    /// problem is in the render rather than the capture.
    var hasDepthButNoBokeh: Bool { hasDepthData && !didApplyBokeh }
}
