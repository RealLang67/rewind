import Foundation

struct CaptureFrameRate: Hashable, Identifiable {
	let framesPerSecond: Int
	let label: String
	let description: String

	var id: Int {
		framesPerSecond
	}

	static let fps30 = CaptureFrameRate(
		framesPerSecond: 30,
		label: "30 FPS",
		description: "Smaller files, good for mostly static screens"
	)

	static let fps60 = CaptureFrameRate(
		framesPerSecond: 60,
		label: "60 FPS",
		description: "Smoother motion, larger files"
	)

	static let fps120 = CaptureFrameRate(
		framesPerSecond: 120,
		label: "120 FPS",
		description: "smooth operator"
	)

	static let options: [CaptureFrameRate] = [fps30, fps60, fps120]
	static let `default` = fps60

	var isDefault: Bool { framesPerSecond == CaptureFrameRate.default.framesPerSecond }
}
