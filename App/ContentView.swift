import SwiftUI
import WidgetKit
import WebKit

struct ContentView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var refreshCoordinator: PoolRefreshCoordinator
    @AppStorage(L10n.appLanguageKey) private var preferredLanguageCode = AppLanguagePreference.auto.rawValue
    @State private var draft = PoolSettings.empty
    @State private var hasLoadedSettings = false
    @State private var showingXiaomiCookieBrowser = false

    var body: some View {
        NavigationSplitView {
            Form {
                Section(L10n.text("Connection", "连接")) {
                    TextField(L10n.text("Pool URL", "池地址"), text: $draft.baseURL)
                        .textFieldStyle(.roundedBorder)
                    SecureField(L10n.text("Management key", "管理密钥"), text: $draft.managementKey)
                        .textFieldStyle(.roundedBorder)
                }

                Section(L10n.text("Xiaomi Token Plan", "小米 Token Plan")) {
                    Toggle(L10n.text("Show Xiaomi Token Plan", "显示小米 Token Plan"), isOn: $draft.xiaomiTokenPlanEnabled)
                    if draft.xiaomiTokenPlanEnabled {
                        SecureField(L10n.text("Platform cookie", "平台 Cookie"), text: $draft.xiaomiCookie)
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            Button {
                                showingXiaomiCookieBrowser = true
                            } label: {
                                Label(L10n.text("Capture Cookie", "抓取 Cookie"), systemImage: "globe")
                            }
                            Button {
                                draft.xiaomiCookie = ""
                            } label: {
                                Label(L10n.text("Clear", "清空"), systemImage: "trash")
                            }
                            .disabled(draft.xiaomiCookie.isEmpty)
                        }
                    }
                }

                Section(L10n.text("Widget", "组件")) {
                    Picker(L10n.text("Language", "语言"), selection: $preferredLanguageCode) {
                        ForEach(AppLanguagePreference.allCases) { language in
                            Text(language.title)
                                .tag(language.rawValue)
                        }
                    }
                    .pickerStyle(.menu)

                    Stepper(
                        L10n.isChinese ? "刷新：\(draft.refreshMinutes) 分钟" : "Refresh: \(draft.refreshMinutes) min",
                        value: $draft.refreshMinutes,
                        in: 5...60,
                        step: 5
                    )
                    Stepper(
                        L10n.isChinese ? "显示账号数：\(draft.usageAccountLimit)" : "Displayed accounts: \(draft.usageAccountLimit)",
                        value: $draft.usageAccountLimit,
                        in: 1...32
                    )
                    Toggle(L10n.text("Show Codex/OpenAI accounts only", "只显示 Codex/OpenAI 账号"), isOn: $draft.showOnlyCodex)
                }

                Section(L10n.text("App Live Mode", "应用实时模式")) {
                    Toggle(L10n.text("Live refresh", "实时刷新"), isOn: $draft.liveRefreshEnabled)
                    Stepper(
                        L10n.isChinese ? "间隔：\(draft.appRefreshSeconds) 秒" : "Interval: \(draft.appRefreshSeconds)s",
                        value: $draft.appRefreshSeconds,
                        in: 10...300,
                        step: 5
                    )
                    if draft.liveRefreshEnabled, let nextLiveRefreshAt = refreshCoordinator.nextRefreshAt {
                        Text(
                            L10n.isChinese
                                ? "下次刷新 \(nextLiveRefreshAt.formatted(date: .omitted, time: .standard))"
                                : "Next refresh \(nextLiveRefreshAt.formatted(date: .omitted, time: .standard))"
                        )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section(L10n.text("Plan Weights", "套餐权重")) {
                    Stepper("Plus: \(formatWeight(draft.plusWeight))x", value: $draft.plusWeight, in: 0.1...100, step: 0.1)
                    Stepper("Pro Lite: \(formatWeight(draft.proLiteWeight))x", value: $draft.proLiteWeight, in: 0.1...100, step: 0.5)
                    Stepper("Pro: \(formatWeight(draft.proWeight))x", value: $draft.proWeight, in: 0.1...100, step: 0.5)
                    Stepper(
                        L10n.isChinese
                            ? "周限流阈值：\(formatWeight(draft.weeklyKillLinePercent))%"
                            : "Week kill line: \(formatWeight(draft.weeklyKillLinePercent))%",
                        value: $draft.weeklyKillLinePercent,
                        in: 0...20,
                        step: 0.5
                    )
                }

                HStack {
                    Button(L10n.text("Save", "保存")) {
                        let saved = PoolRefreshCoordinator.sanitize(draft)
                        draft = saved
                        Task { await refreshCoordinator.saveAndRefresh(saved) }
                    }
                    .keyboardShortcut(.defaultAction)

                    Button(L10n.text("Test Fetch", "测试抓取")) {
                        Task { await refreshCoordinator.refresh() }
                    }
                    .disabled(refreshCoordinator.refreshInFlight || !(draft.isConfigured || draft.isXiaomiTokenPlanConfigured))
                }

                if let lastMessage = refreshCoordinator.lastMessage {
                    Text(lastMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .navigationSplitViewColumnWidth(min: 280, ideal: 320)
        } detail: {
            SummaryView(
                summary: refreshCoordinator.summary,
                isLoading: refreshCoordinator.isLoading,
                accountDisplayLimit: PoolRefreshCoordinator.sanitize(draft).usageAccountLimit
            )
                .padding()
        }
        .onAppear {
            draft = settingsStore.settings
            preferredLanguageCode = draft.preferredLanguageCode
            hasLoadedSettings = true
        }
        .onChange(of: preferredLanguageCode) { _, newValue in
            guard hasLoadedSettings else {
                return
            }
            draft.preferredLanguageCode = newValue
        }
        .onChange(of: draft) { _, newValue in
            guard hasLoadedSettings else {
                return
            }
            settingsStore.settings = newValue
        }
        .sheet(isPresented: $showingXiaomiCookieBrowser) {
            XiaomiCookieCaptureView { cookie in
                draft.xiaomiTokenPlanEnabled = true
                draft.xiaomiCookie = cookie
                showingXiaomiCookieBrowser = false
            } onCancel: {
                showingXiaomiCookieBrowser = false
            }
            .frame(minWidth: 980, minHeight: 720)
        }
    }

    private func formatWeight(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}

struct XiaomiCookieCaptureView: View {
    let onCapture: (String) -> Void
    let onCancel: () -> Void
    @State private var latestCookie = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label(L10n.text("Xiaomi MiMo", "小米 MiMo"), systemImage: "globe")
                    .font(.headline)
                Spacer()
                Button(L10n.text("Cancel", "取消")) {
                    onCancel()
                }
                Button {
                    capture(latestCookie)
                } label: {
                    Label(L10n.text("Use Cookie", "使用 Cookie"), systemImage: "checkmark")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(latestCookie.isEmpty)
            }
            .padding(12)

            Divider()

            XiaomiCookieWebView { cookie in
                latestCookie = cookie
                if !cookie.isEmpty {
                    capture(cookie)
                }
            }
        }
    }

    private func capture(_ cookie: String) {
        guard !cookie.isEmpty else {
            return
        }
        onCapture(cookie)
    }
}

struct XiaomiCookieWebView: NSViewRepresentable {
    let onCookie: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCookie: onCookie)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.startCookiePolling()
        webView.load(URLRequest(url: URL(string: "https://platform.xiaomimimo.com/console/plan-manage")!))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.stopCookiePolling()
        nsView.navigationDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        private let onCookie: (String) -> Void
        private var timer: Timer?
        private var lastCookie = ""

        init(onCookie: @escaping (String) -> Void) {
            self.onCookie = onCookie
        }

        func startCookiePolling() {
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.readCookies()
                }
            }
        }

        func stopCookiePolling() {
            timer?.invalidate()
            timer = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            readCookies()
        }

        private func readCookies() {
            webView?.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self else {
                    return
                }
                let cookie = Self.platformCookieHeader(from: cookies)
                guard !cookie.isEmpty, cookie != lastCookie else {
                    return
                }
                lastCookie = cookie
                DispatchQueue.main.async {
                    self.onCookie(cookie)
                }
            }
        }

        private static func platformCookieHeader(from cookies: [HTTPCookie]) -> String {
            let wantedNames = [
                "api-platform_serviceToken",
                "userId",
                "api-platform_slh",
                "api-platform_ph",
                "cookie-preferences"
            ]
            let byName = Dictionary(
                cookies
                    .filter { cookie in
                        wantedNames.contains(cookie.name) &&
                        cookie.domain.contains("xiaomimimo.com")
                    }
                    .map { ($0.name, $0.value) },
                uniquingKeysWith: { first, _ in first }
            )

            guard byName["api-platform_serviceToken"] != nil else {
                return ""
            }

            return wantedNames.compactMap { name in
                byName[name].map { "\(name)=\($0)" }
            }
            .joined(separator: "; ")
        }
    }
}

