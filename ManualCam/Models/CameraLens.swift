import AVFoundation
import CoreGraphics

/// A selectable lens/zoom preset on the back camera. Switching to one makes
/// `deviceType` (always position `.back`) the session's active physical camera, then
/// sets `videoZoomFactor` to `ownZoomFactor` on it — `ownZoomFactor` is 1.0 for the
/// lens's own native full field of view, or greater for an extra native crop point that
/// same physical lens supports (e.g. a telephoto's own secondary native zoom beyond its
/// base optical magnification, surfaced by `AVCaptureDeviceFormat
/// .secondaryNativeResolutionZoomFactors`).
///
/// Deliberately uses discrete physical lenses (never the virtual multi-camera device)
/// so manual focus keeps working: `AVCaptureDevice.isLockingFocusWithCustomLensPositionSupported`
/// is generally false on virtual devices, which crashes `setFocusModeLocked(lensPosition:)`
/// the moment you try to focus after switching to one.
struct CameraLens: Identifiable, Equatable {
    let deviceType: AVCaptureDevice.DeviceType
    /// The zoom factor to set on `deviceType`'s own device instance (relative to that
    /// lens's own native 1.0), not a system-wide zoom number.
    let ownZoomFactor: CGFloat
    /// Approximate 35mm-equivalent focal length — used as both the display label and
    /// the sort/dedup key, since it's the one number that's directly comparable across
    /// every lens regardless of which physical device or crop point it comes from.
    let millimeters: Int
    let symbolName: String

    var id: String { "\(deviceType.rawValue)-\(ownZoomFactor)" }
    var displayName: String { "\(millimeters)mm" }

    static func < (lhs: CameraLens, rhs: CameraLens) -> Bool {
        lhs.millimeters < rhs.millimeters
    }

    /// iPhone's main/wide camera is conventionally described as ~24mm (35mm-equivalent)
    /// across recent models — the reference point for converting every lens's
    /// system-relative zoom factor (1.0 == wide) into an approximate mm focal length.
    private static let wideEquivalentMM: CGFloat = 24

    /// - Parameters:
    ///   - ownZoomFactor: value to actually set on `deviceType`'s `videoZoomFactor`.
    ///   - systemZoom: zoom relative to the wide lens (1.0 == wide), used only for the
    ///     mm label — get this from Apple's own reported values
    ///     (`virtualDeviceSwitchOverVideoZoomFactors`/`minAvailableVideoZoomFactor` on
    ///     the virtual device), not an approximation, or the mm figure will be off.
    static func make(deviceType: AVCaptureDevice.DeviceType, ownZoomFactor: CGFloat, systemZoom: CGFloat) -> CameraLens {
        let mm = Int((systemZoom * wideEquivalentMM).rounded())
        let symbol: String
        switch deviceType {
        case .builtInUltraWideCamera: symbol = "camera.macro"
        case .builtInTelephotoCamera: symbol = "camera.filters"
        default: symbol = systemZoom > 1.01 ? "camera.filters" : "camera"
        }
        return CameraLens(deviceType: deviceType, ownZoomFactor: ownZoomFactor, millimeters: mm, symbolName: symbol)
    }
}
