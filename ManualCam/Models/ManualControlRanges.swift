import CoreMedia
import Foundation

/// Manual control ranges queried live from the active `AVCaptureDevice`.
/// Never hardcode these — they vary per device/lens.
struct ManualControlRanges: Equatable {
    var isoRange: ClosedRange<Float>
    var exposureDurationRange: ClosedRange<CMTime>
    var maxWhiteBalanceGain: Float

    /// Focus (lens position) is always normalized 0...1 by AVFoundation convention.
    static let lensPositionRange: ClosedRange<Float> = 0.0...1.0

    /// Reasonable general Kelvin bounds most iPhones support.
    static let kelvinRange: ClosedRange<Double> = 2000...10000

    static let fallback = ManualControlRanges(
        isoRange: 50...800,
        exposureDurationRange: CMTime(value: 1, timescale: 1000)...CMTime(value: 1, timescale: 30),
        maxWhiteBalanceGain: 4.0
    )
}
