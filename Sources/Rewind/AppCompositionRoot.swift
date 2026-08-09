@MainActor
final class AppCompositionRoot {
	static let shared = AppCompositionRoot()

	let appState: AppState
	let lifecycleController: AppLifecycleController
	let updaterController: UpdaterController
	let analytics: any AnalyticsTracking

	private init() {
		let hotkeyManager = GlobalHotkeyManager.shared
		let settings = AppSettingsStorage.load()
		let analytics = PostHogAnalytics(enabled: settings.analyticsEnabled)
		let appState = AppState(analytics: analytics, hotkeyManager: hotkeyManager)
		let updaterController = UpdaterController()

		self.appState = appState
		self.updaterController = updaterController
		self.analytics = analytics
		lifecycleController = AppLifecycleController(
			appState: appState,
			hotkeyManager: hotkeyManager
		)
	}
}
