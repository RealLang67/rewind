import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
	private let compositionRoot = AppCompositionRoot.shared

	func applicationDidFinishLaunching(_: Notification) {
		compositionRoot.lifecycleController.start()
	}

	func applicationWillTerminate(_: Notification) {
		compositionRoot.lifecycleController.stop()
	}
}
