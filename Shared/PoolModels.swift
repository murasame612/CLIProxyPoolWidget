import Foundation

enum PoolWatchConstants {
    static let appGroupID = "group.com.zipwuu.CLIProxyPoolWidget"
    static let defaultBaseURL = ""
    static let defaultRefreshMinutes = 5
    static let defaultAppRefreshSeconds = 30
    static let defaultLiveRefreshEnabled = true
    static let defaultUsageAccountLimit = 8
    static let defaultPlusWeight = 1.0
    static let defaultProLiteWeight = 10.0
    static let defaultProWeight = 20.0
    static let defaultWeeklyKillLinePercent = 3.0
    static let resetAggregationSeconds = 30 * 60
    static let resetAggregationToleranceSeconds = 60
}

struct PoolSettings: Codable, Equatable {
    var baseURL: String
    var managementKey: String
    var refreshMinutes: Int
    var appRefreshSeconds: Int
    var liveRefreshEnabled: Bool
    var usageAccountLimit: Int
    var showOnlyCodex: Bool
    var plusWeight: Double
    var proLiteWeight: Double
    var proWeight: Double
    var weeklyKillLinePercent: Double

    static let empty = PoolSettings(
        baseURL: PoolWatchConstants.defaultBaseURL,
        managementKey: "",
        refreshMinutes: PoolWatchConstants.defaultRefreshMinutes,
        appRefreshSeconds: PoolWatchConstants.defaultAppRefreshSeconds,
        liveRefreshEnabled: PoolWatchConstants.defaultLiveRefreshEnabled,
        usageAccountLimit: PoolWatchConstants.defaultUsageAccountLimit,
        showOnlyCodex: true,
        plusWeight: PoolWatchConstants.defaultPlusWeight,
        proLiteWeight: PoolWatchConstants.defaultProLiteWeight,
        proWeight: PoolWatchConstants.defaultProWeight,
        weeklyKillLinePercent: PoolWatchConstants.defaultWeeklyKillLinePercent
    )

    var isConfigured: Bool {
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !managementKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func weight(for planType: String?) -> Double {
        switch PlanType.normalize(planType) {
        case "pro":
            return max(0, proWeight)
        case "prolite", "pro_lite", "pro-lite":
            return max(0, proLiteWeight)
        default:
            return max(0, plusWeight)
        }
    }

    enum CodingKeys: String, CodingKey {
        case baseURL
        case managementKey
        case refreshMinutes
        case appRefreshSeconds
        case liveRefreshEnabled
        case usageAccountLimit
        case showOnlyCodex
        case plusWeight
        case proLiteWeight
        case proWeight
        case weeklyKillLinePercent
    }

    init(
        baseURL: String,
        managementKey: String,
        refreshMinutes: Int,
        appRefreshSeconds: Int,
        liveRefreshEnabled: Bool,
        usageAccountLimit: Int,
        showOnlyCodex: Bool,
        plusWeight: Double,
        proLiteWeight: Double,
        proWeight: Double,
        weeklyKillLinePercent: Double
    ) {
        self.baseURL = baseURL
        self.managementKey = managementKey
        self.refreshMinutes = refreshMinutes
        self.appRefreshSeconds = appRefreshSeconds
        self.liveRefreshEnabled = liveRefreshEnabled
        self.usageAccountLimit = usageAccountLimit
        self.showOnlyCodex = showOnlyCodex
        self.plusWeight = plusWeight
        self.proLiteWeight = proLiteWeight
        self.proWeight = proWeight
        self.weeklyKillLinePercent = weeklyKillLinePercent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? Self.empty.baseURL
        managementKey = try container.decodeIfPresent(String.self, forKey: .managementKey) ?? ""
        refreshMinutes = try container.decodeIfPresent(Int.self, forKey: .refreshMinutes) ?? Self.empty.refreshMinutes
        appRefreshSeconds = try container.decodeIfPresent(Int.self, forKey: .appRefreshSeconds) ?? Self.empty.appRefreshSeconds
        liveRefreshEnabled = try container.decodeIfPresent(Bool.self, forKey: .liveRefreshEnabled) ?? Self.empty.liveRefreshEnabled
        usageAccountLimit = try container.decodeIfPresent(Int.self, forKey: .usageAccountLimit) ?? Self.empty.usageAccountLimit
        showOnlyCodex = try container.decodeIfPresent(Bool.self, forKey: .showOnlyCodex) ?? Self.empty.showOnlyCodex
        plusWeight = try container.decodeIfPresent(Double.self, forKey: .plusWeight) ?? Self.empty.plusWeight
        proLiteWeight = try container.decodeIfPresent(Double.self, forKey: .proLiteWeight) ?? Self.empty.proLiteWeight
        proWeight = try container.decodeIfPresent(Double.self, forKey: .proWeight) ?? Self.empty.proWeight
        weeklyKillLinePercent = try container.decodeIfPresent(Double.self, forKey: .weeklyKillLinePercent) ?? Self.empty.weeklyKillLinePercent
    }
}

enum PlanType {
    static func normalize(_ value: String?) -> String {
        (value ?? "plus")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    static func displayName(_ value: String?) -> String {
        switch normalize(value) {
        case "pro":
            return "Pro"
        case "prolite", "pro_lite", "pro-lite":
            return "Pro Lite"
        default:
            return "Plus"
        }
    }
}

struct AuthFilesResponse: Decodable {
    let files: [AuthFile]
}

struct AuthFile: Decodable, Identifiable, Hashable {
    let id: String
    let authIndex: String
    let name: String?
    let type: String?
    let provider: String?
    let label: String?
    let email: String?
    let account: String?
    let accountType: String?
    let status: String?
    let statusMessage: String?
    let disabled: Bool
    let unavailable: Bool
    let runtimeOnly: Bool
    let success: Int
    let failed: Int
    let nextRetryAfter: Date?
    let recentRequests: [RecentRequestBucket]
    let idToken: CodexIDToken?

