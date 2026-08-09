@testable import Rewind
import XCTest

final class PostHogAnalyticsTests: XCTestCase {
	private final class URLProtocolStub: URLProtocol {
		private static let lock = NSLock()
		private nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

		static func setRequestHandler(_ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) {
			lock.lock()
			requestHandler = handler
			lock.unlock()
		}

		override class func canInit(with _: URLRequest) -> Bool {
			true
		}

		override class func canonicalRequest(for request: URLRequest) -> URLRequest {
			request
		}

		override func startLoading() {
			Self.lock.lock()
			let handler = Self.requestHandler
			Self.lock.unlock()

			do {
				let (response, data) = try XCTUnwrap(handler)(request)
				client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
				client?.urlProtocol(self, didLoad: data)
				client?.urlProtocolDidFinishLoading(self)
			} catch {
				client?.urlProtocol(self, didFailWithError: error)
			}
		}

		override func stopLoading() {}
	}

	func testCaptureSessionStartedSendsOnlyAllowlistedPrivateProperties() async throws {
		let suiteName = "PostHogAnalyticsTests.\(UUID().uuidString)"
		let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
		let sendableDefaults = UncheckedSendable(defaults)
		defer { sendableDefaults.value.removePersistentDomain(forName: suiteName) }

		let sessionConfiguration = URLSessionConfiguration.ephemeral
		sessionConfiguration.protocolClasses = [URLProtocolStub.self]
		let session = URLSession(configuration: sessionConfiguration)

		let requestExpectation = expectation(description: "PostHog request")
		URLProtocolStub.setRequestHandler { request in
			defer { requestExpectation.fulfill() }
			XCTAssertEqual(request.url?.absoluteString, "https://eu.i.posthog.com/batch/")
			XCTAssertEqual(request.httpMethod, "POST")

			let body = try self.requestBody(request)
			let root = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
			XCTAssertEqual(root["api_key"] as? String, "phc_test")

			let batch = try XCTUnwrap(root["batch"] as? [[String: Any]])
			let event = try XCTUnwrap(batch.first)
			XCTAssertEqual(event["event"] as? String, "capture_session_started")

			let properties = try XCTUnwrap(event["properties"] as? [String: Any])
			XCTAssertEqual(Set(properties.keys), Set([
				"distinct_id",
				"$process_person_profile",
				"$geoip_disable",
				"analytics_schema_version",
				"app_version",
				"app_build",
				"macos_version",
				"architecture",
				"capture_session_id",
				"reason",
				"replay_duration_bucket",
				"resolution",
				"quality",
				"frame_rate",
				"container",
				"audio_codec",
				"always_record_enabled",
				"microphone_enabled",
				"desktop_audio_enabled",
				"capture_target_prompt_enabled",
				"discord_rpc_enabled",
				"game_presence_enabled",
				"roblox_experience_enabled",
				"catbox_enabled",
				"litterbox_enabled",
				"launch_at_login_enabled",
				"beta_updates_enabled",
				"custom_output_directory",
			]))
			XCTAssertNotNil(try UUID(uuidString: XCTUnwrap(properties["distinct_id"] as? String)))
			XCTAssertNotNil(try UUID(uuidString: XCTUnwrap(properties["capture_session_id"] as? String)))
			XCTAssertEqual(properties["$process_person_profile"] as? Bool, false)
			XCTAssertEqual(properties["$geoip_disable"] as? Bool, true)
			XCTAssertEqual(properties["analytics_schema_version"] as? Int, 2)
			XCTAssertEqual(properties["reason"] as? String, "manual")
			XCTAssertEqual(properties["replay_duration_bucket"] as? String, "31-60")
			XCTAssertEqual(properties["quality"] as? String, "high")
			XCTAssertEqual(properties["frame_rate"] as? Int, 60)
			XCTAssertEqual(properties["always_record_enabled"] as? Bool, true)
			XCTAssertEqual(properties["microphone_enabled"] as? Bool, false)
			XCTAssertEqual(properties["custom_output_directory"] as? Bool, true)
			let response = try XCTUnwrap(
				try HTTPURLResponse(
					url: XCTUnwrap(request.url),
					statusCode: 200,
					httpVersion: nil,
					headerFields: nil
				)
			)
			return (response, Data())
		}

		let analytics = try PostHogAnalytics(
			enabled: true,
			userDefaults: sendableDefaults,
			configuration: .init(
				projectToken: "phc_test",
				host: XCTUnwrap(URL(string: "https://eu.i.posthog.com"))
			),
			session: session
		)

		await analytics.captureSessionStarted(reason: .manual, settings: settingsSnapshot)
		await fulfillment(of: [requestExpectation], timeout: 1)
	}

