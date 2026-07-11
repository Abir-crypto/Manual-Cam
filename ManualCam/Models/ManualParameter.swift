import Foundation

enum ManualParameter: String, CaseIterable, Identifiable {
    case iso, shutter, focus, whiteBalance

    var id: String { rawValue }

    var label: String {
        switch self {
        case .iso: "ISO"
        case .shutter: "SHUTTER"
        case .focus: "FOCUS"
        case .whiteBalance: "WB"
        }
    }
}
