import Foundation
import SwiftData
import SwiftUI

@main
struct VocabApp: App {
    private let container: ModelContainer = Self.makeContainer()

    private static func makeContainer() -> ModelContainer {
        do {
            return try VocabModelContainerFactory.makeContainer()
        } catch {
            fatalError("Unable to prepare local learning data: \(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup("Vocab", id: "main") {
            RootView()
                .modelContainer(container)
        }
        .defaultSize(width: 1160, height: 760)
        .windowResizability(.automatic)

        Settings {
            SettingsView()
                .modelContainer(container)
        }
    }
}
