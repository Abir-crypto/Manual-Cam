import Foundation

/// Settings for the Multi-Shot Timer (intervalometer) run — see `MULTI_SHOT_TIMER.md`.
/// A standalone shooting aid usable only in Manual mode: an initial countdown, a fixed
/// number of shots, and the interval between subsequent shots. Each shot is an
/// independent capture (no stacking/blending).
struct TimerConfiguration: Equatable {
    /// Seconds before the first shot fires.
    var initialDelay: Int
    /// Total number of shots to take.
    var shotCount: Int
    /// Seconds between each subsequent shot after the first.
    var interval: Int

    static let initialDelayRange = 0...60
    static let shotCountRange = 1...50
    static let intervalRange = 1...60

    static let `default` = TimerConfiguration(initialDelay: 3, shotCount: 3, interval: 3)

    /// Clamp every field back into its supported range — guards against stale persisted
    /// values drifting out of bounds.
    func clamped() -> TimerConfiguration {
        TimerConfiguration(
            initialDelay: min(max(initialDelay, Self.initialDelayRange.lowerBound), Self.initialDelayRange.upperBound),
            shotCount: min(max(shotCount, Self.shotCountRange.lowerBound), Self.shotCountRange.upperBound),
            interval: min(max(interval, Self.intervalRange.lowerBound), Self.intervalRange.upperBound)
        )
    }
}
