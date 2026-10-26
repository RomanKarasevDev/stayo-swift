import SwiftUI
import Stayo

@main struct StayoNotesApp: App {
    var body: some Scene { WindowGroup { NotesView() } }
}

private struct Note: Decodable, Identifiable, Sendable { let id: String; let title: String }
private struct NotesView: View {
    @State private var client: StayoClient?
    @State private var email = ""
    @State private var password = ""
    @State private var notes: [Note] = []
    @State private var status = "Add STAYO_URL and STAYO_PUBLIC_KEY in your app Info.plist."
    @State private var busy = false
    var body: some View {
        VStack(spacing: 16) {
            Text("Stayo Notes").font(.largeTitle)
            TextField("Email", text: $email).textContentType(.emailAddress)
            SecureField("Password", text: $password)
            HStack {
                Button("Sign in") { Task { await signIn() } }.disabled(client == nil || busy)
                Button("Reload") { Task { await load() } }.disabled(client == nil || busy)
                Button("Sign out") { Task { await signOut() } }.disabled(client == nil || busy)
            }
            Text(status).font(.caption)
            List(notes) { Text($0.title) }
        }
        .padding().task {
            guard let value = Bundle.main.object(forInfoDictionaryKey: "STAYO_URL") as? String,
                  let url = URL(string: value), let key = Bundle.main.object(forInfoDictionaryKey: "STAYO_PUBLIC_KEY") as? String else { return }
            do { client = try StayoClient(url: url, publicKey: key, namespace: "notes-example"); status = "Ready" }
            catch { status = "Invalid project settings or unavailable Keychain" }
        }
    }
    @MainActor private func signIn() async {
        guard let client else { return }; busy = true; defer { busy = false; password = "" }
        do { _ = try await client.auth.signIn(email: email, password: password); status = "Signed in" }
        catch { status = "Sign-in failed" }
    }
    @MainActor private func load() async {
        guard let client else { return }; busy = true; defer { busy = false }
        do { notes = try await client.database.from("notes").select("id,title").limit(20).execute(as: [Note].self).value; status = "Loaded \(notes.count) notes" }
        catch { status = "Query failed; check the notes table and RLS policies" }
    }
    @MainActor private func signOut() async {
        guard let client else { return }; busy = true; defer { busy = false }
        do { try await client.auth.signOut(); status = "Signed out" } catch { status = "Local session cleared; server logout failed" }
        notes = []
    }
}
