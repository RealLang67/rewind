import Foundation

/// A file host that accepts a multipart POST and answers with a link to the
/// uploaded clip. Most providers are anonymous; authenticated providers declare
/// the credential type they require.
///
/// Live endpoint contracts are covered by opt-in integration tests because host
/// APIs and limits can change independently of the app.
struct ClipUploadProvider: Hashable, Identifiable, Sendable {
	/// Where the clip link sits in a successful response body.
	enum ResponseParser: Hashable, Sendable {
		/// The trimmed body is the link itself.
		case plainText
		/// Walk object keys and array indices down to a string value.
		case json(path: [JSONPathComponent])
		/// Read a short share code from JSON and append it to a trusted base URL.
		case jsonShareCode(path: [JSONPathComponent], baseURL: URL)
	}

	enum Authentication: Hashable, Sendable {
		case none
		case streamableBasic
	}

	enum JSONPathComponent: Hashable, Sendable {
		case key(String)
		case index(Int)
	}

	/// A retention window picked at upload time. Only Litterbox offers these.
	struct ExpirationOption: Hashable, Identifiable, Sendable {
		/// Sent verbatim as the value of the provider's `expirationFieldName`.
		let id: String
		let label: String
	}

	let id: String
	let displayName: String
	/// Shown beside the toggle in Settings.
	let summary: String
	let homepage: URL
	let endpoint: URL
	/// Name of the multipart part that carries the clip.
	let fileFieldName: String
	/// Text parts sent with every upload to this host.
	let staticFields: [String: String]
	let parser: ResponseParser
	let authentication: Authentication
	/// Checked before uploading so an oversized clip fails immediately instead of
	/// after a long transfer. `nil` where the host publishes no limit we can rely on.
	let maxFileSizeBytes: Int64?
	let expirationFieldName: String?
	/// Ordered shortest to longest.
	let expirationOptions: [ExpirationOption]

	init(
		id: String,
		displayName: String,
		summary: String,
		homepage: URL,
		endpoint: URL,
		fileFieldName: String,
		staticFields: [String: String] = [:],
		parser: ResponseParser,
		authentication: Authentication = .none,
		maxFileSizeBytes: Int64? = nil,
		expirationFieldName: String? = nil,
		expirationOptions: [ExpirationOption] = []
	) {
		self.id = id
		self.displayName = displayName
		self.summary = summary
		self.homepage = homepage
		self.endpoint = endpoint
		self.fileFieldName = fileFieldName
		self.staticFields = staticFields
		self.parser = parser
		self.authentication = authentication
		self.maxFileSizeBytes = maxFileSizeBytes
		self.expirationFieldName = expirationFieldName
		self.expirationOptions = expirationOptions
	}

	var supportsExpiration: Bool {
		expirationFieldName != nil && !expirationOptions.isEmpty
	}

	/// Falls back to the longest window when nothing is stored.
	var defaultExpiration: ExpirationOption? {
		expirationOptions.last
	}

	func expiration(id: String?) -> ExpirationOption? {
		guard let id else { return defaultExpiration }
		return expirationOptions.first { $0.id == id } ?? defaultExpiration
	}
}

extension ClipUploadProvider {
	/// The two hosts that predate the provider list; legacy settings migrate onto these.
	static let catboxID = "catbox"
	static let litterboxID = "litterbox"
	static let streamableID = "streamable"

	/// Ordered longest-lived first, so the most useful choice sits at the top of the menu.
	static let providers: [ClipUploadProvider] = [
		ClipUploadProvider(
			id: catboxID,
			displayName: "Catbox.moe",
			summary: "Permanent hosting, up to 200 MB. Links play inline in Discord.",
			homepage: URL(string: "https://catbox.moe")!,
			endpoint: URL(string: "https://catbox.moe/user/api.php")!,
			fileFieldName: "fileToUpload",
			staticFields: ["reqtype": "fileupload"],
			parser: .plainText,
			maxFileSizeBytes: 200 * 1_000_000
		),
		ClipUploadProvider(
			id: streamableID,
			displayName: "Streamable",
			summary: "Video hosting with inline playback. Requires an account; "
				+ "free uploads are limited to 250 MB and 10 minutes.",
			homepage: URL(string: "https://streamable.com")!,
			endpoint: URL(string: "https://api.streamable.com/upload")!,
			fileFieldName: "file",
			parser: .jsonShareCode(
				path: [.key("shortcode")],
				baseURL: URL(string: "https://streamable.com")!
			),
			authentication: .streamableBasic
		),
		ClipUploadProvider(
			id: "quax",
			displayName: "qu.ax",
			summary: "Kept for about 30 days.",
			homepage: URL(string: "https://qu.ax")!,
			endpoint: URL(string: "https://qu.ax/upload.php")!,
			fileFieldName: "files[]",
			parser: .json(path: [.key("files"), .index(0), .key("url")])
		),
		ClipUploadProvider(
			id: litterboxID,
			displayName: "Litterbox",
			summary: "Temporary Catbox hosting, up to 1 GB. You pick how long it lives.",
			homepage: URL(string: "https://litterbox.catbox.moe")!,
			endpoint: URL(string: "https://litterbox.catbox.moe/resources/internals/api.php")!,
			fileFieldName: "fileToUpload",
			staticFields: ["reqtype": "fileupload"],
			parser: .plainText,
			maxFileSizeBytes: 1_000 * 1_000_000,
			expirationFieldName: "time",
			expirationOptions: [
				ExpirationOption(id: "1h", label: "1 Hour"),
				ExpirationOption(id: "12h", label: "12 Hours"),
				ExpirationOption(id: "24h", label: "24 Hours"),
				ExpirationOption(id: "72h", label: "72 Hours"),
			]
		),
		ClipUploadProvider(
			id: "tempsh",
			displayName: "temp.sh",
			summary: "Short-lived hosting that copes well with big clips.",
			homepage: URL(string: "https://temp.sh")!,
			endpoint: URL(string: "https://temp.sh/upload")!,
			fileFieldName: "file",
			parser: .plainText
		),
		ClipUploadProvider(
			id: "x0at",
			displayName: "x0.at",
			summary: "Temporary hosting; smaller clips are kept longer.",
			homepage: URL(string: "https://x0.at")!,
			endpoint: URL(string: "https://x0.at")!,
			fileFieldName: "file",
			parser: .plainText
		),
		ClipUploadProvider(
			id: "kappa",
			displayName: "kappa.lol",
			summary: "Quick temporary hosting.",
			homepage: URL(string: "https://kappa.lol")!,
			endpoint: URL(string: "https://kappa.lol/api/upload")!,
			fileFieldName: "file",
			parser: .json(path: [.key("link")])
		),
		ClipUploadProvider(
			id: "uguu",
			displayName: "uguu.se",
			summary: "Deleted after 3 hours, up to 128 MB.",
			homepage: URL(string: "https://uguu.se")!,
			endpoint: URL(string: "https://uguu.se/upload")!,
			fileFieldName: "files[]",
			parser: .json(path: [.key("files"), .index(0), .key("url")]),
			maxFileSizeBytes: 128 * 1_024 * 1_024
		),
	]

	static func provider(id: String) -> ClipUploadProvider? {
		providers.first { $0.id == id }
	}
}
