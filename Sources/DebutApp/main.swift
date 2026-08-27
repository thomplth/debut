import AppKit
import DebutCore
import Sparkle

@MainActor
final class SparkleApplicationUpdater: ApplicationUpdating {
    private let controller = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    func start() {
        controller.startUpdater()
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate(applicationUpdater: SparkleApplicationUpdater())
app.delegate = delegate
app.run()
