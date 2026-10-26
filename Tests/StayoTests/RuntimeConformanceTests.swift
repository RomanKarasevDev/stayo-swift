import XCTest
import Foundation
import Darwin
@testable import Stayo

/// Explicitly enabled only for two dedicated disposable runtime projects.
/// Fixture identities/configuration never appear in output or assertion messages.
final class RuntimeConformanceTests: XCTestCase {
    private struct Configuration: Decodable {
        let runtime_version: String
        let candidate_revision: String?
        let fixture_generator_revision: String?
        let image_refs: [String]
        let projects: [Project]
    }
    private struct Project: Decodable {
        let url: URL
        let publicKey: String
        let users: [Credentials]
    }
    private struct Credentials: Decodable { let email: String; let password: String }
    private struct ProbeRow: Codable, Sendable {
        let id: String; let owner_id: String; let run_id: String; let title: String
    }
    private struct Echo: Decodable, Sendable {
        let probe: String; let nonce: String; let user_id: String; let secret_present: Bool
    }
    private struct Publication: Decodable, Sendable {
        let published: Bool; let insert: Bool; let update: Bool; let delete: Bool
    }
    private struct ProjectClients {
        let project: Project; let first: StayoClient; let second: StayoClient
        let firstUser: String; let secondUser: String
    }
    private enum Failure: Error { case invalidConfiguration, unexpectedAccess, invalidFixture }
    private let table = "stayo_sdk_probe"
    private let bucket = "stayo-sdk-conformance"

