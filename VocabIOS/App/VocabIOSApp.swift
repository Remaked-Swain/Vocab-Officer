import SwiftData
import SwiftUI

@main
struct VocabIOSApp: App {
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
                fatalError("Unable to prepare vocabulary data: \(error.localizedDescription)")
            }
            do {
                return Launch(
                    container: try VocabModelContainerFactory.makeContainer(syncMode: .localOnly),
                    fallbackMessage: "iCloud mirrored store를 열지 못해 이 iPhone의 로컬 단어장으로 열었습니다. \(error.localizedDescription)"
                )
            } catch {
                fatalError("Unable to prepare fallback local vocabulary data: \(error.localizedDescription)")
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            VocabIOSRootView(launchWarning: launch.fallbackMessage)
                .modelContainer(launch.container)
        }
    }
}
