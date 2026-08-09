import SwiftUI
import PhotosUI

struct ItemCard: View {
    @Environment(AppStore.self) private var store
    let item: CollectionItem
    @State private var showingEdit = false
    var body: some View { let status = store.status(for: item.state); return HStack(spacing: 14) { if let data = item.imageData, let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFill().frame(width: 54, height: 64).clipShape(RoundedRectangle(cornerRadius: 14)) } else { Image(systemName: item.imageSystemName).font(.title2).foregroundStyle(status.color.color).frame(width: 54, height: 64).background(status.color.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 14)) }; VStack(alignment: .leading, spacing: 4) { HStack { Text(item.title).font(.headline); Spacer(); Text(status.name).font(.caption.weight(.semibold)).foregroundStyle(status.color.color).padding(.horizontal, 8).padding(.vertical, 4).background(status.color.color.opacity(0.12), in: Capsule()) }; Text([item.brand, item.variant].filter { !$0.isEmpty }.joined(separator: " · ")).foregroundStyle(.secondary); if !item.itemDescription.isEmpty { LinkedText(item.itemDescription).font(.subheadline).foregroundStyle(.secondary).lineLimit(4) }; TagFlowLayout { ForEach(item.tags, id: \.self) { TagChip(title: $0) }; if item.quantity > 1 { Text("×\(item.quantity)").font(.caption).foregroundStyle(.secondary) } }; if !item.ratings.isEmpty { RatingSummary(ratings: item.ratings) }; if !item.comments.isEmpty { Label("\(item.comments.count) collaborator comment\(item.comments.count == 1 ? "" : "s")", systemImage: "text.bubble").font(.caption).foregroundStyle(.secondary) } } }.padding(14).background(.background, in: RoundedRectangle(cornerRadius: 20)).contentShape(Rectangle()).onTapGesture { showingEdit = true }.contextMenu { Button { showingEdit = true } label: { Label("Edit", systemImage: "pencil") }; Button(role: .destructive) { store.deleteItem(item) } label: { Label("Delete", systemImage: "trash") } }.sheet(isPresented: $showingEdit) { EditItemView(item: item) } }
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
    let value: AttributedString

    init(_ text: String) {
        let attributed = NSMutableAttributedString(string: text)
        let range = NSRange(location: 0, length: text.utf16.count)
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            detector.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
                guard let url = match?.url, let matchRange = match?.range else { return }
                attributed.addAttribute(.link, value: url, range: matchRange)
            }
        }
        value = (try? AttributedString(attributed, including: \.swiftUI)) ?? AttributedString(text)
    }

    var body: some View {
        Text(value)
            .tint(.blue)
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

struct AddItemView: View {
    @Environment(AppStore.self) private var store; @Environment(\.dismiss) private var dismiss
    @State private var title = ""; @State private var brand = ""; @State private var variant = ""; @State private var description = ""; @State private var quantity = 1; @State private var tags = ""; @State private var metadata: [String: MetadataValue] = [:]; @State private var state: ItemState = .wanted; @State private var barcode: Barcode?; @State private var imageData: Data?; @State private var showingScanner = false; @State private var showingCamera = false; @State private var pickerItem: PhotosPickerItem?; @State private var manualBarcode = ""; @State private var isLookingUp = false; @State private var recognitionMessage: String?; @State private var productMatches: [CollectionProductMatch] = []
    var body: some View {
        let category = store.selectedCollection?.category ?? .custom
        NavigationStack {
            Form {
                Section("Identify") {
                    if category.supportsBarcodeScanning {
                        Button { showingScanner = true } label: {
                            Label(barcode.map { "Scanned \($0.value)" } ?? "Scan Barcode", systemImage: "barcode.viewfinder")
                        }
                        .accessibilityHint("Opens the camera barcode scanner")
                    }

                    HStack {
                        TextField("Enter barcode manually", text: $manualBarcode)
                            .keyboardType(.numberPad)
                            .accessibilityLabel("Barcode")
                        Button("Use") {
                            if let value = Barcode(rawValue: manualBarcode) {
                                selectBarcode(value, lookupImmediately: false)
                            } else {
                                recognitionMessage = "Enter a valid 8, 12, 13, or 14 digit barcode."
                            }
                        }
                    }

                    if let barcode {
                        HStack {
                            Label("Barcode: \(barcode.value)", systemImage: "barcode")
                            Spacer()
                            if category.supportsBarcodeScanning {
                                Button(isLookingUp ? "Looking up…" : "Look up product") { lookup(barcode) }
                                    .disabled(isLookingUp)
                            }
                        }
                        if let status = store.barcodeStatus(barcode) {
                            let configuredStatus = store.status(for: status)
                            Label(status == .consumed ? "Already consumed in this collection" : status == .stored ? "Currently in storage" : "Already in collection: \(configuredStatus.name)", systemImage: configuredStatus.symbol)
                                .foregroundStyle(configuredStatus.color.color)
                        }
                    }

                    Button { showingCamera = true } label: { Label("Take Photo", systemImage: "camera") }
                    PhotosPicker(selection: $pickerItem, matching: .images) { Label("Choose Existing Photo", systemImage: "photo") }
                        .onChange(of: pickerItem) { _, newValue in
                            Task { if let data = try? await newValue?.loadTransferable(type: Data.self) { handleImage(data) } }
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

                if !category.detailFields.isEmpty {
                    Section("\(category.name) details") {
                        ForEach(category.detailFields, id: \.key) { field in
                            TextField(field.title, text: metadataBinding(for: field.key), prompt: Text(field.placeholder))
                        }
                    }
                }

                Section("Editable proposal") {
                    TextField("Title", text: $title)
                    TextField("Brand", text: $brand)
                    TextField("Variant", text: $variant)
                    TextField("Description", text: $description, axis: .vertical)
                    Stepper("Quantity: \(quantity)", value: $quantity, in: 1...999)
                    Picker("Status", selection: $state) { ForEach(store.statuses) { status in Text(status.name).tag(ItemState(rawValue: status.id)) } }
                    TextField("Tags, separated by commas", text: $tags)
                }

                if let recognitionMessage { Section { Text(recognitionMessage).font(.footnote).foregroundStyle(.secondary) } }
                Section { Text("Barcode lookup uses the free Open Food Facts service and sends only the barcode. OCR and product results are suggestions—review the proposal before saving.").font(.footnote).foregroundStyle(.secondary) }
            }
            .navigationTitle("Add item")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.addItem(title: title.trimmingCharacters(in: .whitespacesAndNewlines), brand: brand, variant: variant, description: description, state: state, quantity: quantity, tags: tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }, metadata: metadata.compactMapValues { value in if case .string(let text) = value, text.isEmpty { return nil }; return value }, barcode: barcode, imageData: imageData)
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .sheet(isPresented: $showingScanner) { BarcodeScannerSheet { value in selectBarcode(value, lookupImmediately: true) } }
            .fullScreenCover(isPresented: $showingCamera) { PhotoCaptureView { handleImage($0) } }
            .onAppear { if !store.statuses.contains(where: { $0.id == state.rawValue }), let first = store.statuses.first { state = ItemState(rawValue: first.id) } }
        }
    }
    private func selectBarcode(_ value: Barcode, lookupImmediately: Bool) { barcode = value; manualBarcode = value.value; productMatches = store.productMatches(for: value); if lookupImmediately { lookup(value) } }
    private func lookup(_ value: Barcode) { let provider: any ProductMetadataProvider; switch store.selectedCollection?.category { case .food: provider = OpenFoodFactsProvider(); case .games: provider = GamesEANProvider(); case .boardGames: provider = GameUPCProvider(); case .books: provider = OpenLibraryProvider(); case .music: provider = MusicBrainzProvider(); case .cosmetics: provider = OpenFactsProvider(host: "world.openbeautyfacts.org"); case .petFood: provider = OpenFactsProvider(host: "world.openpetfoodfacts.org"); case .products: provider = OpenFactsProvider(host: "world.openproductsfacts.org"); default: recognitionMessage = "Product lookup is not configured for this collection category yet."; return }; isLookingUp = true; productMatches = store.productMatches(for: value); Task { do { if let product = try await provider.product(for: value) { await MainActor.run { if title.isEmpty { title = product.title }; if brand.isEmpty { brand = product.brand }; if variant.isEmpty { variant = product.variant }; if tags.isEmpty { tags = product.categories.joined(separator: ", ") }; if let country = product.country, !country.isEmpty { metadata["country"] = .string(country) }; if !product.categories.isEmpty { metadata["categories"] = .string(product.categories.joined(separator: ", ")) }; for (key, value) in product.extraFields { metadata[key] = .string(value) }; productMatches = store.productMatches(for: value, productName: product.title); recognitionMessage = "Product data found. Review the proposal before saving." } } else { await MainActor.run { recognitionMessage = "No product was found for this barcode." } } } catch { await MainActor.run { recognitionMessage = "\(error.localizedDescription) You can still enter the item manually." } }; await MainActor.run { isLookingUp = false } } }
    private func metadataBinding(for key: String) -> Binding<String> { Binding(get: { if case .string(let value) = metadata[key] { return value }; return metadata[key]?.displayValue ?? "" }, set: { metadata[key] = .string($0) }) }
    private func handleImage(_ data: Data) { imageData = data; Task { do { let result = try await OCRService().recognizeText(in: data); await MainActor.run { if title.isEmpty { title = result.lines.first ?? "" }; if description.isEmpty { description = result.text }; recognitionMessage = result.text.isEmpty ? "No readable text was found." : "Text recognized from photo. Review the proposal." } } catch { await MainActor.run { recognitionMessage = "Photo saved, but text recognition failed." } } } }
}

struct EditItemView: View {
    @Environment(AppStore.self) private var store; @Environment(\.dismiss) private var dismiss; let original: CollectionItem
    @State private var title: String; @State private var brand: String; @State private var variant: String; @State private var description: String; @State private var quantity: Int; @State private var tags: String; @State private var metadata: [String: MetadataValue]; @State private var state: ItemState; @State private var imageData: Data?; @State private var pickerItem: PhotosPickerItem?; @State private var recognitionMessage: String?; @State private var ratings: [ItemRating]; @State private var comments: [ItemComment]; @State private var commentDraft = ""; @State private var selectedRating: Int
    init(item: CollectionItem) { original = item; _title = State(initialValue: item.title); _brand = State(initialValue: item.brand); _variant = State(initialValue: item.variant); _description = State(initialValue: item.itemDescription); _quantity = State(initialValue: item.quantity); _tags = State(initialValue: item.tags.joined(separator: ", ")); _metadata = State(initialValue: item.metadata); _state = State(initialValue: item.state); _imageData = State(initialValue: item.imageData); _ratings = State(initialValue: item.ratings); _comments = State(initialValue: item.comments); _selectedRating = State(initialValue: item.ratings.first(where: { $0.participantID == CollaboratorIdentity.current.id })?.value ?? 0) }
    var body: some View {
        let category = store.selectedCollection?.category ?? .custom
        NavigationStack {
            Form {
                Section("Item details") {
                    TextField("Title", text: $title); TextField("Brand", text: $brand); TextField("Variant", text: $variant); TextField("Description", text: $description, axis: .vertical)
                    Stepper("Quantity: \(quantity)", value: $quantity, in: 1...999)
                    Picker("Status", selection: $state) { ForEach(store.statuses) { status in Text(status.name).tag(ItemState(rawValue: status.id)) } }
                    TextField("Tags, separated by commas", text: $tags)
                    PhotosPicker(selection: $pickerItem, matching: .images) { Label("Replace photo / run OCR", systemImage: "photo") }
                        .onChange(of: pickerItem) { _, newValue in Task { if let data = try? await newValue?.loadTransferable(type: Data.self) { imageData = data; if let result = try? await OCRService().recognizeText(in: data) { await MainActor.run { if description.isEmpty { description = result.text }; recognitionMessage = "Text recognized from photo. Review your changes." } } } } }
                    if let recognitionMessage { Text(recognitionMessage).font(.footnote).foregroundStyle(.secondary) }
                }
                if !category.detailFields.isEmpty {
                    Section("\(category.name) details") {
                        ForEach(category.detailFields, id: \.key) { field in TextField(field.title, text: metadataBinding(for: field.key), prompt: Text(field.placeholder)) }
                    }
                }
                annotationsSection
                Section { Button("Delete item", role: .destructive) { store.deleteItem(original); dismiss() } }
            }
            .navigationTitle("Edit item")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { var item = original; let previous = item.state; item.title = title; item.brand = brand; item.variant = variant; item.itemDescription = description; item.quantity = quantity; item.state = state; item.consumedAt = state == .consumed ? (item.consumedAt ?? .now) : nil; item.updatedAt = .now; item.tags = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }; item.metadata = metadata.compactMapValues { value in if case .string(let text) = value, text.isEmpty { return nil }; return value }; item.imageData = imageData; store.updateItem(item, previousState: previous); dismiss() } }
            }
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

private struct RatingPicker: View {
    @Binding var value: Int
    let onChange: (Int) -> Void
    var body: some View { HStack(spacing: 4) { Button { value = 0; onChange(0) } label: { Text("None").font(.caption) }.buttonStyle(.bordered); ForEach(1...5, id: \.self) { rating in Button { value = rating; onChange(rating) } label: { Image(systemName: rating <= value ? "star.fill" : "star").foregroundStyle(.orange) }.buttonStyle(.plain).accessibilityLabel("Rate \(rating) out of 5") } } }
}
