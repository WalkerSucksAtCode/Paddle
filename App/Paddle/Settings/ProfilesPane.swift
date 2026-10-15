import PaddleCore
import SwiftUI

/// Settings > Profiles: add, rename, change the symbol of, open a window in, and delete profiles. The list is
/// profiles.json (`AppModel.profiles`), not config.json.
struct ProfilesPane: View {
    let model: SettingsModel
    @State private var pendingDelete: Profile?
    @State private var deleteFailed = false
    @FocusState private var focused: String?

    private var store: ProfileStore { AppModel.shared.profiles }

    var body: some View {
        SettingsForm {
            Section("Profiles") {
                if let error = store.loadError {
                    Text("\(error). Paddle leaves the file alone until it is fixed.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.all, id: \.id) { profile in
                    ProfileRow(profile: profile, focused: $focused) { pendingDelete = profile }
                }
                Button("Add Profile", systemImage: "plus") { add() }
                    .disabled(store.loadError != nil)
            }
            Section {
                Text("Separate in each profile: cookies, logins, site data, cache, history (and so address suggestions and Frequently visited) and extensions. Shared by all: bookmarks, New Tab pinned sites, settings and block lists. A tab can't be moved to a window of another profile.")
                    .foregroundStyle(.secondary)
            }
        }
        .alert(
            pendingDelete.map { "Delete the profile \($0.name)?" } ?? "",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { profile in
            Button("Delete", role: .destructive) {
                Task { deleteFailed = !(await store.delete(id: profile.id)) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its cookies, logins, site data and history are deleted, and its windows close.")
        }
        .alert("The profile could not be deleted", isPresented: $deleteFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("WebKit could not remove its site data. The profile is kept; try again.")
        }
    }

    private func add() {
        let used = Set(store.all.map(\.symbol))
        let symbol = ProfileSymbol.allCases.first { !used.contains($0) } ?? .person
        guard let profile = store.add(name: "New Profile", symbol: symbol) else { return }
        // On the next turn: the new row's field doesn't exist until SwiftUI has drawn it.
        Task { @MainActor in focused = profile.id }
    }
}

/// One profile: symbol, editable name, symbol picker, Open Window and Delete…
private struct ProfileRow: View {
    let profile: Profile
    var focused: FocusState<String?>.Binding
    let onDelete: () -> Void
    @State private var name = ""

    private var store: ProfileStore { AppModel.shared.profiles }

    var body: some View {
        HStack {
            Image(systemName: profile.symbol.sfSymbol)
                .frame(width: 20)
                .accessibilityHidden(true)
            TextField("Name", text: $name)
                .labelsHidden()
                .focused(focused, equals: profile.id)
                .onSubmit(commit)
                .help("The profile's name, saved when you press Return or leave the field. Two profiles can't share a name.")
            Picker("Symbol", selection: Binding(
                get: { profile.symbol },
                set: { store.setSymbol($0, for: profile.id) }
            )) {
                ForEach(ProfileSymbol.allCases, id: \.self) { symbol in
                    Label(symbol.displayName, systemImage: symbol.sfSymbol).tag(symbol)
                }
            }
            .labelsHidden()
            .frame(width: 140)
            Button("Open Window") { AppModel.shared.openWindow(profile: profile.id) }
            if !profile.isDefault {
                Button("Delete…", role: .destructive, action: onDelete)
            }
        }
        .onAppear { name = profile.name }
        .onChange(of: profile.name) { name = profile.name }
        .onChange(of: focused.wrappedValue) { old, new in
            if old == profile.id, new != profile.id { commit() }
        }
    }

    /// Saves the typed name; one the store refuses (empty, or another profile's) goes back to the saved name.
    private func commit() {
        guard name != profile.name else { return }
        if !store.rename(id: profile.id, to: name) { name = profile.name }
    }
}
