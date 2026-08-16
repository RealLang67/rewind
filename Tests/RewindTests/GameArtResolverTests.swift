@testable import Rewind
import XCTest

final class GameArtResolverTests: XCTestCase {
	func testAcceptsExactMatch() {
		XCTAssertTrue(GameArtResolver.matches(query: "Terraria", result: "Terraria"))
		XCTAssertTrue(GameArtResolver.matches(query: "Baldur's Gate 3", result: "Baldur's Gate 3"))
	}

	func testAcceptsEditionSuffix() {
		XCTAssertTrue(GameArtResolver.matches(query: "Football Manager", result: "Football Manager 26"))
	}

	func testIgnoresPunctuationAndTrademarks() {
		XCTAssertTrue(GameArtResolver.matches(query: "The Sims 4", result: "The Sims™ 4"))
	}

	func testRejectsOffTargetHit() {

		XCTAssertFalse(GameArtResolver.matches(query: "Minecraft", result: "Minecraft Dungeons"))
		XCTAssertFalse(GameArtResolver.matches(query: "Old School RuneScape", result: "RuneScape"))
	}
}
