import SwiftUI
import WidgetKit

struct PoolEntry: TimelineEntry {
    let date: Date
    let summary: PoolSummary
    let settingsConfigured: Bool
}

struct PoolProvider: TimelineProvider {
    func placeholder(in context: Context) -> PoolEntry {
        PoolEntry(date: Date(), summary: .placeholder, settingsConfigured: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (PoolEntry) -> Void) {
        let settings = SettingsStore.loadForWidget()
        guard settings.isConfigured else {
            completion(PoolEntry(date: Date(), summary: .placeholder, settingsConfigured: false))
            return
        }

        let completionBox = SendableCompletion(completion)
        Task {
            let summary = await PoolSummaryService(client: PoolAPIClient(settings: settings)).loadSummary()
            completionBox.call(PoolEntry(date: Date(), summary: summary, settingsConfigured: true))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PoolEntry>) -> Void) {
        let settings = SettingsStore.loadForWidget()
        guard settings.isConfigured else {
            let entry = PoolEntry(date: Date(), summary: .placeholder, settingsConfigured: false)
            completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(5 * 60))))
            return
        }

        let completionBox = SendableCompletion(completion)
        Task {
            let summary = await PoolSummaryService(client: PoolAPIClient(settings: settings)).loadSummary()
            let entry = PoolEntry(date: Date(), summary: summary, settingsConfigured: true)
            let minutes = max(5, settings.refreshMinutes)
            completionBox.call(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(TimeInterval(minutes * 60)))))
        }
    }
}

final class SendableCompletion<Value>: @unchecked Sendable {
    private let completion: (Value) -> Void

    init(_ completion: @escaping (Value) -> Void) {
        self.completion = completion
    }

    func call(_ value: Value) {
        completion(value)
    }
}

struct PoolWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PoolEntry

    var body: some View {
        if !entry.settingsConfigured {
            WidgetMessageView(title: "CLIProxy Pool", message: "Open the app to configure the pool URL and key.", systemImage: "gearshape")
        } else if let error = entry.summary.errorMessage {
            WidgetMessageView(title: "Fetch failed", message: error, systemImage: "exclamationmark.triangle")
        } else {
            switch family {
            case .systemSmall:
                SmallPoolView(summary: entry.summary)
            case .systemMedium:
                MediumPoolView(summary: entry.summary)
            default:
                LargePoolView(summary: entry.summary)
            }
        }
    }
}

struct SmallPoolView: View {
    let summary: PoolSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HeaderView(date: summary.generatedAt)
            Spacer()
            Text("\(formatPercent(summary.primaryRemainingPercent))/\(formatPercent(summary.primaryCapacityPercent))%")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.7)
                .monospacedDigit()
                .foregroundStyle(WidgetUsageColor.color(forRemainingPercent: summary.primaryCapacityRelativeRemainingPercent))
            Text("5h balance")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            WidgetBalanceStack(summary: summary, compact: true)
        }
        .containerBackground(.background, for: .widget)
    }

    private func formatPercent(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}

struct MediumPoolView: View {
    let summary: PoolSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HeaderView(date: summary.generatedAt)
            HStack(spacing: 12) {
                Gauge(value: summary.primaryRemainingUnits, in: 0...max(summary.primaryCapacityUnits, 1)) {
                    Text("Balance")
                } currentValueLabel: {
                    Text("\(formatPercent(summary.primaryRemainingPercent))%")
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .tint(WidgetUsageColor.color(forRemainingPercent: summary.primaryCapacityRelativeRemainingPercent))

                VStack(alignment: .leading, spacing: 6) {
                    Text("Plus-base")
                        .font(.title3.bold())
                    WidgetBalanceStack(summary: summary, compact: false)
                }

                Spacer()
            }
            AccountList(accounts: Array(summary.accounts.prefix(2)))
        }
        .containerBackground(.background, for: .widget)
    }

    private func formatPercent(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}

