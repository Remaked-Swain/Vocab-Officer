import Foundation
import SwiftData
import SwiftUI

@main
struct VocabApp: App {
    @StateObject private var storeBoundary = VocabApplicationStoreBoundary()

    var body: some Scene {
        WindowGroup("Vocab", id: "main") {
            if let launch = storeBoundary.launch {
                RootView(connectionError: launch.connectionError, syncMode: launch.mode)
                    .modelContainer(launch.container)
            } else {
                ProgressView("로컬 단어장 복구 준비 중…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .defaultSize(width: 1160, height: 760)
        .windowResizability(.automatic)

        Window("Vocab 설정", id: "settings") {
            if let launch = storeBoundary.launch {
                SettingsView()
                    .modelContainer(launch.container)
            } else {
                ProgressView("로컬 단어장 복구 준비 중…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
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
