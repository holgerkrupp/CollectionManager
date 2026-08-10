import SwiftUI

struct RootView: View {
    @Environment(AppStore.self) private var store
    @State private var showingNewCollection = false
    @State private var showingSettings = false
    @State private var selectedCollectionID: UUID?
    @State private var collectionPendingDeletion: CollectionModel?
    var body: some View {
        NavigationSplitView {
            List(selection: $selectedCollectionID) {
                Section("Your collections") { ForEach(store.collections) { collection in CollectionRow(collection: collection).tag(collection.id).swipeActions(edge: .trailing, allowsFullSwipe: false) { if collection.role.canDelete { Button(role: .destructive) { collectionPendingDeletion = collection } label: { Label("Delete", systemImage: "trash") } } } } }
                Section { Button { showingSettings = true } label: { Label("Settings", systemImage: "gearshape") } }
            }.navigationTitle("Collections").onChange(of: selectedCollectionID) { _, id in store.select(id) }.onChange(of: store.selectedCollection?.id) { _, id in if selectedCollectionID != id { selectedCollectionID = id } }.toolbar { ToolbarItem(placement: .topBarTrailing) { Button { showingNewCollection = true } label: { Image(systemName: "plus") } } }
        } detail: { if store.selectedCollection != nil { CollectionDetailView() } else { ContentUnavailableView("No collections yet", systemImage: "square.stack.3d.up", description: Text("Create your first collection to get started.")) } }
        .sheet(isPresented: $showingNewCollection) { NewCollectionView() }
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .confirmationDialog("Delete this collection? All items and collection settings will be permanently deleted.", isPresented: Binding(get: { collectionPendingDeletion != nil }, set: { if !$0 { collectionPendingDeletion = nil } }), titleVisibility: .visible) {
            Button("Delete Collection", role: .destructive) { if let collection = collectionPendingDeletion { Task { await store.deleteCollection(collection) } }; collectionPendingDeletion = nil }
        }
    }
}

struct CollectionRow: View { let collection: CollectionModel; var body: some View { HStack(spacing: 12) { Image(systemName: collection.icon).font(.title3).foregroundStyle(Color.accentColor).frame(width: 30); VStack(alignment: .leading) { Text(collection.name).font(.headline); Text(collection.subtitle).font(.caption).foregroundStyle(.secondary) } } } }
