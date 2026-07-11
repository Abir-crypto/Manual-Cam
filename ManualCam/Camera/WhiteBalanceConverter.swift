import AVFoundation

/// Converts a single Kelvin value (+ fixed neutral tint) to/from device white balance gains (Task 4).
enum WhiteBalanceConverter {
    /// Neutral tint — the app only exposes a Kelvin slider, not a separate tint control.
    static let neutralTint: Float = 0.0

    static func gains(forKelvin kelvin: Double, device: AVCaptureDevice) -> AVCaptureDevice.WhiteBalanceGains {
        let temperatureAndTint = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
            temperature: Float(kelvin),
            tint: neutralTint
        )
        var gains = device.deviceWhiteBalanceGains(for: temperatureAndTint)
        clamp(&gains, to: device.maxWhiteBalanceGain)
        return gains
    }

    static func kelvin(forGains gains: AVCaptureDevice.WhiteBalanceGains, device: AVCaptureDevice) -> Double {
        var clamped = gains
        clamp(&clamped, to: device.maxWhiteBalanceGain)
        let values = device.temperatureAndTintValues(for: clamped)
        return Double(values.temperature)
    }

    /// Out-of-range gains crash `setWhiteBalanceModeLocked` — always clamp before applying.
    private static func clamp(_ gains: inout AVCaptureDevice.WhiteBalanceGains, to maxGain: Float) {
        gains.redGain = min(max(gains.redGain, 1.0), maxGain)
        gains.greenGain = min(max(gains.greenGain, 1.0), maxGain)
        gains.blueGain = min(max(gains.blueGain, 1.0), maxGain)
    }
}
