import Foundation
import CryptoKit
import Security
import AuthenticationServices

public struct AuthUser: Codable, Sendable, Equatable {
    public let id: String
    public let email: String?
    public let userMetadata: [String: JSONValue]?
    enum CodingKeys: String, CodingKey { case id, email; case userMetadata = "user_metadata" }
}

public struct Session: Codable, Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: TimeInterval
    public let user: AuthUser?
    enum CodingKeys: String, CodingKey { case accessToken = "access_token", refreshToken = "refresh_token", expiresAt = "expires_at", expiresIn = "expires_in", user }
    public init(accessToken: String, refreshToken: String, expiresAt: TimeInterval, user: AuthUser? = nil) {
        self.accessToken = accessToken; self.refreshToken = refreshToken; self.expiresAt = expiresAt; self.user = user
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try c.decode(String.self, forKey: .accessToken); refreshToken = try c.decode(String.self, forKey: .refreshToken)
        expiresAt = try c.decodeIfPresent(TimeInterval.self, forKey: .expiresAt) ?? Date().timeIntervalSince1970 + c.decode(TimeInterval.self, forKey: .expiresIn)
        user = try c.decodeIfPresent(AuthUser.self, forKey: .user)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(accessToken, forKey: .accessToken); try c.encode(refreshToken, forKey: .refreshToken)
        try c.encode(expiresAt, forKey: .expiresAt); try c.encodeIfPresent(user, forKey: .user)
    }
}

/// Implementations must be safe to call from any thread. Storage keys are scoped by normalized project origin and caller namespace.
public protocol SessionStore: Sendable {
    func load(key: String) throws -> Data?
    func save(_ data: Data, key: String) throws
    func remove(key: String) throws
}
public final class MemorySessionStore: SessionStore, @unchecked Sendable {
    private let lock = NSLock(); private var values: [String: Data] = [:]
    public init() {}
    public func load(key: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[key] }
    public func save(_ data: Data, key: String) throws { lock.lock(); defer { lock.unlock() }; values[key] = data }
    public func remove(key: String) throws { lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: key) }
}
public struct KeychainSessionStore: SessionStore {
    public init() {}
    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "live.stayo.sdk.session.v1", kSecAttrAccount as String: key]
    }
    public func load(key: String) throws -> Data? {
        var q = query(key); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?; let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }; guard status == errSecSuccess else { throw StayoError.keychain(status) }
        return result as? Data
    }
    public func save(_ data: Data, key: String) throws {
        let q = query(key)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = q; add[kSecValueData as String] = data; add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(add as CFDictionary, nil); guard added == errSecSuccess else { throw StayoError.keychain(added) }
        } else if status != errSecSuccess { throw StayoError.keychain(status) }
    }
    public func remove(key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StayoError.keychain(status) }
    }
}

public enum OAuthProvider: String, Sendable { case google, apple }
public struct OAuthRequest: Sendable {
    public let url: URL
    public let redirectURL: URL
    fileprivate let id: UUID
}

