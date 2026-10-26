import Foundation

public enum RealtimeStatus: String, Sendable { case connecting, subscribed, disconnected, resyncRequired, closed }
public struct RealtimeChange: Sendable {
    public let event: String; public let schema: String; public let table: String
    public let record: [String: JSONValue]; public let oldRecord: [String: JSONValue]
}
public enum RealtimeEvent: Sendable { case status(RealtimeStatus), change(RealtimeChange) }

public actor RealtimeClient {
    private let transport: Transport; private let auth: AuthClient
    private var channels: [UUID: RealtimeSubscription] = [:]
    private var listening = false; private let listenerID = UUID()
    init(transport: Transport, auth: AuthClient) { self.transport = transport; self.auth = auth }
    /// Retain the subscription and iterate events. A resyncRequired event requires refetching a database snapshot.
    public func subscribe(table: String, schema: String = "public", filter: String? = nil) async throws -> RealtimeSubscription {
        guard !table.isEmpty, !schema.isEmpty else { throw StayoError.invalidPath }
        _ = try await auth.token(required: true)
        if !listening {
            listening = true
            await auth.listen(id: listenerID) { [weak self] session in await self?.sessionChanged(session) }
        }
        let id = UUID()
        let subscription = RealtimeSubscription(transport: transport, auth: auth, table: table, schema: schema, filter: filter) { [weak self] in await self?.remove(id) }
        channels[id] = subscription; await subscription.start(); return subscription
    }
    private func remove(_ id: UUID) { channels.removeValue(forKey: id) }
    private func sessionChanged(_ session: Session?) async {
        if let session { for channel in channels.values { await channel.updateToken(session.accessToken) } }
        else { await close() }
    }
    public func close() async {
        let copy = Array(channels.values); channels.removeAll()
        for channel in copy { await channel.unsubscribe() }
        if listening { listening = false; await auth.unlisten(id: listenerID) }
    }
}

