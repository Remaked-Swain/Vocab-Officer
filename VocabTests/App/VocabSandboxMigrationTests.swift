import XCTest

/// The first sandboxed launch moves the pre-sandbox data into the container
/// only if this manifest ships in the app bundle's Resources.
final class VocabSandboxMigrationTests: XCTestCase {
    func testContainerMigrationManifestShipsAndMovesEveryPreSandboxLocation() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "container-migration", withExtension: "plist"))
        let manifest = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any]
        )
        let moves = Set(try XCTUnwrap(manifest["Move"] as? [String]))

        XCTAssertEqual(moves, [
            "${ApplicationSupport}/Vocab",
            "${ApplicationSupport}/default.store",
            "${ApplicationSupport}/default.store-shm",
            "${ApplicationSupport}/default.store-wal",
            "${Library}/Preferences/com.swainyun.Vocab.plist"
        ])
    }
}
