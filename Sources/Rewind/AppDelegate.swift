import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
	private let compositionRoot = AppCompositionRoot.shared

	func applicationDidFinishLaunching(_: Notification) {
		compositionRoot.lifecycleController.start()
		compositionRoot.appState.trackAppOpened()
	}

	func applicationWillTerminate(_: Notification) {
		compositionRoot.lifecycleController.stop()
	}
}
