import Foundation

/// Portrait mode's film styles (`PORTRAIT_MODE.md` Task 6). Colour grades applied over a depth bokeh
/// render — an honest approximation of a portrait look, explicitly **not** a clone of Apple Portrait
/// Lighting, which relies on proprietary face-relighting ML no third-party app can reach.
///
/// Each case is applied to the **final composite** (post depth-blur, post subject compositing), not
/// just the background, because these are whole-image grades.
///
/// **The three graded styles are 3D LUTs from `/ManualCam/Luts`, not hand-written filter chains**
/// (changed 2026-08-19 at the user's request — they supplied the `.cube` files). The previous
/// hand-tuned Golden Hour / Teal Frost / Noir grades are gone; see `FilmStyleGrade` for why a LUT is
/// the better mechanism and `CubeLUTStore` for the loader.
enum FilmStyle: String, CaseIterable, Identifiable, Codable {
    /// Passthrough — no grade at all.
    case natural
    /// Lifted, warm-yellow blacks with blue pulled out of the midtones — faded film stock.
    case vintage
    /// A stronger, golden version of the same idea: warm haze in the shadows, blue crushed throughout.
    case warmLight
    /// Teal-and-orange cross-process. Leaves the neutral axis untouched and works purely on hue and
    /// saturation, so greys stay grey while skin warms and shadows/foliage push toward teal.
    case cine

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .natural: return "Natural"
        case .vintage: return "Vintage"
        case .warmLight: return "Warm"
        case .cine: return "Cine"
        }
    }

    /// Basename of the `.cube` resource backing this style, or nil for a passthrough.
    ///
    /// These match the filenames in `/ManualCam/Luts` exactly, spaces included. The folder is inside
    /// the project's file-system-synchronized group, so the files reach the bundle without a pbxproj
    /// edit — but that also means **renaming a file on disk silently breaks the style** (the loader
    /// caches the failure and the grade degrades to passthrough). Rename here too if you rename there.
    var lutResourceName: String? {
        switch self {
        case .natural: return nil
        case .vintage: return "02_Film LUTs_Vintage"
        case .warmLight: return "03_Film LUTs_Warm Light"
        case .cine: return "Vintage Color"
        }
    }

    /// `.natural` is a genuine passthrough, so both the render and the live preview can skip all work
    /// for it rather than running an identity filter chain.
    var isPassthrough: Bool { self == .natural }

    /// Every LUT the app can be asked for, for `CubeLUTStore.prewarm(_:)`.
    static var allLUTResourceNames: [String] { allCases.compactMap(\.lutResourceName) }
}
