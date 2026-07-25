@testable import Rewind
import XCTest

@MainActor
final class SleepWakeTests: XCTestCase {
	func testSleepAndWakeUpdatesState() {
		let appState = AppState()
		XCTAssertFalse(appState.isAsleep)

		appState.handleSleep()
		XCTAssertTrue(appState.isAsleep)
		XCTAssertTrue(appState.isDisplayOrSystemAsleep)

		appState.handleWake()
		XCTAssertFalse(appState.isAsleep)
	}

	func testStartAlwaysRecordingSkippedWhenAsleep() {
		let appState = AppState()
		appState.handleSleep()

		appState.startAlwaysRecording(isAutomatic: true)
		XCTAssertFalse(appState.isCapturing)
	}
}
