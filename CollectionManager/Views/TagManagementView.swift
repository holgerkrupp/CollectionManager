import SwiftUI

struct TagManagementView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let collection: CollectionModel
    @State private var tagSeparators = ",|;/"
    @State private var splitTagsOnWhitespace = false
    @State private var generateTagsFromTitle = true
    @State private var titleTagMode: TitleTagMode = .firstSegment
    @State private var titleSeparators = "-–—_:|/,"
    @State private var keepExistingTags = true
    @State private var mergedTags: [MergedTagRule]
    @State private var sourceTags = ""
    @State private var mergedTag = ""
    @State private var resultMessage: String?

    init(collection: CollectionModel) {
        self.collection = collection
        _mergedTags = State(initialValue: collection.mergedTags)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Split tags") {
                    TextField("Tag separators", text: $tagSeparators)
                    Toggle("Also split on spaces", isOn: $splitTagsOnWhitespace)
                    Text("Use any characters as separators, for example , | ; / or -.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Generate from title") {
                    Toggle("Generate tags from title", isOn: $generateTagsFromTitle)
                    if generateTagsFromTitle {
                        Picker("Title tag mode", selection: $titleTagMode) {
                            ForEach(TitleTagMode.allCases) { Text($0.label).tag($0) }
                        }
                        TextField("Title separators", text: $titleSeparators)
                    }
                    Toggle("Keep existing tags", isOn: $keepExistingTags)
                }
                Section("Merged tags") {
                    Text("When an item has every source tag, the merged tag is added automatically. Existing source tags are kept.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(mergedTags) { rule in
                        HStack {
                            Text(rule.sourceTags.joined(separator: " + "))
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            Text(rule.mergedTag).fontWeight(.semibold)
                        }
                    }
                    .onDelete { offsets in
                        mergedTags.remove(atOffsets: offsets)
                        saveMergedTags()
                    }
                    TextField("Source tags, separated by commas", text: $sourceTags)
                    TextField("Merged tag", text: $mergedTag)
                    Button("Add merged tag") { addMergedTag() }
                        .disabled(TagUtilities.splitTags(sourceTags).count < 2 || mergedTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let resultMessage {
                    Section { Text(resultMessage).font(.caption).foregroundStyle(.secondary) }
                }
                Section {
                    Button("Apply to existing items") {
                        let count = store.applyTagRules(options)
                        resultMessage = "Updated tags for \(count) item\(count == 1 ? "" : "s")."
                    }
                }
            }
            .navigationTitle("Manage tags")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private var options: TagGenerationOptions {
        var options = TagGenerationOptions()
        options.separators = tagSeparators
        options.splitOnWhitespace = splitTagsOnWhitespace
        options.generateFromTitle = generateTagsFromTitle
        options.titleMode = titleTagMode
        options.titleSeparators = titleSeparators
        options.keepExistingTags = keepExistingTags
        return options
    }

    private func addMergedTag() {
        let sources = TagUtilities.splitTags(sourceTags)
        let name = mergedTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sources.count >= 2, !name.isEmpty else { return }
        mergedTags.append(MergedTagRule(sourceTags: sources, mergedTag: name))
        sourceTags = ""
        mergedTag = ""
        saveMergedTags()
    }

    private func saveMergedTags() {
        var updated = collection
        updated.mergedTags = mergedTags
        store.updateCollection(updated)
        let count = store.applyMergedTagsToExistingItems()
        if count > 0 {
            resultMessage = "Applied merged tags to \(count) existing items."
        }
    }
}
