import AVFoundation

/// an audio input device the user can capture from. `id` is the
/// `AVCaptureDevice.uniqueID`, which is what `SCStreamConfiguration`'s
/// `microphoneCaptureDeviceID` expects
struct MicrophoneDevice: Identifiable, Hashable {
	let id: String
	let name: String
}

@MainActor
enum MicrophoneDeviceProvider {
	static func availableDevices() -> [MicrophoneDevice] {
		let deviceTypes: [AVCaptureDevice.DeviceType]
		if #available(macOS 14.0, *) {
			deviceTypes = [.microphone, .external]
		} else {
			deviceTypes = [.builtInMicrophone, .externalUnknown]
		}

		let session = AVCaptureDevice.DiscoverySession(
			deviceTypes: deviceTypes, mediaType: .audio, position: .unspecified
		)
		return session.devices.map { MicrophoneDevice(id: $0.uniqueID, name: $0.localizedName) }
	}
}
