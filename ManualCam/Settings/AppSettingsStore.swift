import Foundation
import Combine

/// UserDefaults-backed settings shown in the Settings sheet (Task 9).
final class AppSettingsStore: ObservableObject {
    private enum Keys {
        static let defaultCaptureFormat = "AppSettingsStore.defaultCaptureFormat"
        static let appleProRAWEnabled = "AppSettingsStore.appleProRAWEnabled"
        static let persistLastUsedValues = "AppSettingsStore.persistLastUsedValues"
        static let isPeakingEnabled = "AppSettingsStore.isPeakingEnabled"
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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaultCaptureFormat = defaults.string(forKey: Keys.defaultCaptureFormat)
            .flatMap(CaptureFormat.init(rawValue:)) ?? .heic
        appleProRAWEnabled = defaults.bool(forKey: Keys.appleProRAWEnabled)
        persistLastUsedValues = defaults.object(forKey: Keys.persistLastUsedValues) as? Bool ?? true
        isPeakingEnabled = defaults.bool(forKey: Keys.isPeakingEnabled)
    }
}
