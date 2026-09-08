@testable import Rewind
import XCTest

@MainActor
final class VoiceCommandDetectorTests: XCTestCase {
	func testMatchesExactCommandIgnoringCaseAndPunctuation() {
		XCTAssertTrue(AppleSpeechVoiceCommandDetector.matchesCommand(
			in: "Hey, Rewind — clip that!"
		))
	}

	func testMatchesCommandOnlyWhenItEndsTheTranscript() {
		XCTAssertTrue(AppleSpeechVoiceCommandDetector.matchesCommand(
			in: "nice play hey rewind clip that"
		))
		XCTAssertFalse(AppleSpeechVoiceCommandDetector.matchesCommand(
			in: "hey rewind clip that please"
		))
	}

	func testDoesNotMatchNearPhrases() {
		XCTAssertFalse(AppleSpeechVoiceCommandDetector.matchesCommand(
			in: "hey rewind save that"
		))
		XCTAssertFalse(AppleSpeechVoiceCommandDetector.matchesCommand(
			in: "rewind clip that"
		))
	}

	func testRepeatedStartWhileAuthorizationIsPendingIsIdempotent() async {
		let backend = MockVoiceRecognitionBackend()
		backend.speechStatus = .notDetermined
		let detector = AppleSpeechVoiceCommandDetector(backend: backend)

		let firstStart = Task { await detector.start() }
		await waitUntil { backend.pendingSpeechAuthorizationCount == 1 }

		let secondState = await detector.start()
		XCTAssertEqual(secondState, .requestingAuthorization)
		XCTAssertEqual(backend.pendingSpeechAuthorizationCount, 1)
		XCTAssertEqual(backend.startCount, 0)

		backend.resolveNextSpeechAuthorization(with: .authorized)
		_ = await firstStart.value
		XCTAssertEqual(detector.state, .listening)
		XCTAssertEqual(backend.startCount, 1)
	}

	func testStopInvalidatesAuthorizationRequestInFlight() async {
		let backend = MockVoiceRecognitionBackend()
		backend.speechStatus = .notDetermined
		let detector = AppleSpeechVoiceCommandDetector(backend: backend)
		let start = Task { await detector.start() }
		await waitUntil { backend.pendingSpeechAuthorizationCount == 1 }

		detector.stop()
		backend.resolveNextSpeechAuthorization(with: .authorized)
		_ = await start.value

		XCTAssertEqual(detector.state, .stopped)
		XCTAssertEqual(backend.startCount, 0)
	}

	func testStaleStartCannotReplaceANewerStart() async {
		let backend = MockVoiceRecognitionBackend()
		backend.speechStatus = .notDetermined
		let detector = AppleSpeechVoiceCommandDetector(backend: backend)
		let oldStart = Task { await detector.start() }
		await waitUntil { backend.pendingSpeechAuthorizationCount == 1 }

		detector.stop()
		let newStart = Task { await detector.start() }
		await waitUntil { backend.pendingSpeechAuthorizationCount == 2 }

		backend.resolveNextSpeechAuthorization(with: .authorized)
		_ = await oldStart.value
		XCTAssertEqual(backend.startCount, 0)

		backend.resolveNextSpeechAuthorization(with: .authorized)
		_ = await newStart.value
		XCTAssertEqual(detector.state, .listening)
		XCTAssertEqual(backend.startCount, 1)
	}

	func testRepeatedStopAndStartConvergesOnLatestState() async {
		let backend = MockVoiceRecognitionBackend()
		let detector = AppleSpeechVoiceCommandDetector(backend: backend)

		let firstStartedState = await detector.start()
		XCTAssertEqual(firstStartedState, .listening)
		detector.stop()
		detector.stop()
		XCTAssertEqual(detector.state, .stopped)
		let restartedState = await detector.start()
		XCTAssertEqual(restartedState, .listening)

		XCTAssertEqual(backend.startCount, 2)
		XCTAssertGreaterThanOrEqual(backend.stopCount, 3)
	}

