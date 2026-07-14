import Combine
import Foundation
import Sparkle

@MainActor
final class UpdaterController: NSObject, ObservableObject, SPUUpdaterDelegate {
	private var _updaterController: SPUStandardUpdaterController!

	var updater: SPUUpdater {
		_updaterController.updater
	}

	override init() {
		super.init()
		_updaterController = SPUStandardUpdaterController(
			startingUpdater: true,
			updaterDelegate: self,
			userDriverDelegate: nil
		)
	}

	func checkForUpdates() {
		_updaterController.checkForUpdates(nil)
	}

	nonisolated func updater(_: SPUUpdater, willInstallUpdate _: SUAppcastItem) {
		if let bundleID = Bundle.main.bundleIdentifier {
			let process = Process()
			process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
			process.arguments = ["reset", "All", bundleID]
			do {
				try process.run()
				process.waitUntilExit()
				AppLog.info(.app, "Reset TCC permissions for", bundleID)
			} catch {
				AppLog.error(.app, "Could not reset TCC permissions", error: error)
			}
		}
	}
}
