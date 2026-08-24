#if os(macOS)
import SwiftUI
import SFSymbolSelector

/// Identifier of the resizable collection-settings window scene. The window is
/// opened per collection, so several collections can be configured at once.
enum CollectionSettingsWindow {
    static let id = "collection-settings"
}

/// The panes listed in the collection settings sidebar.
enum CollectionSettingsPane: String, CaseIterable, Identifiable, Hashable {
    case general
    case statuses
    case metadata
    case adding
    case notifications

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .statuses: "Statuses"
        case .metadata: "Item Metadata"
        case .adding: "Adding"
        case .notifications: "Notifications"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .statuses: "flag"
        case .metadata: "list.bullet.rectangle"
        case .adding: "plus.rectangle.on.rectangle"
        case .notifications: "bell"
        }
    }
}

/// Window root. Resolves the collection from the store so the window keeps
/// showing live data after a sync, and rebuilds its editing state when the
/// window is reused for a different collection.
struct CollectionSettingsWindowView: View {
    @Environment(AppStore.self) private var store
    let collectionID: UUID?

    private var collection: CollectionModel? {
        guard let collectionID else { return nil }
        return store.collections.first(where: { $0.id == collectionID })
    }

    var body: some View {
        Group {
            if let collection {
                CollectionSettingsSplitView(collection: collection)
                    .id(collection.id)
            } else {
                ContentUnavailableView(
                    "No collection",
                    systemImage: "square.stack.3d.up",
                    description: Text("Select a collection in the main window, then open its settings again.")
                )
            }
        }
        .frame(minWidth: 820, minHeight: 500)
    }
}

private struct CollectionSettingsSplitView: View {
    @Environment(AppStore.self) private var store
    let collection: CollectionModel

    @State private var pane: CollectionSettingsPane? = .general
    @State private var name: String
    @State private var subtitle: String
    @State private var icon: String
    @State private var category: CollectionCategory
    @State private var statuses: [CollectionStatus]
    @State private var metadataFields: [MetadataFieldDefinition]
    @State private var selectedStatusID: CollectionStatus.ID?
    @State private var selectedFieldID: MetadataFieldDefinition.ID?
    @State private var defaultState: ItemState
    @State private var barcodeRequired = false
    @AppStorage private var notifySharedItemAdded: Bool
    @AppStorage private var notifySharedItemRemoved: Bool
    @AppStorage private var notifyAutomaticSyncItemAdded: Bool
    @AppStorage private var notifyAutomaticSyncStatusChanged: Bool

    init(collection: CollectionModel) {
        self.collection = collection
        let configured = collection.statuses.isEmpty ? CollectionStatus.defaults : collection.statuses
        _name = State(initialValue: collection.name)
        _subtitle = State(initialValue: collection.subtitle)
        _icon = State(initialValue: collection.icon)
        _category = State(initialValue: collection.category)
        _statuses = State(initialValue: configured)
        _metadataFields = State(initialValue: collection.metadataFields)
        _selectedStatusID = State(initialValue: configured.first?.id)
        _selectedFieldID = State(initialValue: collection.metadataFields.first?.id)
        _defaultState = State(initialValue: configured.first.map { ItemState(rawValue: $0.id) } ?? .wanted)
        _notifySharedItemAdded = AppStorage(wrappedValue: false, LocalNotificationPreferences.key(.sharedItemAdded, collectionID: collection.id))
        _notifySharedItemRemoved = AppStorage(wrappedValue: false, LocalNotificationPreferences.key(.sharedItemRemoved, collectionID: collection.id))
        _notifyAutomaticSyncItemAdded = AppStorage(wrappedValue: false, LocalNotificationPreferences.key(.automaticSyncItemAdded, collectionID: collection.id))
        _notifyAutomaticSyncStatusChanged = AppStorage(wrappedValue: false, LocalNotificationPreferences.key(.automaticSyncStatusChanged, collectionID: collection.id))
    }