public actor RealtimeSubscription {
    public nonisolated let events: AsyncStream<RealtimeEvent>
    private let continuation: AsyncStream<RealtimeEvent>.Continuation
    private let transport: Transport; private let auth: AuthClient; private let table: String; private let schema: String; private let filter: String?
    private let onClose: @Sendable () async -> Void
    private let topic = "realtime:stayo:" + UUID().uuidString
    private var socket: URLSessionWebSocketTask?
    private var worker: Task<Void, Never>?; private var heartbeat: Task<Void, Never>?
    private var closed = false; private var ref = 0; private var joinRef = ""
    private var pendingHeartbeat: String?
    private var connectedBefore = false; private var subscribed = false
    init(transport: Transport, auth: AuthClient, table: String, schema: String, filter: String?, onClose: @escaping @Sendable () async -> Void) {
        self.transport = transport; self.auth = auth; self.table = table; self.schema = schema; self.filter = filter; self.onClose = onClose
        var c: AsyncStream<RealtimeEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(256)) { c = $0 }; continuation = c
        continuation.onTermination = { [weak self] _ in Task { await self?.unsubscribe() } }
    }
    func start() { worker = Task { [weak self] in await self?.run() } }
    private func nextRef() -> String { ref += 1; return String(ref) }
    private func emit(_ event: RealtimeEvent) {
        if case .dropped = continuation.yield(event) { _ = continuation.yield(.status(.resyncRequired)) }
    }
    private func send(_ event: String, payload: [String: Any], topic: String? = nil, reference: String? = nil) async throws {
        guard let socket else { throw StayoError.invalidResponse }
        let message: [String: Any] = ["topic": topic ?? self.topic, "event": event, "payload": payload, "ref": reference ?? nextRef(), "join_ref": joinRef]
        let data = try JSONSerialization.data(withJSONObject: message)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }
    private func run() async {
        var attempt = 0
        while !closed && !Task.isCancelled {
            do {
                emit(.status(.connecting))
                let token = try await auth.token(required: true)
                var c = URLComponents(url: try transport.url(["realtime", "v1", "websocket"], query: [.init(name: "apikey", value: transport.publicKey), .init(name: "vsn", value: "1.0.0")]), resolvingAgainstBaseURL: false)!
                c.scheme = c.scheme == "https" ? "wss" : "ws"
                guard !closed else { break }
                let active = transport.session.webSocketTask(with: c.url!); socket = active; active.resume()
                subscribed = false; joinRef = nextRef()
                var insert: [String: Any] = ["event": "INSERT", "schema": schema, "table": table]
                var update: [String: Any] = ["event": "UPDATE", "schema": schema, "table": table]
                if let filter { insert["filter"] = filter; update["filter"] = filter }
                try await send("phx_join", payload: ["config": ["broadcast": ["ack": false, "self": false], "presence": ["key": ""], "postgres_changes": [insert, update]], "access_token": token!], reference: joinRef)
                pendingHeartbeat = nil
                heartbeat = Task { [weak self] in
                    do {
                        // Also bounds a join that is never acknowledged.
                        while !Task.isCancelled { try await Task.sleep(nanoseconds: 25_000_000_000); try await self?.beat() }
                    } catch { await self?.breakConnection() }
                }
                var joined = false; var joinAcknowledged = false; var postgresReady = false
                while !closed && !Task.isCancelled {
                    let received = try await active.receive()
                    let data: Data
                    switch received { case .string(let string): data = Data(string.utf8); case .data(let bytes): data = bytes; @unknown default: continue }
                    guard let message = try JSONSerialization.jsonObject(with: data) as? [String: Any], let event = message["event"] as? String else { continue }
                    let payload = message["payload"] as? [String: Any] ?? [:]
                    if message["topic"] as? String == "phoenix", message["ref"] as? String == pendingHeartbeat, event == "phx_reply", payload["status"] as? String == "ok" { pendingHeartbeat = nil; continue }
                    guard message["topic"] as? String == topic else { continue }
                    if event == "phx_reply", message["ref"] as? String == joinRef {
                        guard payload["status"] as? String == "ok" else { throw StayoError.invalidResponse }
                        joinAcknowledged = true
                    } else if event == "system", payload["extension"] as? String == "postgres_changes" {
                        guard payload["status"] as? String == "ok" else { throw StayoError.invalidResponse }
                        postgresReady = true
                    } else if event == "phx_error" || event == "phx_close" { throw StayoError.invalidResponse }
                    else if event == "postgres_changes", joined, let change = payload["data"] as? [String: Any],
                            let kind = change["type"] as? String, ["INSERT", "UPDATE"].contains(kind),
                            let changeSchema = change["schema"] as? String, changeSchema == schema,
                            let changeTable = change["table"] as? String, changeTable == table {
                        func record(_ name: String) -> [String: JSONValue] {
                            guard let value = change[name], let bytes = try? JSONSerialization.data(withJSONObject: value),
                                  let object = try? JSONDecoder().decode([String: JSONValue].self, from: bytes) else { return [:] }; return object
                        }
                        emit(.change(RealtimeChange(event: kind, schema: changeSchema, table: changeTable, record: record("record"), oldRecord: record("old_record"))))
                    }
                    // The Phoenix join ACK precedes the replication subscription.
                    // Callers may write as soon as subscribed is emitted, so both
                    // readiness messages must arrive, in either order.
                    if !joined && joinAcknowledged && postgresReady {
                        joined = true; subscribed = true; attempt = 0; emit(.status(.subscribed))
                        if connectedBefore { emit(.status(.resyncRequired)) }; connectedBefore = true
                    }
                }
            } catch { if case StayoError.noSession = error { await unsubscribe() }; if !closed { emit(.status(.disconnected)) } }
            heartbeat?.cancel(); heartbeat = nil; socket?.cancel(with: .goingAway, reason: nil); socket = nil
            if closed || Task.isCancelled { break }
            attempt += 1
            do { try await Task.sleep(nanoseconds: UInt64(min(30, 1 << min(attempt - 1, 5))) * 1_000_000_000) } catch { break }
        }
    }
    private func beat() async throws {
        if !subscribed || pendingHeartbeat != nil { throw StayoError.invalidResponse }
        _ = try await auth.token(required: true)
        let reference = nextRef(); pendingHeartbeat = reference
        try await send("heartbeat", payload: [:], topic: "phoenix", reference: reference)
    }
    private func breakConnection() { socket?.cancel(with: .goingAway, reason: nil) }
    func updateToken(_ token: String) async { if !closed && socket != nil { do { try await send("access_token", payload: ["access_token": token]) } catch { breakConnection() } } }
    public func unsubscribe() async {
        guard !closed else { return }; closed = true
        worker?.cancel(); heartbeat?.cancel()
        // Closing the websocket releases its server-side channel even when leave cannot be sent.
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        emit(.status(.closed)); continuation.finish(); await onClose()
    }
}
