import Foundation

/// The app's top-level shooting modes — `PORTRAIT_MODE.md` Task 1 and `ASTRO_MODE.md`
/// Task 1 both call for the same Manual / Portrait / Astro switcher.
///
/// The two added modes relate to the base app's manual controls in opposite ways, which is
/// why `showsManualControls` exists rather than a blanket "is a special mode" flag: Portrait
/// **replaces** the manual controls with its own bar (it runs the device in continuous auto
/// so depth and matte generation work), while Astro **keeps** them and stacks its own panel
/// on top.
enum ShootingMode: String, CaseIterable, Identifiable, Codable {
    case manual
    case portrait
    case astro

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .manual: return "MANUAL"
        case .portrait: return "PORTRAIT"
        case .astro: return "ASTRO"
        }
    }

    /// Astro's `StackCaptureEngine` and control panel aren't built yet (`ASTRO_MODE.md`), so
    /// it stays out of the switcher instead of appearing as a tab that silently does nothing.
    /// Everything else here — persistence, mode switching, Portrait teardown/restore — is
    /// already mode-generic, so shipping Astro should only mean flipping this and adding its
    /// panel.
    var isImplemented: Bool { self != .astro }

    /// Whether the base app's manual control tabs, slider, and value readout strip belong on
    /// screen in this mode.
    var showsManualControls: Bool { self != .portrait }

    /// Portrait needs depth, which only the virtual multi-camera device provides — so it's
    /// gated on hardware at runtime (`CameraSessionManager.isPortraitModeSupported`), not on
    /// an OS version. Manual and Astro work on any back camera.
    var requiresMultiCameraDevice: Bool { self == .portrait }
}