    private var canEdit: Bool { collection.role.canEdit }
    private var savedStatuses: [CollectionStatus] { collection.statuses.isEmpty ? CollectionStatus.defaults : collection.statuses }
    private var hasChanges: Bool {
        name != collection.name
            || subtitle != collection.subtitle
            || icon != collection.icon
            || category != collection.category
            || statuses != savedStatuses
            || metadataFields != collection.metadataFields
    }

    var body: some View {
        NavigationSplitView {
            List(CollectionSettingsPane.allCases, selection: $pane) { item in
                Label(item.title, systemImage: item.symbol).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 172, ideal: 190, max: 240)
        } detail: {
            VStack(spacing: 0) {
                detailContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                bottomBar
            }
            .navigationTitle(pane?.title ?? "Collection Settings")
            .navigationSubtitle(collection.name)
        }
    }

    @ViewBuilder private var detailContent: some View {
        switch pane {
        case .general: generalPane
        case .statuses: statusesPane
        case .metadata: metadataPane
        case .adding: addingPane
        case .notifications: notificationsPane
        case nil:
            ContentUnavailableView("Nothing selected", systemImage: "sidebar.left", description: Text("Choose a section in the sidebar."))
        }
    }

    // MARK: - General

    private var generalPane: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                categoryPicker
                TextField("Sharing label", text: $subtitle)
                    .textFieldStyle(.roundedBorder)
            } header: {
                Text("Collection")
            } footer: {
                Text("Category controls barcode providers and item detail fields.")
            }

            Section {
                TextField("SF Symbol", text: $icon)
                    .textFieldStyle(.roundedBorder)
                SFSymbolSelector(selection: $icon, suggestedSymbolName: icon)
            } header: {
                Text("Icon")
            }

            Section {
                Label(trimmedName.isEmpty ? collection.name : trimmedName, systemImage: trimmedIcon.isEmpty ? CollectionSettingsSplitView.fallbackIcon : trimmedIcon)
            } header: {
                Text("Preview")
            }
        }
        .formStyle(.grouped)
        .disabled(!canEdit)
    }

    @ViewBuilder private var categoryPicker: some View {
        Picker("Category", selection: $category) {
            ForEach(["Consumables & Care", "Games & Play", "Books & Media", "Toys, Collectibles & General Products", "Flexible"], id: \.self) { group in
                Section(group) { ForEach(CollectionCategory.allCases.filter { $0.pickerGroup == group }) { Text($0.name).tag($0) } }
            }
        }
    }

    // MARK: - Statuses

    private var statusesPane: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selectedStatusID) {
                    ForEach($statuses) { $status in
                        Label {
                            Text(status.name.isEmpty ? "Unnamed status" : status.name)
                        } icon: {
                            Image(systemName: status.symbol.isEmpty ? "circle" : status.symbol)
                                .foregroundStyle(status.color.color)
                        }
                        .tag(status.id)
                    }
                    .onMove { statuses.move(fromOffsets: $0, toOffset: $1) }
                }
                .listStyle(.inset)

                listFooter(
                    addHelp: "Add status",
                    removeHelp: "Remove selected status",
                    // A collection must keep at least one status, otherwise its
                    // items would have nothing valid to point at.
                    canRemove: selectedStatusID != nil && statuses.count > 1,
                    add: addStatus,
                    remove: removeSelectedStatus
                )
            }
            .frame(width: 216)

            Divider()

            Group {
                if let index = statuses.firstIndex(where: { $0.id == selectedStatusID }) {
                    StatusEditorForm(status: $statuses[index])
                } else {
                    ContentUnavailableView(
                        "No status selected",
                        systemImage: "flag",
                        description: Text("Select a status to edit its name, color, and symbol.")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .disabled(!canEdit)
    }

    private func addStatus() {
        let status = CollectionStatus(name: "New status", color: .indigo, symbol: "circle")
        statuses.append(status)
        selectedStatusID = status.id
    }

    private func removeSelectedStatus() {
        guard statuses.count > 1,
              let index = statuses.firstIndex(where: { $0.id == selectedStatusID }) else { return }
        statuses.remove(at: index)
        selectedStatusID = statuses[min(index, statuses.count - 1)].id
    }

    // MARK: - Item metadata

    private var metadataPane: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Group {
                    if metadataFields.isEmpty {
                        ContentUnavailableView("No fields", systemImage: "list.bullet.rectangle", description: Text("Add a field to collect extra details on every item."))
                    } else {
                        List(selection: $selectedFieldID) {
                            ForEach($metadataFields) { $field in
                                Label {
                                    HStack {
                                        Text(field.name.isEmpty ? "Unnamed field" : field.name)
                                        Spacer()
                                        if field.showsInItemRows {
                                            Image(systemName: "eye.fill")
                                                .foregroundStyle(.secondary)
                                                .accessibilityLabel("Shown in item rows")
                                        }
                                    }
                                } icon: {
                                    Image(systemName: field.type.symbol)
                                }
                                .tag(field.id)
                            }
                            .onMove { metadataFields.move(fromOffsets: $0, toOffset: $1) }
                        }
                        .listStyle(.inset)
                    }
                }
                .frame(maxHeight: .infinity)

                listFooter(
                    addHelp: "Add metadata field",
                    removeHelp: "Remove selected field",
                    canRemove: selectedFieldID != nil,
                    add: addMetadataField,
                    remove: removeSelectedMetadataField
                )
            }
            .frame(width: 216)

            Divider()

            Group {
                if let index = metadataFields.firstIndex(where: { $0.id == selectedFieldID }) {
                    MetadataFieldEditorForm(field: $metadataFields[index])
                } else {
                    ContentUnavailableView(
                        "No field selected",
                        systemImage: "list.bullet.rectangle",
                        description: Text("Select a field to edit its name and type.")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .disabled(!canEdit)
    }

    private func addMetadataField() {
        let field = MetadataFieldDefinition()
        metadataFields.append(field)
        selectedFieldID = field.id
    }

    private func removeSelectedMetadataField() {
        guard let index = metadataFields.firstIndex(where: { $0.id == selectedFieldID }) else { return }
        metadataFields.remove(at: index)
        selectedFieldID = metadataFields.isEmpty ? nil : metadataFields[min(index, metadataFields.count - 1)].id
    }

    // MARK: - Adding

    private var addingPane: some View {
        Form {
            Section {
                Picker("Default status", selection: $defaultState) {
                    ForEach(statuses) { status in
                        Text(status.name).tag(ItemState(rawValue: status.id))
                    }
                }
                Toggle("Require barcode", isOn: $barcodeRequired)
            } header: {
                Text("New items")
            }
        }
        .formStyle(.grouped)
        .disabled(!canEdit)
    }

    // MARK: - Notifications

    private var notificationsPane: some View {
        Form {
            Section {
                Toggle("Another user added an item", isOn: $notifySharedItemAdded)
                    .onChange(of: notifySharedItemAdded) { _, enabled in LocalNotificationService.shared.userEnabledNotification(enabled) }
                Toggle("Another user removed an item", isOn: $notifySharedItemRemoved)
                    .onChange(of: notifySharedItemRemoved) { _, enabled in LocalNotificationService.shared.userEnabledNotification(enabled) }
                Toggle("Automatic sync added an item", isOn: $notifyAutomaticSyncItemAdded)
                    .onChange(of: notifyAutomaticSyncItemAdded) { _, enabled in LocalNotificationService.shared.userEnabledNotification(enabled) }
                Toggle("Automatic sync changed a matched item's status", isOn: $notifyAutomaticSyncStatusChanged)
                    .onChange(of: notifyAutomaticSyncStatusChanged) { _, enabled in LocalNotificationService.shared.userEnabledNotification(enabled) }
            } footer: {
                Text("These preferences are stored only on this device and are never included in iCloud sync.")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Chrome

    private func listFooter(
        addHelp: String,
        removeHelp: String,
        canRemove: Bool,
        add: @escaping () -> Void,
        remove: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 2) {
            Button(action: add) { Image(systemName: "plus") }
                .help(addHelp)
                .accessibilityLabel(addHelp)
            Button(action: remove) { Image(systemName: "minus") }
                .help(removeHelp)
                .accessibilityLabel(removeHelp)
                .disabled(!canRemove)
            Spacer()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            if !canEdit {
                Label("View-only collection", systemImage: "eye")
                    .foregroundStyle(.secondary)
            } else if hasChanges {
                Text("Unsaved changes")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Save") { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(!canEdit || !hasChanges)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    static let fallbackIcon = "square.stack.3d.up.fill"
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedIcon: String { icon.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func save() {
        var updated = collection
        // A collection with no name or icon would be unpickable in the sidebar,
        // so blank entries fall back rather than being stored.
        let cleanedName = trimmedName.isEmpty ? collection.name : trimmedName
        let cleanedIcon = trimmedIcon.isEmpty ? Self.fallbackIcon : trimmedIcon
        let cleanedStatuses = Self.cleaned(statuses)
        let cleanedFields = Self.cleaned(metadataFields)
        updated.name = cleanedName
        updated.subtitle = subtitle
        updated.icon = cleanedIcon
        updated.category = category
        updated.statuses = cleanedStatuses
        updated.metadataFields = cleanedFields
        store.updateCollection(updated)
        // Adopt the normalized values so the editor reflects what was stored
        // and the Save button settles back to its disabled, saved state.
        name = cleanedName
        icon = cleanedIcon
        statuses = cleanedStatuses
        metadataFields = cleanedFields
    }

    private static func cleaned(_ statuses: [CollectionStatus]) -> [CollectionStatus] {
        statuses.enumerated().map { index, status in
            var status = status
            status.name = status.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if status.name.isEmpty { status.name = "Status \(index + 1)" }
            if status.symbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { status.symbol = "circle" }
            return status
        }
    }

    private static func cleaned(_ fields: [MetadataFieldDefinition]) -> [MetadataFieldDefinition] {
        fields.enumerated().map { index, field in
            var field = field
            field.name = field.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if field.name.isEmpty { field.name = "Field \(index + 1)" }
            return field
        }
    }
}

private struct StatusEditorForm: View {
    @Binding var status: CollectionStatus

    var body: some View {
        Form {
            Section {
                // A grouped Form renders a plain TextField as right-aligned
                // text, which reads as read-only. The border makes the editable
                // rows obvious.
                TextField("Name", text: $status.name)
                    .textFieldStyle(.roundedBorder)
                Picker("Color", selection: $status.color) {
                    ForEach(StatusColor.allCases) { color in
                        Label(color.rawValue.capitalized, systemImage: "circle.fill")
                            .foregroundStyle(color.color)
                            .tag(color)
                    }
                }
                TextField("SF Symbol", text: $status.symbol)
                    .textFieldStyle(.roundedBorder)
                SFSymbolSelector(selection: $status.symbol, suggestedSymbolName: status.symbol, tint: status.color.color)
            } header: {
                Text("Status")
            }

            Section {
                Label(status.name.isEmpty ? "Status" : status.name, systemImage: status.symbol.isEmpty ? "circle" : status.symbol)
                    .foregroundStyle(status.color.color)
            } header: {
                Text("Preview")
            } footer: {
                Text("Removing a status moves its existing items to the first remaining status.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct MetadataFieldEditorForm: View {
    @Binding var field: MetadataFieldDefinition

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $field.name)
                    .textFieldStyle(.roundedBorder)
                Picker("Type", selection: $field.type) {
                    ForEach(MetadataFieldType.allCases) { type in
                        Label(type.label, systemImage: type.symbol).tag(type)
                    }
                }
                Toggle("Show in item rows", isOn: $field.showsInItemRows)
            } header: {
                Text("Field")
            }

            Section {
                Label(field.name.isEmpty ? "Field name" : field.name, systemImage: field.type.symbol)
            } header: {
                Text("Preview")
            } footer: {
                Text("Changing a field's type keeps existing values. Each item can replace its value the next time it is edited. Removing a field hides its existing values but does not delete them.")
            }
        }
        .formStyle(.grouped)
    }
}
#endif
