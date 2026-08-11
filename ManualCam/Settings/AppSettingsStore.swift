import Foundation
import Combine

/// UserDefaults-backed settings shown in the Settings sheet (Task 9).
final class AppSettingsStore: ObservableObject {
    private enum Keys {
        static let defaultCaptureFormat = "AppSettingsStore.defaultCaptureFormat"
        static let appleProRAWEnabled = "AppSettingsStore.appleProRAWEnabled"
        static let persistLastUsedValues = "AppSettingsStore.persistLastUsedValues"
        static let isPeakingEnabled = "AppSettingsStore.isPeakingEnabled"
        static let timerInitialDelay = "AppSettingsStore.timerInitialDelay"
        static let timerShotCount = "AppSettingsStore.timerShotCount"
        static let timerInterval = "AppSettingsStore.timerInterval"
    }

    private let defaults: UserDefaults

    /// The sole source of truth for capture format now — there's no separate top-bar
    /// session override anymore, so this both drives the live capture and persists it.
    @Published var defaultCaptureFormat: CaptureFormat {
        didSet { defaults.set(defaultCaptureFormat.rawValue, forKey: Keys.defaultCaptureFormat) }
    }
    @Published var appleProRAWEnabled: Bool {
        didSet { defaults.set(appleProRAWEnabled, forKey: Keys.appleProRAWEnabled) }
    }
    @Published var persistLastUsedValues: Bool {
        didSet { defaults.set(persistLastUsedValues, forKey: Keys.persistLastUsedValues) }
    }
    /// Off by default, but remembered across launches once the user sets it.
    @Published var isPeakingEnabled: Bool {
        didSet { defaults.set(isPeakingEnabled, forKey: Keys.isPeakingEnabled) }
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
        defaultCaptureFormat = defaults.string(forKey: Keys.defaultCaptureFormat)
            .flatMap(CaptureFormat.init(rawValue:)) ?? .heic
        appleProRAWEnabled = defaults.bool(forKey: Keys.appleProRAWEnabled)
        persistLastUsedValues = defaults.object(forKey: Keys.persistLastUsedValues) as? Bool ?? true
        isPeakingEnabled = defaults.bool(forKey: Keys.isPeakingEnabled)
        timerConfiguration = TimerConfiguration(
            initialDelay: defaults.object(forKey: Keys.timerInitialDelay) as? Int ?? TimerConfiguration.default.initialDelay,
            shotCount: defaults.object(forKey: Keys.timerShotCount) as? Int ?? TimerConfiguration.default.shotCount,
            interval: defaults.object(forKey: Keys.timerInterval) as? Int ?? TimerConfiguration.default.interval
        ).clamped()
    }
}
