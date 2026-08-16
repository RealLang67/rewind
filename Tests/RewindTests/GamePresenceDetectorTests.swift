@testable import Rewind
import XCTest

final class GamePresenceDetectorTests: XCTestCase {
	private func app(_ name: String, bundleID: String = "", executable: String = "") -> GamePresenceDetector.RunningApp {
		GamePresenceDetector.RunningApp(name: name, bundleID: bundleID, executable: executable)
	}

	func testMatchesRobloxByExecutable() async {
		let detector = GamePresenceDetector()
		let game = await detector.matchCatalog(apps: [app("Roblox", bundleID: "com.roblox.RobloxPlayer", executable: "RobloxPlayer")])
		XCTAssertEqual(game?.name, "Roblox")
	}

	func testMatchesMinecraftLauncher() async {
		let detector = GamePresenceDetector()
		let game = await detector.matchCatalog(apps: [app("Minecraft", bundleID: "com.mojang.minecraftlauncher", executable: "Minecraft")])
		XCTAssertEqual(game?.name, "Minecraft")
	}

	func testMatchesNativeAppByName() async {
		let detector = GamePresenceDetector()
		let game = await detector.matchCatalog(apps: [app("Terraria", executable: "Terraria")])
		XCTAssertEqual(game?.name, "Terraria")
	}

	func testMatchesLeagueClient() async {
		let detector = GamePresenceDetector()
		let game = await detector.matchCatalog(apps: [app("League of Legends", executable: "LeagueClient")])
		XCTAssertEqual(game?.name, "League of Legends")
	}

	func testMatchingIsCaseInsensitive() async {
		let detector = GamePresenceDetector()
		let game = await detector.matchCatalog(apps: [app("", executable: "robloxplayer")])
		XCTAssertEqual(game?.name, "Roblox")
	}

	func testReturnsNilForNonGameApps() async {
		let detector = GamePresenceDetector()
		let apps = [
			app("Finder", bundleID: "com.apple.finder", executable: "Finder"),
			app("Safari", bundleID: "com.apple.Safari", executable: "Safari"),
		]
		let game = await detector.matchCatalog(apps: apps)
		XCTAssertNil(game)
	}

	// Bundled Discord catalog (basename lookup).

	func testCatalogMatchesNativeAppBinary() {
		let catalog = ["deadcells": "Dead Cells"]
		let apps = [GamePresenceDetector.RunningApp(name: "Dead Cells", bundleID: "", executable: "deadcells")]
		XCTAssertEqual(GamePresenceDetector.match(apps: apps, in: catalog), "Dead Cells")
	}

	func testCatalogMatchesAppSuffix() {
		let catalog = ["celeste": "Celeste"]
		let apps = [GamePresenceDetector.RunningApp(name: "Celeste", bundleID: "", executable: "Celeste.app")]
		XCTAssertEqual(GamePresenceDetector.match(apps: apps, in: catalog), "Celeste")
	}

	func testCatalogNoMatchForSystemApps() {
		let catalog = ["hades": "Hades"]
		let apps = [GamePresenceDetector.RunningApp(name: "Finder", bundleID: "com.apple.finder", executable: "Finder")]
		XCTAssertNil(GamePresenceDetector.match(apps: apps, in: catalog))
	}
}
