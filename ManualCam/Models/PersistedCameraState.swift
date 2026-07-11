import CoreMedia
import Foundation

/// Last-used manual control values, persisted to UserDefaults (Task 11).
struct PersistedCameraState: Codable, Equatable {
    var iso: Float
    var exposureDurationSeconds: Double
    var lensPosition: Float
    var whiteBalanceKelvin: Double
    var captureFormat: CaptureFormat

    var exposureDuration: CMTime {
        CMTime(seconds: exposureDurationSeconds, preferredTimescale: 1_000_000)
    }

    init(
        iso: Float,
        exposureDuration: CMTime,
        lensPosition: Float,
        whiteBalanceKelvin: Double,
        captureFormat: CaptureFormat
    ) {
        self.iso = iso
        self.exposureDurationSeconds = exposureDuration.seconds
        self.lensPosition = lensPosition
        self.whiteBalanceKelvin = whiteBalanceKelvin
        self.captureFormat = captureFormat
    }
}
