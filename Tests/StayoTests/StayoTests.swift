import XCTest
@testable import Stayo

final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    struct Reply { var status: Int = 200; var json: String = "{}"; var headers: [String: String] = [:]; var delay: Double = 0; var gate: DispatchSemaphore? }
    private static let lock = NSLock()
    private static var callback: ((URLRequest) throws -> Reply)?
    private var stopped = false
    private let stateLock = NSLock()
    static func handler(_ value: @escaping (URLRequest) throws -> Reply) { lock.lock(); callback = value; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let callback = Self.callback; Self.lock.unlock()
        do {
            let reply = try callback!(request)
            DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay) { [self] in
                if let gate = reply.gate { _ = gate.wait(timeout: .now() + 5) }
                stateLock.lock(); let cancelled = stopped; stateLock.unlock(); guard !cancelled else { return }
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(reply.json.utf8)); client?.urlProtocolDidFinishLoading(self)
            }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { stateLock.lock(); stopped = true; stateLock.unlock() }
}

final class StayoTests: XCTestCase {
    private let sessionJSON = "{\"access_token\":\"user-token\",\"refresh_token\":\"refresh-token\",\"expires_in\":3600,\"user\":{\"id\":\"u1\",\"email\":\"user@example.test\"}}"
    private let config: URLSessionConfiguration = { let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [FixtureProtocol.self]; return c }()
    private func client(_ url: String = "https://project.example.test", store: any SessionStore = MemorySessionStore(), namespace: String = "default") throws -> StayoClient {
        try StayoClient(url: URL(string: url)!, publicKey: "public-test-key", namespace: namespace, sessionStore: store, configuration: config)
    }
    func testEmailAndRecoveryCodeVerificationInstallsServerSession() async throws {
        let reply = sessionJSON
        for type in ["email", "recovery"] {
            let count = Counter()
            FixtureProtocol.handler { request in
                count.increment()
                XCTAssertEqual(request.url?.path, "/auth/v1/verify")
                XCTAssertEqual(request.httpMethod, "POST")
                let bytes: Data
                if let data = request.httpBody { bytes = data }
                else if let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
                    while true {
                        let read = stream.read(&buffer, maxLength: buffer.count)
                        if read < 0 { throw URLError(.cannotDecodeRawData) }
                        if read == 0 { break }
                        data.append(buffer, count: read)
                    }
                    bytes = data
                } else { throw URLError(.badServerResponse) }
                let payload = try JSONSerialization.jsonObject(with: bytes) as! [String: String]
                XCTAssertEqual(payload, ["email": "user@example.test", "token": "123456", "type": type])
                return .init(json: reply)
            }
            let sdk = try client()
            let result = try await sdk.auth.verify(email: "user@example.test", token: "123456", type: type)
            XCTAssertEqual(result.user?.id, "u1")
            let installed = try await sdk.auth.session()
            XCTAssertEqual(installed?.accessToken, "user-token")
            XCTAssertEqual(count.value, 1)
        }
    }
    func testRejectedRecoveryCodeDoesNotInstallOrRetrySession() async throws {
        let count = Counter()
        FixtureProtocol.handler { _ in count.increment(); return .init(status: 403, json: "{\"code\":\"otp_expired\"}") }
        let sdk = try client()
        do {
            _ = try await sdk.auth.verify(email: "user@example.test", token: "123456", type: "recovery")
            XCTFail("Rejected code installed a session")
        } catch let error as StayoError { XCTAssertEqual(error, .http(status: 403, code: "otp_expired")) }
        let installed = try await sdk.auth.session()
        XCTAssertNil(installed); XCTAssertEqual(count.value, 1)
    }
    func testAuthCRUDRPCAndStorageWireContracts() async throws {
        let session = sessionJSON; let count = Counter()
        FixtureProtocol.handler { request in
            count.increment(); let path = request.url!.path
            switch path {
            case "/auth/v1/signup": XCTAssertEqual(request.httpMethod, "POST"); return .init(json: "{\"id\":\"u1\",\"email\":\"user@example.test\"}")
            case "/auth/v1/verify": XCTAssertEqual(request.httpMethod, "POST"); return .init(json: session)
            case "/auth/v1/recover": XCTAssertEqual(request.httpMethod, "POST"); return .init()
            case "/auth/v1/user": XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer user-token"); return .init(json: "{\"id\":\"u1\"}")
            case "/rest/v1/notes": XCTAssertTrue(["POST", "PATCH", "DELETE"].contains(request.httpMethod!)); XCTAssertEqual(request.value(forHTTPHeaderField: "Prefer"), "return=representation"); return .init(json: "[]")
            case "/rest/v1/rpc/check": XCTAssertEqual(request.httpMethod, "POST"); return .init(json: "{\"ok\":true}")
            case "/storage/v1/object/photos/a.txt": XCTAssertEqual(request.httpMethod, "POST"); XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "text/plain"); return .init(json: "{\"Key\":\"photos/a.txt\"}")
            case "/storage/v1/object/photos": XCTAssertEqual(request.httpMethod, "DELETE"); return .init(json: "[]")
            default: XCTFail("Unexpected wire path"); return .init(status: 404)
            }
        }
        let sdk = try client()
        let user = try await sdk.auth.signUp(email: "user@example.test", password: "password")
        XCTAssertEqual(user?.id, "u1"); let preConfirmation = try await sdk.auth.session(); XCTAssertNil(preConfirmation)
        _ = try await sdk.auth.verify(email: "user@example.test", token: "123456")
        _ = try await sdk.auth.user(); _ = try await sdk.auth.updatePassword("new-password")
        try await sdk.auth.recoverPassword(email: "user@example.test")
        _ = try await sdk.database.from("notes").insert(["title": "New"], as: [JSONValue].self)
        _ = try await sdk.database.from("notes").filter("id", .eq, "n1").update(["title": "Changed"], as: [JSONValue].self)
        _ = try await sdk.database.from("notes").filter("id", .eq, "n1").delete(as: [JSONValue].self)
        _ = try await sdk.database.rpc("check", parameters: ["input": "value"], as: JSONValue.self)
        _ = try await sdk.storage.bucket("photos").upload("a.txt", data: Data("hello".utf8), contentType: "text/plain")
        _ = try await sdk.storage.bucket("photos").remove(["a.txt"])
        XCTAssertEqual(count.value, 11)
    }
    func testAccountTransitionsCannotBeOverwrittenByPreviousSession() async throws {
        let old = sessionJSON
        let next = old.replacingOccurrences(of: "user-token", with: "user-b-token").replacingOccurrences(of: "u1", with: "u2")
        FixtureProtocol.handler { _ in .init(json: old) }
        let sdk = try client(); _ = try await sdk.auth.signIn(email: "a", password: "a")
        let refreshes = Counter()
        FixtureProtocol.handler { request in
            if request.url!.query?.contains("refresh_token") == true { refreshes.increment(); return .init(json: old, delay: 0.2) }
            return .init(json: next, delay: 0.1)
        }
        let login = Task { try await sdk.auth.signIn(email: "b", password: "b") }
        try await Task.sleep(nanoseconds: 20_000_000)
        do { _ = try await sdk.auth.refresh(); XCTFail("Old account remained refreshable during login") }
        catch { XCTAssertEqual(error as? StayoError, .noSession) }
        _ = try await login.value
        XCTAssertEqual(refreshes.value, 0)
        let active = try await sdk.auth.session(); XCTAssertEqual(active?.user?.id, "u2")
        // An old verification or signup must not install after a newer login succeeds.
        for path in ["verify", "signup"] {
            FixtureProtocol.handler { request in .init(json: request.url!.path.hasSuffix("token") ? next : old, delay: request.url!.path.hasSuffix("token") ? 0.01 : 0.15) }
            let previous = Task {
                if path == "verify" { _ = try await sdk.auth.verify(email: "a", token: "123") }
                else { _ = try await sdk.auth.signUp(email: "a", password: "a") }
            }
            try await Task.sleep(nanoseconds: 20_000_000)
            _ = try await sdk.auth.signIn(email: "b", password: "b")
            do { _ = try await previous.value; XCTFail("Old auth result replaced the new account") }
            catch { XCTAssertEqual(error as? StayoError, .staleSession) }
            let value = try await sdk.auth.session(); XCTAssertEqual(value?.user?.id, "u2")
        }
    }
    func testCancelOAuthInvalidatesAlreadyExchangingCode() async throws {
        let response = sessionJSON
        FixtureProtocol.handler { _ in .init(json: response, delay: 0.15) }
        let store = MemorySessionStore(); let sdk = try client(store: store)
        let redirect = URL(string: "stayoexample://login/callback")!
        let request = try await sdk.auth.beginOAuth(provider: .google, redirectURL: redirect, allowedRedirectURLs: [redirect])
        let exchange = Task { try await sdk.auth.completeOAuth(request, callbackURL: URL(string: "stayoexample://login/callback?code=code")!) }
        try await Task.sleep(nanoseconds: 20_000_000); try await sdk.auth.cancelOAuth(request)
        do { _ = try await exchange.value; XCTFail("Canceled exchange installed a session") }
        catch { XCTAssertEqual(error as? StayoError, .staleSession) }
        let session = try await sdk.auth.session(); XCTAssertNil(session)
        let reopened = try client(store: store); let restored = try await reopened.auth.session(); XCTAssertNil(restored)
    }
    func testPreviousAccountUserResponseCannotEscapeAfterSwitch() async throws {
        let old = sessionJSON; let next = old.replacingOccurrences(of: "user-token", with: "user-b-token")
        FixtureProtocol.handler { _ in .init(json: old) }
        let sdk = try client(); _ = try await sdk.auth.signIn(email: "a", password: "a")
        FixtureProtocol.handler { request in .init(json: request.url!.path.hasSuffix("user") ? "{\"id\":\"u1\"}" : next, delay: request.url!.path.hasSuffix("user") ? 0.15 : 0.01) }
        let user = Task { try await sdk.auth.updatePassword("new") }
        try await Task.sleep(nanoseconds: 20_000_000); _ = try await sdk.auth.signIn(email: "b", password: "b")
        do { _ = try await user.value; XCTFail("Previous-account response returned after switch") }
        catch { XCTAssertEqual(error as? StayoError, .staleSession) }
    }
    func testOriginAndPrivilegedKeyValidation() throws {
        for url in ["http://public.example", "https://user:password@project.test", "https://project.test/prefix", "https://project.test?key=value"] { XCTAssertThrowsError(try client(url)) }
        XCTAssertNoThrow(try client("http://localhost:8000"))
        let payload = Data("{\"role\":\"service_role\"}".utf8).base64URL
        for key in ["sb_secret_key", "header.\(payload).signature"] { XCTAssertThrowsError(try StayoClient(url: URL(string: "https://project.test")!, publicKey: key, sessionStore: MemorySessionStore())) }
    }
    func testCRUDHeadersFiltersAndRange() async throws {
        FixtureProtocol.handler { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "public-test-key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer public-test-key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Profile"), "public")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "0-9")
            XCTAssertTrue(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.contains(.init(name: "title", value: "eq.a & b")))
            return .init(json: "[{\"id\":\"n1\"}]", headers: ["Content-Range": "0-0/1"])
        }
        struct Row: Decodable, Sendable { let id: String }
        let result = try await client().database.from("notes").filter("title", .eq, "a & b").range(0, 9).execute(as: [Row].self)
        XCTAssertEqual(result.value.first?.id, "n1"); XCTAssertEqual(result.contentRange, "0-0/1")
    }
    func testStorageEncodesSegmentsAndRejectsTraversal() async throws {
        FixtureProtocol.handler { request in
            XCTAssertEqual(request.url!.path(percentEncoded: true), "/storage/v1/object/photos/folder/a%20%23%3F.png")
            return .init(json: "bytes")
        }
        let bucket = try client().storage.bucket("photos")
        let bytes = try await bucket.download("folder/a #?.png"); XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "bytes")
        for path in ["../secret", "a//b", "a/./b", "a\\b", "/absolute"] {
            do { _ = try await bucket.download(path); XCTFail(path) } catch { XCTAssertEqual(error as? StayoError, .invalidPath) }
        }
    }
    func testSignedURLsRejectCrossOriginAndNormalizeStoragePrefix() async throws {
        FixtureProtocol.handler { _ in .init(json: "{\"signedURL\":\"https://attacker.test/object?token=hidden\"}") }
        do { _ = try await client().storage.bucket("photos").signedURL("a.png"); XCTFail() } catch { XCTAssertEqual(error as? StayoError, .invalidResponse) }
        FixtureProtocol.handler { _ in .init(json: "{\"signedURL\":\"/object/sign/photos/a.png?token=signed\"}") }
        let url = try await client().storage.bucket("photos").signedURL("a.png")
        XCTAssertEqual(url.absoluteString, "https://project.example.test/storage/v1/object/sign/photos/a.png?token=signed")
    }
    func testNamespacedSessionsAndLogout() async throws {
        let store = MemorySessionStore(); let response = sessionJSON
        FixtureProtocol.handler { request in
            if request.url!.path.hasSuffix("logout") {
                XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems, [.init(name: "scope", value: "local")])
                return .init(json: "{}")
            }
            return .init(json: response)
        }
        let first = try client(store: store); _ = try await first.auth.signIn(email: "user@example.test", password: "password")
        let reopened = try client(store: store); let same = try await reopened.auth.session(); XCTAssertEqual(same?.user?.id, "u1")
        let other = try client("https://other.example.test", store: store); let otherSession = try await other.auth.session(); XCTAssertNil(otherSession)
        let namespace = try client(store: store, namespace: "other"); let different = try await namespace.auth.session(); XCTAssertNil(different)
        try await first.auth.signOut(); let cleared = try client(store: store); let clearedSession = try await cleared.auth.session(); XCTAssertNil(clearedSession)
    }
    func testRefreshSingleFlightAndLogoutBarrier() async throws {
        let counter = Counter(); let response = sessionJSON
        FixtureProtocol.handler { request in
            if request.url!.query?.contains("refresh_token") == true { counter.increment(); return .init(json: response, delay: 0.2) }
            return .init(json: request.url!.path.hasSuffix("logout") ? "{}" : response)
        }
        let sdk = try client(); _ = try await sdk.auth.signIn(email: "x", password: "y")
        async let one = sdk.auth.refresh(); async let two = sdk.auth.refresh()
        _ = try await (one, two); XCTAssertEqual(counter.value, 1)
        let pending = Task { try await sdk.auth.refresh() }; try await Task.sleep(nanoseconds: 30_000_000)
        try await sdk.auth.signOut()
        do { _ = try await pending.value; XCTFail("Refresh survived logout") } catch {}
        let final = try await sdk.auth.session(); XCTAssertNil(final)
    }
    func testOAuthPKCEOneUseAndExactCallback() async throws {
        let response = sessionJSON; let counter = Counter()
        FixtureProtocol.handler { request in counter.increment(); XCTAssertTrue(request.url!.query!.contains("pkce")); return .init(json: response) }
        let auth = try client().auth; let redirect = URL(string: "stayoexample://login/callback")!
        let request = try await auth.beginOAuth(provider: .google, redirectURL: redirect, allowedRedirectURLs: [redirect])
        let parameters = URLComponents(url: request.url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(parameters.first(where: { $0.name == "code_challenge_method" })?.value, "s256")
        XCTAssertEqual(parameters.first(where: { $0.name == "code_challenge" })?.value?.count, 43)
        _ = try await auth.completeOAuth(request, callbackURL: URL(string: "stayoexample://login/callback?code=one")!)
        do { _ = try await auth.completeOAuth(request, callbackURL: URL(string: "stayoexample://login/callback?code=one")!); XCTFail() } catch { XCTAssertEqual(error as? StayoError, .invalidCallback) }
        let bad = try await auth.beginOAuth(provider: .apple, redirectURL: redirect, allowedRedirectURLs: [redirect])
        do { _ = try await auth.completeOAuth(bad, callbackURL: URL(string: "stayoexample://evil/callback?code=two")!); XCTFail() } catch { XCTAssertEqual(error as? StayoError, .invalidCallback) }
        XCTAssertEqual(counter.value, 1)
    }
    func testFunctionsCapabilityAndSingleDispatch() async throws {
        let response = sessionJSON; let counter = Counter()
        FixtureProtocol.handler { request in
            if request.url!.path.hasPrefix("/auth") { return .init(json: response) }
            if request.url!.path == "/.well-known/stayo.json" { return .init(json: "{\"protocol_version\":1,\"runtime_version\":\"1.3.0-compatible\",\"capabilities\":{\"functions\":true}}") }
            counter.increment(); return .init(status: 429, json: "{\"error\":{\"code\":\"FUNCTION_CONCURRENCY_LIMIT\",\"message\":\"secret should never appear\"}}")
        }
        let sdk = try client(); _ = try await sdk.auth.signIn(email: "x", password: "y")
        do { let _: JSONValue = try await sdk.functions.invoke("hello", body: ["name": "World"]); XCTFail() }
        catch { XCTAssertEqual(error as? StayoError, .http(status: 429, code: "FUNCTION_CONCURRENCY_LIMIT")); XCTAssertFalse(String(describing: error).contains("secret should")) }
        XCTAssertEqual(counter.value, 1)
        FixtureProtocol.handler { _ in .init(json: "{\"protocol_version\":1,\"runtime_version\":\"1.2.0-compatible\",\"capabilities\":{\"functions\":false}}") }
        do { let _: JSONValue = try await sdk.functions.invoke("hello", body: ["name": "World"]); XCTFail() } catch { XCTAssertEqual(error as? StayoError, .unavailableCapability("functions")) }
    }
    func testNestedErrorRejectsNonMachineCodeWithoutProviderText() async throws {
        FixtureProtocol.handler { _ in .init(status: 403, json: "{\"error\":{\"code\":\"private provider value\",\"message\":\"provider-secret\"}}") }
        let sdk = try client()
        do { let _: QueryResult<JSONValue> = try await sdk.database.from("notes").execute(); XCTFail() }
        catch { XCTAssertEqual(error as? StayoError, .http(status: 403, code: nil)); XCTAssertFalse(String(describing: error).contains("provider-secret")) }
    }
    func testRealWebSocketReconnectRefreshAndLogout() async throws {
        let process = Process(); let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/realtime_server.py").path]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run(); defer { process.terminate() }
        var line = Data()
        while true { let byte = pipe.fileHandleForReading.readData(ofLength: 1); if byte.isEmpty || byte == Data([10]) { break }; line.append(byte) }
        let port = try XCTUnwrap(Int(String(decoding: line, as: UTF8.self)))
        let sdk = try StayoClient(url: URL(string: "http://127.0.0.1:\(port)")!, publicKey: "public-test-key", sessionStore: MemorySessionStore())
        _ = try await sdk.auth.signIn(email: "x", password: "y")
        do { let _: QueryResult<JSONValue> = try await sdk.database.from("redirect").execute(); XCTFail("Followed a credential-bearing redirect") }
        catch { XCTAssertEqual(error as? StayoError, .http(status: 302, code: nil)) }
        let subscription = try await sdk.realtime.subscribe(table: "notes")
        let resynced = expectation(description: "Reconnected channel requests resync")
        let closed = expectation(description: "Logout closes subscription")
        let collector = Task {
            var changes = 0; var prematureSubscription = false
            for await event in subscription.events {
                switch event {
                case .change(let change): XCTAssertNotEqual(change.event, "DELETE"); changes += 1
                case .status(.subscribed):
                    if let (data, _) = try? await URLSession(configuration: .ephemeral).data(from: URL(string: "http://127.0.0.1:\(port)/stats")!),
                       let state = try? JSONSerialization.jsonObject(with: data) as? [String: Int],
                       (state["ready"] ?? 0) < (state["connections"] ?? 0) { prematureSubscription = true }
                case .status(.resyncRequired): resynced.fulfill()
                case .status(.closed): closed.fulfill()
                default: break
                }
            }
            return (changes, prematureSubscription)
        }
        await fulfillment(of: [resynced], timeout: 8)
        _ = try await sdk.auth.refresh()
        try await Task.sleep(nanoseconds: 100_000_000)
        let (stats, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/stats")!)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: stats) as? [String: Int])
        XCTAssertEqual(object["connections"], 2); XCTAssertEqual(object["tokens"], 1); XCTAssertEqual(object["leaks"], 0)
        try await sdk.auth.signOut(); await fulfillment(of: [closed], timeout: 2)
        let result = await collector.value; XCTAssertGreaterThanOrEqual(result.0, 2)
        XCTAssertFalse(result.1, "Subscribed must wait for postgres_changes readiness after the join ACK")
    }
    func testFunctionCancellationDoesNotRetry() async throws {
        let response = sessionJSON; let counter = Counter()
        FixtureProtocol.handler { request in
            if request.url!.path.hasPrefix("/auth") { return .init(json: response) }
            if request.url!.path.hasPrefix("/.well-known") { return .init(json: "{\"protocol_version\":1,\"runtime_version\":\"1.3.0-compatible\",\"capabilities\":{\"functions\":true}}") }
            counter.increment(); return .init(json: "{}", delay: 2)
        }
        let sdk = try client(); _ = try await sdk.auth.signIn(email: "x", password: "y")
        let task = Task { try await sdk.functions.invoke("hello", body: ["name": "x"], as: JSONValue.self) }
        try await Task.sleep(nanoseconds: 100_000_000); task.cancel()
        do { _ = try await task.value; XCTFail() } catch {}
        XCTAssertEqual(counter.value, 1)
    }

    func testFunctionRejectsAccountTransitionsDuringDiscovery() async throws {
        let marker = "{\"protocol_version\":1,\"runtime_version\":\"1.3.0-compatible\",\"capabilities\":{\"functions\":true}}"
        for transition in ["other-account", "same-token", "sign-out", "failed-login", "oauth", "refresh-rejected"] {
            let gate = DispatchSemaphore(value: 0); defer { gate.signal() }
            let discovered = expectation(description: "Discovery started: \(transition)")
            let posts = Counter(); let logins = Counter(); let first = sessionJSON
            FixtureProtocol.handler { request in
                switch request.url!.path {
                case "/auth/v1/token":
                    logins.increment()
                    if logins.value > 1 {
                        if transition == "failed-login" || transition == "refresh-rejected" { return .init(status: 401, json: "{}") }
                        if transition == "other-account" { return .init(json: first.replacingOccurrences(of: "user-token", with: "account-b-token")) }
                    }
                    return .init(json: first)
                case "/auth/v1/logout": return .init()
                case "/.well-known/stayo.json": discovered.fulfill(); return .init(json: marker, gate: gate)
                default: posts.increment(); return .init()
                }
            }
            let sdk = try client(); _ = try await sdk.auth.signIn(email: "a", password: "unused")
            let invocation = Task { try await sdk.functions.invoke("change", body: ["value": "prepared-for-a"], as: JSONValue.self) }
            await fulfillment(of: [discovered], timeout: 2)
            switch transition {
            case "sign-out": try await sdk.auth.signOut()
            case "failed-login": _ = try? await sdk.auth.signIn(email: "b", password: "unused")
            case "refresh-rejected": _ = try? await sdk.auth.refresh()
            case "oauth":
                let callback = URL(string: "stayo-fixture://callback")!
                _ = try await sdk.auth.beginOAuth(provider: .google, redirectURL: callback, allowedRedirectURLs: [callback])
            default: _ = try await sdk.auth.signIn(email: "b", password: "unused")
            }
            gate.signal()
            do { _ = try await invocation.value; XCTFail("Stale invocation completed: \(transition)") }
            catch { XCTAssertEqual(error as? StayoError, .staleSession, transition) }
            XCTAssertEqual(posts.value, 0, transition)
            if transition == "other-account" {
                let session = try await sdk.auth.session(); XCTAssertEqual(session?.accessToken, "account-b-token")
            }
        }
    }

    func testFunctionAllowsRefreshWithinOriginalAccountGeneration() async throws {
        let gate = DispatchSemaphore(value: 0); defer { gate.signal() }
        let discovered = expectation(description: "Discovery started")
        let logins = Counter(); let posts = Counter(); let first = sessionJSON
        FixtureProtocol.handler { request in
            switch request.url!.path {
            case "/auth/v1/token": logins.increment(); return .init(json: logins.value == 1 ? first : first.replacingOccurrences(of: "user-token", with: "refreshed-token"))
            case "/.well-known/stayo.json": discovered.fulfill(); return .init(json: "{\"protocol_version\":1,\"runtime_version\":\"1.3.0-compatible\",\"capabilities\":{\"functions\":true}}", gate: gate)
            default: posts.increment(); XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer refreshed-token"); return .init()
            }
        }
        let sdk = try client(); _ = try await sdk.auth.signIn(email: "a", password: "unused")
        let invocation = Task { try await sdk.functions.invoke("change", body: ["value": "for-a"], as: JSONValue.self) }
        await fulfillment(of: [discovered], timeout: 2)
        _ = try await sdk.auth.refresh(); gate.signal()
        _ = try await invocation.value; XCTAssertEqual(posts.value, 1)
    }

    func testFunctionChecksIdentityAfterBodyEncoding() async throws {
        let encoding = expectation(description: "Encoding body")
        let gate = DispatchSemaphore(value: 0); defer { gate.signal() }
        let first = sessionJSON; let posts = Counter()
        FixtureProtocol.handler { request in
            switch request.url!.path {
            case "/auth/v1/token": return .init(json: first)
            case "/auth/v1/logout": return .init()
            case "/.well-known/stayo.json": return .init(json: "{\"protocol_version\":1,\"runtime_version\":\"1.3.0-compatible\",\"capabilities\":{\"functions\":true}}")
            default: posts.increment(); return .init()
            }
        }
        let sdk = try client(); _ = try await sdk.auth.signIn(email: "a", password: "unused")
        let invocation = Task { try await sdk.functions.invoke("change", body: BlockingFunctionBody(started: encoding, gate: gate), as: JSONValue.self) }
        await fulfillment(of: [encoding], timeout: 2)
        try await sdk.auth.signOut(); gate.signal()
        do { _ = try await invocation.value; XCTFail("Encoded body escaped the initiating session") }
        catch { XCTAssertEqual(error as? StayoError, .staleSession) }
        XCTAssertEqual(posts.value, 0)
    }

    func testFunctionRejectsLateResponseAfterLogoutWithoutRetry() async throws {
        let posted = expectation(description: "Function dispatched")
        let gate = DispatchSemaphore(value: 0); defer { gate.signal() }
        let first = sessionJSON; let posts = Counter()
        FixtureProtocol.handler { request in
            switch request.url!.path {
            case "/auth/v1/token": return .init(json: first)
            case "/auth/v1/logout": return .init()
            case "/.well-known/stayo.json": return .init(json: "{\"protocol_version\":1,\"runtime_version\":\"1.3.0-compatible\",\"capabilities\":{\"functions\":true}}")
            default: posts.increment(); posted.fulfill(); return .init(gate: gate)
            }
        }
        let sdk = try client(); _ = try await sdk.auth.signIn(email: "a", password: "unused")
        let invocation = Task { try await sdk.functions.invoke("change", body: ["value": "for-a"], as: JSONValue.self) }
        await fulfillment(of: [posted], timeout: 2)
        try await sdk.auth.signOut(); gate.signal()
        do { _ = try await invocation.value; XCTFail("Late function response accepted after logout") }
        catch { XCTAssertEqual(error as? StayoError, .staleSession) }
        XCTAssertEqual(posts.value, 1) // A dispatched server mutation cannot be undone by the SDK.
    }

    func testDatabaseRPCAndStorageRejectLateResponsesAfterLogout() async throws {
        let first = sessionJSON; let dispatched = Counter()
        for (label, call) in [
            ("select", { (sdk: StayoClient) async throws -> Void in _ = try await sdk.database.from("notes").select().execute(as: JSONValue.self) }),
            ("rpc", { (sdk: StayoClient) async throws -> Void in _ = try await sdk.database.rpc("change", parameters: ["v": 1], as: JSONValue.self) }),
            ("download", { (sdk: StayoClient) async throws -> Void in _ = try await sdk.storage.bucket("private").download("a/b.txt") }),
        ] {
            let posted = expectation(description: "\(label) dispatched")
            let gate = DispatchSemaphore(value: 0)
            FixtureProtocol.handler { request in
                switch request.url!.path {
                case "/auth/v1/token": return .init(json: first)
                case "/auth/v1/logout": return .init()
                default: dispatched.increment(); posted.fulfill(); return .init(json: "[]", gate: gate)
                }
            }
            let sdk = try client(); _ = try await sdk.auth.signIn(email: "a", password: "unused")
            let operation = Task { try await call(sdk) }
            await fulfillment(of: [posted], timeout: 2)
            try await sdk.auth.signOut(); gate.signal()
            do { try await operation.value; XCTFail("Late \(label) response accepted after logout") }
            catch { XCTAssertEqual(error as? StayoError, .staleSession, label) }
        }
        XCTAssertEqual(dispatched.value, 3) // Each request was sent exactly once; none is retried.
    }

    func testAnonymousDatabaseReadStillWorks() async throws {
        FixtureProtocol.handler { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization")?.range(of: "user-token"))
            return .init(json: "[{\"id\":1}]")
        }
        let sdk = try client()
        let result = try await sdk.database.from("public_notes").select().execute(as: [[String: Int]].self)
        XCTAssertEqual(result.value, [["id": 1]])
    }

    func testFunctionMissingSessionFailsBeforeDiscovery() async throws {
        let requests = Counter()
        FixtureProtocol.handler { _ in requests.increment(); return .init() }
        let sdk = try client()
        do { _ = try await sdk.functions.invoke("change", body: ["value": "none"], as: JSONValue.self); XCTFail() }
        catch { XCTAssertEqual(error as? StayoError, .noSession) }
        XCTAssertEqual(requests.value, 0)
    }
}
private struct BlockingFunctionBody: Encodable, @unchecked Sendable {
    let started: XCTestExpectation
    let gate: DispatchSemaphore
    func encode(to encoder: Encoder) throws {
        started.fulfill(); _ = gate.wait(timeout: .now() + 5)
        var container = encoder.singleValueContainer(); try container.encode("prepared-for-a")
    }
}
final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
