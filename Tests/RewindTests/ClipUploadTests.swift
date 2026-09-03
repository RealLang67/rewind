@testable import Rewind
import XCTest

final class ClipUploadTests: XCTestCase {
	// - Catalog ---

	func testProviderIDsAreUnique() {
		let ids = ClipUploadProvider.providers.map(\.id)
		XCTAssertEqual(ids.count, Set(ids).count, "Two providers share an id")
	}

	func testEveryProviderUsesHTTPSAndHasAFileField() {
		for provider in ClipUploadProvider.providers {
			XCTAssertEqual(provider.endpoint.scheme, "https", "\(provider.id) endpoint isn't https")
			XCTAssertEqual(provider.homepage.scheme, "https", "\(provider.id) homepage isn't https")
			XCTAssertFalse(provider.fileFieldName.isEmpty, "\(provider.id) has no file field")
			XCTAssertFalse(provider.displayName.isEmpty)
			XCTAssertFalse(provider.summary.isEmpty)
		}
	}

	func testLegacyProviderIDsStillResolve() {
		XCTAssertNotNil(ClipUploadProvider.provider(id: ClipUploadProvider.catboxID))
		XCTAssertNotNil(ClipUploadProvider.provider(id: ClipUploadProvider.litterboxID))
		XCTAssertNil(ClipUploadProvider.provider(id: "not-a-host"))
	}

	func testStreamableProviderUsesAuthenticatedUploadEndpoint() throws {
		let provider = try XCTUnwrap(
			ClipUploadProvider.provider(id: ClipUploadProvider.streamableID)
		)
		XCTAssertEqual(provider.endpoint.absoluteString, "https://api.streamable.com/upload")
		XCTAssertEqual(provider.fileFieldName, "file")
		XCTAssertEqual(provider.authentication, .streamableBasic)
	}

	func testOnlyLitterboxOffersExpirationOptions() {
		let withExpiration = ClipUploadProvider.providers.filter(\.supportsExpiration).map(\.id)
		XCTAssertEqual(withExpiration, [ClipUploadProvider.litterboxID])
	}

	func testExpirationLookupFallsBackToTheLongestWindow() throws {
		let litterbox = try XCTUnwrap(
			ClipUploadProvider.provider(id: ClipUploadProvider.litterboxID)
		)
		XCTAssertEqual(litterbox.expiration(id: "12h")?.id, "12h")
		XCTAssertEqual(litterbox.expiration(id: "nonsense")?.id, "72h")
		XCTAssertEqual(litterbox.expiration(id: nil)?.id, "72h")
	}

	// - Response parsing ---

	private func provider(parser: ClipUploadProvider.ResponseParser) -> ClipUploadProvider {
		ClipUploadProvider(
			id: "test",
			displayName: "Test",
			summary: "Test",
			homepage: URL(string: "https://example.com")!,
			endpoint: URL(string: "https://example.com/upload")!,
			fileFieldName: "file",
			parser: parser
		)
	}

	func testPlainTextResponseIsTrimmed() throws {
		let data = Data("https://files.catbox.moe/abc123.mp4\n".utf8)
		let link = try ClipUploader.parseLink(from: data, provider: provider(parser: .plainText))
		XCTAssertEqual(link.absoluteString, "https://files.catbox.moe/abc123.mp4")
	}

