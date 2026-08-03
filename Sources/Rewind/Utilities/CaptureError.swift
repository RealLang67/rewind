import Foundation

enum CaptureError: Error, LocalizedError {
	case noDisplay
	case noAudioDevice
	case writerUnavailable
	case noFramesCaptured
	case exportFailed
	case saveInProgress
	case invalidDuration
	case writerFinishTimedOut

	var errorDescription: String? {
		switch self {
		case .noDisplay:
			return "No display is available for capture."
		case .noAudioDevice:
			return "No audio device is available for capture."
		case .writerUnavailable:
			return "The replay writer is unavailable."
		case .noFramesCaptured:
			return "The replay writer did not receive a video frame before rotation."
		case .exportFailed:
			return "The replay segment could not be exported."
		case .saveInProgress:
			return "A replay save is already in progress."
		case .invalidDuration:
			return "The replay segment has an invalid duration."
		case .writerFinishTimedOut:
			return "The replay writer did not finish the segment within the timeout."
		}
	}
}
