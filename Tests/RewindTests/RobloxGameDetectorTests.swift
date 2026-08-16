@testable import Rewind
import XCTest

final class GameDetectorTests: XCTestCase {
	func testParsesMostRecentJoinedPlace() async {
		let detector = RobloxGameDetector()
		let log = """
		[FLog::GameJoinUtil] joinGamePostStandard: placeId: 920587237
		[FLog::Output] ! Joining game '1111-2222' place 606849621 at 10.0.0.1
		[FLog::Network] heartbeat ok
		[FLog::Output] ! Joining game '3333-4444' place 4483381587 at 10.0.0.2
		"""
		let placeID = await detector.lastPlaceID(in: log)
		XCTAssertEqual(placeID, "4483381587")
	}

	func testParsesPlaceIdField() async {
		let detector = RobloxGameDetector()
		let placeID = await detector.lastPlaceID(in: "GameJoinUtil placeId: 920587237,")
		XCTAssertEqual(placeID, "920587237")
	}

	func testReturnsNilWhenNoGamePresent() async {
		let detector = RobloxGameDetector()
		let placeID = await detector.lastPlaceID(in: "FPS 60\nrender stats only\n")
		XCTAssertNil(placeID)
	}

	func testParsesPlaceAndJobFromJoinLine() async {
		let detector = RobloxGameDetector()
		let log = "[FLog::Output] ! Joining game 'a1b2c3-d4e5-jobid' place 606849621 at 10.0.0.1"
		let session = await detector.lastSession(in: log)
		XCTAssertEqual(session?.placeID, "606849621")
		XCTAssertEqual(session?.jobID, "a1b2c3-d4e5-jobid")
	}

	func testSessionFallsBackToPlaceIdWithoutJob() async {
		let detector = RobloxGameDetector()
		let session = await detector.lastSession(in: "GameJoinUtil placeId: 920587237,")
		XCTAssertEqual(session?.placeID, "920587237")
		XCTAssertNil(session?.jobID)
	}
}
