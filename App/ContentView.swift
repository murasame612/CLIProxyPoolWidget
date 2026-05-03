import SwiftUI
import WidgetKit

struct ContentView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    private let liveTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var draft = PoolSettings.empty
    @State private var summary = PoolSummary.placeholder
    @State private var isLoading = false
    @State private var refreshInFlight = false
    @State private var nextLiveRefreshAt: Date?
    @State private var lastMessage: String?
    @State private var hasLoadedSettings = false

    var body: some View {
        NavigationSplitView {
            Form {
                Section("Connection") {
                    TextField("Pool URL", text: $draft.baseURL)
                        .textFieldStyle(.roundedBorder)
                    SecureField("Management key", text: $draft.managementKey)
                        .textFieldStyle(.roundedBorder)
                }

                Section("Widget") {
                    Stepper("Refresh: \(draft.refreshMinutes) min", value: $draft.refreshMinutes, in: 5...60, step: 5)
                    Stepper("Usage accounts: \(draft.usageAccountLimit)", value: $draft.usageAccountLimit, in: 1...32)
                    Toggle("Show Codex/OpenAI accounts only", isOn: $draft.showOnlyCodex)
                }

                Section("App Live Mode") {
                    Toggle("Live refresh", isOn: $draft.liveRefreshEnabled)
                    Stepper("Interval: \(draft.appRefreshSeconds)s", value: $draft.appRefreshSeconds, in: 10...300, step: 5)
                    if draft.liveRefreshEnabled, let nextLiveRefreshAt {
                        Text("Next refresh \(nextLiveRefreshAt.formatted(date: .omitted, time: .standard))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Plan Weights") {
                    Stepper("Plus: \(formatWeight(draft.plusWeight))x", value: $draft.plusWeight, in: 0.1...100, step: 0.1)
                    Stepper("Pro Lite: \(formatWeight(draft.proLiteWeight))x", value: $draft.proLiteWeight, in: 0.1...100, step: 0.5)
                    Stepper("Pro: \(formatWeight(draft.proWeight))x", value: $draft.proWeight, in: 0.1...100, step: 0.5)
                    Stepper("Week kill line: \(formatWeight(draft.weeklyKillLinePercent))%", value: $draft.weeklyKillLinePercent, in: 0...20, step: 0.5)
                }

                HStack {
                    Button("Save") {
                        let saved = sanitized(draft)
                        draft = saved
                        settingsStore.syncToWidget(saved)
                        WidgetCenter.shared.reloadAllTimelines()
                        lastMessage = "Saved. The widget will refresh shortly."
                        Task { await refreshSummary(showSpinner: false) }
                    }
                    .keyboardShortcut(.defaultAction)

                    Button("Test Fetch") {
                        Task { await refreshSummary() }
                    }
                    .disabled(refreshInFlight || !draft.isConfigured)
                }

                if let lastMessage {
                    Text(lastMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .navigationSplitViewColumnWidth(min: 280, ideal: 320)
        } detail: {
            SummaryView(summary: summary, isLoading: isLoading)
                .padding()
        }
        .onAppear {
            draft = settingsStore.settings
            hasLoadedSettings = true
            if draft.liveRefreshEnabled, draft.isConfigured {
                nextLiveRefreshAt = Date()
            }
            Task { await refreshSummary() }
        }
        .onChange(of: draft) { _, newValue in
            guard hasLoadedSettings else {
                return
            }
            settingsStore.settings = newValue
        }
        .onChange(of: draft.liveRefreshEnabled) { _, isEnabled in
            if isEnabled {
                nextLiveRefreshAt = Date()
            } else {
                nextLiveRefreshAt = nil
            }
        }
        .onChange(of: draft.appRefreshSeconds) { _, _ in
            if draft.liveRefreshEnabled {
                nextLiveRefreshAt = Date().addingTimeInterval(TimeInterval(max(10, sanitized(draft).appRefreshSeconds)))
            }
        }
        .onReceive(liveTimer) { now in
            guard draft.liveRefreshEnabled, draft.isConfigured else {
                return
            }

            if nextLiveRefreshAt == nil {
                nextLiveRefreshAt = now
            }

            guard let nextLiveRefreshAt, now >= nextLiveRefreshAt, !refreshInFlight else {
                return
            }

            Task { await refreshSummary(showSpinner: false) }
        }
    }

    private func sanitized(_ settings: PoolSettings) -> PoolSettings {
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

    @MainActor
    private func refreshSummary(showSpinner: Bool = true) async {
        guard !refreshInFlight else {
            return
        }
        let settings = sanitized(draft)
        guard settings.isConfigured else {
            summary = .placeholder
            nextLiveRefreshAt = nil
            lastMessage = "Configure the pool URL and management key first."
            return
        }
        refreshInFlight = true
        if showSpinner {
            isLoading = true
        }
        defer {
            isLoading = false
            refreshInFlight = false
        }

        lastMessage = settings.liveRefreshEnabled && !showSpinner ? "Refreshing..." : nil
        let loaded = await PoolSummaryService(client: PoolAPIClient(settings: settings)).loadSummary()
        summary = loaded
        if let error = loaded.errorMessage {
            lastMessage = error
        } else {
            lastMessage = "Fetched \(loaded.totalAccounts) accounts."
        }
        if settings.liveRefreshEnabled {
            nextLiveRefreshAt = Date().addingTimeInterval(TimeInterval(max(10, settings.appRefreshSeconds)))
        }
    }

    private func formatWeight(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}

struct SummaryView: View {
    let summary: PoolSummary
    let isLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("CLIProxy Pool")
                    .font(.largeTitle.bold())
                Spacer()
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let error = summary.errorMessage {
                ContentUnavailableView("Fetch failed", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if summary.totalAccounts == 0 {
                ContentUnavailableView("No data yet", systemImage: "chart.bar", description: Text("Save settings and test the connection."))
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Plus-base balance")
                        .font(.headline)
                    BalanceStack(
                        primaryText: "\(formatPercent(summary.primaryRemainingPercent))% / \(formatPercent(summary.primaryCapacityPercent))%",
                        primaryValue: summary.primaryRemainingUnits,
                        primaryTotal: max(summary.primaryCapacityUnits, 1),
                        primaryHint: summary.nextPrimaryResetHint,
                        weeklyText: "\(formatPercent(summary.weeklyRemainingPercent))% / \(formatPercent(summary.weeklyCapacityPercent))%",
                        weeklyValue: summary.weeklyRemainingUnits,
                        weeklyTotal: max(summary.weeklyCapacityUnits, 1),
                        weeklyHint: summary.nextWeeklyResetHint
                    )
                    PlanBreakdownView(breakdown: summary.planBreakdown)
                }

                HStack(spacing: 12) {
                    MetricTile(title: "Available", value: "\(summary.availableAccounts)/\(summary.totalAccounts)", systemImage: "checkmark.circle.fill", color: .green)
                    MetricTile(title: "Cooling", value: "\(summary.coolingAccounts)", systemImage: "clock.fill", color: .orange)
                    MetricTile(title: "Recent failed", value: "\(summary.failedRecentRequests)", systemImage: "xmark.octagon.fill", color: .red)
                }

                List(summary.accounts) { account in
                    AccountRow(account: account)
                }
                .listStyle(.inset)
            }

            Spacer()
            Text("Updated \(summary.generatedAt.formatted(date: .omitted, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func formatPercent(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}

struct MetricTile: View {
    let title: String
    let value: String
    let systemImage: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
            Text(value)
                .font(.title.bold())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct AccountRow: View {
    let account: AccountUsage

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(account.isAvailable ? Color.green : Color.orange)
                .frame(width: 9, height: 9)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(account.name)
                        .font(.headline)
                        .lineLimit(1)
                    PlanBadge(planType: account.planType, weight: account.weight)
                }
                Text(account.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                UsageStack(account: account)
                if let primaryReset = account.usage?.primaryResetText,
                   let weeklyReset = account.usage?.weeklyResetText {
                    Text("5h \(primaryReset) · week \(weeklyReset)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if account.error != nil {
                    Text("api-call failed")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct PlanBreakdownView: View {
    let breakdown: [PlanBreakdown]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(breakdown, id: \.planType) { item in
                HStack(spacing: 6) {
                    PlanDot(planType: item.planType)
                    Text("\(PlanType.displayName(item.planType)) x\(item.count)")
                    Text("5h \(formatPercent(item.primaryWeightedPercent))% · W \(formatPercent(item.weightedPercent))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private func formatPercent(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}

struct BalanceStack: View {
    let primaryText: String
    let primaryValue: Double
    let primaryTotal: Double
    let primaryHint: QuotaResetHint?
    let weeklyText: String
    let weeklyValue: Double
    let weeklyTotal: Double
    let weeklyHint: QuotaResetHint?

    var body: some View {
        VStack(spacing: 8) {
            BalanceLine(
                label: "5h",
                valueText: primaryText,
                value: primaryValue,
                total: primaryTotal,
                hint: primaryHint
            )
            BalanceLine(
                label: "Week",
                valueText: weeklyText,
                value: weeklyValue,
                total: weeklyTotal,
                hint: weeklyHint
            )
        }
    }
}

struct BalanceLine: View {
    let label: String
    let valueText: String
    let value: Double
    let total: Double
    let hint: QuotaResetHint?

    var ratio: Double {
        max(0, min(1, value / max(total, 0.01)))
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .leading)
            BalanceProgressBar(value: value, total: total, hint: hint, restoreColor: restoreColor)
            ResetHintText(hint: hint, color: restoreColor)
            Text(valueText)
                .font(.headline.monospacedDigit())
                .foregroundStyle(UsageColor.color(forRemainingPercent: ratio * 100))
                .frame(width: 132, alignment: .trailing)
        }
    }

    private var restoreColor: Color {
        label == "5h" ? Color(red: 0.22, green: 0.72, blue: 0.95) : Color(red: 0.72, green: 0.52, blue: 0.95)
    }
}

struct ResetHintText: View {
    let hint: QuotaResetHint?
    let color: Color

    var body: some View {
        if let hint {
            Text("+\(QuotaResetHint.format(hint.restoredPercent))% in \(hint.timeText)")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 96, alignment: .trailing)
        } else {
            Color.clear
                .frame(width: 96)
        }
    }
}

struct UsageStack: View {
    let account: AccountUsage

    var body: some View {
        VStack(alignment: .trailing, spacing: 5) {
            UsageLine(
                label: "5h",
                remainingPercent: account.usage?.primaryRemainingPercent,
                text: account.isWeekKilled ? "weekKILL" : account.effectivePrimaryCompactText,
                isMuted: account.isWeekKilled
            )
            UsageLine(label: "Week", remainingPercent: account.effectiveWeeklyRemainingPercent, text: account.effectiveWeeklyCompactText)
        }
    }
}

struct UsageLine: View {
    let label: String
    let remainingPercent: Double?
    let text: String
    var isMuted = false

    var value: Double {
        max(0, min(100, remainingPercent ?? 0))
    }

    var body: some View {
        HStack(spacing: 7) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .leading)
            InlineUsageBar(remainingPercent: remainingPercent, isMuted: isMuted)
            Text(text)
                .font(.caption.monospacedDigit())
                .foregroundStyle(isMuted ? .secondary : UsageColor.color(forRemainingPercent: value))
                .frame(width: 76, alignment: .trailing)
        }
    }
}

struct BalanceProgressBar: View {
    let value: Double
    let total: Double
    let hint: QuotaResetHint?
    let restoreColor: Color

    var ratio: Double {
        max(0, min(1, value / max(total, 0.01)))
    }

    var targetRatio: Double {
        guard let hint else {
            return ratio
        }
        return max(ratio, min(1, hint.targetUnits / max(total, 0.01)))
    }

    var body: some View {
        GeometryReader { proxy in
            let currentWidth = proxy.size.width * ratio
            let targetWidth = proxy.size.width * targetRatio
            let restoreWidth = max(0, targetWidth - currentWidth)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                if restoreWidth > 0.5 {
                    Capsule()
                        .fill(restoreColor.opacity(0.62))
                        .frame(width: max(8, targetWidth))
                }
                Capsule()
                    .fill(UsageColor.color(forRemainingPercent: ratio * 100))
                    .frame(width: max(8, currentWidth))
            }
            .clipShape(Capsule())
        }
        .frame(height: 16)
    }
}

struct InlineUsageBar: View {
    let remainingPercent: Double?
    var isMuted = false

    var value: Double {
        max(0, min(100, remainingPercent ?? 0))
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                Capsule()
                    .fill(isMuted ? Color.secondary.opacity(0.45) : UsageColor.color(forRemainingPercent: value))
                    .frame(width: max(6, proxy.size.width * value / 100))
            }
        }
        .frame(width: 90, height: 7)
    }
}

struct PlanBadge: View {
    let planType: String?
    let weight: Double

    var body: some View {
        HStack(spacing: 4) {
            PlanDot(planType: planType)
            Text(PlanType.displayName(planType))
            Text("\(formatWeight(weight))x")
                .foregroundStyle(.secondary)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(PlanStyle.color(for: planType).opacity(0.16), in: Capsule())
        .overlay {
            Capsule()
                .stroke(PlanStyle.color(for: planType).opacity(0.36), lineWidth: 1)
        }
        .shadow(color: PlanStyle.glow(for: planType), radius: 8)
    }

    private func formatWeight(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}

struct PlanDot: View {
    let planType: String?

    var body: some View {
        Circle()
            .fill(PlanStyle.color(for: planType))
            .frame(width: 7, height: 7)
            .shadow(color: PlanStyle.glow(for: planType), radius: 5)
    }
}

enum UsageColor {
    static func color(forRemainingPercent percent: Double) -> Color {
        switch percent {
        case ..<20:
            return .red
        case ..<70:
            return .yellow
        default:
            return .green
        }
    }
}

enum PlanStyle {
    static func color(for planType: String?) -> Color {
        switch PlanType.normalize(planType) {
        case "pro":
            return Color(red: 1.0, green: 0.72, blue: 0.18)
        case "prolite", "pro_lite", "pro-lite":
            return Color(red: 0.94, green: 0.64, blue: 0.22)
        default:
            return Color(red: 0.26, green: 0.56, blue: 1.0)
        }
    }

    static func glow(for planType: String?) -> Color {
        PlanType.normalize(planType) == "pro" ? color(for: planType).opacity(0.65) : .clear
    }
}

extension PoolSummary {
    var primaryCapacityPercent: Double {
        primaryCapacityUnits * 100
    }

    var weeklyCapacityPercent: Double {
        weeklyCapacityUnits * 100
    }

    var primaryCapacityRelativeRemainingPercent: Double {
        guard primaryCapacityUnits > 0 else {
            return 0
        }
        return max(0, min(100, primaryRemainingUnits / primaryCapacityUnits * 100))
    }

    var capacityRelativeRemainingPercent: Double {
        guard weeklyCapacityUnits > 0 else {
            return 0
        }
        return max(0, min(100, weeklyRemainingUnits / weeklyCapacityUnits * 100))
    }
}