struct LargePoolView: View {
    let summary: PoolSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HeaderView(date: summary.generatedAt)
            HStack(spacing: 12) {
                StatPill(title: "5h", value: "\(formatPercent(summary.primaryRemainingPercent))/\(formatPercent(summary.primaryCapacityPercent))%", color: WidgetUsageColor.color(forRemainingPercent: summary.primaryCapacityRelativeRemainingPercent))
                StatPill(title: "Week", value: "\(formatPercent(summary.weeklyRemainingPercent))/\(formatPercent(summary.weeklyCapacityPercent))%", color: WidgetUsageColor.color(forRemainingPercent: summary.capacityRelativeRemainingPercent))
                StatPill(title: "Ready", value: "\(summary.availableAccounts)/\(summary.totalAccounts)", color: .green)
            }
            WidgetBalanceStack(summary: summary, compact: false)
            WidgetPlanBreakdownView(breakdown: summary.planBreakdown)
            AccountList(accounts: Array(summary.accounts.prefix(6)))
            Spacer(minLength: 0)
        }
        .containerBackground(.background, for: .widget)
    }

    private func formatPercent(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}

struct HeaderView: View {
    let date: Date

    var body: some View {
        HStack {
            Label("CLIProxy Pool", systemImage: "switch.2")
                .font(.headline)
            Spacer()
            Text(date, style: .time)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

struct StatusStrip: View {
    let summary: PoolSummary

    var body: some View {
        HStack(spacing: 8) {
            Label("\(formatPercent(summary.primaryRemainingPercent))%", systemImage: "bolt.fill")
            Label("\(formatPercent(summary.weeklyRemainingPercent))%", systemImage: "chart.bar.fill")
            Label("\(summary.coolingAccounts)", systemImage: "clock")
            Label("\(summary.failedRecentRequests)", systemImage: "xmark.octagon")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func formatPercent(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}

struct AccountList: View {
    let accounts: [AccountUsage]

    var body: some View {
        VStack(spacing: 6) {
            ForEach(accounts) { account in
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            WidgetPlanDot(planType: account.planType)
                            Text(account.name)
                                .font(.caption)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 6)
                    VStack(alignment: .trailing, spacing: 3) {
                        WidgetUsageLine(
                            label: "5h",
                            remainingPercent: account.usage?.primaryRemainingPercent,
                            text: account.isWeekKilled ? "weekKILL" : account.effectivePrimaryCompactText,
                            isMuted: account.isWeekKilled
                        )
                        WidgetUsageLine(label: "Week", remainingPercent: account.effectiveWeeklyRemainingPercent, text: account.effectiveWeeklyCompactText)
                    }
                }
            }
        }
    }
}

struct WidgetPlanBreakdownView: View {
    let breakdown: [PlanBreakdown]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(breakdown, id: \.planType) { item in
                HStack(spacing: 4) {
                    WidgetPlanDot(planType: item.planType)
                    Text("\(PlanType.displayName(item.planType)) x\(item.count)")
                        .lineLimit(1)
                    Text("5h \(formatPercent(item.primaryWeightedPercent))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.caption2.weight(.semibold))
            }
            Spacer(minLength: 0)
        }
    }

    private func formatPercent(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}

struct WidgetBalanceStack: View {
    let summary: PoolSummary
    let compact: Bool

    var body: some View {
        VStack(spacing: compact ? 5 : 6) {
            WidgetBalanceLine(
                label: "5h",
                valueText: "\(formatPercent(summary.primaryRemainingPercent))/\(formatPercent(summary.primaryCapacityPercent))%",
                value: summary.primaryRemainingUnits,
                total: max(summary.primaryCapacityUnits, 1),
                hint: summary.nextPrimaryResetHint,
                compact: compact
            )
            WidgetBalanceLine(
                label: "Week",
                valueText: "\(formatPercent(summary.weeklyRemainingPercent))/\(formatPercent(summary.weeklyCapacityPercent))%",
                value: summary.weeklyRemainingUnits,
                total: max(summary.weeklyCapacityUnits, 1),
                hint: summary.nextWeeklyResetHint,
                compact: compact
            )
        }
    }

    private func formatPercent(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}

struct WidgetBalanceLine: View {
    let label: String
    let valueText: String
    let value: Double
    let total: Double
    let hint: QuotaResetHint?
    let compact: Bool

    var ratio: Double {
        max(0, min(1, value / max(total, 0.01)))
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: compact ? 30 : 34, alignment: .leading)
            WidgetBalanceBar(value: value, total: total, hint: hint, restoreColor: restoreColor, compact: compact)
            WidgetResetHintText(hint: hint, color: restoreColor, compact: compact)
            Text(valueText)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(WidgetUsageColor.color(forRemainingPercent: ratio * 100))
                .minimumScaleFactor(0.7)
                .frame(width: compact ? 58 : 76, alignment: .trailing)
        }
    }

    private var restoreColor: Color {
        label == "5h" ? Color(red: 0.22, green: 0.72, blue: 0.95) : Color(red: 0.72, green: 0.52, blue: 0.95)
    }
}

struct WidgetResetHintText: View {
    let hint: QuotaResetHint?
    let color: Color
    let compact: Bool

    var body: some View {
        if let hint {
            Text(compact ? "+\(QuotaResetHint.format(hint.restoredPercent))" : "+\(QuotaResetHint.format(hint.restoredPercent))% \(hint.timeText)")
                .font(.caption2.weight(.bold).monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(width: compact ? 34 : 62, alignment: .trailing)
        } else {
            Color.clear
                .frame(width: compact ? 34 : 62)
        }
    }
}

struct WidgetBalanceBar: View {
    let value: Double
    let total: Double
    let hint: QuotaResetHint?
    let restoreColor: Color
    let compact: Bool

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
                    .fill(WidgetUsageColor.color(forRemainingPercent: ratio * 100))
                    .frame(width: max(8, currentWidth))
            }
            .clipShape(Capsule())
        }
        .frame(height: compact ? 12 : 14)
    }
}

struct WidgetUsageLine: View {
    let label: String
    let remainingPercent: Double?
    let text: String
    var isMuted = false

    var value: Double {
        max(0, min(100, remainingPercent ?? 0))
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .leading)
            WidgetMiniBar(remainingPercent: remainingPercent, isMuted: isMuted)
            Text(text)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(isMuted ? .secondary : WidgetUsageColor.color(forRemainingPercent: value))
                .frame(width: 58, alignment: .trailing)
                .lineLimit(1)
        }
    }
}

struct WidgetMiniBar: View {
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
                    .fill(isMuted ? Color.secondary.opacity(0.45) : WidgetUsageColor.color(forRemainingPercent: value))
                    .frame(width: max(4, proxy.size.width * value / 100))
            }
        }
        .frame(width: 42, height: 5)
    }
}

struct WidgetPlanDot: View {
    let planType: String?

    var body: some View {
        Circle()
            .fill(WidgetPlanStyle.color(for: planType))
            .frame(width: 7, height: 7)
            .shadow(color: WidgetPlanStyle.glow(for: planType), radius: 5)
    }
}

enum WidgetUsageColor {
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

enum WidgetPlanStyle {
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

struct StatPill: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.headline.monospacedDigit())
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct WidgetMessageView: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: systemImage)
                .font(.title2)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(4)
            Spacer()
        }
        .containerBackground(.background, for: .widget)
    }
}

@main
struct CLIProxyPoolWidget: Widget {
    let kind = "CLIProxyPoolWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PoolProvider()) { entry in
            PoolWidgetView(entry: entry)
                .padding()
        }
        .configurationDisplayName("CLIProxy Pool")
        .description("Shows CLIProxyAPI account availability and ChatGPT usage.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