    private func configuration() throws -> Configuration {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["STAYO_RUNTIME_CONFIG"] else { throw XCTSkip("Set STAYO_RUNTIME_CONFIG to the dedicated runtime fixture configuration") }
        guard env["STAYO_ALLOW_DISPOSABLE_RUNTIME_WRITES"] == "I_APPROVE_DISPOSABLE_PROJECT_WRITES", path.hasPrefix("/") else { throw Failure.invalidConfiguration }
        let url = URL(fileURLWithPath: path)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 1_048_576 else { throw Failure.invalidConfiguration }
        let result = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: url))
        guard result.runtime_version == "1.3.0-compatible", result.projects.count == 2,
              (result.fixture_generator_revision ?? result.candidate_revision)?.range(of: "^[a-fA-F0-9]{40}$", options: .regularExpression) != nil,
              !result.image_refs.isEmpty, result.image_refs.allSatisfy({ $0.contains("@sha256:") }),
              Set(result.projects.map { $0.url.absoluteString }).count == 2,
              result.projects.allSatisfy({ $0.users.count == 2 && $0.users[0].email != $0.users[1].email }) else { throw Failure.invalidConfiguration }
        for project in result.projects {
            guard let host = project.url.host else { throw Failure.invalidConfiguration }
            if !["127.0.0.1", "localhost", "::1", "[::1]"].contains(host), env["STAYO_ALLOW_REMOTE_DISPOSABLE_WRITES"] != "I_APPROVE_REMOTE_DISPOSABLE_PROJECT_WRITES" { throw Failure.invalidConfiguration }
        }
        return result
    }
    private func denied(_ operation: () async throws -> Void) async throws {
        do { try await operation() }
        catch StayoError.http(let status, _) where [400, 401, 403, 404].contains(status) { return }
        throw Failure.unexpectedAccess
    }
    private func cleanup(_ clients: [ProjectClients], runID: String) async {
        for pair in clients {
            for (client, owner) in [(pair.first, pair.firstUser), (pair.second, pair.secondUser)] {
                _ = try? await client.storage.bucket(bucket).remove(["\(owner)/\(runID)/file.txt"])
                _ = try? await client.database.from(table).filter("run_id", .eq, runID).delete(as: [ProbeRow].self)
                await client.realtime.close()
                try? await client.auth.signOut()
            }
        }
    }
    private func redacted(_ error: Error) -> String {
        if case StayoError.http(let status, _) = error { return "HTTP \(status)" }
        if case StayoError.noSession = error { return "missing session" }
        return "operation failed"
    }

    func testTwoPinnedRuntimeProjectsWithTwoUsers() async throws {
        let config: Configuration
        do { config = try configuration() }
        catch let skip as XCTSkip { throw skip }
        catch { XCTFail("Runtime configuration must be a dedicated owner-only 0600 file with explicit write approval"); return }
        let runID = UUID().uuidString.lowercased()
        var clients: [ProjectClients] = []
        var stage = "authenticate dedicated users"
        do {
            for project in config.projects {
                let first = try StayoClient(url: project.url, publicKey: project.publicKey, namespace: "conformance-first-\(runID)", sessionStore: MemorySessionStore())
                let second = try StayoClient(url: project.url, publicKey: project.publicKey, namespace: "conformance-second-\(runID)", sessionStore: MemorySessionStore())
                let a = try await first.auth.signIn(email: project.users[0].email, password: project.users[0].password)
                let b = try await second.auth.signIn(email: project.users[1].email, password: project.users[1].password)
                guard let aID = a.user?.id, let bID = b.user?.id, aID != bID else { throw Failure.invalidFixture }
                clients.append(ProjectClients(project: project, first: first, second: second, firstUser: aID, secondUser: bID))
            }
            for (index, pair) in clients.enumerated() {
                stage = "project \(index + 1) discovery and publication"
                let marker = try await pair.first.functions.capabilities()
                XCTAssertEqual(marker.protocolVersion, 1); XCTAssertEqual(marker.runtimeVersion, config.runtime_version)
                XCTAssertEqual(marker.capabilities["functions"], true)
                let publication = try await pair.first.database.rpc("stayo_sdk_probe_publication", parameters: [String: String](), as: Publication.self)
                XCTAssertTrue(publication.published && publication.insert && publication.update && !publication.delete)
                let rowA = ProbeRow(id: UUID().uuidString.lowercased(), owner_id: pair.firstUser, run_id: runID, title: "swift-before")
                let rowB = ProbeRow(id: UUID().uuidString.lowercased(), owner_id: pair.secondUser, run_id: runID, title: "swift-other")
                let subscribedA = expectation(description: "first user subscribed")
                let subscribedB = expectation(description: "second user subscribed")
                let inserted = expectation(description: "owner receives INSERT")
                let updated = expectation(description: "owner receives UPDATE after refresh")
                let closed = expectation(description: "logout closes owner subscription")
                let channelA = try await pair.first.realtime.subscribe(table: table)
                let channelB = try await pair.second.realtime.subscribe(table: table)
                let collectorA = Task {
                    var foreign = false
                    for await event in channelA.events {
                        switch event {
                        case .status(.subscribed): subscribedA.fulfill()
                        case .status(.closed): closed.fulfill()
                        case .change(let change):
                            if change.record["id"] == .string(rowB.id) { foreign = true }
                            if change.record["id"] == .string(rowA.id) {
                                if change.event == "INSERT" { inserted.fulfill() }
                                if change.event == "UPDATE", change.record["title"] == .string("swift-after") { updated.fulfill() }
                            }
                        default: break
                        }
                    }
                    return foreign
                }
                let collectorB = Task {
                    var foreign = false
                    for await event in channelB.events {
                        if case .status(.subscribed) = event { subscribedB.fulfill() }
                        if case .change(let change) = event, change.record["id"] == .string(rowA.id) { foreign = true }
                    }
                    return foreign
                }
                await fulfillment(of: [subscribedA, subscribedB], timeout: 20)
                stage = "project \(index + 1) CRUD and owner RLS"
                _ = try await pair.first.database.from(table).insert(rowA, as: [ProbeRow].self)
                _ = try await pair.second.database.from(table).insert(rowB, as: [ProbeRow].self)
                await fulfillment(of: [inserted], timeout: 20)
                let visibleA = try await pair.first.database.from(table).filter("run_id", .eq, runID).execute(as: [ProbeRow].self)
                let visibleB = try await pair.second.database.from(table).filter("run_id", .eq, runID).execute(as: [ProbeRow].self)
                XCTAssertEqual(visibleA.value.count, 1); XCTAssertEqual(visibleB.value.count, 1)
                XCTAssertTrue(visibleA.value.allSatisfy({ $0.owner_id == pair.firstUser }))
                XCTAssertTrue(visibleB.value.allSatisfy({ $0.owner_id == pair.secondUser }))
                let blockedUpdate = try await pair.second.database.from(table).filter("id", .eq, rowA.id).update(["title": "forbidden"], as: [ProbeRow].self)
                let blockedDelete = try await pair.second.database.from(table).filter("id", .eq, rowA.id).delete(as: [ProbeRow].self)
                XCTAssertTrue(blockedUpdate.value.isEmpty && blockedDelete.value.isEmpty)
                let forged = ProbeRow(id: UUID().uuidString.lowercased(), owner_id: pair.firstUser, run_id: runID, title: "forbidden")
                try await denied { _ = try await pair.second.database.from(self.table).insert(forged, as: [ProbeRow].self) }
                let count = try await pair.first.database.rpc("stayo_sdk_probe_count", parameters: ["probe_run_id": runID], as: Int.self)
                XCTAssertEqual(count, 1)
                stage = "project \(index + 1) refresh and realtime authorization"
                async let refreshedA = pair.first.auth.refresh(); async let refreshedB = pair.first.auth.refresh()
                _ = try await (refreshedA, refreshedB)
                _ = try await pair.first.database.from(table).filter("id", .eq, rowA.id).update(["title": "swift-after"], as: [ProbeRow].self)
                await fulfillment(of: [updated], timeout: 20)
                stage = "project \(index + 1) private storage"
                let path = "\(pair.firstUser)/\(runID)/file.txt"; let bytes = Data("synthetic-swift-conformance".utf8)
                _ = try await pair.first.storage.bucket(bucket).upload(path, data: bytes, contentType: "text/plain")
                let downloaded = try await pair.first.storage.bucket(bucket).download(path); XCTAssertEqual(downloaded, bytes)
                let signed = try await pair.first.storage.bucket(bucket).signedURL(path)
                let (signedBytes, signedResponse) = try await URLSession(configuration: .ephemeral).data(from: signed)
                XCTAssertEqual((signedResponse as? HTTPURLResponse)?.statusCode, 200); XCTAssertEqual(signedBytes, bytes)
                try await denied { _ = try await pair.second.storage.bucket(self.bucket).download(path) }
                try await denied { _ = try await pair.second.storage.bucket(self.bucket).signedURL(path) }
                stage = "project \(index + 1) authenticated function and private secret delivery"
                let echoed = try await pair.first.functions.invoke("sdk-conformance", body: ["nonce": runID], as: Echo.self)
                XCTAssertEqual(echoed.probe, "stayo-sdk-conformance-v1"); XCTAssertEqual(echoed.nonce, runID)
                XCTAssertEqual(echoed.user_id, pair.firstUser); XCTAssertTrue(echoed.secret_present)
                try await denied { _ = try await pair.first.functions.invoke("sdk-missing", body: ["nonce": runID], as: JSONValue.self) }
                stage = "project \(index + 1) cross-project access"
                let other = clients[1 - index]
                let otherRows = try await other.first.database.from(table).filter("id", .eq, rowA.id).execute(as: [ProbeRow].self)
                XCTAssertTrue(otherRows.value.isEmpty)
                try await denied { _ = try await other.first.storage.bucket(self.bucket).download(path) }
                guard let session = try await pair.first.auth.session() else { throw Failure.invalidFixture }
                let otherTransport = try Transport(url: other.project.url, publicKey: other.project.publicKey, configuration: .ephemeral)
                try await denied { _ = try await otherTransport.request(["auth", "v1", "user"], token: session.accessToken) }
                stage = "project \(index + 1) delete and logout"
                _ = try await pair.first.storage.bucket(bucket).remove([path])
                _ = try await pair.first.database.from(table).filter("id", .eq, rowA.id).delete(as: [ProbeRow].self)
                try await pair.first.auth.signOut()
                await fulfillment(of: [closed], timeout: 10)
                await channelB.unsubscribe()
                let foreignA = await collectorA.value; let foreignB = await collectorB.value
                XCTAssertFalse(foreignA || foreignB, "Realtime must not reveal the other owner's rows")
                // Restore a valid cleanup session; each next iteration still exercises its own two identities.
                _ = try await pair.first.auth.signIn(email: pair.project.users[0].email, password: pair.project.users[0].password)
            }
            await cleanup(clients, runID: runID)
        } catch {
            await cleanup(clients, runID: runID)
            XCTFail("Runtime conformance failed at \(stage): \(redacted(error))")
        }
    }
}
