import SwiftUI

@main
struct RewindApp: App {
	@NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
	@ObservedObject private var appState: AppState
	@ObservedObject private var updaterController: UpdaterController

	init() {
		_appState = ObservedObject(initialValue: AppCompositionRoot.shared.appState)
		_updaterController = ObservedObject(initialValue: AppCompositionRoot.shared.updaterController)
		AppLog.setupCrashHandlers()
	}

	var body: some Scene {
		MenuBarExtra("Rewind", systemImage: "backward.end.fill") {
			MenuBarView(appState: appState)
		}

		Settings {
			SettingsView(appState: appState, updaterController: updaterController)
		}
		.defaultSize(width: 520, height: 440)

		Window("Home", id: "home") {
			HomeView(appState: appState)
		}
		.defaultSize(width: 800, height: 600)

		Window("Settings", id: "settings-fallback") {
			SettingsView(appState: appState, updaterController: updaterController)
		}
		.defaultSize(width: 520, height: 440)
	}
}