struct SummaryView: View {
    let summary: PoolSummary
    let isLoading: Bool
    let accountDisplayLimit: Int
    @AppStorage("accountSortMode") private var accountSortMode = AccountSortMode.fiveHour.rawValue
    @AppStorage("accountSortDescending") private var accountSortDescending = true

    private var sortMode: AccountSortMode {
        AccountSortMode(rawValue: accountSortMode) ?? .fiveHour
    }

    private var sortedAccounts: [AccountUsage] {
        Array(sorted(summary.accounts, by: sortMode, descending: accountSortDescending).prefix(max(1, accountDisplayLimit)))
    }

    private var displayRows: [SummaryListRow] {
        var rows: [SummaryListRow] = []
        rows.append(contentsOf: sortedAccounts.map(SummaryListRow.account))
        rows.append(contentsOf: summary.apiKeyUsages.map(SummaryListRow.apiKey))
        return rows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(L10n.text("CLIProxy Pool", "CLIProxy 池"))
                    .font(.largeTitle.bold())
                Spacer()
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let error = summary.errorMessage,
               summary.xiaomiTokenPlan == nil,
               summary.apiKeyUsageSummary == nil {
                ContentUnavailableView(L10n.text("Fetch failed", "获取失败"), systemImage: "exclamationmark.triangle", description: Text(error))
            } else if summary.totalAccounts == 0,
                      summary.xiaomiTokenPlan == nil,
                      summary.apiKeyUsageSummary == nil {
                ContentUnavailableView(
                    L10n.text("No data yet", "暂无数据"),
                    systemImage: "chart.bar",
                    description: Text(L10n.text("Save settings and test the connection.", "请先保存设置并测试连接。"))
                )
            } else {
                if let tokenPlan = summary.xiaomiTokenPlan {
                    XiaomiTokenPlanCard(snapshot: tokenPlan)
                }
                if let error = summary.errorMessage {
                    ContentUnavailableView(L10n.text("CLIProxy fetch failed", "CLIProxy 获取失败"), systemImage: "exclamationmark.triangle", description: Text(error))
                } else {
                    if summary.totalAccounts > 0 {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(L10n.text("Plus-base balance", "Plus 基础额度"))
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
                    }
                    HealthOverview(buckets: summary.recentRequests)

                    if !displayRows.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            if summary.totalAccounts > 0 {
                                HStack(spacing: 8) {
                                    Picker(L10n.text("Sort", "排序"), selection: $accountSortMode) {
                                        ForEach(AccountSortMode.allCases) { mode in
                                            Label(mode.title, systemImage: mode.systemImage)
                                                .tag(mode.rawValue)
                                        }
                                    }
                                    .pickerStyle(.segmented)

                                    Button {
                                        accountSortDescending.toggle()
                                    } label: {
                                        Image(systemName: accountSortDescending ? "arrow.down" : "arrow.up")
                                    }
                                    .buttonStyle(.bordered)
                                    .help(accountSortDescending ? L10n.text("High to low", "从高到低") : L10n.text("Low to high", "从低到高"))
                                }
                            }

                            List(displayRows) { row in
                                switch row {
                                case .apiKey(let apiKey):
                                    APIKeyRow(snapshot: apiKey)
                                case .account(let account):
                                    AccountRow(account: account)
                                }
                            }
                            .listStyle(.inset)
                        }
                    }
                }
            }

            Spacer()
            Text(
                L10n.isChinese
                    ? "更新于 \(summary.generatedAt.formatted(date: .omitted, time: .shortened))"
                    : "Updated \(summary.generatedAt.formatted(date: .omitted, time: .shortened))"
            )
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func formatPercent(_ value: Double) -> String {
        String(format: "%.0f", value)
    }

    private func sorted(_ accounts: [AccountUsage], by mode: AccountSortMode, descending: Bool) -> [AccountUsage] {
        accounts.sorted { lhs, rhs in
            let comparison: ComparisonResult
            switch mode {
            case .fiveHour:
                comparison = compare(
                    lhs.primaryWeightedRemaining,
                    rhs.primaryWeightedRemaining,
                    lhs: lhs,
                    rhs: rhs
                )
            case .week:
                comparison = compare(
                    lhs.weeklyWeightedRemaining,
                    rhs.weeklyWeightedRemaining,
                    lhs: lhs,
                    rhs: rhs
                )
            case .name:
                comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            }

            if comparison == .orderedSame {
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            return descending ? comparison == .orderedDescending : comparison == .orderedAscending
        }
    }

    private func compare(_ lhsValue: Double, _ rhsValue: Double, lhs: AccountUsage, rhs: AccountUsage) -> ComparisonResult {
        if lhsValue == rhsValue {
            if lhs.weight != rhs.weight {
                return lhs.weight < rhs.weight ? .orderedAscending : .orderedDescending
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        }
        return lhsValue < rhsValue ? .orderedAscending : .orderedDescending
    }
}

private enum SummaryListRow: Identifiable {
    case apiKey(APIKeyUsageSnapshot)
    case account(AccountUsage)

    var id: String {
        switch self {
        case .apiKey(let snapshot):
            return "api-key-\(snapshot.id)"
        case .account(let account):
            return "account-\(account.id)"
        }
    }
}

enum AccountSortMode: String, CaseIterable, Identifiable {
    case fiveHour
    case week
    case name

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fiveHour:
            return "5h"
        case .week:
            return L10n.text("Week", "周")
        case .name:
            return L10n.text("Name", "名称")
        }
    }

    var systemImage: String {
        switch self {
        case .fiveHour:
            return "clock"
        case .week:
            return "calendar"
        case .name:
            return "textformat"
        }
    }
}

