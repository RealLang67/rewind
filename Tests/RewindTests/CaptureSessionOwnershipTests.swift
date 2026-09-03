@testable import Rewind
import XCTest

@MainActor
final class CaptureSessionOwnershipTests: XCTestCase {
	func testCurrentSessionInterruptionIsHandled() {
		let shouldHandle = AppState.shouldHandleCaptureInterruption(
			sessionGeneration: 4,
			activeSessionGeneration: 4,
			latestSessionGeneration: 4,
			captureIsStartingOrRestarting: false
		)
		XCTAssertTrue(shouldHandle)
	}

	func testOlderSessionInterruptionIsIgnoredAfterRestart() {
		let shouldHandle = AppState.shouldHandleCaptureInterruption(
			sessionGeneration: 4,
			activeSessionGeneration: 5,
			latestSessionGeneration: 5,
			captureIsStartingOrRestarting: false
		)
		XCTAssertFalse(shouldHandle)
	}

	func testNewSessionInterruptionIsHandledWhileRestartIsFinishing() {
		let shouldHandle = AppState.shouldHandleCaptureInterruption(
			sessionGeneration: 5,
			activeSessionGeneration: 4,
			latestSessionGeneration: 4,
			captureIsStartingOrRestarting: true
		)
		XCTAssertTrue(shouldHandle)
	}

	func testDuplicateInterruptionIsIgnoredAfterSessionEnded() {
		let shouldHandle = AppState.shouldHandleCaptureInterruption(
			sessionGeneration: 5,
			activeSessionGeneration: nil,
			latestSessionGeneration: 5,
			captureIsStartingOrRestarting: false
		)
		XCTAssertFalse(shouldHandle)
	}
}
