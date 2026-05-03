import Foundation

enum PoolAPIError: LocalizedError {
    case notConfigured
    case invalidBaseURL
    case httpStatus(Int, String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Pool URL and management key are required."
        case .invalidBaseURL:
            return "Pool URL is invalid."
        case let .httpStatus(status, body):
            return "HTTP \(status): \(body.prefix(160))"
        case .invalidResponse:
            return "The server returned an invalid response."
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

    func fetchWhamUsage(authIndex: String, chatgptAccountID: String? = nil) async throws -> UsageSnapshot {
        let url = try managementURL(path: "/v0/management/api-call")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyManagementHeaders(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var headers = [
            "Authorization": "Bearer $TOKEN$",
            "Accept": "application/json",
            "Content-Type": "application/json",
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/537.36 (KHTML, like Gecko) Safari/537.36"
        ]
        if let chatgptAccountID = chatgptAccountID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !chatgptAccountID.isEmpty {
            headers["ChatGPT-Account-Id"] = chatgptAccountID
        }

        let payload = APICallRequest(
            authIndex: authIndex,
            method: "GET",
            url: "https://chatgpt.com/backend-api/wham/usage",
            header: headers,
            data: nil
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let data = try await data(for: request)
        let response = try JSONDecoder().decode(APICallResponse.self, from: data)
        guard (200..<300).contains(response.statusCode) else {
            throw PoolAPIError.httpStatus(response.statusCode, response.body)
        }
        return UsageParser.parse(response.body)
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
}
