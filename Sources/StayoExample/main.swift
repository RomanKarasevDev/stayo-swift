import Foundation
import Stayo

@main struct Example {
    static func main() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let origin = environment["STAYO_URL"].flatMap(URL.init(string:)), let key = environment["STAYO_PUBLIC_KEY"] else {
            print("Set STAYO_URL and STAYO_PUBLIC_KEY to your project settings. Optional STAYO_EMAIL/STAYO_PASSWORD signs in.")
            return
        }
        let client = try StayoClient(url: origin, publicKey: key, namespace: "example")
        if let email = environment["STAYO_EMAIL"], let password = environment["STAYO_PASSWORD"] { _ = try await client.auth.signIn(email: email, password: password) }
        let capabilities = try await client.functions.capabilities()
        print("Stayo protocol \(capabilities.protocolVersion), runtime \(capabilities.runtimeVersion)")
        // Add an RLS-protected notes table as described in README before using this sample query.
        if environment["STAYO_QUERY_NOTES"] == "1" {
            struct Note: Decodable, Sendable { let id: String; let title: String }
            let notes = try await client.database.from("notes").select("id,title").limit(10).execute(as: [Note].self)
            print("Visible notes: \(notes.value.count)")
        }
    }
}
