import SwiftUI

struct SettingsView: View {
    @AppStorage("global.defaultCollectionIcon") private var defaultIcon = "square.stack.3d.up.fill"
    @AppStorage("global.confirmDeletes") private var confirmDeletes = true
    @State private var gamesEANAPIKey = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Defaults") {
                    TextField("Default collection icon", text: $defaultIcon)
                    Toggle("Confirm before deleting", isOn: $confirmDeletes)
                }

                Section("Games EAN lookup") {
                    SecureField("API key", text: $gamesEANAPIKey)
                        .onChange(of: gamesEANAPIKey) { _, newValue in GamesEANAPIKeyStore.save(newValue) }
                    Text("Used only for Games collections. Requests go to your Game Collector API at levelcomplete.de. The key is stored in Keychain.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Account") {
                    Label("iCloud status", systemImage: "icloud")
                    Text("Cloud sharing uses your private CloudKit database and shared database.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .task {
                gamesEANAPIKey = GamesEANAPIKeyStore.load()
            }
        }
    }
}

struct CollectionSettingsView: View {
    @Environment(AppStore.self) private var store; @Environment(\.dismiss) private var dismiss; let collection: CollectionModel
    @State private var statuses: [CollectionStatus]
    @State private var metadataFields: [MetadataFieldDefinition]
    @State private var defaultState: ItemState
    @State private var barcodeRequired = false
    @AppStorage private var notifySharedItemAdded: Bool
    @AppStorage private var notifySharedItemRemoved: Bool
    @AppStorage private var notifyAutomaticSyncItemAdded: Bool
    @AppStorage private var notifyAutomaticSyncStatusChanged: Bool

    init(collection: CollectionModel) {
        self.collection = collection
        let configured = collection.statuses.isEmpty ? CollectionStatus.defaults : collection.statuses
        _statuses = State(initialValue: configured)
        _metadataFields = State(initialValue: collection.metadataFields)
        _defaultState = State(initialValue: configured.first.map { ItemState(rawValue: $0.id) } ?? .wanted)
        _notifySharedItemAdded = AppStorage(wrappedValue: false, LocalNotificationPreferences.key(.sharedItemAdded, collectionID: collection.id))
        _notifySharedItemRemoved = AppStorage(wrappedValue: false, LocalNotificationPreferences.key(.sharedItemRemoved, collectionID: collection.id))
        _notifyAutomaticSyncItemAdded = AppStorage(wrappedValue: false, LocalNotificationPreferences.key(.automaticSyncItemAdded, collectionID: collection.id))
        _notifyAutomaticSyncStatusChanged = AppStorage(wrappedValue: false, LocalNotificationPreferences.key(.automaticSyncStatusChanged, collectionID: collection.id))
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
                    Text("Tap a status to edit it. Use Edit to reorder or remove statuses. Removing one moves its existing items to the first remaining status.")
                }

                Section {
                    ForEach($metadataFields) { $field in
                        NavigationLink {
                            MetadataFieldDefinitionEditorView(field: $field)
                        } label: {
                            HStack {
                                Label(field.name.isEmpty ? "Unnamed field" : field.name, systemImage: field.type.symbol)
                                Spacer()
                                if field.showsInItemRows {
                                    Image(systemName: "eye.fill")
                                        .foregroundStyle(.secondary)
                                        .accessibilityLabel("Shown in item rows")
                                }
                            }
                        }
                    }
                    .onDelete { metadataFields.remove(atOffsets: $0) }
                    .onMove { metadataFields.move(fromOffsets: $0, toOffset: $1) }

                    Button {
                        metadataFields.append(MetadataFieldDefinition())
                    } label: {
                        Label("Add metadata field", systemImage: "plus.circle.fill")
                    }
                } header: {
                    Text("Item metadata")
                } footer: {
                    Text("Tap a field to edit it. Use Edit to reorder or remove fields. Custom fields appear when adding or editing every item in this collection. Removing one hides its existing values but does not delete them.")
                }

