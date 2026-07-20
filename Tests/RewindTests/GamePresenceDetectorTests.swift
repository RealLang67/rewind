@testable import Rewind
import XCTest

final class GamePresenceDetectorTests: XCTestCase {
	func testMatchesMinecraftFromJavaArgs() async {
		let detector = GamePresenceDetector()
		let commands = [
			"/usr/bin/java -Xmx2G -cp /Users/x/.minecraft/versions net.minecraft.client.main.Main --username player",
		]
		let game = await detector.matchRunningGame(commands: commands)
		XCTAssertEqual(game?.name, "Minecraft")
	}

	func testMatchesNativeAppByPath() async {
		let detector = GamePresenceDetector()
		let commands = ["/Applications/Terraria.app/Contents/MacOS/Terraria"]
		let game = await detector.matchRunningGame(commands: commands)
		XCTAssertEqual(game?.name, "Terraria")
	}

	func testMatchesLeagueClient() async {
		let detector = GamePresenceDetector()
		let commands = ["/Applications/League of Legends.app/Contents/LoL/LeagueClient.app/Contents/MacOS/LeagueClient"]
		let game = await detector.matchRunningGame(commands: commands)
		XCTAssertEqual(game?.name, "League of Legends")
	}

	func testMatchingIsCaseInsensitive() async {
		let detector = GamePresenceDetector()
		let game = await detector.matchRunningGame(commands: ["/games/robloxplayer"])
		XCTAssertEqual(game?.name, "Roblox")
	}

	func testReturnsNilForNonGameProcesses() async {
		let detector = GamePresenceDetector()
		let commands = ["/usr/sbin/cfprefsd", "/bin/zsh", "/System/Library/Frameworks/…/WindowServer"]
		let game = await detector.matchRunningGame(commands: commands)
		XCTAssertNil(game)
	}
}
