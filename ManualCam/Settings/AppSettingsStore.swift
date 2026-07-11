import Foundation
import Combine

/// UserDefaults-backed settings shown in the Settings sheet (Task 9).
final class AppSettingsStore: ObservableObject {
    private enum Keys {
        static let defaultCaptureFormat = "AppSettingsStore.defaultCaptureFormat"
        static let appleProRAWEnabled = "AppSettingsStore.appleProRAWEnabled"
        static let persistLastUsedValues = "AppSettingsStore.persistLastUsedValues"
    }

    private let defaults: UserDefaults

    @Published var defaultCaptureFormat: CaptureFormat {
        didSet { defaults.set(defaultCaptureFormat.rawValue, forKey: Keys.defaultCaptureFormat) }
    }
    @Published var appleProRAWEnabled: Bool {
        didSet { defaults.set(appleProRAWEnabled, forKey: Keys.appleProRAWEnabled) }
    }
    @Published var persistLastUsedValues: Bool {
        didSet { defaults.set(persistLastUsedValues, forKey: Keys.persistLastUsedValues) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaultCaptureFormat = defaults.string(forKey: Keys.defaultCaptureFormat)
            .flatMap(CaptureFormat.init(rawValue:)) ?? .heicOnly
        appleProRAWEnabled = defaults.bool(forKey: Keys.appleProRAWEnabled)
        persistLastUsedValues = defaults.object(forKey: Keys.persistLastUsedValues) as? Bool ?? true
    }
}
