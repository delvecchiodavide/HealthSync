import Foundation

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GoogleAPIError.invalidResponse }
        return (data, http)
    }
}

/// Supplies OAuth access tokens. `forceRefresh` is set after a 401.
public protocol AccessTokenProvider: Sendable {
    func accessToken(forceRefresh: Bool) async throws -> String
}

public enum GoogleAPIError: Error, LocalizedError, Sendable, Equatable {
    case unauthorized
    case http(status: Int, message: String)
    case invalidResponse

    public var isNotFound: Bool {
        if case .http(404, _) = self { return true }
        return false
    }

    public var errorDescription: String? {
        switch self {
        case .unauthorized: "Google sign-in expired. Please sign in again."
        case .http(let status, let message): "Google API error \(status): \(message)"
        case .invalidResponse: "Unexpected response from Google."
        }
    }
}

public struct RetryPolicy: Sendable {
    public var maxAttempts = 5
    public var baseDelay: TimeInterval = 1
    public var maxDelay: TimeInterval = 32

    public init(maxAttempts: Int = 5, baseDelay: TimeInterval = 1, maxDelay: TimeInterval = 32) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    /// Exponential backoff with jitter. `attempt` starts at 0; `jitter` is in 0...1.
    public func delay(forAttempt attempt: Int, jitter: Double) -> TimeInterval {
        let exponential = min(maxDelay, baseDelay * pow(2, Double(attempt)))
        return exponential * (0.5 + 0.5 * min(max(jitter, 0), 1))
    }

    public static func isRetryable(status: Int, body: Data) -> Bool {
        if status == 429 || (500...599).contains(status) { return true }
        // Drive reports per-user rate limits as 403.
        if status == 403, let text = String(data: body, encoding: .utf8) {
            return text.contains("rateLimitExceeded") || text.contains("userRateLimitExceeded")
        }
        return false
    }
}

/// Authorized JSON requests with retry on 429/5xx and one token refresh on 401.
public struct GoogleAPIClient: Sendable {
    let transport: any HTTPTransport
    let tokens: any AccessTokenProvider
    let retry: RetryPolicy
    let sleep: @Sendable (TimeInterval) async throws -> Void
    let jitter: @Sendable () -> Double

    public init(
        transport: any HTTPTransport = URLSessionTransport(),
        tokens: any AccessTokenProvider,
        retry: RetryPolicy = RetryPolicy(),
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }
    ) {
        self.transport = transport
        self.tokens = tokens
        self.retry = retry
        self.sleep = sleep
        self.jitter = jitter
    }

    public func data(_ method: String, _ url: URL, json body: [String: Any]? = nil) async throws -> Data {
        let bodyData = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        var attempt = 0
        var refreshedAfter401 = false

        while true {
            try Task.checkCancellation()
            let token = try await tokens.accessToken(forceRefresh: refreshedAfter401)
            var request = URLRequest(url: url, timeoutInterval: 30)
            request.httpMethod = method
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let bodyData {
                request.httpBody = bodyData
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }

            let data: Data
            let response: HTTPURLResponse
            do {
                (data, response) = try await transport.send(request)
            } catch let error as URLError where [.timedOut, .networkConnectionLost].contains(error.code) {
                guard attempt + 1 < retry.maxAttempts else { throw error }
                try await sleep(retry.delay(forAttempt: attempt, jitter: jitter()))
                attempt += 1
                continue
            }

            switch response.statusCode {
            case 200..<300:
                return data
            case 401:
                if refreshedAfter401 { throw GoogleAPIError.unauthorized }
                Log.google.info("401 from Google, refreshing token")
                refreshedAfter401 = true
            case let status where RetryPolicy.isRetryable(status: status, body: data) && attempt + 1 < retry.maxAttempts:
                Log.google.info("Google returned \(status), retrying (attempt \(attempt + 1))")
                try await sleep(retry.delay(forAttempt: attempt, jitter: jitter()))
                attempt += 1
            default:
                throw GoogleAPIError.http(status: response.statusCode, message: Self.errorMessage(from: data))
            }
        }
    }

    public func decode<T: Decodable>(_ type: T.Type, _ method: String, _ url: URL, json body: [String: Any]? = nil) async throws -> T {
        let data = try await data(method, url, json: body)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw GoogleAPIError.invalidResponse
        }
    }

    static func errorMessage(from data: Data) -> String {
        struct Envelope: Decodable { struct Inner: Decodable { let message: String? }; let error: Inner? }
        if let message = (try? JSONDecoder().decode(Envelope.self, from: data))?.error?.message {
            return message
        }
        return String(decoding: data.prefix(300), as: UTF8.self)
    }

    static func url(_ base: String, path: String = "", query: [String: String] = [:]) -> URL {
        var components = URLComponents(string: base)!
        components.path += path
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return components.url!
    }
}
