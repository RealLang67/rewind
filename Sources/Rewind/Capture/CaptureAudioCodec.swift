import Foundation

struct CaptureAudioCodec: Hashable, Identifiable {
	let id: String
	let label: String
	let description: String

	static let appleLossless = CaptureAudioCodec(
		id: "alac",
		label: "Apple Lossless",
		description: "Lossless compression, smaller files"
	)

	static let aac = CaptureAudioCodec(
		id: "aac",
		label: "AAC",
		description: "Compressed audio, smallest files"
	)

	static let options: [CaptureAudioCodec] = [.appleLossless, .aac]
	static let `default` = aac

	var isDefault: Bool { id == CaptureAudioCodec.default.id }
}