struct XiaomiTokenPlanCard: View {
    let snapshot: XiaomiTokenPlanSnapshot

    private var hasError: Bool {
        snapshot.errorMessage != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label(L10n.text("Xiaomi Token Plan", "小米 Token Plan"), systemImage: hasError ? "exclamationmark.triangle.fill" : "sparkles")
                    .font(.headline)
                    .foregroundStyle(hasError ? .orange : .primary)
                Spacer()
                Text(snapshot.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if hasError {
                Text(snapshot.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                BalanceLine(
                    label: L10n.text("Plan", "套餐"),
                    valueText: L10n.isChinese ? "剩余 \(formatPercent(snapshot.remainingPercent))%" : "\(formatPercent(snapshot.remainingPercent))% left",
                    value: snapshot.remainingCredits,
                    total: max(snapshot.limitCredits, 1),
                    hint: nil
                )
                HStack {
                    Text(snapshot.compactUsageText)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(snapshot.statusText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(snapshot.expired ? .red : .secondary)
                }
                if let monthlyUsed = snapshot.monthlyUsedCredits,
                   let monthlyLimit = snapshot.monthlyLimitCredits {
                    Text(
                        L10n.isChinese
                            ? "本月 \(XiaomiTokenPlanSnapshot.formatCredits(monthlyUsed)) / \(XiaomiTokenPlanSnapshot.formatCredits(monthlyLimit))"
                            : "Month \(XiaomiTokenPlanSnapshot.formatCredits(monthlyUsed)) / \(XiaomiTokenPlanSnapshot.formatCredits(monthlyLimit))"
                    )
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func formatPercent(_ value: Double) -> String {
        String(format: "%.0f", value)
    }
}

struct APIKeyUsageCard: View {
    let summary: APIKeyUsageSummary

    private var recentFailedCount: Int {
        summary.recentRequests.reduce(0) { $0 + $1.failed }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label(L10n.text("API Key Traffic", "API Key 流量"), systemImage: "link.badge.plus")
                    .font(.headline)
                Spacer()
                Text(
                    L10n.isChinese
                        ? "\(summary.apiKeyCount) 个 key · \(summary.providerCount) 个提供方"
                        : "\(summary.apiKeyCount) keys · \(summary.providerCount) providers"
                )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                MetricPill(title: L10n.text("Req", "请求"), value: "\(summary.requests)")
                MetricPill(title: L10n.text("Fail", "失败"), value: "\(summary.failedRequests)")
                MetricPill(title: "OK", value: "\(summary.success)")
            }

            HStack(spacing: 12) {
                Label(L10n.text("Status", "状态"), systemImage: "waveform.path.ecg")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .leading)
                HealthTimeline(buckets: summary.recentRequests, height: 8, minCapsuleWidth: 4, maxCapsuleWidth: 16)
                    .frame(maxWidth: .infinity, alignment: .center)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(recentFailedCount)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(recentFailedCount > 0 ? .red : .secondary)
                    Text(L10n.text("recent fail", "最近失败"))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .frame(width: 80, alignment: .trailing)
            }

            if summary.hasTokenUsage {
                Text(
                    L10n.isChinese
                        ? "总 Token：\(formatTokens(summary.tokens.totalTokens))"
                        : "\(formatTokens(summary.tokens.totalTokens)) total tokens"
                )
                    .font(.title3.bold().monospacedDigit())
                Text(
                    L10n.isChinese
                        ? "输入 \(formatTokens(summary.tokens.inputTokens)) · 输出 \(formatTokens(summary.tokens.outputTokens)) · 推理 \(formatTokens(summary.tokens.reasoningTokens)) · 缓存 \(formatTokens(summary.tokens.cachedTokens))"
                        : "In \(formatTokens(summary.tokens.inputTokens)) · Out \(formatTokens(summary.tokens.outputTokens)) · Think \(formatTokens(summary.tokens.reasoningTokens)) · Cache \(formatTokens(summary.tokens.cachedTokens))"
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            } else {
                Text(L10n.text("Token totals will appear after the pool API exposes runtime token usage on `api-key-usage`.", "等池 API 在 `api-key-usage` 暴露运行时 Token 用量后，这里才会显示 Token 汇总。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func formatTokens(_ value: Int64) -> String {
        let count = Double(max(0, value))
        switch count {
        case 1_000_000_000...:
            return String(format: "%.2fB", count / 1_000_000_000)
        case 1_000_000...:
            return String(format: "%.2fM", count / 1_000_000)
        case 1_000...:
            return String(format: "%.1fK", count / 1_000)
        default:
            return "\(value)"
        }
    }
}

struct MetricPill: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.headline.monospacedDigit())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct HealthOverview: View {
    let buckets: [RecentRequestBucket]

    private var failedCount: Int {
        buckets.reduce(0) { $0 + $1.failed }
    }

    var body: some View {
        HStack(spacing: 12) {
            Label(L10n.text("Health", "健康度"), systemImage: "waveform.path.ecg")
                .font(.headline)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            HealthTimeline(buckets: buckets, height: 10, minCapsuleWidth: 6, maxCapsuleWidth: 28)
                .frame(maxWidth: .infinity, alignment: .center)
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(failedCount)")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(failedCount > 0 ? .red : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(L10n.text("failed", "失败"))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(width: 92, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct HealthTimeline: View {
    let buckets: [RecentRequestBucket]
    var height: CGFloat = 8
    var minCapsuleWidth: CGFloat = 4
    var maxCapsuleWidth: CGFloat = 18
    private let spacing: CGFloat = 3

    private var displayBuckets: [RecentRequestBucket] {
        let latest = Array(buckets.suffix(20))
        let padding = max(0, 20 - latest.count)
        return Array(repeating: RecentRequestBucket(success: 0, failed: 0), count: padding) + latest
    }

    var body: some View {
        GeometryReader { proxy in
            let buckets = displayBuckets
            let count = max(1, buckets.count)
            let availableWidth = max(0, proxy.size.width - spacing * CGFloat(count - 1))
            let adaptiveWidth = max(minCapsuleWidth, min(maxCapsuleWidth, availableWidth / CGFloat(count)))

            HStack(spacing: spacing) {
                ForEach(Array(buckets.enumerated()), id: \.offset) { _, bucket in
                    Capsule()
                        .fill(color(for: bucket))
                        .frame(width: adaptiveWidth, height: height)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(height: height)
        .help(L10n.text("Recent request health. Each capsule is one 10-minute server bucket.", "最近请求健康度。每个胶囊代表一个 10 分钟服务端桶。"))
    }

    private func color(for bucket: RecentRequestBucket) -> Color {
        if bucket.failed > 0 && bucket.success > 0 {
            return .yellow
        }
        if bucket.failed > 0 {
            return .red
        }
        if bucket.success > 0 {
            return .green
        }
        return Color.secondary.opacity(0.22)
    }
}

struct AccountRow: View {
    let account: AccountUsage
    private let rowHeight: CGFloat = 58

    var body: some View {
        GeometryReader { proxy in
            let metrics = summaryRowMetrics(for: proxy.size.width)

            ZStack(alignment: .leading) {
                accountIdentity
                    .frame(width: metrics.sideWidth, alignment: .leading)
                    .position(x: metrics.sideWidth / 2, y: rowHeight / 2)

                HealthTimeline(buckets: account.recentRequests, height: 7, minCapsuleWidth: 3, maxCapsuleWidth: 12)
                    .frame(width: metrics.centerWidth, alignment: .center)
                    .position(x: proxy.size.width / 2, y: rowHeight / 2)

                quotaDetails
                    .frame(width: metrics.rightWidth, alignment: .trailing)
                    .position(x: proxy.size.width - metrics.rightWidth / 2, y: rowHeight / 2)
            }
        }
        .frame(height: rowHeight)
        .padding(.vertical, 4)
    }

    private var accountIdentity: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(account.isAvailable ? Color.green : Color.orange)
                .frame(width: 9, height: 9)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(account.name)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    PlanBadge(planType: account.planType, weight: account.weight)
                }
                Text(account.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var quotaDetails: some View {
        VStack(alignment: .trailing, spacing: 3) {
            UsageStack(account: account)
            if let primaryReset = account.usage?.primaryResetText,
               let weeklyReset = account.usage?.weeklyResetText {
                Text(L10n.isChinese ? "5h \(primaryReset) · 周 \(weeklyReset)" : "5h \(primaryReset) · week \(weeklyReset)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            } else if account.error != nil {
                Text(account.apiCallFailureText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

}

struct APIKeyRow: View {
    let snapshot: APIKeyUsageSnapshot
    private let rowHeight: CGFloat = 58

    private var recentFailureCount: Int {
        snapshot.recentRequests.reduce(0) { $0 + $1.failed }
    }

    private var statusText: String {
        if recentFailureCount > 0 {
            return L10n.isChinese
                ? "\(snapshot.providerDisplayName) · 最近失败 \(recentFailureCount)"
                : "\(snapshot.providerDisplayName) · \(recentFailureCount) recent fail"
        }
        return snapshot.providerDisplayName
    }

    var body: some View {
        GeometryReader { proxy in
            let metrics = summaryRowMetrics(for: proxy.size.width)

            ZStack(alignment: .leading) {
                apiIdentity
                    .frame(width: metrics.sideWidth, alignment: .leading)
                    .position(x: metrics.sideWidth / 2, y: rowHeight / 2)

                HealthTimeline(buckets: snapshot.recentRequests, height: 7, minCapsuleWidth: 3, maxCapsuleWidth: 12)
                    .frame(width: metrics.centerWidth, alignment: .center)
                    .position(x: proxy.size.width / 2, y: rowHeight / 2)

                apiDetails
                    .frame(width: metrics.rightWidth, alignment: .trailing)
                    .position(x: proxy.size.width - metrics.rightWidth / 2, y: rowHeight / 2)
            }
        }
        .frame(height: rowHeight)
        .padding(.vertical, 4)
    }

    private var apiIdentity: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(recentFailureCount > 0 ? Color.yellow : Color.blue)
                .frame(width: 9, height: 9)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(snapshot.displayName)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(L10n.text("API", "API"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.12), in: Capsule())
                }
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var apiDetails: some View {
        VStack(alignment: .trailing, spacing: 3) {
            HStack(spacing: 10) {
                apiMetric(L10n.text("Req", "请求"), value: snapshot.totalRequests, color: .primary)
                apiMetric(L10n.text("Fail", "失败"), value: snapshot.runtimeFailedRequests, color: snapshot.runtimeFailedRequests > 0 ? .red : .secondary)
                apiMetric("OK", value: snapshot.success, color: .green)
            }
            .font(.caption.monospacedDigit())

            Text(snapshot.providerDisplayName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func apiMetric(_ title: String, value: Int, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .foregroundStyle(.secondary)
            Text("\(value)")
                .foregroundStyle(color)
        }
    }
}

private func summaryRowMetrics(for width: CGFloat) -> (centerWidth: CGFloat, sideWidth: CGFloat, rightWidth: CGFloat) {
    let gap: CGFloat = width < 620 ? 10 : 14
    let rightReadableWidth: CGFloat = 214
    var centerWidth = min(240, max(120, width * 0.34))
    let readableCenterWidth = width - (rightReadableWidth + gap) * 2

    if readableCenterWidth < centerWidth {
        centerWidth = max(96, readableCenterWidth)
    }

    let sideWidth = max(0, (width - centerWidth) / 2 - gap)
    let rightWidth = min(220, sideWidth)
    return (centerWidth, sideWidth, rightWidth)
}

private extension AccountUsage {
    var apiCallFailureText: String {
        guard let error else {
            return L10n.text("api-call failed", "API 调用失败")
        }
        if error.contains("JavaScript/cookie challenge") {
            return L10n.text("ChatGPT 403: JS/cookies required", "ChatGPT 403：需要 JS/Cookie")
        }
        return L10n.text("api-call failed", "API 调用失败")
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
                    Text(L10n.isChinese ? "5h \(formatPercent(item.primaryWeightedPercent))% · 周 \(formatPercent(item.weightedPercent))%" : "5h \(formatPercent(item.primaryWeightedPercent))% · W \(formatPercent(item.weightedPercent))%")
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
        String(format: "%.0f", value)
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
                label: L10n.text("Week", "周"),
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
        Text(hint.map { "+\(QuotaResetHint.format($0.restoredPercent))% in \($0.timeText)" } ?? "")
            .font(.subheadline.weight(.bold).monospacedDigit())
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.74)
            .frame(width: 116, alignment: .trailing)
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
                        .frame(width: max(3, targetWidth))
                }
                if currentWidth > 0.5 {
                    Capsule()
                        .fill(UsageColor.color(forRemainingPercent: ratio * 100))
                        .frame(width: max(3, currentWidth))
                }
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
                let fillWidth = proxy.size.width * value / 100
                if fillWidth > 0.5 {
                    Capsule()
                        .fill(isMuted ? Color.secondary.opacity(0.45) : UsageColor.color(forRemainingPercent: value))
                        .frame(width: max(2, fillWidth))
                }
            }
        }
        .frame(width: 96, height: 8)
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
