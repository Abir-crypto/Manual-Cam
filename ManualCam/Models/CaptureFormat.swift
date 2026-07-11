import Foundation

enum CaptureFormat: String, CaseIterable, Codable, Identifiable {
    case heicOnly
    case heicPlusRAW

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .heicOnly: "HEIC"
        case .heicPlusRAW: "RAW + HEIC"
        }
    }

    var includesRAW: Bool { self == .heicPlusRAW }
}