	func testNestedJSONResponseUnescapesSlashes() throws {
		// uguu.se and qu.ax both answer in this shape, with escaped slashes.
		let data = Data(#"{"success":true,"files":[{"url":"https:\/\/d.uguu.se\/abc.mp4"}]}"#.utf8)
		let parser = ClipUploadProvider.ResponseParser.json(
			path: [.key("files"), .index(0), .key("url")]
		)
		let link = try ClipUploader.parseLink(from: data, provider: provider(parser: parser))
		XCTAssertEqual(link.absoluteString, "https://d.uguu.se/abc.mp4")
	}

	func testTopLevelJSONKeyResponse() throws {
		let data = Data(#"{"id":"ed3XwN","link":"https://kappa.lol/ed3XwN"}"#.utf8)
		let link = try ClipUploader.parseLink(
			from: data, provider: provider(parser: .json(path: [.key("link")]))
		)
		XCTAssertEqual(link.absoluteString, "https://kappa.lol/ed3XwN")
	}

	func testStreamableShortcodeBecomesShareLink() throws {
		let streamable = try XCTUnwrap(
			ClipUploadProvider.provider(id: ClipUploadProvider.streamableID)
		)
		let data = Data(#"{"status":1,"shortcode":"aB12_z"}"#.utf8)
		let link = try ClipUploader.parseLink(from: data, provider: streamable)
		XCTAssertEqual(link.absoluteString, "https://streamable.com/aB12_z")
	}

	func testUnsafeStreamableShortcodesAreRejected() throws {
		let streamable = try XCTUnwrap(
			ClipUploadProvider.provider(id: ClipUploadProvider.streamableID)
		)
		for code in ["", "../account", "abc/def", "https://example.com", "abc?token=x"] {
			let data = try JSONSerialization.data(withJSONObject: ["shortcode": code])
			XCTAssertThrowsError(
				try ClipUploader.parseLink(from: data, provider: streamable),
				"\(code) should not be accepted as a Streamable shortcode"
			)
		}
	}

	func testMissingJSONPathIsRejected() {
		let data = Data(#"{"success":false,"description":"file too big"}"#.utf8)
		let parser = ClipUploadProvider.ResponseParser.json(
			path: [.key("files"), .index(0), .key("url")]
		)
		XCTAssertThrowsError(
			try ClipUploader.parseLink(from: data, provider: provider(parser: parser))
		) { error in
			XCTAssertEqual(error as? ClipUploadError, .unreadableResponse)
		}
	}

	func testErrorTextInAPlainTextResponseIsRejected() {
		// Catbox answers 200 with a prose error rather than a link.
		let data = Data("File too large.".utf8)
		XCTAssertThrowsError(
			try ClipUploader.parseLink(from: data, provider: provider(parser: .plainText))
		)
	}

	func testNonHTTPSchemesAreRejected() {
		for body in ["file:///etc/passwd", "javascript:alert(1)", "ftp://example.com/x.mp4"] {
			XCTAssertThrowsError(
				try ClipUploader.parseLink(
					from: Data(body.utf8), provider: provider(parser: .plainText)
				),
				"\(body) should not be accepted"
			)
		}
	}

	// - Authentication ---

	func testStreamableBasicAuthorizationHeader() throws {
		let streamable = try XCTUnwrap(
			ClipUploadProvider.provider(id: ClipUploadProvider.streamableID)
		)
		let credentials = try StreamableCredentials(
			email: "player@example.com",
			password: "secret:with-colon"
		)
		let header = try ClipUploader.authorizationHeader(
			for: streamable,
			credentials: credentials
		)
		let expected = Data("player@example.com:secret:with-colon".utf8).base64EncodedString()
		XCTAssertEqual(header, "Basic \(expected)")
	}

	func testStreamableCredentialsNormalizeEmail() throws {
		let credentials = try StreamableCredentials(
			email: "  player@example.com\n",
			password: " secret "
		)
		XCTAssertEqual(credentials.email, "player@example.com")
		XCTAssertEqual(credentials.password, " secret ")
	}

	func testInvalidStreamableCredentialsAreRejected() {
		for email in ["", "not-an-email", "user:admin@example.com", "a @example.com"] {
			XCTAssertThrowsError(
				try StreamableCredentials(email: email, password: "secret"),
				"\(email) should not be accepted"
			)
		}
		XCTAssertThrowsError(
			try StreamableCredentials(email: "player@example.com", password: "   ")
		)
	}

	func testStreamableCredentialsAreRequired() throws {
		let streamable = try XCTUnwrap(
			ClipUploadProvider.provider(id: ClipUploadProvider.streamableID)
		)
		XCTAssertThrowsError(
			try ClipUploader.authorizationHeader(for: streamable, credentials: nil)
		) { error in
			XCTAssertEqual(error as? ClipUploadError, .credentialsRequired)
		}
	}

	func testCredentialsCannotBeSentToAnonymousProvider() throws {
		let catbox = try XCTUnwrap(
			ClipUploadProvider.provider(id: ClipUploadProvider.catboxID)
		)
		let credentials = try StreamableCredentials(
			email: "player@example.com",
			password: "secret"
		)
		XCTAssertThrowsError(
			try ClipUploader.authorizationHeader(for: catbox, credentials: credentials)
		) { error in
			XCTAssertEqual(error as? ClipUploadError, .credentialsNotAllowed)
		}
	}

	func testStreamableCredentialsCannotBeSentToAnotherHost() throws {
		let provider = ClipUploadProvider(
			id: "unsafe",
			displayName: "Unsafe",
			summary: "Test",
			homepage: URL(string: "https://example.com")!,
			endpoint: URL(string: "https://example.com/upload")!,
			fileFieldName: "file",
			parser: .plainText,
			authentication: .streamableBasic
		)
		let credentials = try StreamableCredentials(
			email: "player@example.com",
			password: "never-send-this"
		)
		XCTAssertThrowsError(
			try ClipUploader.authorizationHeader(for: provider, credentials: credentials)
		) { error in
			XCTAssertEqual(error as? ClipUploadError, .unsafeAuthenticationTarget)
			XCTAssertFalse(error.localizedDescription.contains(credentials.password))
		}
	}

	// - Multipart helpers ---

	func testMimeTypeByExtension() {
		XCTAssertEqual(ClipUploader.mimeType(for: URL(fileURLWithPath: "/a/clip.mp4")), "video/mp4")
		XCTAssertEqual(
			ClipUploader.mimeType(for: URL(fileURLWithPath: "/a/clip.MOV")), "video/quicktime"
		)
		XCTAssertEqual(
			ClipUploader.mimeType(for: URL(fileURLWithPath: "/a/clip.bin")),
			"application/octet-stream"
		)
	}

	func testFilenameQuotesAreStrippedFromTheHeader() {
		let url = URL(fileURLWithPath: "/clips/my \"best\" play.mp4")
		let name = ClipUploader.safeFilename(for: url)
		XCTAssertFalse(name.contains("\""))
		XCTAssertTrue(name.hasSuffix(".mp4"))
	}

	// - Settings migration ---

	private func decodeSettings(_ json: String) throws -> AppSettings {
		try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
	}

	private let minimalSettings = #""replayDuration":30,"hotkey":{"keyCode":1,"modifiers":256}"#

	func testLegacyBooleansMigrateOntoTheProviderList() throws {
		let settings = try decodeSettings(
			"{\(minimalSettings),\"catboxEnabled\":true,\"litterboxEnabled\":true}"
		)
		XCTAssertEqual(
			settings.enabledUploadProviderIDs,
			[ClipUploadProvider.catboxID, ClipUploadProvider.litterboxID]
		)
	}

	func testLegacyBooleansSetToFalseMigrateToAnEmptyList() throws {
		let settings = try decodeSettings(
			"{\(minimalSettings),\"catboxEnabled\":false,\"litterboxEnabled\":false}"
		)
		XCTAssertEqual(settings.enabledUploadProviderIDs, [])
	}

	func testProviderListWinsOverLegacyBooleans() throws {
		let settings = try decodeSettings(
			"{\(minimalSettings),\"catboxEnabled\":true,\"enabledUploadProviderIDs\":[\"uguu\"]}"
		)
		XCTAssertEqual(settings.enabledUploadProviderIDs, ["uguu"])
	}

	func testDuplicateProviderIDsAreCollapsed() throws {
		let settings = try decodeSettings(
			"{\(minimalSettings),\"enabledUploadProviderIDs\":[\"uguu\",\"uguu\",\"catbox\"]}"
		)
		XCTAssertEqual(settings.enabledUploadProviderIDs, ["uguu", "catbox"])
	}

	func testUnknownProviderIDsSurviveARoundTrip() throws {
		// A host added by a newer build shouldn't be silently dropped on downgrade.
		let settings = try decodeSettings(
			"{\(minimalSettings),\"enabledUploadProviderIDs\":[\"from-the-future\"]}"
		)
		XCTAssertEqual(settings.enabledUploadProviderIDs, ["from-the-future"])

		let reencoded = try JSONEncoder().encode(settings)
		let reloaded = try JSONDecoder().decode(AppSettings.self, from: reencoded)
		XCTAssertEqual(reloaded.enabledUploadProviderIDs, ["from-the-future"])
	}
}