                Section("Adding") {
                    Picker("Default status", selection: $defaultState) {
                        ForEach(statuses) { status in
                            Text(status.name).tag(ItemState(rawValue: status.id))
                        }
                    }
                    Toggle("Require barcode", isOn: $barcodeRequired)
                }

                Section {
                    Toggle("Another user added an item", isOn: $notifySharedItemAdded)
                        .onChange(of: notifySharedItemAdded) { _, enabled in LocalNotificationService.shared.userEnabledNotification(enabled) }
                    Toggle("Another user removed an item", isOn: $notifySharedItemRemoved)
                        .onChange(of: notifySharedItemRemoved) { _, enabled in LocalNotificationService.shared.userEnabledNotification(enabled) }
                    Toggle("Automatic sync added an item", isOn: $notifyAutomaticSyncItemAdded)
                        .onChange(of: notifyAutomaticSyncItemAdded) { _, enabled in LocalNotificationService.shared.userEnabledNotification(enabled) }
                    Toggle("Automatic sync changed a matched item's status", isOn: $notifyAutomaticSyncStatusChanged)
                        .onChange(of: notifyAutomaticSyncStatusChanged) { _, enabled in LocalNotificationService.shared.userEnabledNotification(enabled) }
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("These preferences are stored only on this device and are never included in iCloud sync.")
                }
            }
            .navigationTitle("Collection settings")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                }
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
        updated.metadataFields = metadataFields.enumerated().map { index, field in
            var field = field
            field.name = field.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if field.name.isEmpty { field.name = "Field \(index + 1)" }
            return field
        }
        store.updateCollection(updated)
        dismiss()
    }
}

struct MetadataFieldDefinitionEditorView: View {
    @Binding var field: MetadataFieldDefinition

    var body: some View {
        Form {
            Section("Field") {
                TextField("Name", text: $field.name)
                Picker("Type", selection: $field.type) {
                    ForEach(MetadataFieldType.allCases) { type in
                        Label(type.label, systemImage: type.symbol).tag(type)
                    }
                }
                Toggle("Show in item rows", isOn: $field.showsInItemRows)
            }
            Section {
                Label(field.name.isEmpty ? "Field name" : field.name, systemImage: field.type.symbol)
            } header: {
                Text("Preview")
            } footer: {
                Text("Changing a field's type keeps existing values. Each item can replace its value the next time it is edited.")
            }
        }
        .navigationTitle("Edit metadata field")
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
    var body: some View { NavigationStack { Form { TextField("Name", text: $name); Picker("Category", selection: $category) { ForEach(CollectionCategory.allCases) { Text($0.name).tag($0) } }; TextField("Sharing label", text: $subtitle); TextField("SF Symbol", text: $icon); Section { Text("Category controls barcode providers and item detail fields.").font(.footnote).foregroundStyle(.secondary); NavigationLink("Customize statuses and metadata") { CollectionSettingsView(collection: store.selectedCollection ?? original) } } }.navigationTitle("Edit collection").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Save") { var collection = store.selectedCollection?.id == original.id ? store.selectedCollection! : original; collection.name = name; collection.subtitle = subtitle; collection.icon = icon; collection.category = category; store.updateCollection(collection); dismiss() } } } } }
}

struct NewCollectionView: View {
    @Environment(AppStore.self) private var store; @Environment(\.dismiss) private var dismiss
    @State private var name = ""; @State private var subtitle = "Private"; @State private var icon = "square.stack.3d.up.fill"; @State private var category: CollectionCategory = .custom
    var body: some View { NavigationStack { Form { TextField("Collection name", text: $name); Picker("Category", selection: $category) { ForEach(CollectionCategory.allCases) { Text($0.name).tag($0) } }; TextField("Sharing", text: $subtitle); TextField("SF Symbol", text: $icon); Text("Category controls barcode providers and item detail fields.").font(.footnote).foregroundStyle(.secondary) }.navigationTitle("New collection").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Create") { store.addCollection(name: name, icon: icon, subtitle: subtitle, category: category); dismiss() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty) } } } }
}
