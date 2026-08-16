import ServiceManagement

enum LaunchAtLogin {
	static var isEnabled: Bool {
		SMAppService.mainApp.status == .enabled
	}

	static func setEnabled(_ enabled: Bool) throws {
		let service = SMAppService.mainApp
		if enabled {
			guard service.status != .enabled else { return }
			try service.register()
		} else {
			guard service.status == .enabled else { return }
			try service.unregister()
		}
	}
}
