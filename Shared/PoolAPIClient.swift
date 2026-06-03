import Foundation

enum PoolAPIError: LocalizedError {
    case notConfigured
    case xiaomiNotConfigured
    case invalidBaseURL
    case chatGPTChallenge(Int)
    case httpStatus(Int, String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return L10n.text("Pool URL and management key are required.", "需要填写池地址和管理密钥。")
        case .xiaomiNotConfigured:
            return L10n.text("Xiaomi Token Plan cookie is required.", "需要填写小米 Token Plan 的 Cookie。")
        case .invalidBaseURL:
            return L10n.text("Pool URL is invalid.", "池地址无效。")
        case let .chatGPTChallenge(status):
            return L10n.isChinese
                ? "ChatGPT 阻止了 API 调用：需要 JavaScript/Cookie 验证（HTTP \(status)）。"
                : "ChatGPT blocked api-call: JavaScript/cookie challenge (HTTP \(status))."
        case let .httpStatus(status, body):
            return "HTTP \(status): \(body.prefix(160))"
        case .invalidResponse:
            return L10n.text("The server returned an invalid response.", "服务端返回了无效响应。")
        }
    }
}

struct PoolAPIClient {
    let settings: PoolSettings
    var session: URLSession = .shared

    func fetchAuthFiles() async throws -> [AuthFile] {
        let url = try managementURL(path: "/v0/management/auth-files")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyManagementHeaders(to: &request)

        let data = try await data(for: request)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = DateParser.parse(value) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(value)")
        }
        return try decoder.decode(AuthFilesResponse.self, from: data).files
    }

    func fetchAPIKeyUsage() async throws -> [APIKeyUsageSnapshot] {
        let url = try managementURL(path: "/v0/management/api-key-usage")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyManagementHeaders(to: &request)

        let data = try await data(for: request)
        let response = try JSONDecoder().decode([String: [String: APIKeyUsageEntry]].self, from: data)
        return response.flatMap { provider, entries in
            entries.map { keyIdentifier, entry in
                APIKeyUsageSnapshot(
                    id: "\(provider):\(keyIdentifier)",
                    provider: provider,
                    keyIdentifier: keyIdentifier,
                    success: entry.success,
                    failed: entry.failed,
                    recentRequests: entry.recentRequests,
                    tokens: entry.tokens,
                    requests: entry.requests,
                    failedRequests: entry.failedRequests
                )
            }
        }
    }

    func fetchWhamUsage(authIndex: String, chatgptAccountID: String? = nil) async throws -> UsageSnapshot {
        let url = try managementURL(path: "/v0/management/api-call")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyManagementHeaders(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var headers = [
            "Authorization": "Bearer $TOKEN$",
            "Content-Type": "application/json",
            "User-Agent": "codex_cli_rs/0.76.0 (Debian 13.0.0; x86_64) WindowsTerminal"
        ]
        if let chatgptAccountID = chatgptAccountID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !chatgptAccountID.isEmpty {
            headers["Chatgpt-Account-Id"] = chatgptAccountID
        }

        let payload = APICallRequest(
            authIndex: authIndex,
            method: "GET",
            url: "https://chatgpt.com/backend-api/wham/usage",
            header: headers,
            data: nil
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, urlResponse) = try await session.data(for: request)
        guard let http = urlResponse as? HTTPURLResponse else {
            throw PoolAPIError.invalidResponse
        }

        let rawBody = String(data: data, encoding: .utf8) ?? ""
        if let response = apiCallEnvelope(from: data) {
            if (200..<300).contains(response.statusCode) {
                return UsageParser.parse(response.body)
            }
            if let snapshot = quotaSnapshot(from: response.body) {
                return snapshot
            }
            if isBrowserChallenge(response.body) {
                throw PoolAPIError.chatGPTChallenge(response.statusCode)
            }
            // Body is valid JSON but no quota fields — the account is
            // likely working but rate-limited. Return the snapshot so
            // the caller can fall back to auth-file availability.
            if let bodyData = response.body.data(using: .utf8),
               (try? JSONSerialization.jsonObject(with: bodyData)) != nil {
                return UsageParser.parse(response.body)
            }
            throw PoolAPIError.httpStatus(response.statusCode, response.body)
        }

        if let snapshot = quotaSnapshot(from: rawBody) {
            return snapshot
        }
        if isBrowserChallenge(rawBody) {
            throw PoolAPIError.chatGPTChallenge(http.statusCode)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw PoolAPIError.httpStatus(http.statusCode, rawBody)
        }
        throw PoolAPIError.invalidResponse
    }

    func fetchXiaomiTokenPlan() async throws -> XiaomiTokenPlanSnapshot {
        guard settings.isXiaomiTokenPlanConfigured else {
            throw PoolAPIError.xiaomiNotConfigured
        }

        async let usageResponse = fetchXiaomiUsage()
        async let detailResponse = fetchXiaomiDetail()
        let (usage, detail) = try await (usageResponse, detailResponse)

        guard let planItem = usage.data.usage.item(named: "plan_total_token") ??
                usage.data.usage.items.first
        else {
            throw PoolAPIError.invalidResponse
        }

        let monthItem = usage.data.monthUsage?.item(named: "month_total_token") ??
            usage.data.monthUsage?.items.first
        return XiaomiTokenPlanSnapshot(
            planCode: detail.data.planCode,
            planName: detail.data.planName,
            currentPeriodEnd: detail.data.currentPeriodEnd,
            expired: detail.data.expired ?? false,
            enableAutoRenew: detail.data.enableAutoRenew,
            usedCredits: planItem.used,
            limitCredits: planItem.limit,
            usedFraction: fraction(used: planItem.used, limit: planItem.limit),
            monthlyUsedCredits: monthItem?.used,
            monthlyLimitCredits: monthItem?.limit,
            monthlyUsedFraction: monthItem.map { fraction(used: $0.used, limit: $0.limit) },
            errorMessage: nil
        )
    }

    private func managementURL(path: String) throws -> URL {
        guard settings.isConfigured else {
            throw PoolAPIError.notConfigured
        }

        let raw = settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: raw) else {
            throw PoolAPIError.invalidBaseURL
        }
        if components.scheme == nil {
            components = URLComponents(string: "https://" + raw) ?? components
        }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let suffix = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [basePath, suffix].filter { !$0.isEmpty }.joined(separator: "/")
        guard let url = components.url else {
            throw PoolAPIError.invalidBaseURL
        }
        return url
    }

    private func applyManagementHeaders(to request: inout URLRequest) {
        let token = settings.managementKey.trimmingCharacters(in: .whitespacesAndNewlines)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("CLIProxyPoolWidget/0.1", forHTTPHeaderField: "User-Agent")
    }

    private func xiaomiURL(path: String) throws -> URL {
        guard var components = URLComponents(string: PoolWatchConstants.xiaomiPlatformBaseURL) else {
            throw PoolAPIError.invalidBaseURL
        }
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [components.path, path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        guard let url = components.url else {
            throw PoolAPIError.invalidBaseURL
        }
        return url
    }

    private func applyXiaomiHeaders(to request: inout URLRequest) {
        request.setValue("application/json,*/*", forHTTPHeaderField: "Accept")
        request.setValue("zh", forHTTPHeaderField: "Accept-Language")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(settings.xiaomiCookie.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "Cookie")
        request.setValue("https://platform.xiaomimimo.com/console/plan-manage", forHTTPHeaderField: "Referer")
        request.setValue("Asia/Shanghai", forHTTPHeaderField: "X-Timezone")
        request.setValue("CLIProxyPoolWidget/0.1", forHTTPHeaderField: "User-Agent")
    }

    private func fetchXiaomiUsage() async throws -> XiaomiUsageResponse {
        let url = try xiaomiURL(path: "/tokenPlan/usage")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyXiaomiHeaders(to: &request)
        return try JSONDecoder().decode(XiaomiUsageResponse.self, from: await data(for: request))
    }

    private func fetchXiaomiDetail() async throws -> XiaomiDetailResponse {
        let url = try xiaomiURL(path: "/tokenPlan/detail")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyXiaomiHeaders(to: &request)
        return try JSONDecoder().decode(XiaomiDetailResponse.self, from: await data(for: request))
    }

    private func fraction(used: Double, limit: Double) -> Double {
        guard limit > 0 else {
            return 0
        }
        return max(0, min(1, used / limit))
    }

    private func quotaSnapshot(from body: String) -> UsageSnapshot? {
        let snapshot = UsageParser.parse(body)
        return snapshot.hasQuotaSignal ? snapshot : nil
    }

    private func isBrowserChallenge(_ body: String) -> Bool {
        let normalized = body.lowercased()
        return normalized.contains("enable javascript and cookies")
            || (normalized.contains("<html") && normalized.contains("challenge"))
    }

    private struct APICallEnvelope {
        let statusCode: Int
        let body: String
    }

    private struct APIKeyUsageEntry: Decodable {
        let success: Int
        let failed: Int
        let recentRequests: [RecentRequestBucket]
        let tokens: APIKeyTokenTotals?
        let requests: Int?
        let failedRequests: Int?

        enum CodingKeys: String, CodingKey {
            case success
            case failed
            case recentRequests = "recent_requests"
            case tokens
            case requests
            case failedRequests = "failed_requests"
        }
    }

    private func apiCallEnvelope(from data: Data) -> APICallEnvelope? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              let statusCode = intValue(dictionary["status_code"] ?? dictionary["statusCode"])
        else {
            return nil
        }

        let body = stringBody(from: dictionary["body"] ?? dictionary["data"] ?? "")
        return APICallEnvelope(statusCode: statusCode, body: body)
    }

    private func stringBody(from value: Any) -> String {
        if let string = value as? String {
            return string
        }
        if value is NSNull {
            return ""
        }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return String(describing: value)
    }

    private func intValue(_ value: Any?) -> Int? {
        switch value {
        case let value as Int:
            return value
        case let value as Int64:
            return Int(value)
        case let value as Double:
            return Int(value)
        case let value as NSNumber:
            return value.intValue
        case let value as String:
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    private func data(for request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PoolAPIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw PoolAPIError.httpStatus(http.statusCode, body)
        }
        return data
    }

    private struct XiaomiUsageResponse: Decodable {
        let data: XiaomiUsageData
    }

    private struct XiaomiUsageData: Decodable {
        let monthUsage: XiaomiUsageBucket?
        let usage: XiaomiUsageBucket
    }

    private struct XiaomiUsageBucket: Decodable {
        let percent: Double?
        let items: [XiaomiUsageItem]

        func item(named name: String) -> XiaomiUsageItem? {
            items.first { $0.name == name }
        }
    }

    private struct XiaomiUsageItem: Decodable {
        let name: String
        let used: Double
        let limit: Double
        let percent: Double?
    }

    private struct XiaomiDetailResponse: Decodable {
        let data: XiaomiDetailData
    }

    private struct XiaomiDetailData: Decodable {
        let planCode: String?
        let planName: String?
        let currentPeriodEnd: String?
        let expired: Bool?
        let enableAutoRenew: Bool?
    }
}
