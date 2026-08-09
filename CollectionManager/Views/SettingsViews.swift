import SwiftUI

struct SettingsView: View {
    @AppStorage("global.defaultCollectionIcon") private var defaultIcon = "square.stack.3d.up.fill"
    @AppStorage("global.confirmDeletes") private var confirmDeletes = true
    @State private var gamesEANAPIKey = ""
    var body: some View { NavigationStack { Form { Section("Defaults") { TextField("Default collection icon", text: $defaultIcon); Toggle("Confirm before deleting", isOn: $confirmDeletes) }; Section("Games EAN lookup") { SecureField("API key", text: $gamesEANAPIKey).onChange(of: gamesEANAPIKey) { _, newValue in GamesEANAPIKeyStore.save(newValue) }; Text("Used only for Games collections. Requests go to your Game Collector API at levelcomplete.de. The key is stored in Keychain.").font(.footnote).foregroundStyle(.secondary) }; Section("Account") { Label("iCloud status", systemImage: "icloud"); Text("Cloud sharing uses your private CloudKit database and shared database.").font(.footnote).foregroundStyle(.secondary) } }.navigationTitle("Settings").onAppear { gamesEANAPIKey = GamesEANAPIKeyStore.load() } } }
}

struct CollectionSettingsView: View {
    @Environment(AppStore.self) private var store; @Environment(\.dismiss) private var dismiss; let collection: CollectionModel
    @State private var statuses: [CollectionStatus]
    @State private var defaultState: ItemState
    @State private var barcodeRequired = false

    init(collection: CollectionModel) {
        self.collection = collection
        let configured = collection.statuses.isEmpty ? CollectionStatus.defaults : collection.statuses
        _statuses = State(initialValue: configured)
        _defaultState = State(initialValue: configured.first.map { ItemState(rawValue: $0.id) } ?? .wanted)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach($statuses) { $status in
                        NavigationLink {
                            StatusEditorView(status: $status)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: status.symbol).foregroundStyle(status.color.color)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(status.name.isEmpty ? "Unnamed status" : status.name)
                                }
                            }
                        }
                    }
                    .onDelete { offsets in
                        guard statuses.count - offsets.count >= 1 else { return }
                        statuses.remove(atOffsets: offsets)
                    }
                    .onMove { statuses.move(fromOffsets: $0, toOffset: $1) }

                    Button { statuses.append(CollectionStatus(name: "New status", color: .indigo, symbol: "circle")) } label: {
                        Label("Add status", systemImage: "plus.circle.fill")
                    }
                } header: {
                    Text("Statuses")
                } footer: {
                    Text("Drag to reorder. Removing a status moves its existing items to the first remaining status.")
                }

                Section("Adding") {
                    Picker("Default status", selection: $defaultState) {
                        ForEach(statuses) { status in
                            Text(status.name).tag(ItemState(rawValue: status.id))
                        }
                    }
                    Toggle("Require barcode", isOn: $barcodeRequired)
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Collection settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { save() }
                }
            }
        }
    }

    private func save() {
        var updated = collection
        var cleaned = statuses
        for index in cleaned.indices {
            cleaned[index].name = cleaned[index].name.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned[index].name.isEmpty { cleaned[index].name = "Status \(index + 1)" }
            if cleaned[index].symbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { cleaned[index].symbol = "circle" }
        }
        updated.statuses = cleaned
        store.updateCollection(updated)
        dismiss()
    }
}

struct StatusEditorView: View {
    @Binding var status: CollectionStatus

    var body: some View {
        Form {
            Section("Status") {
                TextField("Name", text: $status.name)
                Picker("Color", selection: $status.color) {
                    ForEach(StatusColor.allCases) { color in
                        Label(color.rawValue.capitalized, systemImage: "circle.fill").foregroundStyle(color.color).tag(color)
                    }
                }
                TextField("SF Symbol", text: $status.symbol)
                    .textInputAutocapitalization(.never)
            }
            Section("Preview") {
                Label(status.name.isEmpty ? "Status" : status.name, systemImage: status.symbol.isEmpty ? "circle" : status.symbol)
                    .foregroundStyle(status.color.color)
            }
        }
        .navigationTitle("Edit status")
    }
}

struct EditCollectionView: View {
    @Environment(AppStore.self) private var store; @Environment(\.dismiss) private var dismiss; let original: CollectionModel
    @State private var name: String; @State private var subtitle: String; @State private var icon: String; @State private var category: CollectionCategory
    init(collection: CollectionModel) { original = collection; _name = State(initialValue: collection.name); _subtitle = State(initialValue: collection.subtitle); _icon = State(initialValue: collection.icon); _category = State(initialValue: collection.category) }
    var body: some View { NavigationStack { Form { TextField("Name", text: $name); Picker("Category", selection: $category) { ForEach(CollectionCategory.allCases) { Text($0.name).tag($0) } }; TextField("Sharing label", text: $subtitle); TextField("SF Symbol", text: $icon); Section { Text("Category controls barcode providers and item detail fields.").font(.footnote).foregroundStyle(.secondary); NavigationLink("Customize statuses") { CollectionSettingsView(collection: store.selectedCollection ?? original) } } }.navigationTitle("Edit collection").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Save") { var collection = store.selectedCollection?.id == original.id ? store.selectedCollection! : original; collection.name = name; collection.subtitle = subtitle; collection.icon = icon; collection.category = category; store.updateCollection(collection); dismiss() } } } } }
}

struct NewCollectionView: View {
    @Environment(AppStore.self) private var store; @Environment(\.dismiss) private var dismiss
    @State private var name = ""; @State private var subtitle = "Private"; @State private var icon = "square.stack.3d.up.fill"; @State private var category: CollectionCategory = .custom
    var body: some View { NavigationStack { Form { TextField("Collection name", text: $name); Picker("Category", selection: $category) { ForEach(CollectionCategory.allCases) { Text($0.name).tag($0) } }; TextField("Sharing", text: $subtitle); TextField("SF Symbol", text: $icon); Text("Category controls barcode providers and item detail fields.").font(.footnote).foregroundStyle(.secondary) }.navigationTitle("New collection").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Create") { store.addCollection(name: name, icon: icon, subtitle: subtitle, category: category); dismiss() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty) } } } }
}
