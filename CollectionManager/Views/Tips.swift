import SwiftUI
import TipKit

/// Feature tips, following the HIG guidance on offering help: each tip covers
/// a simple feature that is easy to miss, appears only once the person is in
/// a position to use it, and is invalidated for good once they have used it.
enum AppTips {
    /// Set from Settings; the datastore can only be reset before it is configured.
    static let resetRequestKey = "tips.resetOnNextLaunch"

    /// Call once per launch, before any tip view is created.
    static func configure() {
        if UserDefaults.standard.bool(forKey: resetRequestKey) {
            try? Tips.resetDatastore()
            UserDefaults.standard.removeObject(forKey: resetRequestKey)
        }
        // At most one tip a day, so help never crowds out the collection itself.
        try? Tips.configure([.displayFrequency(.daily)])
    }

    /// Tips never compete with onboarding for attention.
    @Parameter static var hasCompletedOnboarding: Bool = false
    /// Donated each time the person adds an item themselves.
    static let itemAdded = Tips.Event(id: "itemAdded")
    /// Donated when the person narrows the list by status, brand, or search.
    static let listFiltered = Tips.Event(id: "listFiltered")
}

struct ScanBarcodeTip: Tip {
    var title: Text { Text("Scan a Barcode") }
    var message: Text? { Text("Point the camera at a product’s barcode to look up its details for you.") }
    var image: Image? { Image(systemName: "barcode.viewfinder") }
    var rules: [Rule] {
        #Rule(AppTips.$hasCompletedOnboarding) { $0 }
    }
}

struct TableLayoutTip: Tip {
    /// The table only pays off once there are enough rows to edit in one pass.
    @Parameter static var itemCount: Int = 0

    var title: Text { Text("Edit Like a Spreadsheet") }
    var message: Text? { Text("Switch to Table to edit every item’s fields side by side.") }
    var image: Image? { Image(systemName: "tablecells.fill") }
    var rules: [Rule] {
        #Rule(AppTips.$hasCompletedOnboarding) { $0 }
        #Rule(Self.$itemCount) { $0 >= 10 }
    }
}

struct BulkEditTip: Tip {
    var title: Text { Text("Update Many Items at Once") }
    var message: Text? { Text("Filter or search the list, then change the status of every matching item in one step.") }
    var image: Image? { Image(systemName: "checklist") }
    var rules: [Rule] {
        #Rule(AppTips.$hasCompletedOnboarding) { $0 }
        // Shown once the person has filtered, which is when it is useful.
        #Rule(AppTips.listFiltered) { $0.donations.count >= 1 }
    }
}

struct ShareCollectionTip: Tip {
    static let shareActionID = "share"

    var title: Text { Text("Collect Together") }
    var message: Text? { Text("Share this collection through iCloud so others can add, rate, and comment on items.") }
    var image: Image? { Image(systemName: "person.2.fill") }
    var actions: [Action] {
        Action(id: Self.shareActionID, title: "Share Collection")
    }
    var rules: [Rule] {
        #Rule(AppTips.$hasCompletedOnboarding) { $0 }
        #Rule(AppTips.itemAdded) { $0.donations.count >= 3 }
    }
}

/// Offered to people who keep adding items by hand, since the App Shortcut
/// saves them opening the app at all.
struct AddItemsWithSiriTip: Tip {
    var title: Text { Text("Add Items with Siri") }
    var message: Text? { Text("Say “Add an item in \(Self.appName)” to add something without opening the app.") }
    var image: Image? { Image(systemName: "mic.fill") }
    var rules: [Rule] {
        #Rule(AppTips.$hasCompletedOnboarding) { $0 }
        #Rule(AppTips.itemAdded) { $0.donations.count >= 5 }
    }

    private static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Collection Manager"
    }
}
