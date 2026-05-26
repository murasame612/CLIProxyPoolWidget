import Combine
import SwiftUI
import WidgetKit

@main
struct CLIProxyPoolWidgetApp: App {
    @StateObject private var settingsStore: SettingsStore
    @StateObject private var refreshCoordinator: PoolRefreshCoordinator

    init() {
        let settingsStore = SettingsStore.shared
        _settingsStore = StateObject(wrappedValue: settingsStore)
        _refreshCoordinator = StateObject(wrappedValue: PoolRefreshCoordinator(settingsStore: settingsStore))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settingsStore)
                .environmentObject(refreshCoordinator)
                .frame(minWidth: 620, minHeight: 520)
        }
        .windowStyle(.titleBar)
    }
}

@MainActor
final class PoolRefreshCoordinator: ObservableObject {
    @Published var summary: PoolSummary
    @Published var isLoading = false
    @Published var refreshInFlight = false
    @Published var nextRefreshAt: Date?
    @Published var lastMessage: String?

    private let settingsStore: SettingsStore
    private var refreshTimer: Timer?
    private var settingsSubscription: AnyCancellable?
    private var backgroundActivity: NSObjectProtocol?

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        self.summary = SettingsStore.loadSummaryForWidget() ?? .placeholder
        settingsSubscription = settingsStore.$settings
            .sink { [weak self] settings in
                self?.settingsDidChange(settings)
            }

        let settings = Self.sanitize(settingsStore.settings)
        syncSettings(settings)
        if settings.isConfigured {
            Task { await refresh(showSpinner: false) }
        } else {
            updateSchedule(for: settings)
        }
    }

    static func sanitize(_ settings: PoolSettings) -> PoolSettings {
        PoolSettings(
            baseURL: settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            managementKey: settings.managementKey.trimmingCharacters(in: .whitespacesAndNewlines),
            refreshMinutes: max(5, settings.refreshMinutes),
            appRefreshSeconds: max(10, settings.appRefreshSeconds),
            liveRefreshEnabled: settings.liveRefreshEnabled,
            usageAccountLimit: max(1, settings.usageAccountLimit),
            showOnlyCodex: settings.showOnlyCodex,
            plusWeight: max(0.1, settings.plusWeight),
            proLiteWeight: max(0.1, settings.proLiteWeight),
            proWeight: max(0.1, settings.proWeight),
            weeklyKillLinePercent: max(0, settings.weeklyKillLinePercent)
        )
    }

    func saveAndRefresh(_ settings: PoolSettings) async {
        let saved = Self.sanitize(settings)
        settingsStore.settings = saved
        syncSettings(saved)
        lastMessage = "Saved. The widget will refresh shortly."
        await refresh(showSpinner: false)
    }

    func refresh(showSpinner: Bool = true) async {
        guard !refreshInFlight else {
            return
        }

        let settings = Self.sanitize(settingsStore.settings)
        guard settings.isConfigured else {
            summary = .placeholder
            nextRefreshAt = nil
            lastMessage = "Configure the pool URL and management key first."
            updateSchedule(for: settings)
            return
        }

        syncSettings(settings)
        refreshInFlight = true
        if showSpinner {
            isLoading = true
        }
        defer {
            isLoading = false
            refreshInFlight = false
            updateSchedule(for: settings)
        }

        lastMessage = settings.liveRefreshEnabled && !showSpinner ? "Refreshing..." : nil
        let loaded = await PoolSummaryService(client: PoolAPIClient(settings: settings)).loadSummary()
        summary = loaded
        if let error = loaded.errorMessage {
            lastMessage = error
        } else {
            lastMessage = "Fetched \(loaded.totalAccounts) accounts."
            settingsStore.syncSummaryToWidget(loaded)
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    private func settingsDidChange(_ rawSettings: PoolSettings) {
        let settings = Self.sanitize(rawSettings)
        syncSettings(settings)
        updateSchedule(for: settings)
    }

    private func syncSettings(_ settings: PoolSettings) {
        guard settings.isConfigured else {
            return
        }
        settingsStore.syncToWidget(settings)
        WidgetCenter.shared.reloadTimelines(ofKind: "CLIProxyPoolWidget")
    }

    private func updateSchedule(for settings: PoolSettings) {
        refreshTimer?.invalidate()
        refreshTimer = nil

        guard settings.isConfigured, settings.liveRefreshEnabled else {
            nextRefreshAt = nil
            endBackgroundActivity()
            return
        }

        beginBackgroundActivity()
        let interval = TimeInterval(max(10, settings.appRefreshSeconds))
        nextRefreshAt = Date().addingTimeInterval(interval)

        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh(showSpinner: false)
            }
        }
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func beginBackgroundActivity() {
        guard backgroundActivity == nil else {
            return
        }
        backgroundActivity = ProcessInfo.processInfo.beginActivity(
            options: [.background, .automaticTerminationDisabled],
            reason: "Refresh CLIProxy Pool widget data in the background"
        )
    }

    private func endBackgroundActivity() {
        guard let backgroundActivity else {
            return
        }
        ProcessInfo.processInfo.endActivity(backgroundActivity)
        self.backgroundActivity = nil
    }
}
