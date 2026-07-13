import SwiftData
import SwiftUI

@main
struct VocabIOSApp: App {
    private let container: ModelContainer = Self.makeContainer()

    private static func makeContainer() -> ModelContainer {
        do {
            return try VocabModelContainerFactory.makeContainer()
        } catch {
            fatalError("Unable to prepare vocabulary data: \(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup {
            VocabIOSRootView()
                .modelContainer(container)
        }
    }
}
