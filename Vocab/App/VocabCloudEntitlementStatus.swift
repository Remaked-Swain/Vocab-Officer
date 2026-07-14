import Foundation
#if os(macOS)
import Security
#endif

enum VocabCloudEntitlementVerification: Equatable {
    case verified
    case missing
    case unavailable

    var allowsCloudKitRequests: Bool {
        self != .missing
    }
}

enum VocabCloudEntitlementStatus {
    typealias EntitlementValueReader = (String) -> Any?
    typealias InfoDictionaryValueReader = (String) -> Any?

    static func hasRequiredCloudKitContainer(
        containerIdentifier: String = VocabSyncMode.cloudKitContainerIdentifier,
        entitlementValue: EntitlementValueReader = signedEntitlementValue,
        infoDictionaryValue: InfoDictionaryValueReader = Bundle.main.object(forInfoDictionaryKey:),
        allowsInfoDictionaryFallback: Bool = false,
        canReadSignedEntitlements: Bool = canReadSignedEntitlementsAtRuntime
    ) -> Bool {
        verification(
            containerIdentifier: containerIdentifier,
            entitlementValue: entitlementValue,
            infoDictionaryValue: infoDictionaryValue,
            allowsInfoDictionaryFallback: allowsInfoDictionaryFallback,
            canReadSignedEntitlements: canReadSignedEntitlements
        ) == .verified
    }

    static func allowsCloudKitRequests(
        containerIdentifier: String = VocabSyncMode.cloudKitContainerIdentifier,
        entitlementValue: EntitlementValueReader = signedEntitlementValue,
        infoDictionaryValue: InfoDictionaryValueReader = Bundle.main.object(forInfoDictionaryKey:),
        allowsInfoDictionaryFallback: Bool = false,
        canReadSignedEntitlements: Bool = canReadSignedEntitlementsAtRuntime
    ) -> Bool {
        verification(
            containerIdentifier: containerIdentifier,
            entitlementValue: entitlementValue,
            infoDictionaryValue: infoDictionaryValue,
            allowsInfoDictionaryFallback: allowsInfoDictionaryFallback,
            canReadSignedEntitlements: canReadSignedEntitlements
        ).allowsCloudKitRequests
    }

    static func verification(
        containerIdentifier: String = VocabSyncMode.cloudKitContainerIdentifier,
        entitlementValue: EntitlementValueReader = signedEntitlementValue,
        infoDictionaryValue: InfoDictionaryValueReader = Bundle.main.object(forInfoDictionaryKey:),
        allowsInfoDictionaryFallback: Bool = false,
        canReadSignedEntitlements: Bool = canReadSignedEntitlementsAtRuntime
    ) -> VocabCloudEntitlementVerification {
        if containsCloudKitContainer(entitlementValue("com.apple.developer.icloud-container-identifiers"), containerIdentifier: containerIdentifier) {
            return .verified
        }

        if allowsInfoDictionaryFallback,
           infoDictionaryValue("VocabCloudKitEntitlementExpected") as? Bool == true {
            return .verified
        }

        return canReadSignedEntitlements ? .missing : .unavailable
    }

    private static var canReadSignedEntitlementsAtRuntime: Bool {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    private static func signedEntitlementValue(_ key: String) -> Any? {
        #if os(macOS)
        guard
            let task = SecTaskCreateFromSelf(nil),
            let value = SecTaskCopyValueForEntitlement(
                task,
                key as CFString,
                nil
            )
        else {
            return nil
        }

        return value
        #else
        return nil
        #endif
    }

    private static func containsCloudKitContainer(_ value: Any?, containerIdentifier: String) -> Bool {
        guard let containers = value as? [String] else { return false }
        return containers.contains(containerIdentifier)
    }
}
