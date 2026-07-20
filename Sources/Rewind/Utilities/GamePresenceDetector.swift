import Foundation

/// Figures out which game the user is currently playing so it can be shown in
/// Discord Rich Presence ("Clipping <game>").
///
/// Detection is process-based: it lists running processes and matches their
/// command lines against a table of known games. That covers most titles with
/// no per-game API. Roblox is enriched with the specific experience name via
/// its logs (see `GameDetector`). Returns nil when no known game is up.
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
	private let roblox: GameDetector
	private let bundledCatalogURL: URL?
	/// Lazily-parsed `executable-basename -> game name` map distilled from
	/// Discord's detectable-games database (see scripts/generate-game-catalog.py).
	private var bundledCatalog: [String: String]?

	init(catalog: [Game] = GamePresenceDetector.defaultCatalog,
	     roblox: GameDetector = GameDetector(),
	     bundledCatalogURL: URL? = Bundle.main.url(forResource: "games", withExtension: "tsv")) {
		self.catalog = catalog
		self.roblox = roblox
		self.bundledCatalogURL = bundledCatalogURL
	}

	/// A detected game plus an optional server-join URL (Roblox only).
	struct Presence: Equatable {
		let name: String
		let joinURL: String?
	}

	/// The game currently running, or nil.
	func currentGame() async -> Presence? {
		let commands = runningProcessCommands()
		// 1. Curated list first: Roblox's experience/join enrichment plus titles
		//    that need loose or argument-based matching.
		if let game = matchRunningGame(commands: commands) {
			if game.name == "Roblox" {
				if let experience = await roblox.currentExperience() {
					return Presence(name: experience.name, joinURL: experience.joinURL)
				}
				return Presence(name: "Roblox", joinURL: nil)
			}
			return Presence(name: game.name, joinURL: nil)
		}
		// 2. Discord's detectable-games catalog (native macOS games).
		if let name = matchBundledCatalog(commands: commands) {
			return Presence(name: name, joinURL: nil)
		}
		return nil
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

	/// Match process executables against the bundled Discord catalog by basename.
	func matchBundledCatalog(commands: [String]) -> String? {
		let catalog = loadBundledCatalog()
		guard !catalog.isEmpty else { return nil }
		return Self.match(commands: commands, in: catalog)
	}

	/// Pure basename lookup, split out so it can be tested without the bundle.
	static func match(commands: [String], in catalog: [String: String]) -> String? {
		for command in commands {
			for token in command.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
				let base = token.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last
					.map(String.init) ?? String(token)
				let key = base.lowercased()
				if let name = catalog[key] { return name }
				if key.hasSuffix(".app"), let name = catalog[String(key.dropLast(4))] { return name }
			}
		}
		return nil
	}

	private func loadBundledCatalog() -> [String: String] {
		if let bundledCatalog { return bundledCatalog }
		var map: [String: String] = [:]
		if let bundledCatalogURL,
		   let text = try? String(contentsOf: bundledCatalogURL, encoding: .utf8) {
			for line in text.split(separator: "\n") {
				let parts = line.split(separator: "\t", maxSplits: 1)
				if parts.count == 2 { map[String(parts[0])] = String(parts[1]) }
			}
		}
		bundledCatalog = map
		return map
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
