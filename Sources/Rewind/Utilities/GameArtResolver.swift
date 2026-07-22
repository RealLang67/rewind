import Foundation

actor GameArtResolver {
	private let session: URLSession
	/// name -> art url
	private var cache: [String: String?] = [:]

	init(session: URLSession = URLSession(configuration: .ephemeral)) {
		self.session = session
	}

	func artURL(for name: String) async -> String? {
		if let cached = cache[name] { return cached }
		let resolved = await lookup(name)
		cache[name] = resolved
		return resolved
	}

	private func lookup(_ name: String) async -> String? {
		guard let query = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
		      let url = URL(string: "https://store.steampowered.com/api/storesearch/?term=\(query)&cc=us&l=en"),
		      let (data, _) = try? await session.data(from: url),
		      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
		      let items = json["items"] as? [[String: Any]]
		else { return nil }
		for item in items {
			guard let appID = item["id"] as? Int, let title = item["name"] as? String else { continue }
			if Self.matches(query: name, result: title) {
				return "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appID)/header.jpg"
			}
		}
		return nil
	}

	static func matches(query: String, result: String) -> Bool {
		let q = normalize(query)
		let r = normalize(result)
		guard !q.isEmpty, !r.isEmpty else { return false }
		if q == r { return true }
		return r.hasPrefix(q) && Double(q.count) / Double(r.count) >= 0.6
	}

	private static func normalize(_ text: String) -> String {
		String(String.UnicodeScalarView(text.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains)))
	}
}
