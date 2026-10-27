import SwiftUI

/// Small, self-contained SF Symbol picker used by the settings editors.
/// Keeping this control in the app makes a clean checkout independent of a
/// developer-local package while still offering discoverable symbol choices.
struct CollectionSymbolPicker: View {
    @Binding var selection: String
    var suggestedSymbolName: String = "circle"
    var tint: Color = .accentColor

    private static let symbols = [
        "square.stack.3d.up.fill", "square.grid.2x2", "shippingbox.fill", "book.fill",
        "gamecontroller.fill", "music.note", "fork.knife", "cup.and.saucer.fill",
        "cart.fill", "heart.fill", "star.fill", "tag.fill", "folder.fill", "archivebox.fill",
        "checkmark.circle.fill", "clock.fill", "play.circle.fill", "person.2.fill"
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Self.symbols, id: \.self) { symbol in
                    Button { selection = symbol } label: {
                        Image(systemName: symbol)
                            .font(.title3)
                            .foregroundStyle(selection == symbol ? tint : .secondary)
                            .frame(width: 34, height: 34)
                            .background(selection == symbol ? tint.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(symbol)
                    .accessibilityAddTraits(selection == symbol ? .isSelected : [])
                }
            }
            .padding(.vertical, 2)
        }
        .onAppear {
            if selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                selection = suggestedSymbolName
            }
        }
    }
}
