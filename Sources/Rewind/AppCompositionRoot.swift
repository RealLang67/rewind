@MainActor
final class AppCompositionRoot {
	static let shared = AppCompositionRoot()

	let appState: AppState
	let lifecycleController: AppLifecycleController
	let updaterController: UpdaterController

	private init() {
		let hotkeyManager = GlobalHotkeyManager.shared
		let appState = AppState(hotkeyManager: hotkeyManager)
		let updaterController = UpdaterController()

		self.appState = appState
		self.updaterController = updaterController
		lifecycleController = AppLifecycleController(
			appState: appState,
			hotkeyManager: hotkeyManager
		)
	}
}
