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
                AnonymousAggregateRecord.self,
                ManagedBackupRecord.self
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

        Settings {
            SettingsView()
                .modelContainer(container)
        }

        .commands {
            CommandGroup(after: .newItem) {
                Button("새 학습 세트") {}
                    .keyboardShortcut("n", modifiers: .command)
                Button("테스트 시작") {}
                    .keyboardShortcut("t", modifiers: .command)
            }
        }
    }
}
