import AVFoundation
import CoreGraphics
import Foundation

/// Picks the RAW pixel format for a capture, and encodes the one SDK rule that makes this
/// non-obvious: **the `videoZoomFactor == 1.0` requirement applies to Bayer RAW only, not to Apple
/// ProRAW.**
///
/// From `AVCapturePhotoOutput.capturePhoto(with:delegate:)`'s documented validation rules, which
/// throw `NSInvalidArgumentException` when violated:
/// - *Bayer RAW rules*: "the videoZoomFactor of the source device and the videoScaleAndCropFactor of
///   the photo output's video connection must both be 1.0. Ensure no zoom is applied before
///   requesting a RAW capture" — and `photoQualityPrioritization` must be `.speed`, which this app
///   always uses in Manual mode.
/// - *Apple ProRAW rules*: no zoom restriction at all.
///
/// This exists as a single shared rule because two places need the same answer and must not diverge:
/// the capture path (which format to request) and the UI (whether to warn that RAW isn't available
/// here). Getting it wrong crashes the app rather than failing softly.
enum RAWPixelFormatRule {
    /// Bayer RAW requires an unzoomed sensor readout. Compared exactly against 1.0 because that's how
    /// the rule is written, and because the app only ever assigns discrete preset values (1.0, or a
    /// lens's own secondary native factor) rather than arbitrary continuous zoom.
    static func isBayerRAWLegal(atVideoZoomFactor videoZoomFactor: CGFloat) -> Bool {
        videoZoomFactor == 1.0
    }

    /// The RAW format to request, or nil when RAW isn't possible in the current configuration — in
    /// which case the caller should fall back to a processed capture rather than throw.
    ///
    /// **The ordering here is the crash fix.** `availableRawPhotoPixelFormatTypes` lists ProRAW
    /// formats *after* any Bayer ones (per the SDK: "These formats will be added to
    /// -availableRawPhotoPixelFormatTypes after any existing Bayer RAW formats"), so `.first` is the
    /// **Bayer** format whenever one exists. The previous code fell back to `.first` when no ProRAW
    /// format was found, which handed a Bayer format to a zoomed capture on the 2×/8× sensor-crop
    /// presets and threw.
    static func preferredPixelFormat(
        availableFormats: [OSType],
        preferAppleProRAW: Bool,
        videoZoomFactor: CGFloat
    ) -> OSType? {
        // ProRAW when the user asked for it: no zoom restriction, so it's valid at every preset. Note
        // the output only reports ProRAW formats while `isAppleProRAWEnabled` is set, so this can't
        // hand back ProRAW against the user's preference.
        if preferAppleProRAW,
           let proRAWFormat = availableFormats.first(where: { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }) {
            return proRAWFormat
        }

        // Otherwise only Bayer is on the table, and only when unzoomed.
        guard isBayerRAWLegal(atVideoZoomFactor: videoZoomFactor) else { return nil }
        return availableFormats.first(where: { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) })
            ?? availableFormats.first
    }

    /// Whether a RAW capture is possible at all right now — same rule as `preferredPixelFormat`, so the
    /// warning the UI shows can never disagree with what the capture actually does.
    static func isRAWAvailable(
        availableFormats: [OSType],
        preferAppleProRAW: Bool,
        videoZoomFactor: CGFloat
    ) -> Bool {
        preferredPixelFormat(
            availableFormats: availableFormats,
            preferAppleProRAW: preferAppleProRAW,
            videoZoomFactor: videoZoomFactor
        ) != nil
    }
}
