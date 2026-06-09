import SwiftData
import SwiftUI

@main
struct VocabApp: App {
    private let container: ModelContainer = {
        do {
            return try ModelContainer(for:
                WordRecord.self,
                MeaningRecord.self,
                DailySetRecord.self,
                DailySetItemRecord.self,
                TestSessionRecord.self,
                AttemptRecord.self,
                ReviewStateRecord.self,
                AnonymousAggregateRecord.self
            )
        } catch {
            fatalError("Unable to prepare local learning data: \(error.localizedDescription)")
        }
    }()

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
