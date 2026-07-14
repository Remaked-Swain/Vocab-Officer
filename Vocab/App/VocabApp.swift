import Foundation
import SwiftData
import SwiftUI

@main
struct VocabApp: App {
    private let launch = Self.makeLaunch()

    private struct Launch {
        let container: ModelContainer
        let fallbackMessage: String?
    }

    private static func makeLaunch() -> Launch {
        let preferredMode = VocabSyncMode.current(allowsCloudKit: true)
        do {
            return Launch(
                container: try VocabModelContainerFactory.makeContainer(syncMode: preferredMode),
                fallbackMessage: nil
            )
        } catch {
            guard preferredMode == .cloudKitPrivate else {
                fatalError("Unable to prepare local learning data: \(error.localizedDescription)")
            }
            do {
                return Launch(
                    container: try VocabModelContainerFactory.makeContainer(syncMode: .localOnly),
                    fallbackMessage: "iCloud mirrored store를 열지 못해 기존 로컬 단어장으로 열었습니다. \(error.localizedDescription)"
                )
            } catch {
                fatalError("Unable to prepare fallback local learning data: \(error.localizedDescription)")
            }
        }
    }

    var body: some Scene {
        WindowGroup("Vocab", id: "main") {
            RootView(launchWarning: launch.fallbackMessage)
                .modelContainer(launch.container)
        }
        .defaultSize(width: 1160, height: 760)
        .windowResizability(.automatic)

        Settings {
            SettingsView()
                .modelContainer(launch.container)
        }
    }
}