	func testOptOutDeletesAnonymousIdentifier() async throws {
		let suiteName = "PostHogAnalyticsTests.\(UUID().uuidString)"
		let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
		let sendableDefaults = UncheckedSendable(defaults)
		defer { sendableDefaults.value.removePersistentDomain(forName: suiteName) }
		sendableDefaults.value.set("anonymous-id", forKey: "analytics.posthog.anonymous-id.v1")

		let analytics = PostHogAnalytics(
			enabled: true,
			userDefaults: sendableDefaults,
			configuration: nil,
			session: nil
		)

		await analytics.setEnabled(false)

		XCTAssertNil(sendableDefaults.value.string(forKey: "analytics.posthog.anonymous-id.v1"))
	}

	func testEndingCaptureFlushesUsageBeforeSessionEnd() async throws {
		let suiteName = "PostHogAnalyticsTests.\(UUID().uuidString)"
		let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
		let sendableDefaults = UncheckedSendable(defaults)
		defer { sendableDefaults.value.removePersistentDomain(forName: suiteName) }

		let sessionConfiguration = URLSessionConfiguration.ephemeral
		sessionConfiguration.protocolClasses = [URLProtocolStub.self]
		let session = URLSession(configuration: sessionConfiguration)
		let eventsExpectation = expectation(description: "Capture lifecycle events")
		eventsExpectation.expectedFulfillmentCount = 3
		let lock = NSLock()
		var receivedEvents: [(String, [String: Any])] = []

		URLProtocolStub.setRequestHandler { request in
			let body = try self.requestBody(request)
			let root = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
			let batch = try XCTUnwrap(root["batch"] as? [[String: Any]])
			let event = try XCTUnwrap(batch.first)
			let name = try XCTUnwrap(event["event"] as? String)
			let properties = try XCTUnwrap(event["properties"] as? [String: Any])
			lock.withLock {
				receivedEvents.append((name, properties))
			}
			eventsExpectation.fulfill()
			return try (
				XCTUnwrap(try HTTPURLResponse(
					url: XCTUnwrap(request.url),
					statusCode: 200,
					httpVersion: nil,
					headerFields: nil
				)),
				Data()
			)
		}

		let analytics = try PostHogAnalytics(
			enabled: true,
			userDefaults: sendableDefaults,
			configuration: .init(
				projectToken: "phc_test",
				host: XCTUnwrap(URL(string: "https://eu.i.posthog.com"))
			),
			session: session
		)

		await analytics.captureSessionStarted(reason: .alwaysRecord, settings: settingsSnapshot)
		try await Task.sleep(nanoseconds: 1_100_000_000)
		await analytics.captureSessionEnded(reason: .manual)
		await fulfillment(of: [eventsExpectation], timeout: 2)

		let captured = lock.withLock { receivedEvents }
		XCTAssertEqual(captured.map(\.0), [
			"capture_session_started",
			"capture_usage_interval",
			"capture_session_ended",
		])
		XCTAssertEqual(captured[1].1["active_seconds"] as? Int, 1)
		XCTAssertEqual(captured[2].1["duration_seconds"] as? Int, 1)
		XCTAssertEqual(captured[2].1["reason"] as? String, "manual")
	}

	private func requestBody(_ request: URLRequest) throws -> Data {
		if let body = request.httpBody {
			return body
		}

		let stream = try XCTUnwrap(request.httpBodyStream)
		stream.open()
		defer { stream.close() }

		var data = Data()
		var buffer = [UInt8](repeating: 0, count: 1024)
		while stream.hasBytesAvailable {
			let count = stream.read(&buffer, maxLength: buffer.count)
			guard count >= 0 else {
				throw try XCTUnwrap(stream.streamError)
			}
			if count == 0 { break }
			data.append(buffer, count: count)
		}
		return data
	}

	private var settingsSnapshot: AnalyticsSettingsSnapshot {
		AnalyticsSettingsSnapshot(
			replayDurationBucket: "31-60",
			resolution: "native",
			quality: "high",
			frameRate: 60,
			container: "mp4",
			audioCodec: "aac",
			alwaysRecordEnabled: true,
			microphoneEnabled: false,
			desktopAudioEnabled: true,
			captureTargetPromptEnabled: true,
			discordRPCEnabled: true,
			gamePresenceEnabled: true,
			robloxExperienceEnabled: false,
			catboxEnabled: true,
			litterboxEnabled: false,
			launchAtLoginEnabled: true,
			betaUpdatesEnabled: false,
			customOutputDirectory: true
		)
	}
}
