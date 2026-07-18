import SwiftData
import SwiftUI
import UIKit

final class VocabIOSAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }
}

@main
struct VocabIOSApp: App {
    @UIApplicationDelegateAdaptor(VocabIOSAppDelegate.self) private var appDelegate
    private let launch: VocabLaunchPlan = {
        let preferredMode = VocabSyncMode.current(
            allowsCloudKit: true,
            defaultMode: .cloudKitPrivate
        )
        if preferredMode == .cloudKitPrivate {
            VocabMutationAuthorityRuntime.beginValidationEpoch()
        }
        return VocabModelContainerFactory.makeLaunchPlan(preferredMode: preferredMode)
    }()

    var body: some Scene {
        WindowGroup {
            VocabIOSRootView(connectionError: launch.connectionError)
                .modelContainer(launch.container)
        }
    }
}
