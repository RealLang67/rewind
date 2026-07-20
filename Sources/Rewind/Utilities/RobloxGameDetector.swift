import Foundation

/// Detects the Roblox experience the user is currently playing so it can be
/// shown in Discord Rich Presence ("Clipping <game>").
///
/// It reads Roblox Player's own log files under `~/Library/Logs/Roblox/` to
/// find the joined place id, then resolves that id to a display name via
/// Roblox's public web APIs. Nothing is injected into Roblox and no user data
/// is sent; only a numeric place id is looked up. Returns nil when Roblox
/// isn't actively running or the game can't be resolved.
actor RobloxGameDetector {
	private var placeNameCache: [String: String] = [:]
	private let session: URLSession
	private let staleThreshold: TimeInterval

	/// - Parameters:
	///   - session: URLSession used for the place/universe lookups.
	///   - staleThreshold: if the newest Roblox log hasn't been written to
	///     within this window, treat Roblox as inactive (the player logs
	///     continuously while in a game).
	init(session: URLSession = URLSession(configuration: .ephemeral),
	     staleThreshold: TimeInterval = 120) {
		self.session = session
		self.staleThreshold = staleThreshold
	}

	/// Display name of the experience currently being played, or nil.
	func currentGameName() async -> String? {
		guard let placeID = currentPlaceID() else { return nil }
		if let cached = placeNameCache[placeID] { return cached }
		guard let name = await resolveGameName(placeID: placeID) else { return nil }
		placeNameCache[placeID] = name
		return name
	}

	// MARK: - Log parsing

	private func logsDirectory() -> URL {
		FileManager.default.homeDirectoryForCurrentUser
			.appendingPathComponent("Library/Logs/Roblox", isDirectory: true)
	}

	private func currentPlaceID() -> String? {
		guard let (logURL, modified) = newestLog() else { return nil }
		// The player writes to the log constantly while in a game; a stale file
		// means the session ended.
		guard Date().timeIntervalSince(modified) < staleThreshold else { return nil }
		guard let content = try? String(contentsOf: logURL, encoding: .utf8) else { return nil }
		return lastPlaceID(in: content)
	}

	private func newestLog() -> (URL, Date)? {
		let fm = FileManager.default
		guard let files = try? fm.contentsOfDirectory(
			at: logsDirectory(),
			includingPropertiesForKeys: [.contentModificationDateKey],
			options: [.skipsHiddenFiles]
		) else { return nil }

		return files
			.filter { $0.pathExtension == "log" }
			.compactMap { url -> (URL, Date)? in
				let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
					.contentModificationDate
				return date.map { (url, $0) }
			}
			.max { $0.1 < $1.1 }
	}

	/// Returns the last place id mentioned in the log (the current game). Roblox
	/// logs the join like: `! Joining game '<jobId>' place 1818 at <ip>`.
	func lastPlaceID(in log: String) -> String? {
		let patterns = [
			#"Joining game '[^']*' place (\d+)"#,
			#"[Pp]lace[Ii]d[:\s\"=]+(\d+)"#,
		]
		for pattern in patterns {
			guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
			let range = NSRange(log.startIndex..., in: log)
			var last: String?
			regex.enumerateMatches(in: log, range: range) { match, _, _ in
				guard let match, match.numberOfRanges > 1,
				      let captured = Range(match.range(at: 1), in: log) else { return }
				last = String(log[captured])
			}
			if let last { return last }
		}
		return nil
	}

	// MARK: - Name resolution

	private func resolveGameName(placeID: String) async -> String? {
		guard let universeID = await universeID(forPlace: placeID) else { return nil }
		return await gameName(forUniverse: universeID)
	}

	private func universeID(forPlace placeID: String) async -> String? {
		let urlString = "https://apis.roblox.com/universes/v1/places/\(placeID)/universe"
		guard let url = URL(string: urlString),
		      let (data, _) = try? await session.data(from: url),
		      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
		else { return nil }
		if let id = json["universeId"] as? Int { return String(id) }
		return json["universeId"] as? String
	}

	private func gameName(forUniverse universeID: String) async -> String? {
		let urlString = "https://games.roblox.com/v1/games?universeIds=\(universeID)"
		guard let url = URL(string: urlString),
		      let (data, _) = try? await session.data(from: url),
		      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
		      let entries = json["data"] as? [[String: Any]],
		      let name = entries.first?["name"] as? String
		else { return nil }
		return name
	}
}
