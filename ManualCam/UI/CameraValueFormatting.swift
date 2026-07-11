import CoreMedia
import Foundation

enum CameraValueFormatting {
    static func iso(_ value: Float) -> String {
        "ISO \(Int(value.rounded()))"
    }

    static func shutter(_ duration: CMTime) -> String {
        let seconds = duration.seconds
        guard seconds > 0 else { return "—" }
        if seconds >= 1 {
            return String(format: "%.1fs", seconds)
        }
        let denominator = (1.0 / seconds).rounded()
        return "1/\(Int(denominator))"
    }

    static func kelvin(_ value: Double) -> String {
        "\(Int(value.rounded()))K"
    }

    static func exposureBias(_ value: Float) -> String {
        String(format: "%+.1f", value)
    }

    static func focus(_ value: Float) -> String {
        String(format: "%.0f%%", value * 100)
    }
}