	func testRecoveryUsesBoundedRetriesAndStopsAfterExhaustion() async {
		let backend = MockVoiceRecognitionBackend()
		let policy = VoiceCommandRecoveryPolicy(
			maximumAttempts: 2,
			initialDelay: .zero,
			maximumDelay: .zero,
			stableListeningPeriod: .seconds(3_600)
		)
		let detector = AppleSpeechVoiceCommandDetector(
			backend: backend,
			recoveryPolicy: policy
		)
		_ = await detector.start()

		backend.emit(.failed)
		await waitUntil { detector.state == .listening && backend.startCount == 2 }
		backend.emit(.failed)
		await waitUntil { detector.state == .listening && backend.startCount == 3 }
		backend.emit(.failed)

		XCTAssertEqual(detector.state, .unavailable(.repeatedRecognitionFailures))
		XCTAssertEqual(backend.startCount, 3)
	}

	func testPermanentPermissionFailureDoesNotRetry() async {
		let backend = MockVoiceRecognitionBackend()
		backend.speechStatus = .denied
		let detector = AppleSpeechVoiceCommandDetector(backend: backend)

		let state = await detector.start()

		XCTAssertEqual(state, .unavailable(.permissionDenied(.speechRecognition)))
		XCTAssertEqual(backend.startCount, 0)
	}

	func testAudioFailuresHaveDistinctUnavailableReasons() async {
		let noInputBackend = MockVoiceRecognitionBackend()
		noInputBackend.startErrors = [.noAudioInput]
		let noInputDetector = AppleSpeechVoiceCommandDetector(backend: noInputBackend)
		let noInputState = await noInputDetector.start()
		XCTAssertEqual(noInputState, .unavailable(.noAudioInput))

		let engineBackend = MockVoiceRecognitionBackend()
		engineBackend.startErrors = [.audioEngineStartup]
		let noRetryPolicy = VoiceCommandRecoveryPolicy(
			maximumAttempts: 0,
			initialDelay: .zero,
			maximumDelay: .zero,
			stableListeningPeriod: .seconds(10)
		)
		let engineDetector = AppleSpeechVoiceCommandDetector(
			backend: engineBackend,
			recoveryPolicy: noRetryPolicy
		)
		let engineState = await engineDetector.start()
		XCTAssertEqual(engineState, .unavailable(.audioEngineFailure))
	}

	func testOnDeviceRecognitionRequirementIsReported() async {
		let backend = MockVoiceRecognitionBackend()
		backend.currentCapability = .onDeviceRecognitionUnavailable
		let detector = AppleSpeechVoiceCommandDetector(backend: backend)

		let state = await detector.start()

		XCTAssertEqual(state, .unavailable(.onDeviceRecognitionUnavailable))
		XCTAssertEqual(backend.startCount, 0)
	}

	func testAvailabilityReturningRestartsOnlyWhileWanted() async {
		let backend = MockVoiceRecognitionBackend()
		let detector = AppleSpeechVoiceCommandDetector(backend: backend)
		_ = await detector.start()

		backend.setAvailability(false)
		XCTAssertEqual(detector.state, .recovering(attempt: 1))
		backend.setAvailability(true)
		await waitUntil { detector.state == .listening && backend.startCount == 2 }

		detector.stop()
		backend.setAvailability(false)
		backend.setAvailability(true)
		await Task.yield()
		XCTAssertEqual(detector.state, .stopped)
		XCTAssertEqual(backend.startCount, 2)
	}

	func testCallbacksFromStaleRecognitionGenerationAreIgnored() async {
		let backend = MockVoiceRecognitionBackend()
		let detector = AppleSpeechVoiceCommandDetector(backend: backend)
		var commandCount = 0
		detector.onCommand = { _ in commandCount += 1 }
		_ = await detector.start()
		let staleHandlerIndex = backend.latestHandlerIndex

		detector.stop()
		_ = await detector.start()
		backend.emit(.transcription("Hey Rewind, clip that", isFinal: false), at: staleHandlerIndex)
		XCTAssertEqual(commandCount, 0)

		backend.emit(.transcription("Hey Rewind, clip that", isFinal: false))
		XCTAssertEqual(commandCount, 1)
	}

