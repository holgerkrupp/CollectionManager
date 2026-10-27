import Foundation

/// Production preferences keep their existing domain. UI fixtures use a stable
/// private suite so values can change and survive relaunch without overriding
/// mutable keys through the process argument domain.
enum ApplicationPreferences {
    static let defaults: UserDefaults = {
        #if DEBUG
        let process = ProcessInfo.processInfo
        if process.arguments.contains("--ui-testing"),
           let name = process.environment["CM_TEST_STORE_NAME"], UUID(uuidString: name) != nil,
           let isolated = UserDefaults(suiteName: "CollectionManager-UI-preferences-" + name) {
            if isolated.object(forKey: "onboarding.hasCompleted") == nil {
                isolated.set(process.environment["CM_TEST_ONBOARDING"] != "show", forKey: "onboarding.hasCompleted")
            }
            return isolated
        }
        #endif
        return .standard
    }()
}
