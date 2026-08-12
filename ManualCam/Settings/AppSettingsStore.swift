import Foundation
import Combine

/// UserDefaults-backed settings shown in the Settings sheet (Task 9).
final class AppSettingsStore: ObservableObject {
    private enum Keys {
        static let defaultCaptureFormat = "AppSettingsStore.defaultCaptureFormat"
        /// Legacy: ProRAW used to be an independent toggle. Read once at launch to migrate an existing
        /// preference into `CaptureFormat.appleProRAW`, then never written again.
        static let legacyAppleProRAWEnabled = "AppSettingsStore.appleProRAWEnabled"
        static let persistLastUsedValues = "AppSettingsStore.persistLastUsedValues"
        static let isPeakingEnabled = "AppSettingsStore.isPeakingEnabled"
        static let timerInitialDelay = "AppSettingsStore.timerInitialDelay"
        static let timerShotCount = "AppSettingsStore.timerShotCount"
        static let timerInterval = "AppSettingsStore.timerInterval"
        static let shootingMode = "AppSettingsStore.shootingMode"
    }

    private let defaults: UserDefaults

    /// The sole source of truth for capture format now — there's no separate top-bar
    /// session override anymore, so this both drives the live capture and persists it.
    @Published var defaultCaptureFormat: CaptureFormat {
        didSet { defaults.set(defaultCaptureFormat.rawValue, forKey: Keys.defaultCaptureFormat) }
    }
    @Published var persistLastUsedValues: Bool {
        didSet { defaults.set(persistLastUsedValues, forKey: Keys.persistLastUsedValues) }
    }
    /// Off by default, but remembered across launches once the user sets it.
    @Published var isPeakingEnabled: Bool {
        didSet { defaults.set(isPeakingEnabled, forKey: Keys.isPeakingEnabled) }
    }
    /// Last-selected top-level shooting mode, restored on launch (`PORTRAIT_MODE.md` Task 1:
    /// "persist last-selected mode across launches"). Restoring Portrait is additionally gated
    /// on hardware at launch — see `CameraCoordinator.handleDeviceAttached`, which falls back to
    /// Manual on a device with no multi-camera support.
    @Published var shootingMode: ShootingMode {
        didSet { defaults.set(shootingMode.rawValue, forKey: Keys.shootingMode) }
    }
    /// Last-used Multi-Shot Timer settings, remembered across launches (same UserDefaults
    /// pattern as the rest of the store). Seeds the timer setup sheet each time it opens.
    @Published var timerConfiguration: TimerConfiguration {
        didSet {
            defaults.set(timerConfiguration.initialDelay, forKey: Keys.timerInitialDelay)
            defaults.set(timerConfiguration.shotCount, forKey: Keys.timerShotCount)
            defaults.set(timerConfiguration.interval, forKey: Keys.timerInterval)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Migration: ProRAW was an independent toggle before it became a `CaptureFormat` case. Someone
        // who was shooting RAW with that toggle on meant "ProRAW", so carry the intent across rather
        // than silently demoting them to Bayer RAW on first launch after the change.
        let storedFormat = defaults.string(forKey: Keys.defaultCaptureFormat)
            .flatMap(CaptureFormat.init(rawValue:)) ?? .heic
        let migratedFormat: CaptureFormat = (storedFormat == .raw && defaults.bool(forKey: Keys.legacyAppleProRAWEnabled))
            ? .appleProRAW
            : storedFormat
        defaultCaptureFormat = migratedFormat
        // `didSet` doesn't fire for an assignment inside `init`, so the migrated value is written here.
        // Without this the migration would re-run harmlessly every launch, but the stored state would
        // stay inconsistent with what the app is actually doing.
        defaults.set(migratedFormat.rawValue, forKey: Keys.defaultCaptureFormat)
        defaults.removeObject(forKey: Keys.legacyAppleProRAWEnabled)
        persistLastUsedValues = defaults.object(forKey: Keys.persistLastUsedValues) as? Bool ?? true
        isPeakingEnabled = defaults.bool(forKey: Keys.isPeakingEnabled)
        // A persisted mode that isn't built yet (Astro) falls back to Manual rather than
        // restoring into a mode with no UI.
        let restoredMode = defaults.string(forKey: Keys.shootingMode).flatMap(ShootingMode.init(rawValue:)) ?? .manual
        shootingMode = restoredMode.isImplemented ? restoredMode : .manual
        timerConfiguration = TimerConfiguration(
            initialDelay: defaults.object(forKey: Keys.timerInitialDelay) as? Int ?? TimerConfiguration.default.initialDelay,
            shotCount: defaults.object(forKey: Keys.timerShotCount) as? Int ?? TimerConfiguration.default.shotCount,
            interval: defaults.object(forKey: Keys.timerInterval) as? Int ?? TimerConfiguration.default.interval
        ).clamped()
    }
}
