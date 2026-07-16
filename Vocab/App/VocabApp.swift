import Foundation
import SwiftData
import SwiftUI

@main
struct VocabApp: App {
    private let launch: VocabLaunchPlan = {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return VocabLaunchPlan(
                container: try! VocabModelContainerFactory.makeInMemoryContainer(),
                mode: .localOnly,
                connectionError: nil
            )
        }
        let preferredMode = VocabSyncMode.current(allowsCloudKit: true)
        return VocabModelContainerFactory.makeLaunchPlan(preferredMode: preferredMode)
    }()

    var body: some Scene {
        WindowGroup("Vocab", id: "main") {
            RootView(connectionError: launch.connectionError, syncMode: launch.mode)
                .modelContainer(launch.container)
        }
        .defaultSize(width: 1160, height: 760)
        .windowResizability(.automatic)

        Window("Vocab 설정", id: "settings") {
            SettingsView()
                .modelContainer(launch.container)
        }
        .defaultSize(width: 820, height: 760)
        .windowResizability(.automatic)
        .commands {
            VocabSettingsCommands()
        }
    }
}

private struct VocabSettingsCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("설정…") {
                openWindow(id: "settings")
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}
