import AppKit
import AVFoundation
import CoreGraphics

struct PermissionState: Equatable {
	var screenRecording: Bool = false
	var microphone: Bool = false
}

enum PermissionError: Error {
	case screenRecordingDenied
	case microphoneDenied
}

enum PermissionManager {
	private static let screenCaptureSettingsURL = URL(
		string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
	)
	
	private static let microphoneSettingsURL = URL(
		string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
	)

	static func currentState() -> PermissionState {
		PermissionState(
			screenRecording: CGPreflightScreenCaptureAccess(),
			microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
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
	
	static func ensureMicrophoneAccess() async throws {
		if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
			return
		}

		let granted = await AVCaptureDevice.requestAccess(for: .audio)
		if !granted {
			throw PermissionError.microphoneDenied
		}
	}

	static func openSystemSettings() {
		guard let url = screenCaptureSettingsURL else { return }
		NSWorkspace.shared.open(url)
	}
	
	static func openMicrophoneSettings() {
		guard let url = microphoneSettingsURL else { return }
		NSWorkspace.shared.open(url)
	}
}