    enum CodingKeys: String, CodingKey {
        case id
        case authIndex = "auth_index"
        case name
        case type
        case provider
        case label
        case email
        case account
        case accountType = "account_type"
        case status
        case statusMessage = "status_message"
        case disabled
        case unavailable
        case runtimeOnly = "runtime_only"
        case success
        case failed
        case nextRetryAfter = "next_retry_after"
        case recentRequests = "recent_requests"
        case idToken = "id_token"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        authIndex = try container.decodeIfPresent(String.self, forKey: .authIndex) ?? id
        name = try container.decodeIfPresent(String.self, forKey: .name)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        provider = try container.decodeIfPresent(String.self, forKey: .provider)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        account = try container.decodeIfPresent(String.self, forKey: .account)
        accountType = try container.decodeIfPresent(String.self, forKey: .accountType)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        statusMessage = try container.decodeIfPresent(String.self, forKey: .statusMessage)
        disabled = try container.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
        unavailable = try container.decodeIfPresent(Bool.self, forKey: .unavailable) ?? false
        runtimeOnly = try container.decodeIfPresent(Bool.self, forKey: .runtimeOnly) ?? false
        success = try container.decodeLossyIntIfPresent(forKey: .success) ?? 0
        failed = try container.decodeLossyIntIfPresent(forKey: .failed) ?? 0
        nextRetryAfter = try container.decodeFlexibleDateIfPresent(forKey: .nextRetryAfter)
        recentRequests = try container.decodeIfPresent([RecentRequestBucket].self, forKey: .recentRequests) ?? []
        idToken = try container.decodeIfPresent(CodexIDToken.self, forKey: .idToken)
    }

