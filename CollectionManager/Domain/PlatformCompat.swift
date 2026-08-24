import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

#if os(iOS)
typealias PlatformColor = UIColor
typealias PlatformImage = UIImage
#elseif os(macOS)
typealias PlatformColor = NSColor
typealias PlatformImage = NSImage
#endif

extension View {
    /// `.fullScreenCover` is unavailable on macOS. `.sheet` is the closest
    /// available presentation there.
    @ViewBuilder func platformFullScreenCover<Content: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        #if os(iOS)
        self.fullScreenCover(isPresented: isPresented, content: content)
        #elseif os(macOS)
        self.sheet(isPresented: isPresented, content: content)
        #endif
    }
}

extension View {
    /// A checkbox is the native form of a secondary on/off choice on macOS,
    /// while iOS has no checkbox style and uses a switch.
    @ViewBuilder func platformCheckboxToggle() -> some View {
        #if os(macOS)
        self.toggleStyle(.checkbox)
        #else
        self.toggleStyle(.switch)
        #endif
    }
}

extension ToolbarItemPlacement {
    /// `.topBarLeading` on iOS has no macOS equivalent; `.automatic` lets
    /// AppKit place the item sensibly instead.
    static var platformLeading: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .automatic
        #endif
    }

    /// `.topBarTrailing` on iOS has no macOS equivalent; `.automatic` lets
    /// AppKit place the item sensibly instead.
    static var platformTrailing: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .automatic
        #endif
    }
}

extension Color {
    /// The system's grouped-list background color, on whichever platform is
    /// building. macOS has no exact analog to `systemGroupedBackground`, so
    /// the window background is used as the closest visual match.
    static var platformGroupedBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemGroupedBackground)
        #elseif os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #endif
    }
}

extension Image {
    /// Wraps a `PlatformImage` (UIImage on iOS, NSImage on macOS) for display.
    init(platformImage: PlatformImage) {
        #if os(iOS)
        self.init(uiImage: platformImage)
        #elseif os(macOS)
        self.init(nsImage: platformImage)
        #endif
    }
}

/// The current device or machine's display name, used as a default
/// collaborator name. iOS reports the device's given name; macOS has no
/// equivalent concept, so the Mac's host name is used instead.
enum PlatformDeviceName {
    static var current: String {
        #if os(iOS)
        return UIDevice.current.name
        #elseif os(macOS)
        return Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #else
        return ""
        #endif
    }
}
