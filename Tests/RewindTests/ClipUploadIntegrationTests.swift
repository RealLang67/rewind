@testable import Rewind
import XCTest

/// Live checks against the real upload hosts. Skipped unless asked for, since they
/// need network and publish a small file to each service:
///
///     REWIND_UPLOAD_INTEGRATION=1 swift test --filter ClipUploadIntegrationTests
///
/// Run this when someone reports that a provider stopped working — these hosts do
/// disappear (Pomf and oshi.at both went away, Pixeldrain dropped anonymous uploads).
final class ClipUploadIntegrationTests: XCTestCase {
	private var isEnabled: Bool {
		ProcessInfo.processInfo.environment["REWIND_UPLOAD_INTEGRATION"] == "1"
	}

	private func makeSampleClip() throws -> URL {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("rewind-integration-\(UUID().uuidString).mp4")
		try Data(repeating: 0x21, count: 4_096).write(to: url)
		return url
	}

	func testEveryAnonymousProviderReturnsAUsableLink() async throws {
		try XCTSkipUnless(isEnabled, "Set REWIND_UPLOAD_INTEGRATION=1 to run live upload checks")

		let clipURL = try makeSampleClip()
		defer { try? FileManager.default.removeItem(at: clipURL) }

		var failures: [String] = []
		for provider in ClipUploadProvider.providers where provider.authentication == .none {
			do {
				let link = try await ClipUploader.shared.upload(clipAt: clipURL, provider: provider)
				XCTAssertEqual(link.scheme, "https", "\(provider.id) returned a non-https link")
				print("✅ \(provider.id): \(link.absoluteString)")
			} catch {
				failures.append("\(provider.id): \(error.localizedDescription)")
				print("❌ \(provider.id): \(error.localizedDescription)")
			}
		}

		XCTAssertTrue(failures.isEmpty, "Providers failed:\n" + failures.joined(separator: "\n"))
	}

	func testStreamableReturnsAUsableLink() async throws {
		try XCTSkipUnless(isEnabled, "Set REWIND_UPLOAD_INTEGRATION=1 to run live upload checks")
		let environment = ProcessInfo.processInfo.environment
		guard let email = environment["REWIND_STREAMABLE_EMAIL"],
		      let password = environment["REWIND_STREAMABLE_PASSWORD"]
		else {
			throw XCTSkip(
				"Set REWIND_STREAMABLE_EMAIL and REWIND_STREAMABLE_PASSWORD to test Streamable"
			)
		}

		let provider = try XCTUnwrap(
			ClipUploadProvider.provider(id: ClipUploadProvider.streamableID)
		)
		let credentials = try StreamableCredentials(email: email, password: password)
		let clipURL = try makeSampleClip()
		defer { try? FileManager.default.removeItem(at: clipURL) }

		let link = try await ClipUploader.shared.upload(
			clipAt: clipURL,
			provider: provider,
			credentials: credentials
		)
		XCTAssertEqual(link.scheme, "https")
		XCTAssertEqual(link.host, "streamable.com")
		print("✅ streamable: \(link.absoluteString)")
	}
}
