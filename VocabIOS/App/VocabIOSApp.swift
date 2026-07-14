import SwiftData
import SwiftUI

@main
struct VocabIOSApp: App {
    private let launch: VocabLaunchPlan = {
        let preferredMode = VocabSyncMode.current(
            allowsCloudKit: true,
            defaultMode: .cloudKitPrivate
        )
        return VocabModelContainerFactory.makeLaunchPlan(preferredMode: preferredMode)
    }()

    var body: some Scene {
        WindowGroup {
            VocabIOSRootView(connectionError: launch.connectionError)
                .modelContainer(launch.container)
        }
    }
}
