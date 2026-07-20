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

	// Bundled Discord catalog (basename lookup).

	func testCatalogMatchesWindowsExeUnderWine() {
		let catalog = ["hades.exe": "Hades", "celeste.exe": "Celeste"]
		let cmd = ["/Applications/CrossOver.app/Contents/wine64 C:\\Games\\Hades\\Hades.exe --fullscreen"]
		XCTAssertEqual(GamePresenceDetector.match(commands: cmd, in: catalog), "Hades")
	}

	func testCatalogMatchesNativeAppBinary() {
		let catalog = ["deadcells": "Dead Cells"]
		let cmd = ["/Applications/Dead Cells.app/Contents/MacOS/deadcells"]
		XCTAssertEqual(GamePresenceDetector.match(commands: cmd, in: catalog), "Dead Cells")
	}

	func testCatalogNoMatchForSystemProcesses() {
		let catalog = ["hades.exe": "Hades"]
		XCTAssertNil(GamePresenceDetector.match(commands: ["/bin/zsh", "/usr/sbin/cfprefsd"], in: catalog))
	}
}
