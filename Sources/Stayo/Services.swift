import Foundation

public struct DatabaseClient: Sendable {
    let transport: Transport; let auth: AuthClient
    public func from(_ table: String, schema: String = "public") -> TableQuery { TableQuery(transport: transport, auth: auth, table: table, schema: schema) }
    public func rpc<T: Decodable & Sendable, P: Encodable & Sendable>(_ name: String, parameters: P, as type: T.Type = T.self, schema: String = "public") async throws -> T {
        let body = try JSONEncoder().encode(parameters); let transport = transport
        return try await auth.bound { token in try await transport.json(type, ["rest", "v1", "rpc", name], method: "POST", token: token, body: body, headers: ["Content-Profile": schema]) }
    }
}
public struct QueryResult<T: Sendable>: Sendable { public let value: T; public let contentRange: String? }
public enum FilterOperator: String, Sendable { case eq, neq, gt, gte, lt, lte, like, ilike, `is`, cs, cd, ov }
public struct TableQuery: Sendable {
    let transport: Transport; let auth: AuthClient; let table: String; let schema: String
    private var query: [URLQueryItem] = []; private var rangeHeader: String?
    init(transport: Transport, auth: AuthClient, table: String, schema: String) { self.transport = transport; self.auth = auth; self.table = table; self.schema = schema }
    public func select(_ columns: String = "*") -> Self { var v = self; v.query.append(.init(name: "select", value: columns)); return v }
    public func filter(_ column: String, _ operation: FilterOperator, _ value: String) -> Self {
        var v = self; v.query.append(.init(name: column, value: operation.rawValue + "." + value)); return v
    }
    public func order(_ column: String, ascending: Bool = true) -> Self { var v = self; v.query.append(.init(name: "order", value: column + (ascending ? ".asc" : ".desc"))); return v }
    public func range(_ from: Int, _ to: Int) throws -> Self {
        guard from >= 0 && to >= from else { throw StayoError.invalidConfiguration("Invalid pagination range") }
        var v = self; v.rangeHeader = "\(from)-\(to)"; return v
    }
    public func limit(_ count: Int) throws -> Self {
        guard count >= 0 else { throw StayoError.invalidConfiguration("Invalid pagination limit") }
        var v = self; v.query.append(.init(name: "limit", value: String(count))); return v
    }
    public func execute<T: Decodable & Sendable>(as type: T.Type = T.self, exactCount: Bool = false) async throws -> QueryResult<T> { try await perform("GET", body: nil, type: type, exactCount: exactCount) }
    public func insert<P: Encodable & Sendable, T: Decodable & Sendable>(_ value: P, as type: T.Type = T.self) async throws -> QueryResult<T> { try await perform("POST", body: JSONEncoder().encode(value), type: type) }
    public func update<P: Encodable & Sendable, T: Decodable & Sendable>(_ value: P, as type: T.Type = T.self) async throws -> QueryResult<T> { try await perform("PATCH", body: JSONEncoder().encode(value), type: type) }
    public func delete<T: Decodable & Sendable>(as type: T.Type = T.self) async throws -> QueryResult<T> { try await perform("DELETE", body: nil, type: type) }
    private func perform<T: Decodable & Sendable>(_ method: String, body: Data?, type: T.Type, exactCount: Bool = false) async throws -> QueryResult<T> {
        var headers = ["Accept-Profile": schema, "Content-Profile": schema, "Prefer": "return=representation" + (exactCount ? ",count=exact" : "")]
        if let rangeHeader { headers["Range"] = rangeHeader; headers["Range-Unit"] = "items" }
        let transport = transport; let table = table; let query = query; let requestHeaders = headers
        return try await auth.bound { token in
            let (data, response) = try await transport.request(["rest", "v1", table], method: method, query: query, token: token, body: body, headers: requestHeaders)
            guard let value = try? JSONDecoder().decode(type, from: data) else { throw StayoError.invalidResponse }
            return QueryResult(value: value, contentRange: response.value(forHTTPHeaderField: "Content-Range"))
        }
    }
}