    var normalizedProvider: String {
        (provider ?? type ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var displayName: String {
        if let email, !email.isEmpty { return email }
        if let account, !account.isEmpty { return account }
        if let name, !name.isEmpty { return name }
        if let label, !label.isEmpty { return label }
        return authIndex
    }

    var isCodexLike: Bool {
        normalizedProvider == "codex" || normalizedProvider.contains("openai")
    }

    var isAvailable: Bool {
        guard !disabled, !unavailable else { return false }
        let normalizedStatus = (status ?? "").lowercased()
        return normalizedStatus.isEmpty || normalizedStatus == "active" || normalizedStatus == "ok"
    }
}

struct RecentRequestBucket: Decodable, Hashable {
    let time: String?
    let success: Int
    let failed: Int
}

struct CodexIDToken: Decodable, Hashable {
    let chatgptAccountID: String?
    let planType: String?
    let activeUntil: Date?

    enum CodingKeys: String, CodingKey {
        case chatgptAccountID = "chatgpt_account_id"
        case planType = "plan_type"
        case activeUntil = "chatgpt_subscription_active_until"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chatgptAccountID = try container.decodeIfPresent(String.self, forKey: .chatgptAccountID)
        planType = try container.decodeIfPresent(String.self, forKey: .planType)
        activeUntil = try container.decodeFlexibleDateIfPresent(forKey: .activeUntil)
    }
}

struct APICallRequest: Encodable {
    let authIndex: String
    let method: String
    let url: String
    let header: [String: String]
    let data: String?
}

struct APICallResponse: Decodable {
    let statusCode: Int
    let header: [String: [String]]?
    let body: String

    enum CodingKeys: String, CodingKey {
        case statusCode = "status_code"
        case header
        case body
    }
}

struct UsageSnapshot: Codable, Hashable {
    var used: Double?
    var limit: Double?
    var remaining: Double?
    var usedPercent: Double?
    var planType: String?
    var primaryUsedPercent: Double?
    var primaryResetSeconds: Double?
    var primaryResetText: String?
    var weeklyUsedPercent: Double?
    var weeklyResetSeconds: Double?
    var weeklyResetText: String?
    var resetText: String?
    var rawStatus: String?

    var percentUsed: Double? {
        if let usedPercent = primaryUsedPercent ?? usedPercent {
            return max(0, min(1, usedPercent / 100))
        }
        if let used, let limit, limit > 0 {
            return max(0, min(1, used / limit))
        }
        if let remaining, let limit, limit > 0 {
            return max(0, min(1, (limit - remaining) / limit))
        }
        return nil
    }

    var hasQuotaSignal: Bool {
        used != nil ||
        limit != nil ||
        remaining != nil ||
        usedPercent != nil ||
        primaryUsedPercent != nil ||
        primaryResetSeconds != nil ||
        weeklyUsedPercent != nil ||
        weeklyResetSeconds != nil ||
        planType != nil
    }

    var weeklyRemainingPercent: Double? {
        guard let weeklyUsedPercent else {
            return remaining
        }
        return max(0, min(100, 100 - weeklyUsedPercent))
    }

    var primaryRemainingPercent: Double? {
        guard let primaryUsedPercent = primaryUsedPercent ?? usedPercent else {
            return remaining
        }
        return max(0, min(100, 100 - primaryUsedPercent))
    }

    var primaryCompactText: String {
        if let primaryRemainingPercent {
            return "\(Self.format(primaryRemainingPercent))% left"
        }
        return compactText
    }

    var weeklyCompactText: String {
        if let weeklyRemainingPercent {
            return "\(Self.format(weeklyRemainingPercent))% left"
        }
        return compactText
    }

    var compactText: String {
        if let weeklyRemainingPercent {
            return "\(Self.format(weeklyRemainingPercent))% left"
        }
        if let usedPercent = primaryUsedPercent ?? usedPercent {
            return "\(Self.format(usedPercent))% used"
        }
        if let used, let limit, limit > 0 {
            return "\(Self.format(used))/\(Self.format(limit))"
        }
        if let remaining {
            return "\(Self.format(remaining)) left"
        }
        return rawStatus ?? "usage unknown"
    }

    private static func format(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(format: "%.1f", value)
    }
}

struct AccountUsage: Codable, Identifiable, Hashable {
    var id: String { authIndex }
    let authIndex: String
    let name: String
    let provider: String
    let isAvailable: Bool
    let statusText: String
    let weight: Double
    let weeklyKillLinePercent: Double
    let usage: UsageSnapshot?
    let error: String?

    var planType: String? {
        usage?.planType
    }

    var weeklyWeightedRemaining: Double {
        guard isAvailable, let remaining = effectiveWeeklyRemainingPercent else {
            return 0
        }
        return weight * remaining / 100
    }

    var primaryWeightedRemaining: Double {
        guard isAvailable, let remaining = effectivePrimaryRemainingPercent else {
            return 0
        }
        return weight * remaining / 100
    }

    var effectiveWeeklyRemainingPercent: Double? {
        guard let weeklyRemainingPercent = usage?.weeklyRemainingPercent else {
            return nil
        }
        return weeklyRemainingPercent < weeklyKillLinePercent ? 0 : weeklyRemainingPercent
    }

    var effectivePrimaryRemainingPercent: Double? {
        guard let primaryRemainingPercent = usage?.primaryRemainingPercent else {
            return nil
        }
        guard let weeklyRemainingPercent = usage?.weeklyRemainingPercent else {
            return primaryRemainingPercent
        }
        if weeklyRemainingPercent < weeklyKillLinePercent {
            return 0
        }
        return primaryRemainingPercent
    }

    var isWeekKilled: Bool {
        guard let weeklyRemainingPercent = usage?.weeklyRemainingPercent else {
            return false
        }
        return weeklyRemainingPercent < weeklyKillLinePercent
    }

    var effectivePrimaryCompactText: String {
        guard let effectivePrimaryRemainingPercent else {
            return usage?.primaryCompactText ?? "unknown"
        }
        return "\(Self.format(effectivePrimaryRemainingPercent))% left"
    }

    var effectiveWeeklyCompactText: String {
        guard let effectiveWeeklyRemainingPercent else {
            return usage?.weeklyCompactText ?? "unknown"
        }
        return "\(Self.format(effectiveWeeklyRemainingPercent))% left"
    }

    var primaryResetRestoredUnits: Double {
        guard isAvailable,
              usage?.primaryResetSeconds != nil,
              let currentRemaining = usage?.primaryRemainingPercent
        else {
            return 0
        }

        if let weeklyRemainingPercent = usage?.weeklyRemainingPercent,
           weeklyRemainingPercent < weeklyKillLinePercent {
            return 0
        }

        return max(0, 100 - currentRemaining) * weight / 100
    }

    var weeklyResetRestoredUnits: Double {
        guard isAvailable,
              usage?.weeklyResetSeconds != nil,
              let currentRemaining = effectiveWeeklyRemainingPercent
        else {
            return 0
        }
        return max(0, 100 - currentRemaining) * weight / 100
    }

    private static func format(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(format: "%.1f", value)
    }
}

struct PlanBreakdown: Codable, Hashable {
    let planType: String
    let count: Int
    let weight: Double
    let primaryRemainingUnits: Double
    let weeklyRemainingUnits: Double

    var weightedPercent: Double {
        weeklyRemainingUnits * 100
    }

    var primaryWeightedPercent: Double {
        primaryRemainingUnits * 100
    }
}

struct QuotaResetHint: Codable, Hashable {
    let accountCount: Int
    let secondsUntil: Double
    let restoredUnits: Double
    let targetUnits: Double
    let capacityUnits: Double

    var restoredPercent: Double {
        restoredUnits * 100
    }

    var targetPercent: Double {
        targetUnits * 100
    }

    var capacityPercent: Double {
        capacityUnits * 100
    }

    var timeText: String {
        let minutes = max(0, secondsUntil / 60)
        if minutes < 1 {
            return "<1m"
        }
        if minutes < 60 {
            return "\(Int(minutes.rounded()))m"
        }
        let hours = minutes / 60
        if hours.rounded() == hours {
            return "\(Int(hours))h"
        }
        return String(format: "%.1fh", hours)
    }

    var compactText: String {
        "+\(Self.format(restoredPercent))% -> \(Self.format(targetPercent))% in \(timeText)"
    }

    var detailText: String {
        "\(accountCount) acct\(accountCount == 1 ? "" : "s") · cap \(Self.format(capacityPercent))%"
    }

    static func format(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(format: "%.1f", value)
    }
}

struct PoolSummary: Codable, Hashable {
    let generatedAt: Date
    let totalAccounts: Int
    let availableAccounts: Int
    let coolingAccounts: Int
    let disabledAccounts: Int
    let failedRecentRequests: Int
    let primaryRemainingUnits: Double
    let primaryCapacityUnits: Double
    let weeklyRemainingUnits: Double
    let weeklyCapacityUnits: Double
    let nextPrimaryResetHint: QuotaResetHint?
    let nextWeeklyResetHint: QuotaResetHint?
    let planBreakdown: [PlanBreakdown]
    let accounts: [AccountUsage]
    let errorMessage: String?

    var weeklyRemainingPercent: Double {
        weeklyRemainingUnits * 100
    }

    var primaryRemainingPercent: Double {
        primaryRemainingUnits * 100
    }

    static let placeholder = PoolSummary(
        generatedAt: Date(),
        totalAccounts: 0,
        availableAccounts: 0,
        coolingAccounts: 0,
        disabledAccounts: 0,
        failedRecentRequests: 0,
        primaryRemainingUnits: 0,
        primaryCapacityUnits: 0,
        weeklyRemainingUnits: 0,
        weeklyCapacityUnits: 0,
        nextPrimaryResetHint: nil,
        nextWeeklyResetHint: nil,
        planBreakdown: [],
        accounts: [],
        errorMessage: nil
    )
}

extension KeyedDecodingContainer {
    func decodeLossyIntIfPresent(forKey key: Key) throws -> Int? {
        if let value = try decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try decodeIfPresent(Double.self, forKey: key) {
            return Int(value)
        }
        if let value = try decodeIfPresent(String.self, forKey: key) {
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    func decodeFlexibleDateIfPresent(forKey key: Key) throws -> Date? {
        if let value = try decodeIfPresent(Date.self, forKey: key) {
            return value
        }
        if let value = try decodeIfPresent(String.self, forKey: key) {
            return DateParser.parse(value)
        }
        return nil
    }
}

enum DateParser {
    static func parse(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: trimmed) {
            return date
        }

        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: trimmed)
    }
}
