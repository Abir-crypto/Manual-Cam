import Foundation

/// What each shutter press saves. Mutually exclusive — **deviation from spec**: SPEC.md's twin
/// RAW+HEIC-in-one-shot capture is gone per explicit user request ("I don't need them together").
///
/// ProRAW is a *case here* rather than a separate toggle (changed 2026-08-11 on user request: "there
/// is 2 raw settings that I'm seeing … I don't know the difference"). It previously lived as an
/// independent `AppSettingsStore.appleProRAWEnabled` switch shown beside the format picker, which was
/// genuinely confusing: it only did anything when the format was RAW, so in HEIC mode it was a control
/// that silently affected nothing. Folding it in makes the three real outcomes the three options, and
/// makes an inert setting impossible to reach.
enum CaptureFormat: String, CaseIterable, Codable, Identifiable {
    case heic
    /// Bayer RAW — the undemosaiced sensor readout. Note this is the flavour the SDK restricts to an
    /// unzoomed sensor; see `RAWPixelFormatRule`.
    case raw
    /// Apple ProRAW — demosaiced, partially processed, still scene-referred ("Linear DNG"). The only
    /// RAW available on the sensor-crop zoom presets.
    case appleProRAW

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .heic: "HEIC"
        case .raw: "RAW"
        case .appleProRAW: "ProRAW"
        }
    }

    /// True for both RAW flavours — use this rather than `== .raw` anywhere the question is "is this a
    /// RAW capture", or ProRAW will silently take the HEIC path.
    var isRAW: Bool { self != .heic }

    /// Whether to ask the photo output for an Apple ProRAW pixel format. Drives both the per-capture
    /// format choice and the output-level `isAppleProRAWEnabled`, so the two can't diverge.
    var prefersAppleProRAW: Bool { self == .appleProRAW }
}
