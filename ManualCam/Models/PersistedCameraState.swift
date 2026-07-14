import CoreMedia
import Foundation

/// Last-used manual control values, persisted to UserDefaults (Task 11). Capture format
/// is *not* part of this — it's owned solely by `AppSettingsStore.defaultCaptureFormat`
/// now that there's no separate top-bar session override to reconcile it with.
struct PersistedCameraState: Codable, Equatable {
    var iso: Float
    var exposureDurationSeconds: Double
    var lensPosition: Float
    var whiteBalanceKelvin: Double

    var exposureDuration: CMTime {
        CMTime(seconds: exposureDurationSeconds, preferredTimescale: 1_000_000)
    }

    init(
        iso: Float,
        exposureDuration: CMTime,
        lensPosition: Float,
        whiteBalanceKelvin: Double
    ) {
        self.iso = iso
        self.exposureDurationSeconds = exposureDuration.seconds
        self.lensPosition = lensPosition
        self.whiteBalanceKelvin = whiteBalanceKelvin
    }
}
