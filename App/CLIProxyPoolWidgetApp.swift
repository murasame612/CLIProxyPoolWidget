import SwiftUI
import WidgetKit

@main
struct CLIProxyPoolWidgetApp: App {
    @StateObject private var settingsStore = SettingsStore.shared

    init() {
        let settingsStore = SettingsStore.shared
        if settingsStore.settings.isConfigured {
            settingsStore.syncToWidget(settingsStore.settings)
            WidgetCenter.shared.reloadTimelines(ofKind: "CLIProxyPoolWidget")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settingsStore)
                .frame(minWidth: 620, minHeight: 520)
        }
        .windowStyle(.titleBar)
    }
}
