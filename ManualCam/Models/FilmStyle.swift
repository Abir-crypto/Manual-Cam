import Foundation

/// Portrait mode's film styles (`PORTRAIT_MODE.md` Task 6). Matte-masked colour grades over a
/// depth bokeh render — an honest approximation of a portrait look, explicitly **not** a clone of
/// Apple Portrait Lighting, which relies on proprietary face-relighting ML no third-party app can
/// reach.
///
/// Each case is applied to the **final composite** (post depth-blur, post subject compositing), not
/// just the background, because these are whole-image grades.
enum FilmStyle: String, CaseIterable, Identifiable, Codable {
    /// Passthrough — no grade at all.
    case natural
    case goldenHour
    case tealFrost
    case noir

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .natural: return "Natural"
        case .goldenHour: return "Golden"
        case .tealFrost: return "Teal"
        case .noir: return "Noir"
        }
    }

    /// `.natural` is a genuine passthrough, so both the render and the live preview can skip all work
    /// for it rather than running an identity filter chain.
    var isPassthrough: Bool { self == .natural }
}
