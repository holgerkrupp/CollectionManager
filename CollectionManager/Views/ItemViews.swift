import SwiftUI
import PhotosUI
import AppIntents
import TipKit

enum MetadataColorCodec {
    static func color(from value: MetadataValue?) -> Color? {
        guard case .string(let rawValue)? = value else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let namedColors: [String: Color] = [
            "black": .black, "white": .white, "gray": .gray, "grey": .gray,
            "silver": Color(red: 0.75, green: 0.75, blue: 0.75), "gold": Color(red: 0.83, green: 0.69, blue: 0.22),
            "red": .red, "orange": .orange, "yellow": .yellow, "green": .green,
            "mint": .mint, "teal": .teal, "cyan": .cyan, "blue": .blue,
            "indigo": .indigo, "purple": .purple, "pink": .pink, "brown": .brown
        ]
        if let named = namedColors[value] { return named }
        let hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
        guard hex.count == 6 || hex.count == 8, let number = UInt64(hex, radix: 16) else { return nil }
        let red = Double((number >> (hex.count == 8 ? 24 : 16)) & 0xff) / 255
        let green = Double((number >> (hex.count == 8 ? 16 : 8)) & 0xff) / 255
        let blue = Double((number >> (hex.count == 8 ? 8 : 0)) & 0xff) / 255
        let opacity = hex.count == 8 ? Double(number & 0xff) / 255 : 1
        return Color(red: red, green: green, blue: blue, opacity: opacity)
    }

    static func hex(from color: Color) -> String {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        #if os(iOS)
        guard PlatformColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return "#007AFF" }
        #elseif os(macOS)
        guard let rgbColor = PlatformColor(color).usingColorSpace(.deviceRGB) else { return "#007AFF" }
        rgbColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        #endif
        return String(format: "#%02X%02X%02X", Int(red * 255), Int(green * 255), Int(blue * 255))
    }
}

struct ItemCard: View {
    @Environment(AppStore.self) private var store
    let item: CollectionItem
    @State private var showingEdit = false
    var body: some View {
        let status = store.status(for: item.state)
        let rowMetadataFields = store.selectedCollection?.metadataFields.filter(\.showsInItemRows) ?? []
        HStack(spacing: 14) {
            ItemThumbnail(item: item, tint: status.color.color)
            VStack(alignment: .leading, spacing: 4) {
                HStack { Text(item.title).font(.headline); Spacer(); Text(status.name).font(.caption.weight(.semibold)).foregroundStyle(status.color.color).padding(.horizontal, 8).padding(.vertical, 4).background(status.color.color.opacity(0.12), in: Capsule()) }
                Text([item.brand, item.variant].filter { !$0.isEmpty }.joined(separator: " · ")).foregroundStyle(.secondary)
                if !item.itemDescription.isEmpty { LinkedText(item.itemDescription).font(.subheadline).foregroundStyle(.secondary).lineLimit(4) }
                TagFlowLayout { ForEach(item.tags, id: \.self) { TagChip(title: $0) }; if item.quantity > 1 { Text("×\(item.quantity)").font(.caption).foregroundStyle(.secondary) } }
                if !rowMetadataFields.isEmpty {
                    ItemMetadataSummary(item: item, fields: rowMetadataFields)
                }
                if !item.ratings.isEmpty { RatingSummary(ratings: item.ratings) }
                if !item.comments.isEmpty { Label("\(item.comments.count) collaborator comment\(item.comments.count == 1 ? "" : "s")", systemImage: "text.bubble").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 20))
        .contentShape(Rectangle())
        // Lets Siri resolve "this item" to the card on screen.
        .appEntityIdentifier(EntityIdentifier(for: ItemEntity.self, identifier: item.id))
        .onTapGesture { showingEdit = true }
        .contextMenu {
            Button { showingEdit = true } label: { Label("Edit", systemImage: "pencil") }
            Button(role: .destructive) { Task { await store.deleteItem(item) } } label: { Label("Delete", systemImage: "trash") }
        }
        .sheet(isPresented: $showingEdit) { EditItemView(item: item) }
    }
}

private struct ItemMetadataSummary: View {
    struct Entry: Identifiable {
        let field: MetadataFieldDefinition
        let value: MetadataValue
        var id: UUID { field.id }
    }

    let item: CollectionItem
    let fields: [MetadataFieldDefinition]

    var body: some View {
        let entries = fields.compactMap { field -> Entry? in
            guard let value = item.metadata[field.storageKey] else { return nil }
            if case .string(let text) = value, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
            return Entry(field: field, value: value)
        }
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(entries) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("\(entry.field.name):")
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                        if entry.field.type == .color, let color = MetadataColorCodec.color(from: entry.value) {
                            Circle()
                                .fill(color)
                                .overlay(Circle().stroke(.secondary.opacity(0.35), lineWidth: 1))
                                .frame(width: 10, height: 10)
                        }
                        Text(entry.value.displayValue)
                            .foregroundStyle(.primary)
                    }
                    .font(.caption)
                    .lineLimit(2)
                }
            }
            .padding(.top, 2)
        }
    }
}

private struct ItemThumbnail: View {
    let item: CollectionItem
    let tint: Color
    @State private var image: PlatformImage?

