import SwiftUI

@main
struct CLIProxyPoolWidgetApp: App {
    @StateObject private var settingsStore = SettingsStore.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settingsStore)
                .frame(minWidth: 620, minHeight: 520)
        }
        .windowStyle(.titleBar)
    }
}
