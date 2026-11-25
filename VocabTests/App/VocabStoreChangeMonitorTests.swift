import CoreData
import SwiftData
import XCTest
@testable import Vocab

@MainActor
final class VocabStoreChangeMonitorTests: XCTestCase {
    func testSaveIntoObservedContainerOffTheMainThreadYieldsASaveEvent() async throws {
        let container = try makeContainer()
        var events = VocabStoreChangeMonitor.events(for: container).makeAsyncIterator()

        _ = try await Self.saveWord("observed", into: container)

        // The test host's own store may report remote changes first.
        while let event = await events.next() {
            if case .localSave = event { return }
        }
        XCTFail("the stream ended without a save")
    }

    func testSaveIntoAnotherContainerIsNotReported() async throws {
        var events = VocabStoreChangeMonitor.events(for: try makeContainer()).makeAsyncIterator()

        _ = try await Self.saveWord("ignored", into: try makeContainer())
        await Self.post(.vocabMasteryCleanupRequested)

        // Everything before the marker must be free of local saves.
        while let event = await events.next() {
            switch event {
            case .masteryCleanupRequested:
                return
            case .localSave:
                return XCTFail("a save into another container was reported")
            case .remoteChange, .successfulImport:
                continue
            }
        }
        XCTFail("the stream ended before the marker")
    }

    func testRemoteChangePostedOffTheMainThreadYieldsARemoteChange() async throws {
        var events = VocabStoreChangeMonitor.events(for: try makeContainer()).makeAsyncIterator()

        await Self.post(.NSPersistentStoreRemoteChange)

        // A stray remote change from the test host's own store is also
        // `.remoteChange`, so the first event is the one asserted.
        guard case .remoteChange? = await events.next() else {
            return XCTFail("expected a remote change")
        }
    }

    func testMasteryCleanupRequestYieldsItsEvent() async throws {
        var events = VocabStoreChangeMonitor.events(for: try makeContainer()).makeAsyncIterator()

        await Self.post(.vocabMasteryCleanupRequested)

        // The test host's own store may report remote changes or imports first.
        while let event = await events.next() {
            switch event {
            case .masteryCleanupRequested:
                return
            case .localSave:
                return XCTFail("no save was made into the observed container")
            case .remoteChange, .successfulImport:
                continue
            }
        }
        XCTFail("the stream ended without the mastery cleanup request")
    }

    /// Saves on the global executor, like a background model actor.
    @concurrent
    private static func saveWord(_ term: String, into container: ModelContainer) async throws -> UUID {
        let context = ModelContext(container)
        let word = WordRecord(term: term)
        context.insert(word)
        try context.save()
        return word.id
    }

    @concurrent
    private static func post(_ name: Notification.Name) async {
        NotificationCenter.default.post(name: name, object: nil)
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            WordRecord.self,
            MeaningRecord.self,
            DailySetRecord.self,
            DailySetItemRecord.self,
            TestSessionRecord.self,
            AttemptRecord.self,
            ReviewStateRecord.self,
            AnonymousAggregateRecord.self
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