    var body: some View {
        Group {
            if let image {
                Image(platformImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: item.imageSystemName).font(.title2).foregroundStyle(tint)
                    .background(tint.opacity(0.12))
            }
        }
        .frame(width: 54, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .task(id: item.imageData) {
            guard let data = item.imageData else { image = nil; return }
            image = await Task.detached(priority: .utility) { PlatformImage(data: data) }.value
        }
    }
}

private struct RatingSummary: View {
    let ratings: [ItemRating]
    var body: some View {
        let average = Double(ratings.map(\.value).reduce(0, +)) / Double(ratings.count)
        Label("\(average, specifier: "%.1f") / 5 · \(ratings.count) rating\(ratings.count == 1 ? "" : "s")", systemImage: "star.fill")
            .font(.caption)
            .foregroundStyle(.orange)
    }
}

private struct LinkedText: View {
    let text: String
    @State private var value: AttributedString

    init(_ text: String) { self.text = text; _value = State(initialValue: AttributedString(text)) }

    var body: some View {
        Text(value)
            .tint(.blue)
            .task(id: text) {
                guard text.localizedCaseInsensitiveContains("http") || text.localizedCaseInsensitiveContains("www.") else { return }
                value = await Task.detached(priority: .utility) {
                    let attributed = NSMutableAttributedString(string: text)
                    let range = NSRange(location: 0, length: text.utf16.count)
                    if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
                        detector.enumerateMatches(in: text, range: range) { match, _, _ in
                            guard let url = match?.url, let matchRange = match?.range else { return }
                            attributed.addAttribute(.link, value: url, range: matchRange)
                        }
                    }
                    return (try? AttributedString(attributed, including: \.swiftUI)) ?? AttributedString(text)
                }.value
            }
    }
}

private struct TagChip: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption2)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .frame(maxWidth: 150, alignment: .leading)
            .background(.fill.tertiary, in: Capsule())
    }
}

private struct TagFlowLayout: Layout {
    var horizontalSpacing: CGFloat = 6
    var verticalSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposalWidth: proposal.width ?? .greatestFiniteMagnitude, subviews: subviews)
        return CGSize(width: proposal.width ?? result.width, height: result.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposalWidth: bounds.width, subviews: subviews)
        for (index, placement) in result.placements.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + placement.origin.x, y: bounds.minY + placement.origin.y), proposal: ProposedViewSize(placement.size))
        }
    }

    private func arrange(proposalWidth: CGFloat, subviews: Subviews) -> (width: CGFloat, height: CGFloat, placements: [(origin: CGPoint, size: CGSize)]) {
        let width = max(proposalWidth, 1)
        var placements: [(origin: CGPoint, size: CGSize)] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let maxTagWidth = min(width, 150)
            let naturalSize = subview.sizeThatFits(ProposedViewSize(width: nil, height: nil))
            let size = naturalSize.width > maxTagWidth
                ? subview.sizeThatFits(ProposedViewSize(width: maxTagWidth, height: nil))
                : naturalSize
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            placements.append((CGPoint(x: x, y: y), size))
            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }

        return (width, y + rowHeight, placements)
    }
}

private struct ProductLookupSuggestions {
    var title: String?
    var brand: String?
    var variant: String?
    var tags: String?
    var metadata: [String: MetadataValue] = [:]
}

private struct ProductNameLookupControl: View {
    let query: String
    let onSelect: (ProductMetadata) -> Void
    @State private var isSearching = false
    @State private var message: String?
    @State private var results: [ProductMetadata] = []
    @State private var showingResults = false
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        Button { search() } label: {
            HStack {
                Label(isSearching ? "Searching products…" : "Find Product Details by Name", systemImage: "text.magnifyingglass")
                Spacer()
                if isSearching { ProgressView().controlSize(.small) }
            }
        }
        .disabled(trimmedQuery.count < 2 || isSearching)
        if let message {
            Text(message).font(.footnote).foregroundStyle(.secondary)
        }
        EmptyView()
            .sheet(isPresented: $showingResults) {
                ProductNameSearchResultsView(query: trimmedQuery, products: results) { product in
                    onSelect(product)
                    message = "Product details applied. Review them before saving."
                }
            }
            .onDisappear { searchTask?.cancel() }
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func search() {
        let submittedQuery = trimmedQuery
        guard submittedQuery.count >= 2 else { return }
        searchTask?.cancel()
        isSearching = true
        message = nil
        searchTask = Task {
            do {
                let products = try await OpenFoodFactsNameSearchProvider().products(matching: submittedQuery)
                guard !Task.isCancelled else { return }
                results = products
                if products.isEmpty {
                    message = "No matching products were found. Try including the brand or expression."
                } else {
                    showingResults = true
                }
            } catch {
                guard !Task.isCancelled else { return }
                message = "\(error.localizedDescription) Try again later or enter the details manually."
            }
            guard !Task.isCancelled else { return }
            isSearching = false
            searchTask = nil
        }
    }
}

