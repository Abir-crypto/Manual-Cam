import CoreMedia
import Foundation

/// Persists last-used manual control values across launches (Task 11).
enum CameraStatePersistenceStore {
    private static let key = "CameraStatePersistenceStore.lastState"

    static func load(from defaults: UserDefaults = .standard) -> PersistedCameraState? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PersistedCameraState.self, from: data)
    }

    static func save(_ state: PersistedCameraState, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: key)
    }

    static let defaultState = PersistedCameraState(
        iso: 100,
        exposureDuration: CMTime(value: 1, timescale: 125),
        lensPosition: 0.5,
        whiteBalanceKelvin: 5600
    )
}
