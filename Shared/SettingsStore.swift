import Combine
import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    @Published var settings: PoolSettings {
        didSet {
            saveForApp(settings)
        }
    }

    static let shared = SettingsStore()

    private let appDefaults: UserDefaults
    private let key = "poolWatch.settings"

    init(defaults: UserDefaults = .standard) {
        self.appDefaults = defaults
        self.settings = Self.loadForApp(from: defaults, key: key)
    }

    func reload() {
        settings = Self.loadForApp(from: appDefaults, key: key)
    }

    func saveForApp(_ settings: PoolSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            appDefaults.set(data, forKey: key)
        }
    }

    @discardableResult
    func syncToWidget(_ settings: PoolSettings) -> Bool {
        saveForApp(settings)
        guard let widgetDefaults = UserDefaults(suiteName: PoolWatchConstants.appGroupID),
              let data = try? JSONEncoder().encode(settings)
        else {
            return false
        }
        widgetDefaults.set(data, forKey: key)
        return true
    }

    nonisolated static func loadForWidget() -> PoolSettings {
        let defaults = UserDefaults(suiteName: PoolWatchConstants.appGroupID) ?? .standard
        return load(from: defaults, key: "poolWatch.settings")
    }

    private static func loadForApp(from defaults: UserDefaults, key: String) -> PoolSettings {
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(PoolSettings.self, from: data) {
            return decoded
        }

        guard let groupDefaults = UserDefaults(suiteName: PoolWatchConstants.appGroupID) else {
            return .empty
        }
        let migrated = load(from: groupDefaults, key: key)
        if migrated != .empty, let data = try? JSONEncoder().encode(migrated) {
            defaults.set(data, forKey: key)
        }
        return migrated
    }

    private nonisolated static func load(from defaults: UserDefaults, key: String) -> PoolSettings {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(PoolSettings.self, from: data)
        else {
            return .empty
        }
        return decoded
    }
}
