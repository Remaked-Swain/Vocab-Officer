import XCTest
@testable import Vocab

final class VocabCloudEntitlementStatusTests: XCTestCase {
    func testSignedCloudKitContainerPasses() {
        XCTAssertTrue(
            VocabCloudEntitlementStatus.hasRequiredCloudKitContainer(
                containerIdentifier: "iCloud.com.example.Vocab",
                entitlementValue: { key in
                    XCTAssertEqual(key, "com.apple.developer.icloud-container-identifiers")
                    return ["iCloud.com.example.Vocab"]
                },
                infoDictionaryValue: { _ in false }
            )
        )
    }

    func testInfoDictionaryDoesNotPassWithoutExplicitFallback() {
        XCTAssertFalse(
            VocabCloudEntitlementStatus.hasRequiredCloudKitContainer(
                containerIdentifier: "iCloud.com.example.Vocab",
                entitlementValue: { _ in nil },
                infoDictionaryValue: { key in
                    XCTAssertEqual(key, "VocabCloudKitEntitlementExpected")
                    return true
                },
                canReadSignedEntitlements: true
            )
        )
    }

    func testUnavailableRuntimeEntitlementCheckDoesNotBlockCloudKitRequests() {
        XCTAssertTrue(
            VocabCloudEntitlementStatus.allowsCloudKitRequests(
                containerIdentifier: "iCloud.com.example.Vocab",
                entitlementValue: { _ in nil },
                infoDictionaryValue: { _ in false },
                canReadSignedEntitlements: false
            )
        )
        XCTAssertEqual(
            VocabCloudEntitlementStatus.verification(
                containerIdentifier: "iCloud.com.example.Vocab",
                entitlementValue: { _ in nil },
                infoDictionaryValue: { _ in false },
                canReadSignedEntitlements: false
            ),
            .unavailable
        )
    }

    func testMissingEntitlementBlocksWhenRuntimeCheckIsAvailable() {
        XCTAssertFalse(
            VocabCloudEntitlementStatus.allowsCloudKitRequests(
                containerIdentifier: "iCloud.com.example.Vocab",
                entitlementValue: { _ in nil },
                infoDictionaryValue: { _ in false },
                canReadSignedEntitlements: true
            )
        )
    }

    func testInfoDictionaryFallbackCanBeUsedAsTestHook() {
        XCTAssertTrue(
            VocabCloudEntitlementStatus.hasRequiredCloudKitContainer(
                containerIdentifier: "iCloud.com.example.Vocab",
                entitlementValue: { _ in nil },
                infoDictionaryValue: { _ in true },
                allowsInfoDictionaryFallback: true
            )
        )
    }

    func testDifferentSignedContainerDoesNotPass() {
        XCTAssertFalse(
            VocabCloudEntitlementStatus.hasRequiredCloudKitContainer(
                containerIdentifier: "iCloud.com.example.Vocab",
                entitlementValue: { _ in ["iCloud.com.example.Other"] },
                infoDictionaryValue: { _ in false }
            )
        )
    }
}
