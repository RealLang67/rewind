import AppKit
import AVFoundation
import CoreGraphics

struct PermissionState: Equatable {
	var screenRecording: Bool = false
}

enum PermissionError: Error {
	case screenRecordingDenied
}

enum PermissionManager {
	private static let screenCaptureSettingsURL = URL(
		string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
	)

	static func currentState() -> PermissionState {
		PermissionState(
			screenRecording: CGPreflightScreenCaptureAccess()
		)
	}

	static func ensureScreenAccess() async throws {
		if CGPreflightScreenCaptureAccess() {
			return
		}

		let granted = CGRequestScreenCaptureAccess()
		if !granted {
			throw PermissionError.screenRecordingDenied
		}
	}

	static func openSystemSettings() {
		guard let url = screenCaptureSettingsURL else { return }
		NSWorkspace.shared.open(url)
	}
}
