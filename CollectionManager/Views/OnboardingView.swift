import SwiftUI

struct OnboardingView: View {
    let onFinish: () -> Void

    @State private var page = 0

    private let pages: [OnboardingPage] = [
        OnboardingPage(title: "Keep everything in one place", message: "Collection Manager helps you organize the things you own, want, or are working through.", systemImage: "square.stack.3d.up.fill", tint: .blue),
        OnboardingPage(title: "Add items your way", message: "Create items by hand, scan a barcode, or import them from the web. Add tags, notes, images, and custom metadata as you go.", systemImage: "barcode.viewfinder", tint: .orange),
        OnboardingPage(title: "See what matters", message: "Use statuses, search, filters, and sorting to quickly find what you are looking for in every collection.", systemImage: "line.3.horizontal.decrease.circle.fill", tint: .purple),
        OnboardingPage(title: "Share and stay in sync", message: "Collections can be shared with other people through iCloud. Changes, ratings, and comments stay in sync across participants.", systemImage: "person.2.fill", tint: .green)
    ]

    var body: some View {
        VStack(spacing: 24) {
            HStack {
                Spacer()
                if page < pages.count - 1 { Button("Skip") { onFinish() }.font(.subheadline.weight(.medium)) }
            }
            .frame(height: 24)

            TabView(selection: $page) {
                ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                    VStack(spacing: 24) {
                        Image(systemName: page.systemImage)
                            .font(.system(size: 64, weight: .semibold))
                            .foregroundStyle(page.tint)
                            .frame(width: 136, height: 136)
                            .background(page.tint.opacity(0.12), in: Circle())
                        VStack(spacing: 12) {
                            Text(page.title).font(.largeTitle.bold()).multilineTextAlignment(.center)
                            Text(page.message).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
                        }
                    }
                    .padding(.horizontal, 24)
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))

            Button(action: advance) {
                Text(page == pages.count - 1 ? "Get Started" : "Next")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 24)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 24)
        .interactiveDismissDisabled()
    }

    private func advance() {
        if page == pages.count - 1 { onFinish() } else { withAnimation { page += 1 } }
    }
}

private struct OnboardingPage {
    let title: String
    let message: String
    let systemImage: String
    let tint: Color
}
