import CoreData
import Foundation
import SwiftData

/// A store notification, reduced to `Sendable` values the root views act on.
enum VocabStoreChangeEvent: Sendable {
    /// A context saved into the observed container.
    case localSave
    /// Another coordinator (a CloudKit import, another process or store)
    /// changed the store. Which records changed is read later from
    /// persistent history, not from the notification.
    case remoteChange
    /// CloudKit finished a successful import.
    case successfulImport
    /// The coordinator asked for mastery cleanup after a learning save.
    case masteryCleanupRequested
    /// A CloudKit import or export failed because iCloud storage is full.
    case quotaExceeded
    /// CloudKit exported local changes, so sync is flowing again.
    case exportSucceeded
}

/// Turns store notifications into an event stream for the root views.
///
/// SwiftData, Core Data and CloudKit post these notifications on whichever
/// thread saved or imported. Subscribing in a view with `.onReceive` made
/// SwiftUI process them off the main thread ("Publishing changes from
/// background threads"). The monitor instead observes on the posting thread
/// and yields `Sendable` events; the views iterate the stream in `.task`,
/// so their state changes only on the main actor. Ending the iteration
/// removes the observers.
enum VocabStoreChangeMonitor {
    static func events(for container: ModelContainer) -> AsyncStream<VocabStoreChangeEvent> {
        AsyncStream { continuation in
            let center = NotificationCenter.default
            let observers = VocabNotificationObservers([
                center.addObserver(forName: .NSPersistentStoreRemoteChange, object: nil, queue: nil) { _ in
                    continuation.yield(.remoteChange)
                },
                center.addObserver(forName: ModelContext.didSave, object: nil, queue: nil) { notification in
                    guard let source = notification.object as? ModelContext,
                          source.container === container else { return }
                    continuation.yield(.localSave)
                },
                center.addObserver(
                    forName: NSPersistentCloudKitContainer.eventChangedNotification,
                    object: nil,
                    queue: nil
                ) { notification in
                    if let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                        as? NSPersistentCloudKitContainer.Event, event.endDate != nil {
                        switch VocabCloudSyncEventOutcome.classify(
                            isExport: event.type == .export,
                            succeeded: event.succeeded,
                            error: event.error
                        ) {
                        case .quotaExceeded: continuation.yield(.quotaExceeded)
                        case .exportSucceeded: continuation.yield(.exportSucceeded)
                        case .other: break
                        }
                    }
                    guard VocabHydrationDiagnosticPolicy.isSuccessfulImportEvent(notification) else { return }
                    continuation.yield(.successfulImport)
                },
                center.addObserver(forName: .vocabMasteryCleanupRequested, object: nil, queue: nil) { _ in
                    continuation.yield(.masteryCleanupRequested)
                }
            ])
            continuation.onTermination = { _ in
                // The callback is synchronous; removal hops to the owning
                // actor. A notification arriving meanwhile yields into a
                // finished stream, which drops it.
                Task { await observers.removeAll() }
            }
        }
    }
}

/// Owns the observer tokens so they are removed exactly once.
private actor VocabNotificationObservers {
    private var tokens: [any NSObjectProtocol]

    init(_ tokens: [any NSObjectProtocol]) {
        self.tokens = tokens
    }

    func removeAll() {
        for token in tokens {
            NotificationCenter.default.removeObserver(token)
        }
        tokens.removeAll()
    }
}
