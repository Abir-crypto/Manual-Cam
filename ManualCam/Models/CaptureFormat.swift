import Foundation

/// **Deviation from spec**: SPEC.md's twin RAW+HEIC-in-one-shot capture is gone per
/// explicit user request ("I don't need them together") — `.heic` and `.raw` are
/// mutually exclusive capture modes, not a combined one.
enum CaptureFormat: String, CaseIterable, Codable, Identifiable {
    case heic
    case raw

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .heic: "HEIC"
        case .raw: "RAW"
        }
    }
}