private struct ProductNameSearchResultsView: View {
    @Environment(\.dismiss) private var dismiss
    let query: String
    let products: [ProductMetadata]
    let onSelect: (ProductMetadata) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(products.enumerated()), id: \.offset) { _, product in
                        Button {
                            onSelect(product)
                            dismiss()
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                if let imageURL = product.imageURL {
                                    AsyncImage(url: imageURL) { image in
                                        image.resizable().scaledToFit()
                                    } placeholder: {
                                        ProgressView()
                                    }
                                    .frame(width: 48, height: 64)
                                    .clipShape(.rect(cornerRadius: 6))
                                } else {
                                    Image(systemName: "wineglass").frame(width: 48, height: 48).foregroundStyle(.secondary)
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(product.title).font(.headline).foregroundStyle(.primary)
                                    if !product.brand.isEmpty { Text(product.brand).foregroundStyle(.secondary) }
                                    if !product.variant.isEmpty { Text(product.variant).font(.subheadline).foregroundStyle(.secondary) }
                                    if let barcode = product.barcode { Text(barcode.value).font(.caption.monospacedDigit()).foregroundStyle(.tertiary) }
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text("Select the matching product to fill its name, brand, variant, barcode, categories, and available product metadata.")
                }
            }
            .navigationTitle("Results for “\(query)”")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

struct AddItemView: View {
    @Environment(AppStore.self) private var store; @Environment(\.dismiss) private var dismiss
    @State private var title = ""; @State private var brand = ""; @State private var variant = ""; @State private var description = ""; @State private var quantity = 1; @State private var tags = ""; @State private var metadata: [String: MetadataValue] = [:]; @State private var state: ItemState = .wanted; @State private var barcode: Barcode?; @State private var imageData: Data?; @State private var sourceSnapshot: ProductSourceSnapshot?; @State private var showingScanner = false; @State private var showingCamera = false; @State private var showingMetadataMapping = false; @State private var pickerItem: PhotosPickerItem?; @State private var manualBarcode = ""; @State private var isLookingUp = false; @State private var lookupMessage: String?; @State private var photoMessage: String?; @State private var productMatches: [CollectionProductMatch] = []; @State private var lookupTask: Task<Void, Never>?; @State private var lookupSuggestions = ProductLookupSuggestions()
    private let scanBarcodeTip = ScanBarcodeTip(); private let siriTip = AddItemsWithSiriTip(); @State private var showsSiriTip = false
    var body: some View {
        let category = store.selectedCollection?.category ?? .custom
        NavigationStack {
            Form {
                // Only inserted while eligible, so the form has no empty section otherwise.
                if showsSiriTip {
                    Section { TipView(siriTip) }
                }

                Section {
                    HStack {
                        Label("Barcode", systemImage: "barcode")
                        Spacer(minLength: 12)
                        TextField("Number", text: $manualBarcode)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                            .multilineTextAlignment(.trailing)
                            .onChange(of: manualBarcode) { _, newValue in updateBarcode(from: newValue) }
                            .accessibilityLabel("Barcode")
                        #if os(iOS)
                        if category.supportsBarcodeScanning {
                            Button {
                                scanBarcodeTip.invalidate(reason: .actionPerformed)
                                showingScanner = true
                            } label: {
                                Image(systemName: "barcode.viewfinder")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Scan barcode")
                            .accessibilityHint("Opens the camera barcode scanner")
                            .popoverTip(scanBarcodeTip)
                        }
                        #endif
                    }

                    if category.supportsBarcodeScanning {
                        Button {
                            if let barcode { lookup(barcode) }
                        } label: {
                            HStack {
                                Label(isLookingUp ? "Looking up product…" : "Look Up Product", systemImage: "magnifyingglass")
                                Spacer()
                                if isLookingUp {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                            }
                        }
                        .disabled(barcode == nil || isLookingUp)
                    }

                    if let barcode {
                        if let status = store.barcodeStatus(barcode) {
                            let configuredStatus = store.status(for: status)
                            Label(status == .consumed ? "Already consumed in this collection" : status == .stored ? "Currently in storage" : "Already in collection: \(configuredStatus.name)", systemImage: configuredStatus.symbol)
                                .foregroundStyle(configuredStatus.color.color)
                        }
                    }

                    if !manualBarcode.isEmpty, barcode == nil {
                        Text("Enter a valid 8, 12, 13, or 14 digit barcode.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else if let lookupMessage {
                        Text(lookupMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Identify")
                } footer: {
                    if category.supportsBarcodeScanning {
                        Text("Product lookup sends only the barcode. Results are suggestions and never replace changes you make while lookup is running.")
                    }
                }

                Section("Item details") {
                    TextField("Title", text: $title)
                    if category == .food {
                        ProductNameLookupControl(query: title, onSelect: applyNameLookupResult)
                    }
                    TextField("Brand", text: $brand)
                    TextField("Variant", text: $variant)
                    TextField("Description", text: $description, axis: .vertical)
                    Stepper("Quantity: \(quantity)", value: $quantity, in: 1...999)
                    Picker("Status", selection: $state) { ForEach(store.statuses) { status in Text(status.name).tag(ItemState(rawValue: status.id)) } }
                    TextField("Tags, separated by commas", text: $tags)
                }

                if !category.detailFields.isEmpty {
                    Section("\(category.name) details") {
                        ForEach(category.detailFields, id: \.key) { field in
                            TextField(field.title, text: metadataBinding(for: field.key), prompt: Text(field.placeholder))
                        }
                    }
                }

                if let fields = store.selectedCollection?.metadataFields, !fields.isEmpty {
                    CustomMetadataFieldsSection(fields: fields, metadata: $metadata)
                }

                if let sourceSnapshot {
                    Section("Product metadata") {
                        Button { showingMetadataMapping = true } label: { Label("Map API fields", systemImage: "arrow.triangle.branch") }
                        Text("\(sourceSnapshot.provider) snapshot from \(sourceSnapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Photo") {
                    #if os(iOS)
                    Button { showingCamera = true } label: { Label("Take Photo", systemImage: "camera") }
                    #endif
                    PhotosPicker(selection: $pickerItem, matching: .images) { Label("Choose Existing Photo", systemImage: "photo") }
                        .onChange(of: pickerItem) { _, newValue in
                            Task { if let data = try? await newValue?.loadTransferable(type: Data.self) { handleImage(data) } }
                        }
                    if imageData != nil {
                        Label("Photo added", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    if let photoMessage {
                        Text(photoMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if !productMatches.isEmpty {
                    Section("Possible matches in your collections") {
                        ForEach(productMatches) { match in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: match.status.symbol).foregroundStyle(match.status.color.color)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(match.itemTitle).font(.headline)
                                    Text("\(match.collectionName) · \(match.status.name)").font(.subheadline.weight(.semibold)).foregroundStyle(match.status.color.color)
                                    Text("Matched by \(match.matchedBy.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("\(match.itemTitle), \(match.status.name) in \(match.collectionName). Matched by \(match.matchedBy.joined(separator: ", "))")
                        }
                    }
                }
            }
            .navigationTitle("Add item")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        lookupTask?.cancel()
                        let added = store.addItem(title: title.trimmingCharacters(in: .whitespacesAndNewlines), brand: brand, variant: variant, description: description, state: state, quantity: quantity, tags: tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }, metadata: metadata.compactMapValues { value in if case .string(let text) = value, text.isEmpty { return nil }; return value }, barcode: barcode, imageData: imageData, sourceSnapshot: sourceSnapshot)
                        if added != nil { AppTips.itemAdded.sendDonation() }
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            #if os(iOS)
            .sheet(isPresented: $showingScanner) {
                BarcodeScannerSheet { value in
                    selectBarcode(value)
                    lookup(value)
                }
            }
            #endif
            .sheet(isPresented: $showingMetadataMapping) {
                if let sourceSnapshot { ProductMetadataMappingView(snapshot: sourceSnapshot, metadata: $metadata) }
            }
            #if os(iOS)
            .fullScreenCover(isPresented: $showingCamera) { PhotoCaptureView { handleImage($0) } }
            #endif
            .onAppear { if !store.statuses.contains(where: { $0.id == state.rawValue }), let first = store.statuses.first { state = ItemState(rawValue: first.id) } }
            .onDisappear { lookupTask?.cancel() }
            .task { for await shouldDisplay in siriTip.shouldDisplayUpdates { showsSiriTip = shouldDisplay } }
        }
    }
    private func updateBarcode(from rawValue: String) {
        let value = Barcode(rawValue: rawValue)
        guard value != barcode else { return }
        lookupTask?.cancel()
        lookupTask = nil
        clearLookupSuggestions()
        barcode = value
        isLookingUp = false
        lookupMessage = nil
        productMatches = []
    }
    private func selectBarcode(_ value: Barcode) {
        lookupTask?.cancel()
        lookupTask = nil
        if barcode != value { clearLookupSuggestions() }
        barcode = value
        manualBarcode = value.value
        isLookingUp = false
        lookupMessage = nil
        productMatches = []
    }
    private func lookup(_ value: Barcode) {
        let provider: any ProductMetadataProvider
        switch store.selectedCollection?.category {
        case .food: provider = OpenFoodFactsProvider()
        case .games: provider = FirstMatchProductProvider(providers: [GamesEANProvider(), OpenFactsProvider(host: "world.openproductsfacts.org")])
        case .boardGames: provider = FirstMatchProductProvider(providers: [GameUPCProvider(), OpenFactsProvider(host: "world.openproductsfacts.org")])
        case .books: provider = OpenLibraryProvider()
        case .music: provider = MusicBrainzProvider()
        case .cosmetics: provider = OpenFactsProvider(host: "world.openbeautyfacts.org")
        case .petFood: provider = OpenFactsProvider(host: "world.openpetfoodfacts.org")
        case .products: provider = OpenFactsProvider(host: "world.openproductsfacts.org")
        default:
            lookupMessage = "Product lookup is not configured for this collection category yet."
            return
        }

        lookupTask?.cancel()
        let startingTitle = title
        let startingBrand = brand
        let startingVariant = variant
        let startingTags = tags
        let startingMetadata = metadata
        isLookingUp = true
        lookupMessage = nil

        lookupTask = Task {
            do {
                let product = try await provider.product(for: value)
                guard !Task.isCancelled, barcode == value else { return }
                if let product {
                    sourceSnapshot = product.sourceSnapshot
                    var appliedSuggestions = ProductLookupSuggestions()
                    if startingTitle.isEmpty, title == startingTitle, !product.title.isEmpty {
                        title = product.title
                        appliedSuggestions.title = product.title
                    }
                    if startingBrand.isEmpty, brand == startingBrand, !product.brand.isEmpty {
                        brand = product.brand
                        appliedSuggestions.brand = product.brand
                    }
                    if startingVariant.isEmpty, variant == startingVariant, !product.variant.isEmpty {
                        variant = product.variant
                        appliedSuggestions.variant = product.variant
                    }
                    let suggestedTags = product.categories.joined(separator: ", ")
                    if startingTags.isEmpty, tags == startingTags, !suggestedTags.isEmpty {
                        tags = suggestedTags
                        appliedSuggestions.tags = suggestedTags
                    }
                    if let appliedValue = applyLookupValue(product.country, for: "country", startingMetadata: startingMetadata) {
                        appliedSuggestions.metadata["country"] = appliedValue
                    }
                    if let appliedValue = applyLookupValue(suggestedTags, for: "categories", startingMetadata: startingMetadata) {
                        appliedSuggestions.metadata["categories"] = appliedValue
                    }
                    for (key, suggestedValue) in product.extraFields {
                        if let appliedValue = applyLookupValue(suggestedValue, for: key, startingMetadata: startingMetadata) {
                            appliedSuggestions.metadata[key] = appliedValue
                        }
                    }
                    lookupSuggestions = appliedSuggestions
                    productMatches = store.productMatches(for: value, productName: product.title)
                    lookupMessage = "Product data found. Review the suggested details before saving."
                } else {
                    productMatches = store.productMatches(for: value)
                    lookupMessage = "No product was found. You can still enter the item manually."
                }
            } catch {
                guard !Task.isCancelled, barcode == value else { return }
                productMatches = store.productMatches(for: value)
                lookupMessage = "\(error.localizedDescription) You can still enter the item manually."
            }
            guard !Task.isCancelled, barcode == value else { return }
            isLookingUp = false
            lookupTask = nil
        }
    }
    @discardableResult
    private func applyLookupValue(_ suggestedValue: String?, for key: String, startingMetadata: [String: MetadataValue]) -> MetadataValue? {
        guard let suggestedValue, !suggestedValue.isEmpty, metadata[key] == startingMetadata[key] else { return nil }
        if let startingValue = startingMetadata[key], !startingValue.displayValue.isEmpty { return nil }
        let value = MetadataValue.string(suggestedValue)
        metadata[key] = value
        return value
    }
    private func clearLookupSuggestions() {
        if let suggestedTitle = lookupSuggestions.title, title == suggestedTitle { title = "" }
        if let suggestedBrand = lookupSuggestions.brand, brand == suggestedBrand { brand = "" }
        if let suggestedVariant = lookupSuggestions.variant, variant == suggestedVariant { variant = "" }
        if let suggestedTags = lookupSuggestions.tags, tags == suggestedTags { tags = "" }
        for (key, suggestedValue) in lookupSuggestions.metadata where metadata[key] == suggestedValue {
            metadata.removeValue(forKey: key)
        }
        sourceSnapshot = nil
        lookupSuggestions = ProductLookupSuggestions()
    }
    private func metadataBinding(for key: String) -> Binding<String> { Binding(get: { if case .string(let value) = metadata[key] { return value }; return metadata[key]?.displayValue ?? "" }, set: { metadata[key] = .string($0) }) }
    private func applyNameLookupResult(_ product: ProductMetadata) {
        if !product.title.isEmpty { title = product.title }
        if !product.brand.isEmpty { brand = product.brand }
        if !product.variant.isEmpty { variant = product.variant }
        if let productBarcode = product.barcode {
            barcode = productBarcode
            manualBarcode = productBarcode.value
            productMatches = store.productMatches(for: productBarcode, productName: product.title)
        }
        mergeLookupDetails(from: product)
        sourceSnapshot = product.sourceSnapshot
        loadLookupImageIfNeeded(from: product.imageURL)
    }
    private func mergeLookupDetails(from product: ProductMetadata) {
        var existingTags = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var tagKeys = Set(existingTags.map { $0.lowercased() })
        for category in product.categories where tagKeys.insert(category.lowercased()).inserted { existingTags.append(category) }
        tags = existingTags.joined(separator: ", ")
        let details = product.extraFields.merging(["country": product.country ?? "", "categories": product.categories.joined(separator: ", ")]) { current, _ in current }
        for (key, value) in details where !value.isEmpty && (metadata[key]?.displayValue.isEmpty ?? true) { metadata[key] = .string(value) }
    }
    private func loadLookupImageIfNeeded(from url: URL?) {
        guard imageData == nil, let url else { return }
        Task {
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else { return }
            let prepared = await ImageProcessor.preparedData(data)
            guard imageData == nil else { return }
            imageData = prepared
            photoMessage = "Product image added from the lookup result."
        }
    }
    private func handleImage(_ data: Data) {
        let startingTitle = title
        let startingDescription = description
        photoMessage = "Preparing photo…"
        Task {
            let prepared = await ImageProcessor.preparedData(data)
            imageData = prepared
            do {
                let result = try await OCRService().recognizeText(in: prepared)
                if startingTitle.isEmpty, title == startingTitle { title = result.lines.first ?? "" }
                if startingDescription.isEmpty, description == startingDescription { description = result.text }
                photoMessage = result.text.isEmpty ? "No readable text was found." : "Text recognized from photo. Review the suggested details."
            } catch { photoMessage = "Photo saved, but text recognition failed." }
        }
    }
}

struct EditItemView: View {
    @Environment(AppStore.self) private var store; @Environment(\.dismiss) private var dismiss; let original: CollectionItem
    @State private var title: String; @State private var brand: String; @State private var variant: String; @State private var description: String; @State private var quantity: Int; @State private var tags: String; @State private var metadata: [String: MetadataValue]; @State private var state: ItemState; @State private var barcode: Barcode?; @State private var imageData: Data?; @State private var sourceSnapshot: ProductSourceSnapshot?; @State private var pickerItem: PhotosPickerItem?; @State private var recognitionMessage: String?; @State private var sourceMessage: String?; @State private var isLoadingSource = false; @State private var showingMetadataMapping = false; @State private var ratings: [ItemRating]; @State private var comments: [ItemComment]; @State private var commentDraft = ""; @State private var selectedRating: Int
    init(item: CollectionItem) { original = item; _title = State(initialValue: item.title); _brand = State(initialValue: item.brand); _variant = State(initialValue: item.variant); _description = State(initialValue: item.itemDescription); _quantity = State(initialValue: item.quantity); _tags = State(initialValue: item.tags.joined(separator: ", ")); _metadata = State(initialValue: item.metadata); _state = State(initialValue: item.state); _barcode = State(initialValue: item.barcode); _imageData = State(initialValue: item.imageData); _sourceSnapshot = State(initialValue: item.sourceSnapshot); _ratings = State(initialValue: item.ratings); _comments = State(initialValue: item.comments); _selectedRating = State(initialValue: item.ratings.first(where: { $0.participantID == CollaboratorIdentity.current.id })?.value ?? 0) }
    var body: some View {
        let category = store.selectedCollection?.category ?? .custom
        NavigationStack {
            Form {
                Section("Item details") {
                    TextField("Title", text: $title)
                    if category == .food {
                        ProductNameLookupControl(query: title, onSelect: applyNameLookupResult)
                    }
                    TextField("Brand", text: $brand); TextField("Variant", text: $variant); TextField("Description", text: $description, axis: .vertical)
                    Stepper("Quantity: \(quantity)", value: $quantity, in: 1...999)
                    Picker("Status", selection: $state) { ForEach(store.statuses) { status in Text(status.name).tag(ItemState(rawValue: status.id)) } }
                    TextField("Tags, separated by commas", text: $tags)
                    PhotosPicker(selection: $pickerItem, matching: .images) { Label("Replace photo / run OCR", systemImage: "photo") }
                        .onChange(of: pickerItem) { _, newValue in Task { if let data = try? await newValue?.loadTransferable(type: Data.self) { recognitionMessage = "Preparing photo…"; let prepared = await ImageProcessor.preparedData(data); imageData = prepared; if let result = try? await OCRService().recognizeText(in: prepared) { if description.isEmpty { description = result.text }; recognitionMessage = "Text recognized from photo. Review your changes." } else { recognitionMessage = "Photo saved, but text recognition failed." } } } }
                    if let recognitionMessage { Text(recognitionMessage).font(.footnote).foregroundStyle(.secondary) }
                }
                if !category.detailFields.isEmpty {
                    Section("\(category.name) details") {
                        ForEach(category.detailFields, id: \.key) { field in TextField(field.title, text: metadataBinding(for: field.key), prompt: Text(field.placeholder)) }
                    }
                }
                if let fields = store.selectedCollection?.metadataFields, !fields.isEmpty {
                    CustomMetadataFieldsSection(fields: fields, metadata: $metadata)
                }
                if barcode != nil || sourceSnapshot != nil {
                    Section("Product metadata") {
                        Button { openMetadataMapping(category: category) } label: {
                            Label(isLoadingSource ? "Loading product data…" : "Map API fields", systemImage: "arrow.triangle.branch")
                        }
                        .disabled(isLoadingSource)
                        if let snapshot = sourceSnapshot {
                            Text("\(snapshot.provider) snapshot from \(snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let sourceMessage { Text(sourceMessage).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                annotationsSection
                Section { Button("Delete item", role: .destructive) { dismiss(); Task { await store.deleteItem(original) } } }
            }
            .navigationTitle("Edit item")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { var item = original; let previous = item.state; item.title = title; item.brand = brand; item.variant = variant; item.itemDescription = description; item.quantity = quantity; item.state = state; item.consumedAt = state == .consumed ? (item.consumedAt ?? .now) : nil; item.updatedAt = .now; item.tags = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }; item.metadata = metadata.compactMapValues { value in if case .string(let text) = value, text.isEmpty { return nil }; return value }; item.barcode = barcode; item.imageData = imageData; item.sourceSnapshot = sourceSnapshot; store.updateItem(item, previousState: previous); dismiss() } }
            }
            .sheet(isPresented: $showingMetadataMapping) {
                if let sourceSnapshot { ProductMetadataMappingView(snapshot: sourceSnapshot, metadata: $metadata) }
            }
        }
    }

    private func openMetadataMapping(category: CollectionCategory) {
        sourceMessage = nil
        if sourceSnapshot != nil { showingMetadataMapping = true; return }
        guard category == .food, let barcode else {
            sourceMessage = "Source refresh is not available for this item provider yet."
            return
        }
        isLoadingSource = true
        Task {
            do {
                guard let product = try await OpenFoodFactsProvider().product(for: barcode), let snapshot = product.sourceSnapshot else {
                    sourceMessage = "No product source data was found for this barcode."
                    isLoadingSource = false
                    return
                }
                sourceSnapshot = snapshot
                isLoadingSource = false
                showingMetadataMapping = true
            } catch {
                sourceMessage = error.localizedDescription
                isLoadingSource = false
            }
        }
    }
    private func applyNameLookupResult(_ product: ProductMetadata) {
        if !product.title.isEmpty { title = product.title }
        if !product.brand.isEmpty { brand = product.brand }
        if !product.variant.isEmpty { variant = product.variant }
        if let productBarcode = product.barcode { barcode = productBarcode }
        var existingTags = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var tagKeys = Set(existingTags.map { $0.lowercased() })
        for category in product.categories where tagKeys.insert(category.lowercased()).inserted { existingTags.append(category) }
        tags = existingTags.joined(separator: ", ")
        let details = product.extraFields.merging(["country": product.country ?? "", "categories": product.categories.joined(separator: ", ")]) { current, _ in current }
        for (key, value) in details where !value.isEmpty && (metadata[key]?.displayValue.isEmpty ?? true) { metadata[key] = .string(value) }
        sourceSnapshot = product.sourceSnapshot
        sourceMessage = "Product details applied from name lookup."
        guard imageData == nil, let imageURL = product.imageURL else { return }
        Task {
            guard let (data, response) = try? await URLSession.shared.data(from: imageURL),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else { return }
            let prepared = await ImageProcessor.preparedData(data)
            guard imageData == nil else { return }
            imageData = prepared
            recognitionMessage = "Product image added from the lookup result."
        }
    }
    @ViewBuilder private var annotationsSection: some View {
        Section("Collaborator ratings") {
            if ratings.isEmpty { Text("No ratings yet. Your rating is optional.").font(.footnote).foregroundStyle(.secondary) }
            ForEach(ratings) { rating in
                HStack { Text(rating.participantName); Spacer(); Text(String(repeating: "★", count: rating.value)).foregroundStyle(.orange).accessibilityLabel("\(rating.value) out of 5 stars") }
            }
            HStack {
                Text("Your rating")
                Spacer()
                RatingPicker(value: $selectedRating) { value in
                    store.setRating(value == 0 ? nil : value, for: original)
                    let identity = CollaboratorIdentity.current
                    ratings.removeAll { $0.participantID == identity.id }
                    if value > 0 { ratings.append(ItemRating(id: UUID(), itemID: original.id, participantID: identity.id, participantName: identity.displayName, value: value, updatedAt: .now)) }
                    ratings.sort { $0.participantName.localizedStandardCompare($1.participantName) == .orderedAscending }
                }
            }
        }
        Section("Collaborator comments") {
            if comments.isEmpty { Text("No comments yet.").font(.footnote).foregroundStyle(.secondary) }
            ForEach(comments) { comment in
                VStack(alignment: .leading, spacing: 4) {
                    HStack { Text(comment.participantName).font(.subheadline.weight(.semibold)); Spacer(); Text(comment.createdAt, style: .date).font(.caption).foregroundStyle(.secondary) }
                    Text(comment.text).fixedSize(horizontal: false, vertical: true)
                }.padding(.vertical, 3)
            }
            TextField("Add a comment for collaborators", text: $commentDraft, axis: .vertical)
            Button("Add comment") { if let comment = store.addComment(commentDraft, to: original) { comments.append(comment); commentDraft = "" } }
                .disabled(commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
    private func metadataBinding(for key: String) -> Binding<String> { Binding(get: { if case .string(let value) = metadata[key] { return value }; return metadata[key]?.displayValue ?? "" }, set: { metadata[key] = .string($0) }) }
}

struct BulkEditItemsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let items: [CollectionItem]
    @State private var state: ItemState

    init(items: [CollectionItem]) {
        self.items = items
        _state = State(initialValue: items.first?.state ?? .wanted)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Filtered items") {
                    Label("\(items.count) item\(items.count == 1 ? "" : "s") selected", systemImage: "line.3.horizontal.decrease.circle")
                    Text("This change applies to the current filtered results only.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Change") {
                    Picker("Status", selection: $state) {
                        ForEach(store.statuses) { status in
                            Text(status.name).tag(ItemState(rawValue: status.id))
                        }
                    }
                }
            }
            .navigationTitle("Bulk edit")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        store.bulkUpdateState(for: items, to: state)
                        dismiss()
                    }
                    .disabled(items.isEmpty || store.selectedCollection?.role.canEdit != true)
                }
            }
            .onAppear {
                if !store.statuses.contains(where: { $0.id == state.rawValue }), let first = store.statuses.first {
                    state = ItemState(rawValue: first.id)
                }
            }
        }
    }
}

private struct CustomMetadataFieldsSection: View {
    let fields: [MetadataFieldDefinition]
    @Binding var metadata: [String: MetadataValue]

    var body: some View {
        Section("Custom details") {
            ForEach(fields) { field in
                MetadataFieldValueEditor(
                    field: field,
                    value: Binding(
                        get: { metadata[field.storageKey] },
                        set: { newValue in
                            if let newValue {
                                metadata[field.storageKey] = newValue
                            } else {
                                metadata.removeValue(forKey: field.storageKey)
                            }
                        }
                    )
                )
            }
        }
    }
}

private struct MetadataFieldValueEditor: View {
    let field: MetadataFieldDefinition
    @Binding var value: MetadataValue?
    @State private var numberText: String

    init(field: MetadataFieldDefinition, value: Binding<MetadataValue?>) {
        self.field = field
        _value = value
        _numberText = State(initialValue: Self.numberText(for: value.wrappedValue))
    }

    var body: some View {
        switch field.type {
        case .text:
            TextField(field.name, text: Binding(
                get: {
                    if case .string(let text)? = value { return text }
                    return value?.displayValue ?? ""
                },
                set: { value = $0.isEmpty ? nil : .string($0) }
            ))
        case .number:
            VStack(alignment: .leading, spacing: 4) {
                TextField(field.name, text: $numberText)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                    .onChange(of: numberText) { _, newValue in
                        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.isEmpty {
                            value = nil
                        } else if let number = Self.numberFormatter.number(from: trimmed) {
                            value = .decimal(number.doubleValue)
                        }
                    }
                if hasInvalidNumber {
                    Text("Enter a valid number.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        case .date:
            if case .date? = value {
                HStack {
                    DatePicker(field.name, selection: Binding(
                        get: {
                            if case .date(let date)? = value { return date }
                            return .now
                        },
                        set: { value = .date($0) }
                    ), displayedComponents: .date)
                    Button(role: .destructive) { value = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear \(field.name)")
                }
            } else {
                Button { value = .date(.now) } label: {
                    Label("Set \(field.name)", systemImage: "calendar.badge.plus")
                }
            }
        case .boolean:
            if let boolean = Self.booleanValue(for: value) {
                HStack {
                    Toggle(field.name, isOn: Binding(
                        get: { Self.booleanValue(for: value) ?? boolean },
                        set: { value = .boolean($0) }
                    ))
                    Button(role: .destructive) { value = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear \(field.name)")
                }
            } else {
                Button { value = .boolean(false) } label: {
                    Label("Set \(field.name)", systemImage: "checkmark.circle")
                }
            }
        case .color:
            if let selectedColor = MetadataColorCodec.color(from: value) {
                HStack {
                    ColorPicker(field.name, selection: Binding(
                        get: { MetadataColorCodec.color(from: value) ?? selectedColor },
                        set: { value = .string(MetadataColorCodec.hex(from: $0)) }
                    ), supportsOpacity: false)
                    Button(role: .destructive) { value = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear \(field.name)")
                }
            } else if let importedValue = value?.displayValue, !importedValue.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    LabeledContent(field.name, value: importedValue)
                    Button("Choose color") { value = .string("#007AFF") }
                }
            } else {
                Button { value = .string("#007AFF") } label: {
                    Label("Set \(field.name)", systemImage: "paintpalette")
                }
            }
        }
    }

    private var hasInvalidNumber: Bool {
        let trimmed = numberText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && Self.numberFormatter.number(from: trimmed) == nil
    }

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = .current
        formatter.maximumFractionDigits = 16
        return formatter
    }()

    private static func booleanValue(for value: MetadataValue?) -> Bool? {
        switch value {
        case .boolean(let boolean): return boolean
        case .integer(let number): return number != 0
        case .decimal(let number): return number != 0
        case .string(let text):
            switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "y", "1", "on": return true
            case "false", "no", "n", "0", "off": return false
            default: return nil
            }
        default: return nil
        }
    }

    private static func numberText(for value: MetadataValue?) -> String {
        switch value {
        case .integer(let number):
            return numberFormatter.string(from: NSNumber(value: number)) ?? "\(number)"
        case .decimal(let number):
            return numberFormatter.string(from: NSNumber(value: number)) ?? "\(number)"
        case .string(let text):
            return text
        case .date(let date):
            return date.formatted(date: .numeric, time: .omitted)
        case .boolean(let value):
            return value ? "1" : "0"
        case .url(let url):
            return url.absoluteString
        case nil:
            return ""
        }
    }
}

private struct RatingPicker: View {
    @Binding var value: Int
    let onChange: (Int) -> Void
    var body: some View { HStack(spacing: 4) { Button { value = 0; onChange(0) } label: { Text("None").font(.caption) }.buttonStyle(.bordered); ForEach(1...5, id: \.self) { rating in Button { value = rating; onChange(rating) } label: { Image(systemName: rating <= value ? "star.fill" : "star").foregroundStyle(.orange) }.buttonStyle(.plain).accessibilityLabel("Rate \(rating) out of 5") } } }
}
