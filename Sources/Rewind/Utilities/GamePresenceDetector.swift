import Foundation

/// Figures out which game the user is currently playing so it can be shown in
/// Discord Rich Presence ("Clipping <game>").
///
/// Detection is process-based: it lists running processes and matches their
/// command lines against a table of known games. That covers most titles with
/// no per-game API. Roblox is enriched with the specific experience name via
/// its logs (see `RobloxGameDetector`). Returns nil when no known game is up.
actor GamePresenceDetector {
	/// A known game and the substrings that identify its running process.
	/// `needles` are matched case-insensitively against each process command
	/// line, so they work for native `.app` bundles and launcher/`java`
	/// processes alike. Order matters: earlier entries win.
	struct Game {
		let name: String
		let needles: [String]
	}

	static let defaultCatalog: [Game] = [
		Game(name: "Roblox", needles: ["RobloxPlayer"]),
		Game(name: "Minecraft", needles: ["net.minecraft.client", "minecraft.client", "MinecraftLauncher", "/Minecraft.app/", "lunarclient", "PrismLauncher"]),
		Game(name: "League of Legends", needles: ["LeagueClient", "League of Legends"]),
		Game(name: "Teamfight Tactics", needles: ["TFT", "Teamfight"]),
		Game(name: "Valorant", needles: ["VALORANT", "RiotClientServices"]),
		Game(name: "Counter-Strike 2", needles: ["cs2.app", "/cs2"]),
		Game(name: "Dota 2", needles: ["dota2"]),
		Game(name: "Team Fortress 2", needles: ["TF2.app", "hl2_osx"]),
		Game(name: "Terraria", needles: ["Terraria"]),
		Game(name: "Stardew Valley", needles: ["StardewValley", "Stardew Valley"]),
		Game(name: "Balatro", needles: ["Balatro"]),
		Game(name: "Hades", needles: ["Hades.app", "/Hades"]),
		Game(name: "Celeste", needles: ["Celeste.app"]),
		Game(name: "Vampire Survivors", needles: ["VampireSurvivors", "Vampire Survivors"]),
		Game(name: "Factorio", needles: ["factorio"]),
		Game(name: "Among Us", needles: ["Among Us"]),
		Game(name: "World of Warcraft", needles: ["World of Warcraft"]),
		Game(name: "Final Fantasy XIV", needles: ["ffxiv", "FINAL FANTASY XIV"]),
		Game(name: "Old School RuneScape", needles: ["RuneLite", "Old School RuneScape"]),
		Game(name: "osu!", needles: ["osu!.app", "/osu!"]),
	]

	private let catalog: [Game]
	private let roblox: RobloxGameDetector

	init(catalog: [Game] = GamePresenceDetector.defaultCatalog,
	     roblox: RobloxGameDetector = RobloxGameDetector()) {
		self.catalog = catalog
		self.roblox = roblox
	}

	/// Display name of the game currently running, or nil.
	func currentGame() async -> String? {
		guard let game = matchRunningGame() else { return nil }
		if game.name == "Roblox" {
			// Prefer the specific experience name; fall back to just "Roblox".
			return await roblox.currentGameName() ?? "Roblox"
		}
		return game.name
	}

	/// First catalog game whose process is currently running.
	func matchRunningGame(commands: [String]? = nil) -> Game? {
		let running = commands ?? runningProcessCommands()
		return catalog.first { game in
			game.needles.contains { needle in
				running.contains { $0.range(of: needle, options: .caseInsensitive) != nil }
			}
		}
	}

	private func runningProcessCommands() -> [String] {
		let process = Process()
		// Full command lines (with args) so Java-launched games like Minecraft
		// match on their main-class arguments, not just the `java` binary name.
		process.executableURL = URL(fileURLWithPath: "/bin/ps")
		process.arguments = ["-A", "-o", "command="]
		let out = Pipe()
		process.standardOutput = out
		process.standardError = Pipe()
		do {
			try process.run()
			let data = out.fileHandleForReading.readDataToEndOfFile()
			process.waitUntilExit()
			return String(decoding: data, as: UTF8.self)
				.split(separator: "\n")
				.map(String.init)
		} catch {
			return []
		}
	}
}
