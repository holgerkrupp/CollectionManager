import SwiftUI
#if os(macOS)
import AppKit
#endif

struct RootView: View {
    @Environment(AppStore.self) private var store
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif
    @AppStorage("onboarding.hasCompleted", store: ApplicationPreferences.defaults) private var onboardingCompleted = false
    @State private var showingNewCollection = false
    #if os(iOS)
    @State private var showingSettings = false
    #endif
    @State private var showingOnboarding = false
    @State private var selectedCollectionID: UUID?
    @State private var pendingNavigationID: UUID?
    @State private var showingUnsavedEdits = false
    @State private var collectionPendingDeletion: CollectionModel?
    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { selectedCollectionID }, set: requestSelection)) {
                Section("Your collections") { ForEach(store.collections) { collection in CollectionRow(collection: collection).tag(collection.id).swipeActions(edge: .trailing, allowsFullSwipe: false) { if collection.role.canDelete { Button(role: .destructive) { collectionPendingDeletion = collection } label: { Label("Delete", systemImage: "trash") } } } } }
                Section {
                    #if os(macOS)
                    Button {
                        NSApp.activate(ignoringOtherApps: true)
                        openSettings()
                    } label: { Label("Settings", systemImage: "gearshape") }
                    #else
                    Button { showingSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                    #endif
                }
            }.refreshable { await store.syncCollections() }.navigationTitle("Collections").onChange(of: store.selectedCollection?.id) { _, id in if selectedCollectionID != id { selectedCollectionID = id } }.toolbar { ToolbarItem(placement: .platformTrailing) { Button { showingNewCollection = true } label: { Label("New collection", systemImage: "plus") }.help("Create a new collection") } }
        } detail: { if store.selectedCollection != nil { CollectionDetailView() } else { ContentUnavailableView("No collections yet", systemImage: "square.stack.3d.up", description: Text("Create your first collection to get started.")) } }
        .alert("Library update failed", isPresented: Binding(get: { store.persistenceError != nil }, set: { if !$0 { store.persistenceError = nil } })) {
            Button("OK") { store.persistenceError = nil }
        } message: { Text(store.persistenceError ?? String(localized: "Your library could not save this change.")) }
        .sheet(isPresented: $showingNewCollection) { NewCollectionView() }
        #if os(iOS)
        .sheet(isPresented: $showingSettings) { SettingsView() }
        #endif
        .platformFullScreenCover(isPresented: $showingOnboarding) {
            OnboardingView {
                onboardingCompleted = true
                showingOnboarding = false
            }
        }
        .onAppear {
            AppTips.hasCompletedOnboarding = onboardingCompleted
            if !onboardingCompleted { showingOnboarding = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in store.refreshLocale() }
        .onChange(of: onboardingCompleted) { _, completed in AppTips.hasCompletedOnboarding = completed }
        .confirmationDialog("Save your table edits before leaving?", isPresented: $showingUnsavedEdits, titleVisibility: .visible) {
            Button("Save and Continue") {
                if saveCurrentEdits() { completeNavigation() }
            }
            Button("Discard and Continue", role: .destructive) {
                if let id = store.selectedCollection?.id { store.editSessions.session(for: id).revert() }
                completeNavigation()
            }
            Button("Keep Editing", role: .cancel) { pendingNavigationID = nil }
        } message: {
            Text("Resizing and switching layouts keep your edits. Choose what happens when you leave this collection.")
        }

        .confirmationDialog("Delete this collection? All items and collection settings will be permanently deleted.", isPresented: Binding(get: { collectionPendingDeletion != nil }, set: { if !$0 { collectionPendingDeletion = nil } }), titleVisibility: .visible) {
            Button("Delete Collection", role: .destructive) { if let collection = collectionPendingDeletion { Task { await store.deleteCollection(collection) } }; collectionPendingDeletion = nil }
        }
    }
    private func requestSelection(_ id: UUID?) {
        guard id != nil else { return }
        guard id != store.selectedCollection?.id else { selectedCollectionID = id; return }
        if let currentID = store.selectedCollection?.id,
           store.editSessions.session(for: currentID).hasChanges {
            pendingNavigationID = id
            showingUnsavedEdits = true
        } else {
            selectedCollectionID = id
            store.select(id)
        }
    }

    private func completeNavigation() {
        let id = pendingNavigationID
        pendingNavigationID = nil
        selectedCollectionID = id
        store.select(id)
    }

    private func saveCurrentEdits() -> Bool {
        guard let collection = store.selectedCollection else { return true }
        let session = store.editSessions.session(for: collection.id)
        guard session.save(originals: store.items, canEdit: collection.role.canEdit, persist: {
            store.updateItem($0, previousState: $1)
        }) else { return false }
        guard session.saveNewItem(create: { title in
            store.addItem(title: title, brand: "", variant: "", description: "",
                          state: ItemState(rawValue: collection.defaultStatusID), quantity: 1, tags: []) != nil
        }) else { return false }
        return !session.hasChanges
    }

}

struct CollectionRow: View { let collection: CollectionModel; var body: some View { HStack(spacing: 12) { Image(systemName: collection.icon).font(.title3).foregroundStyle(Color.accentColor).frame(width: 30); VStack(alignment: .leading) { Text(collection.name).font(.headline); Text(collection.caption).font(.caption).foregroundStyle(.secondary) } } } }