public struct StorageClient: Sendable {
    let transport: Transport; let auth: AuthClient
    public func bucket(_ name: String) -> StorageBucket { StorageBucket(transport: transport, auth: auth, name: name) }
}
public struct StorageBucket: Sendable {
    let transport: Transport; let auth: AuthClient; let name: String
    private func segments(_ path: String) throws -> [String] {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        _ = try transport.url(["storage", "v1", "object", name] + parts)
        return parts
    }
    public func upload(_ path: String, data: Data, contentType: String, upsert: Bool = false) async throws -> JSONValue {
        let target = try ["storage", "v1", "object", name] + segments(path); let transport = transport
        return try await auth.bound { token in try await transport.json(JSONValue.self, target, method: "POST", token: token, body: data, headers: ["Content-Type": contentType, "x-upsert": upsert ? "true" : "false"]) }
    }
    public func download(_ path: String) async throws -> Data {
        let target = try ["storage", "v1", "object", name] + segments(path); let transport = transport
        return try await auth.bound { token in try await transport.request(target, token: token).0 }
    }
    public func remove(_ paths: [String]) async throws -> JSONValue {
        for path in paths { _ = try segments(path) }
        let body = try JSONEncoder().encode(["prefixes": paths]); let transport = transport; let name = name
        return try await auth.bound { token in try await transport.json(JSONValue.self, ["storage", "v1", "object", name], method: "DELETE", token: token, body: body) }
    }
    public func signedURL(_ path: String, expiresIn: Int = 60) async throws -> URL {
        guard expiresIn > 0 else { throw StayoError.invalidConfiguration("Signed URL lifetime must be positive") }
        struct Signed: Decodable { let signedURL: String }
        let target = try ["storage", "v1", "object", "sign", name] + segments(path); let body = try JSONEncoder().encode(["expiresIn": expiresIn]); let transport = transport
        let result = try await auth.bound { token in try await transport.json(Signed.self, target, method: "POST", token: token, body: body) }
        let url: URL?
        if result.signedURL.hasPrefix("/object/") { url = URL(string: "/storage/v1" + result.signedURL, relativeTo: transport.origin)?.absoluteURL }
        else { url = URL(string: result.signedURL, relativeTo: transport.origin)?.absoluteURL }
        guard let url, let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.user == nil, c.password == nil, c.fragment == nil,
              url.scheme == transport.origin.scheme, url.host == transport.origin.host, url.port == transport.origin.port,
              c.percentEncodedPath.hasPrefix("/storage/v1/object/sign/") else { throw StayoError.invalidResponse }
        return url
    }
}

public struct RuntimeCapabilities: Decodable, Sendable {
    public let protocolVersion: Int; public let runtimeVersion: String; public let capabilities: [String: Bool]
    enum CodingKeys: String, CodingKey { case protocolVersion = "protocol_version", runtimeVersion = "runtime_version", capabilities }
}
public struct FunctionsClient: Sendable {
    let transport: Transport; let auth: AuthClient
    public func capabilities() async throws -> RuntimeCapabilities { try await transport.json(RuntimeCapabilities.self, [".well-known", "stayo.json"]) }
    /// One dispatch only. URLSession cancellation follows the calling task. No mutation retry is performed.
    public func invoke<P: Encodable & Sendable, T: Decodable & Sendable>(_ name: String, body: P, as type: T.Type = T.self) async throws -> T {
        let generation = try await auth.functionGeneration()
        let marker = try await capabilities()
        guard marker.protocolVersion == 1, marker.runtimeVersion == "1.3.0-compatible", marker.capabilities["functions"] == true else { throw StayoError.unavailableCapability("functions") }
        try Task.checkCancellation()
        let encoded = try JSONEncoder().encode(body)
        return try await auth.invokeFunction(name, body: encoded, generation: generation, as: type)
    }
}