public actor AuthClient {
    private let transport: Transport; private let store: any SessionStore; private let storageKey: String
    private var current: Session?
    private var generation = 0
    private var sessionRevision = 0
    private var exchangingOAuth: UUID?
    private var refreshTask: (UUID, Task<Session, Error>)?
    private var functionCancellations: [UUID: @Sendable () -> Void] = [:]
    private var pending: (id: UUID, verifier: String, redirect: URL, expires: Date)?
    private var listeners: [UUID: @Sendable (Session?) async -> Void] = [:]
    init(transport: Transport, store: any SessionStore, namespace: String) throws {
        self.transport = transport; self.store = store
        storageKey = SHA256.hash(data: Data((transport.origin.absoluteString + "\n" + namespace).utf8)).map { String(format: "%02x", $0) }.joined()
        if let data = try store.load(key: storageKey) { current = try JSONDecoder().decode(Session.self, from: data) }
    }
    public func session() async throws -> Session? {
        if let current, current.expiresAt <= Date().timeIntervalSince1970 + 30 { return try await refresh() }; return current
    }
    func token(required: Bool = false) async throws -> String? {
        let token = try await session()?.accessToken
        if required && token == nil { throw StayoError.noSession }; return token
    }
    // Bind a prepared invocation to the initiating login lifetime. Refresh is
    // allowed within that lifetime; a new login with the same token is not.
    func functionGeneration() async throws -> Int {
        try Task.checkCancellation()
        let expected = generation
        _ = try await token(required: true)
        guard expected == generation, current != nil else { throw StayoError.staleSession }
        return expected
    }
    private func cancelFunctions() {
        for cancel in functionCancellations.values { cancel() }
        functionCancellations.removeAll()
    }
    /// Runs one Database, RPC or Storage request bound to the auth generation
    /// it started in. Sign-in, sign-out, account switch and refresh rejection
    /// cancel it, and a late response is rejected instead of being delivered
    /// to the next identity. A request already received by the server is not
    /// undone and is never retried.
    func bound<T: Sendable>(_ operation: @escaping @Sendable (String?) async throws -> T) async throws -> T {
        try Task.checkCancellation()
        let expected = generation
        let token = try await token()
        guard expected == generation else { throw StayoError.staleSession }
        try Task.checkCancellation()
        let id = UUID()
        let task = Task<T, Error> {
            try Task.checkCancellation()
            let result = try await operation(token)
            try Task.checkCancellation()
            return result
        }
        functionCancellations[id] = { task.cancel() }
        defer { functionCancellations.removeValue(forKey: id) }
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard expected == generation else { throw StayoError.staleSession }
            try Task.checkCancellation()
            return result
        } catch {
            guard expected == generation else { throw StayoError.staleSession }
            throw error
        }
    }
    func invokeFunction<T: Decodable & Sendable>(_ name: String, body: Data, generation expected: Int, as type: T.Type) async throws -> T {
        guard expected == generation, current != nil else { throw StayoError.staleSession }
        let token = try await token(required: true)
        guard expected == generation, current != nil else { throw StayoError.staleSession }
        try Task.checkCancellation()
        let id = UUID(); let transport = transport
        // Register before yielding the actor. Transitions cancel even a child
        // that has not reached URLSession yet. A dispatched server mutation
        // cannot be rolled back by client cancellation and is never retried.
        let task = Task<T, Error> {
            try Task.checkCancellation()
            let result = try await transport.json(type, ["functions", "v1", name], method: "POST", token: token, body: body)
            try Task.checkCancellation()
            return result
        }
        functionCancellations[id] = { task.cancel() }
        defer { functionCancellations.removeValue(forKey: id) }
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard expected == generation, current != nil else { throw StayoError.staleSession }
            try Task.checkCancellation()
            return result
        } catch {
            guard expected == generation, current != nil else { throw StayoError.staleSession }
            throw error
        }
    }
    func listen(id: UUID, callback: @escaping @Sendable (Session?) async -> Void) { listeners[id] = callback }
    func unlisten(id: UUID) { listeners.removeValue(forKey: id) }
    private func notify() async { let value = current; for callback in listeners.values { await callback(value) } }
    private func save(_ session: Session, generation expected: Int) async throws -> Session {
        guard expected == generation else { throw StayoError.staleSession }
        try store.save(JSONEncoder().encode(session), key: storageKey); current = session; sessionRevision += 1
        await notify(); guard expected == generation else { throw StayoError.staleSession }; return session
    }
    private func body(_ value: [String: JSONValue]) throws -> Data { try JSONEncoder().encode(value) }
    private func beginTransition(oauthID: UUID? = nil) async throws -> Int {
        generation += 1; sessionRevision += 1
        cancelFunctions()
        let expected = generation
        refreshTask?.1.cancel(); refreshTask = nil; pending = nil; exchangingOAuth = oauthID; current = nil
        let result = Result { try store.remove(key: storageKey) }
        await notify(); try result.get()
        guard expected == generation else { throw StayoError.staleSession }; return expected
    }
    private func establish(_ path: String, grant: String? = nil, value: [String: JSONValue], generation supplied: Int? = nil) async throws -> Session {
        let expected: Int
        if let supplied { expected = supplied } else { expected = try await beginTransition() }
        let response: Session = try await transport.json(Session.self, ["auth", "v1", path], method: "POST", query: grant.map { [URLQueryItem(name: "grant_type", value: $0)] } ?? [], body: body(value))
        return try await save(response, generation: expected)
    }
    @discardableResult public func signIn(email: String, password: String) async throws -> Session {
        return try await establish("token", grant: "password", value: ["email": .string(email), "password": .string(password)])
    }
    /// Confirmation-enabled projects return a user without a session until the email is verified.
    public func signUp(email: String, password: String, metadata: [String: JSONValue] = [:]) async throws -> AuthUser? {
        let expected = try await beginTransition()
        let (data, _) = try await transport.request(["auth", "v1", "signup"], method: "POST", body: body(["email": .string(email), "password": .string(password), "data": .object(metadata)]))
        if let session = try? JSONDecoder().decode(Session.self, from: data) { return try await save(session, generation: expected).user }
        guard expected == generation else { throw StayoError.staleSession }
        if let user = try? JSONDecoder().decode(AuthUser.self, from: data) { return user }
        struct Result: Decodable { let user: AuthUser? }; return try JSONDecoder().decode(Result.self, from: data).user
    }
    @discardableResult public func verify(email: String, token: String, type: String = "signup") async throws -> Session {
        guard ["signup", "recovery", "email", "email_change", "magiclink"].contains(type) else { throw StayoError.invalidConfiguration("Unsupported verification type") }
        return try await establish("verify", value: ["email": .string(email), "token": .string(token), "type": .string(type)])
    }
    public func recoverPassword(email: String, redirectURL: URL? = nil) async throws {
        _ = try await transport.request(["auth", "v1", "recover"], method: "POST", query: redirectURL.map { [URLQueryItem(name: "redirect_to", value: $0.absoluteString)] } ?? [], body: body(["email": .string(email)]))
    }
    public func user() async throws -> AuthUser { try await currentUser(method: "GET") }
    public func updatePassword(_ password: String) async throws -> AuthUser { try await currentUser(method: "PUT", payload: body(["password": .string(password)])) }
    private func currentUser(method: String, payload: Data? = nil) async throws -> AuthUser {
        let token = try await self.token(required: true); let expected = generation
        let user = try await transport.json(AuthUser.self, ["auth", "v1", "user"], method: method, token: token, body: payload)
        guard expected == generation, current?.accessToken == token else { throw StayoError.staleSession }
        return user
    }
    @discardableResult public func refresh() async throws -> Session {
        try Task.checkCancellation()
        if let task = refreshTask {
            let expected = generation
            let result = try await withTaskCancellationHandler { try await task.1.value } onCancel: { task.1.cancel() }
            try Task.checkCancellation()
            guard expected == generation else { throw StayoError.staleSession }; return result
        }
        guard let current else { throw StayoError.noSession }
        let expected = generation; let revision = sessionRevision; let id = UUID(); let transport = transport
        let encoded = try body(["refresh_token": .string(current.refreshToken)])
        let task = Task<Session, Error> {
            try await transport.json(Session.self, ["auth", "v1", "token"], method: "POST", query: [URLQueryItem(name: "grant_type", value: "refresh_token")], body: encoded)
        }
        refreshTask = (id, task)
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard expected == generation, revision == sessionRevision, self.current?.refreshToken == current.refreshToken else { throw StayoError.staleSession }
            let saved = try await save(result, generation: expected)
            if refreshTask?.0 == id { refreshTask = nil }; return saved
        } catch {
            if refreshTask?.0 == id { refreshTask = nil }
            if expected == generation, case StayoError.http(let status, _) = error, status == 400 || status == 401 {
                self.current = nil; cancelFunctions(); try store.remove(key: storageKey); await notify()
            }; throw error
        }
    }
    public func signOut() async throws {
        let token = current?.accessToken; generation += 1; sessionRevision += 1; pending = nil; exchangingOAuth = nil; refreshTask?.1.cancel(); refreshTask = nil; current = nil
        cancelFunctions()
        // Clear listeners even if protected storage is unavailable.
        let storageResult = Result { try store.remove(key: storageKey) }; await notify(); try storageResult.get()
        if let token { _ = try await transport.request(["auth", "v1", "logout"], method: "POST", query: [.init(name: "scope", value: "local")], token: token) }
    }
    public func beginOAuth(provider: OAuthProvider, redirectURL: URL, allowedRedirectURLs: [URL]) async throws -> OAuthRequest {
        guard allowedRedirectURLs.contains(redirectURL), let c = URLComponents(url: redirectURL, resolvingAgainstBaseURL: false),
              c.scheme != nil, c.user == nil, c.password == nil, c.fragment == nil,
              !(c.queryItems ?? []).contains(where: { ["code", "error", "error_description", "access_token"].contains($0.name) }) else { throw StayoError.invalidCallback }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw StayoError.invalidResponse }
        let verifier = Data(bytes).base64URL
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let id = UUID(); _ = try await beginTransition(oauthID: id)
        pending = (id, verifier, redirectURL, Date().addingTimeInterval(600))
        let url = try transport.url(["auth", "v1", "authorize"], query: [.init(name: "provider", value: provider.rawValue), .init(name: "redirect_to", value: redirectURL.absoluteString), .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "s256")])
        return OAuthRequest(url: url, redirectURL: redirectURL, id: id)
    }
    public func cancelOAuth(_ request: OAuthRequest) async throws {
        if pending?.id == request.id || exchangingOAuth == request.id {
            generation += 1; sessionRevision += 1; pending = nil; exchangingOAuth = nil; current = nil
            cancelFunctions()
            let result = Result { try store.remove(key: storageKey) }; await notify(); try result.get()
        }
    }
    @discardableResult public func completeOAuth(_ request: OAuthRequest, callbackURL: URL) async throws -> Session {
        guard let flow = pending, flow.id == request.id, exchangingOAuth == request.id else { throw StayoError.invalidCallback }
        pending = nil; let expectedGeneration = generation
        defer { if exchangingOAuth == request.id { exchangingOAuth = nil } }
        guard flow.expires > Date(), let callback = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let redirect = URLComponents(url: flow.redirect, resolvingAgainstBaseURL: false),
              callback.scheme == redirect.scheme, callback.host == redirect.host, callback.port == redirect.port,
              callback.path == redirect.path, callback.user == nil, callback.password == nil, callback.fragment == nil else { throw StayoError.invalidCallback }
        let items = callback.queryItems ?? []; let expected = redirect.queryItems ?? []
        guard expected.allSatisfy({ items.contains($0) }), !items.contains(where: { $0.name == "error" }),
              items.filter({ $0.name == "code" }).count == 1, let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else { throw StayoError.invalidCallback }
        return try await establish("token", grant: "pkce", value: ["auth_code": .string(code), "code_verifier": .string(flow.verifier)], generation: expectedGeneration)
    }
}

