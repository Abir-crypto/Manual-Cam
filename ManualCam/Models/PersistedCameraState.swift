import CoreMedia
import Foundation

/// Last-used manual control values, persisted to UserDefaults (Task 11).
struct PersistedCameraState: Codable, Equatable {
    var iso: Float
    var exposureDurationSeconds: Double
    var lensPosition: Float
    var whiteBalanceKelvin: Double
    var exposureTargetBias: Float
    var captureFormat: CaptureFormat

    var exposureDuration: CMTime {
        CMTime(seconds: exposureDurationSeconds, preferredTimescale: 1_000_000)
    }

    init(
        iso: Float,
        exposureDuration: CMTime,
        lensPosition: Float,
        whiteBalanceKelvin: Double,
        exposureTargetBias: Float,
        captureFormat: CaptureFormat
    ) {
        self.iso = iso
        self.exposureDurationSeconds = exposureDuration.seconds
        self.lensPosition = lensPosition
        self.whiteBalanceKelvin = whiteBalanceKelvin
        self.exposureTargetBias = exposureTargetBias
        self.captureFormat = captureFormat
    }
}
