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
    private nonisolated static let settingsKey = "poolWatch.settings"
    private nonisolated static let summaryKey = "poolWatch.summary"
    private nonisolated static let settingsFileName = "poolWatch-settings.json"
    private nonisolated static let summaryFileName = "poolWatch-summary.json"
    private nonisolated static let widgetExtensionBundleID = "com.zipwuu.CLIProxyPoolWidget.WidgetExtension"
    private nonisolated static let widgetBridgeDirectoryName = "CLIProxyPoolWidget"
    private let key = SettingsStore.settingsKey

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
        guard let data = try? JSONEncoder().encode(settings) else {
            return false
        }

        var didSync = Self.writeToWidgetBridgeFile(data, named: Self.settingsFileName)
        if Self.writeToSharedFile(data, named: Self.settingsFileName) {
            didSync = true
        }
        if let widgetDefaults = Self.groupDefaults() {
            widgetDefaults.set(data, forKey: key)
            widgetDefaults.synchronize()
            didSync = true
        }
        return didSync
    }

    @discardableResult
    func syncSummaryToWidget(_ summary: PoolSummary) -> Bool {
        Self.saveSummaryForWidget(summary)
    }

    nonisolated static func loadForWidget() -> PoolSettings {
        if let settings = loadFromWidgetBridgeFile(PoolSettings.self, named: settingsFileName) {
            return settings
        }
        if let settings = loadFromSharedFile(PoolSettings.self, named: settingsFileName) {
            return settings
        }
        let defaults = groupDefaults() ?? .standard
        return load(from: defaults, key: settingsKey)
    }

    @discardableResult
    nonisolated static func saveSummaryForWidget(_ summary: PoolSummary) -> Bool {
        guard let data = try? JSONEncoder().encode(summary) else {
            return false
        }

        var didSync = writeToWidgetBridgeFile(data, named: summaryFileName)
        if writeToSharedFile(data, named: summaryFileName) {
            didSync = true
        }
        if let defaults = groupDefaults() {
            defaults.set(data, forKey: summaryKey)
            defaults.synchronize()
            didSync = true
        }
        return didSync
    }

    nonisolated static func loadSummaryForWidget() -> PoolSummary? {
        if let summary = loadFromWidgetBridgeFile(PoolSummary.self, named: summaryFileName) {
            return summary
        }
        if let summary = loadFromSharedFile(PoolSummary.self, named: summaryFileName) {
            return summary
        }
        guard let defaults = groupDefaults(),
              let data = defaults.data(forKey: summaryKey),
              let decoded = try? JSONDecoder().decode(PoolSummary.self, from: data)
        else {
            return nil
        }
        return decoded
    }

    private static func loadForApp(from defaults: UserDefaults, key: String) -> PoolSettings {
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(PoolSettings.self, from: data) {
            return decoded
        }

        if let migrated = loadFromWidgetBridgeFile(PoolSettings.self, named: settingsFileName) {
            if let data = try? JSONEncoder().encode(migrated) {
                defaults.set(data, forKey: key)
            }
            return migrated
        }

        if let migrated = loadFromSharedFile(PoolSettings.self, named: settingsFileName) {
            if let data = try? JSONEncoder().encode(migrated) {
                defaults.set(data, forKey: key)
            }
            return migrated
        }

        guard let groupDefaults = groupDefaults() else {
            return .empty
        }
        let migrated = load(from: groupDefaults, key: key)
        if migrated != .empty, let data = try? JSONEncoder().encode(migrated) {
            defaults.set(data, forKey: key)
            writeToWidgetBridgeFile(data, named: settingsFileName)
            writeToSharedFile(data, named: settingsFileName)
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

    private nonisolated static func groupDefaults() -> UserDefaults? {
        guard !PoolWatchConstants.appGroupID.isEmpty else {
            return nil
        }
        return UserDefaults(suiteName: PoolWatchConstants.appGroupID)
    }

    private nonisolated static func sharedFileURL(named fileName: String) -> URL? {
        guard !PoolWatchConstants.appGroupID.isEmpty else {
            return nil
        }
        return FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: PoolWatchConstants.appGroupID)?
            .appendingPathComponent(fileName, isDirectory: false)
    }

    private nonisolated static func widgetBridgeDirectoryURL() -> URL? {
        if Bundle.main.bundleIdentifier == widgetExtensionBundleID {
            return FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first?
                .appendingPathComponent(widgetBridgeDirectoryName, isDirectory: true)
        }

        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Containers", isDirectory: true)
            .appendingPathComponent(widgetExtensionBundleID, isDirectory: true)
            .appendingPathComponent("Data", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(widgetBridgeDirectoryName, isDirectory: true)
    }

    private nonisolated static func widgetBridgeFileURL(named fileName: String) -> URL? {
        widgetBridgeDirectoryURL()?.appendingPathComponent(fileName, isDirectory: false)
    }

    @discardableResult
    private nonisolated static func writeToSharedFile(_ data: Data, named fileName: String) -> Bool {
        guard let url = sharedFileURL(named: fileName) else {
            return false
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    private nonisolated static func writeToWidgetBridgeFile(_ data: Data, named fileName: String) -> Bool {
        guard let url = widgetBridgeFileURL(named: fileName) else {
            return false
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    private nonisolated static func loadFromSharedFile<Value: Decodable>(_ type: Value.Type, named fileName: String) -> Value? {
        guard let url = sharedFileURL(named: fileName),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Value.self, from: data)
        else {
            return nil
        }
        return decoded
    }

    private nonisolated static func loadFromWidgetBridgeFile<Value: Decodable>(_ type: Value.Type, named fileName: String) -> Value? {
        guard let url = widgetBridgeFileURL(named: fileName),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Value.self, from: data)
        else {
            return nil
        }
        return decoded
    }
}
