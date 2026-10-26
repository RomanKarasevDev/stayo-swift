import Foundation

public enum StayoError: Error, Equatable, Sendable {
    case invalidConfiguration(String), invalidPath, invalidCallback, noSession, staleSession
    case network(Int), http(status: Int, code: String?), invalidResponse, unavailableCapability(String), keychain(Int32)
}

public enum JSONValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        }
    }
}

final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

final class Transport: @unchecked Sendable {
    let origin: URL
    let publicKey: String
    let session: URLSession
    private let redirect = NoRedirect()
    init(url: URL, publicKey: String, configuration: URLSessionConfiguration) throws {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.user == nil, c.password == nil,
              c.query == nil, c.fragment == nil, (c.path.isEmpty || c.path == "/"), let host = c.host,
              c.scheme == "https" || (c.scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)) else {
            throw StayoError.invalidConfiguration("Use an HTTPS project origin, or loopback HTTP for development")
        }
        guard !publicKey.isEmpty, !publicKey.contains(where: { $0.isWhitespace || $0.isNewline }),
              !publicKey.lowercased().hasPrefix("sb_secret_"), !publicKey.lowercased().hasPrefix("service_role") else {
            throw StayoError.invalidConfiguration("A public application key is required")
        }
        let parts = publicKey.split(separator: ".")
        if parts.count == 3, let payload = Data(base64URL: String(parts[1])),
           let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
           let role = object["role"] as? String, role != "anon" {
            throw StayoError.invalidConfiguration("Privileged keys cannot be used in public clients")
        }
        c.scheme = c.scheme?.lowercased(); c.host = host.lowercased(); c.path = ""
        if (c.scheme == "https" && c.port == 443) || (c.scheme == "http" && c.port == 80) { c.port = nil }
        guard let normalized = c.url else { throw StayoError.invalidPath }
        self.origin = normalized; self.publicKey = publicKey
        let config = configuration.copy() as! URLSessionConfiguration
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        self.session = URLSession(configuration: config, delegate: redirect, delegateQueue: nil)
    }
    func url(_ segments: [String], query: [URLQueryItem] = []) throws -> URL {
        var c = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        c.percentEncodedPath = try "/" + segments.map { segment in
            guard !segment.isEmpty, segment != ".", segment != "..", !segment.contains("/"), !segment.contains("\\"),
                  !segment.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  let encoded = segment.addingPercentEncoding(withAllowedCharacters: allowed) else { throw StayoError.invalidPath }
            return encoded
        }.joined(separator: "/")
        c.queryItems = query.isEmpty ? nil : query
        guard let result = c.url else { throw StayoError.invalidPath }; return result
    }
    func request(_ segments: [String], method: String = "GET", query: [URLQueryItem] = [], token: String? = nil,
                 body: Data? = nil, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: try url(segments, query: query)); request.httpMethod = method
        request.setValue(publicKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token ?? publicKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("stayo-swift/0.1.0", forHTTPHeaderField: "X-Client-Info")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = body
        let data: Data; let response: URLResponse
        try Task.checkCancellation()
        do { (data, response) = try await session.data(for: request, delegate: redirect) }
        catch let error as URLError { if error.code == .cancelled { throw CancellationError() }; throw StayoError.network(error.errorCode) }
        catch { if Task.isCancelled { throw CancellationError() }; throw StayoError.invalidResponse }
        guard let response = response as? HTTPURLResponse else { throw StayoError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            // Only bounded machine codes survive; upstream error text can contain submitted secrets.
            let candidate = (parsed?["code"] as? String) ?? (parsed?["error_code"] as? String)
                ?? ((parsed?["error"] as? [String: Any])?["code"] as? String)
            let code = candidate.flatMap { value in
                !value.isEmpty && value.count <= 80 && value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) ? value : nil
            }
            throw StayoError.http(status: response.statusCode, code: code)
        }
        return (data, response)
    }
    func json<T: Decodable>(_ type: T.Type, _ segments: [String], method: String = "GET", query: [URLQueryItem] = [],
                            token: String? = nil, body: Data? = nil, headers: [String: String] = [:]) async throws -> T {
        let (data, _) = try await request(segments, method: method, query: query, token: token, body: body, headers: headers)
        do { return try JSONDecoder().decode(type, from: data) } catch { throw StayoError.invalidResponse }
    }
}

extension Data {
    init?(base64URL: String) {
        let s = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        self.init(base64Encoded: s + String(repeating: "=", count: (4 - s.count % 4) % 4))
    }
    var base64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}

public final class StayoClient: Sendable {
    public static let version = "0.1.0"
    public let auth: AuthClient
    public let database: DatabaseClient
    public let storage: StorageClient
    public let functions: FunctionsClient
    public let realtime: RealtimeClient
    public init(url: URL, publicKey: String, namespace: String = "default", sessionStore: (any SessionStore)? = nil,
                configuration: URLSessionConfiguration = .ephemeral) throws {
        let transport = try Transport(url: url, publicKey: publicKey, configuration: configuration)
        let auth = try AuthClient(transport: transport, store: sessionStore ?? KeychainSessionStore(), namespace: namespace)
        self.auth = auth; database = DatabaseClient(transport: transport, auth: auth)
        storage = StorageClient(transport: transport, auth: auth); functions = FunctionsClient(transport: transport, auth: auth)
        realtime = RealtimeClient(transport: transport, auth: auth)
    }
}