	func testMissingRecognizerDoesNotReportListeningAndCanBeRetried() async {
		let backend = MockVoiceRecognitionBackend()
		backend.currentCapability = .recognizerUnavailable
		let detector = AppleSpeechVoiceCommandDetector(backend: backend)

		let unavailableState = await detector.start()
		XCTAssertEqual(unavailableState, .unavailable(.recognitionServiceUnavailable))
		XCTAssertEqual(backend.startCount, 0)

		backend.currentCapability = .ready
		let retriedState = await detector.start()
		XCTAssertEqual(retriedState, .listening)
		XCTAssertEqual(backend.startCount, 1)
	}

	func testRequestSlotDetachesBeforeAnyLaterAppendCanObserveRequest() {
		let slot = LockedRequestSlot<RequestToken>()
		let request = RequestToken()
		var observedAppendCount = 0
		slot.attach(request)
		slot.withValue { _ in observedAppendCount += 1 }

		XCTAssertTrue(slot.detach() === request)
		slot.withValue { _ in observedAppendCount += 1 }

		XCTAssertEqual(observedAppendCount, 1)
		XCTAssertNil(slot.detach())
	}

	private func waitUntil(
		_ condition: @MainActor () -> Bool,
		file: StaticString = #filePath,
		line: UInt = #line
	) async {
		for _ in 0 ..< 200 {
			if condition() { return }
			await Task.yield()
		}
		XCTFail("Timed out waiting for asynchronous state", file: file, line: line)
	}
}

private final class RequestToken {}

@MainActor
private final class MockVoiceRecognitionBackend: AppleSpeechRecognitionProviding {
	var onAvailabilityChange: ((Bool) -> Void)?
	var speechStatus: VoiceAuthorizationStatus = .authorized
	var microphoneStatus: VoiceAuthorizationStatus = .authorized
	var currentCapability: VoiceRecognitionCapability = .ready
	var startErrors: [VoiceRecognitionBackendError] = []
	private(set) var startCount = 0
	private(set) var stopCount = 0
	private var speechAuthorizationContinuations:
		[CheckedContinuation<VoiceAuthorizationStatus, Never>] = []
	private var eventHandlers: [(VoiceRecognitionEvent) -> Void] = []

	var pendingSpeechAuthorizationCount: Int {
		speechAuthorizationContinuations.count
	}

	var latestHandlerIndex: Int {
		eventHandlers.index(before: eventHandlers.endIndex)
	}

	func speechAuthorizationStatus() -> VoiceAuthorizationStatus {
		speechStatus
	}

	func requestSpeechAuthorization() async -> VoiceAuthorizationStatus {
		await withCheckedContinuation { continuation in
			speechAuthorizationContinuations.append(continuation)
		}
	}

	func microphoneAuthorizationStatus() -> VoiceAuthorizationStatus {
		microphoneStatus
	}

	func requestMicrophoneAuthorization() async -> VoiceAuthorizationStatus {
		microphoneStatus
	}

	func capability() -> VoiceRecognitionCapability {
		currentCapability
	}

	func startRecognition(onEvent: @escaping (VoiceRecognitionEvent) -> Void) throws {
		startCount += 1
		if !startErrors.isEmpty {
			throw startErrors.removeFirst()
		}
		eventHandlers.append(onEvent)
	}

	func stopRecognition() {
		stopCount += 1
	}

	func resolveNextSpeechAuthorization(with status: VoiceAuthorizationStatus) {
		speechStatus = status
		let continuation = speechAuthorizationContinuations.removeFirst()
		continuation.resume(returning: status)
	}

	func setAvailability(_ available: Bool) {
		currentCapability = available ? .ready : .temporarilyUnavailable
		onAvailabilityChange?(available)
	}

	func emit(_ event: VoiceRecognitionEvent, at index: Int? = nil) {
		let resolvedIndex = index ?? latestHandlerIndex
		eventHandlers[resolvedIndex](event)
	}
}