/// Keep one coordinator for each visible login flow. Uses the system authentication browser.
@MainActor public final class OAuthBrowser: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var browser: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, Error>?
    private var flowID: UUID?
    private func finish(_ result: Result<URL, Error>, id: UUID) {
        guard flowID == id else { return }
        let pending = continuation; continuation = nil; pending?.resume(with: result)
    }
    private let anchor: ASPresentationAnchor
    public init(anchor: ASPresentationAnchor) { self.anchor = anchor }
    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { anchor }
    public func signIn(auth: AuthClient, provider: OAuthProvider, redirectURL: URL, allowedRedirectURLs: [URL]) async throws -> Session {
        guard flowID == nil else { throw StayoError.invalidConfiguration("A login flow is already open") }
        try Task.checkCancellation()
        let id = UUID(); flowID = id
        defer { if flowID == id { flowID = nil; browser = nil } }
        let request = try await auth.beginOAuth(provider: provider, redirectURL: redirectURL, allowedRedirectURLs: allowedRedirectURLs)
        do {
            let callback: URL = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    self.continuation = continuation
                    if Task.isCancelled { finish(.failure(CancellationError()), id: id); return }
                    browser = ASWebAuthenticationSession(url: request.url, callbackURLScheme: redirectURL.scheme) { url, error in
                        Task { @MainActor in
                            if let url { self.finish(.success(url), id: id) }
                            else if let error, (error as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue { self.finish(.failure(CancellationError()), id: id) }
                            else { self.finish(.failure(StayoError.invalidCallback), id: id) }
                        }
                    }
                    browser?.presentationContextProvider = self; browser?.prefersEphemeralWebBrowserSession = true
                    if browser?.start() != true { browser = nil; finish(.failure(StayoError.invalidCallback), id: id) }
                }
            } onCancel: { Task { @MainActor in
                guard self.flowID == id else { return }
                self.browser?.cancel(); self.finish(.failure(CancellationError()), id: id)
            } }
            browser = nil; return try await auth.completeOAuth(request, callbackURL: callback)
        } catch { browser = nil; try await auth.cancelOAuth(request); throw error }
    }
}
