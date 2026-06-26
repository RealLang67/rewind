import Foundation

struct FeedbackSound: Hashable, Identifiable {
	let id: String
	let label: String
	let systemSoundName: String

	static let defaultSound = FeedbackSound(
		id: "default",
		label: "Default",
		systemSoundName: "default"
	)

	static let cling = FeedbackSound(
		id: "cling",
		label: "Cling",
		systemSoundName: "Glass"
	)

	static let ping = FeedbackSound(
		id: "ping",
		label: "Ping",
		systemSoundName: "Ping"
	)

	static let pop = FeedbackSound(
		id: "pop",
		label: "Pop",
		systemSoundName: "Pop"
	)

	static let options: [FeedbackSound] = [
		.defaultSound,
		.cling, .ping, .pop,
	]
	static let `default` = defaultSound
	static let defaultStart = defaultSound
	static let defaultEnd = defaultSound
	static let defaultError = defaultSound
}
