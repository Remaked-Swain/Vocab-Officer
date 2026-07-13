import Foundation
#if os(macOS)
import Security
#endif

enum VocabCloudEntitlementStatus {
    static func hasRequiredCloudKitContainer(
        containerIdentifier: String = VocabSyncMode.cloudKitContainerIdentifier
    ) -> Bool {
        #if os(macOS)
        guard
            let task = SecTaskCreateFromSelf(nil),
            let value = SecTaskCopyValueForEntitlement(
                task,
                "com.apple.developer.icloud-container-identifiers" as CFString,
                nil
            )
        else {
            return false
        }

        guard let containers = value as? [String] else { return false }
        return containers.contains(containerIdentifier)
        #else
        return Bundle.main.object(forInfoDictionaryKey: "VocabCloudKitEntitlementExpected") as? Bool ?? false
        #endif
    }
}
