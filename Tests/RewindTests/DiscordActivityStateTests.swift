@testable import Rewind
import XCTest

final class DiscordActivityStateTests: XCTestCase {
	func testTitleIsGameOnly() {
		let state = DiscordActivityState.recording(game: "War Thunder", joinURL: nil, artURL: nil)
		XCTAssertEqual(state.name, "War Thunder")
		XCTAssertEqual(state.details, "Clipping War Thunder with Rewind")
	}

	func testBodyAlwaysSplitsAcrossTwoLines() {
		let state = DiscordActivityState.recording(game: "Terraria", joinURL: nil, artURL: nil)
		let lines = state.presenceLines
		XCTAssertEqual(lines.details, "Clipping Terraria")
		XCTAssertEqual(lines.state, "with Rewind")
	}

	func testDetailsLineStaysWithinDiscordLimit() {
		let longName = String(repeating: "Neon ", count: 40).trimmingCharacters(in: .whitespaces)
		let state = DiscordActivityState.recording(game: longName, joinURL: nil, artURL: nil)
		let lines = state.presenceLines
		XCTAssertLessThanOrEqual(lines.details.count, 128)
		XCTAssertEqual(lines.state, "with Rewind")
	}

	func testIdleAndNoGameStaySingleLine() {
		XCTAssertNil(DiscordActivityState.idle.presenceLines.state)
		XCTAssertEqual(DiscordActivityState.idle.presenceLines.details, "Idling...")
		let noGame = DiscordActivityState.recording(game: nil, joinURL: nil, artURL: nil)
		XCTAssertNil(noGame.presenceLines.state)
		XCTAssertEqual(noGame.presenceLines.details, "Capturing a game")
	}
}
