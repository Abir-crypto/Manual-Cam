import CoreGraphics
import Foundation

/// A selectable lens/zoom point in Portrait mode — "1×", "2×", "5×".
///
/// Portrait runs on the virtual multi-camera device, so switching lenses there is a matter of
/// setting `videoZoomFactor` and letting the device switch constituent cameras itself, rather than
/// swapping the session's input the way Manual mode's `CameraLens` does.
///
/// **Only depth-capable factors are ever offered.** Virtual devices support depth over a limited set
/// of zoom ranges (`AVCaptureDeviceFormat.supportedVideoZoomRangesForDepthDataDelivery`), and per the
/// SDK, setting a zoom factor outside them while depth delivery is enabled raises an exception. The
/// list is built by intersecting the device's *native* zoom points with those ranges — see
/// `CameraSessionManager.buildPortraitZoomOptions(for:)`.
struct PortraitZoomOption: Identifiable, Equatable {
    /// The value to assign to `AVCaptureDevice.videoZoomFactor` — **device-relative**, i.e. measured
    /// from the virtual device's widest constituent lens. On a device with an ultra-wide this is 1.0
    /// at the ultra-wide, 2.0 at the 24mm main, and so on. Not the number to show the user.
    let zoomFactor: CGFloat

    /// The user-facing multiplier, normalized so the **main (wide) lens is 1×** — the convention every
    /// iPhone camera UI uses, and the one Manual mode's millimetre labels already follow.
    ///
    /// These two values differ, and conflating them was a real bug: labelling with the raw
    /// `zoomFactor` showed the 24mm main lens as "2×" and its 48mm crop as "4×", because on a virtual
    /// device with an ultra-wide, device zoom 1.0 *is* the ultra-wide. See
    /// `CameraSessionManager.wideAngleBaseZoomFactor(for:)`.
    let displayMultiplier: CGFloat

    /// Keyed on the displayed value: two entries that read the same to the user are the same button,
    /// whatever their raw factors.
    var id: String { String(format: "%.1f", Double(displayMultiplier)) }

    /// "1×", "2×", "0.5×" — trailing `.0` dropped, since "1×" is how these are labelled on the
    /// hardware. Deliberately a multiplier rather than the 35mm-equivalent millimetres Manual mode's
    /// lens row uses: this row is about picking a lens quickly, not about focal length.
    var displayName: String {
        let rounded = (Double(displayMultiplier) * 10).rounded() / 10
        let text = rounded == rounded.rounded()
            ? String(format: "%.0f", rounded)
            : String(format: "%.1f", rounded)
        return "\(text)×"
    }
}
