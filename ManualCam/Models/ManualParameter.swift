import Foundation

enum ManualParameter: String, CaseIterable, Identifiable {
    case iso, shutter, focus, whiteBalance, exposureBias

    var id: String { rawValue }

    var label: String {
        switch self {
        case .iso: "ISO"
        case .shutter: "SHUTTER"
        case .focus: "FOCUS"
        case .whiteBalance: "WB"
        case .exposureBias: "EV"
        }
    }
}
