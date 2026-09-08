@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Speech

enum VoiceCommand: Equatable {
	case saveReplay
}

enum VoiceCommandPermission: Equatable {
	case microphone
	case speechRecognition
}

enum VoiceCommandUnavailableReason: Equatable {
	case permissionDenied(VoiceCommandPermission)
	case permissionRestricted(VoiceCommandPermission)
	case onDeviceRecognitionUnavailable
	case recognitionServiceUnavailable
	case noAudioInput
	case audioEngineFailure
	case repeatedRecognitionFailures

	var userDescription: String {
		switch self {
		case .permissionDenied(.microphone):
			return "Microphone access was denied. Enable it in System Settings to use voice clipping."
		case .permissionDenied(.speechRecognition):
			return "Speech recognition access was denied. Enable it in System Settings to use voice clipping."
		case .permissionRestricted(.microphone):
			return "Microphone access is restricted on this Mac."
		case .permissionRestricted(.speechRecognition):
			return "Speech recognition is restricted on this Mac."
		case .onDeviceRecognitionUnavailable:
			return "On-device English speech recognition is unavailable. Rewind will not use network recognition."
		case .recognitionServiceUnavailable:
			return "On-device speech recognition is temporarily unavailable."
		case .noAudioInput:
			return "No usable microphone input is available."
		case .audioEngineFailure:
			return "The microphone could not be started for voice clipping."
		case .repeatedRecognitionFailures:
			return "Voice recognition repeatedly failed. Try disabling and re-enabling it."
		}
	}
}

enum VoiceCommandDetectorState: Equatable {
	case stopped
	case waitingForInstantReplay
	case requestingAuthorization
	case starting
	case listening
	case recovering(attempt: Int)
	case unavailable(VoiceCommandUnavailableReason)

	var userDescription: String {
		switch self {
		case .stopped:
			return "Off"
		case .waitingForInstantReplay:
			return "Ready when Instant Replay is recording."
		case .requestingAuthorization:
			return "Waiting for microphone and speech recognition permission."
		case .starting:
			return "Starting on-device voice recognition…"
		case .listening:
			return "Listening for \"Hey Rewind, clip that\""
		case let .recovering(attempt):
			return "Voice recognition is recovering (attempt \(attempt))…"
		case let .unavailable(reason):
			return reason.userDescription
		}
	}
}

/// Boundary between Rewind's clipping behavior and phrase recognition.
/// A future openWakeWord/Core ML service can implement this protocol without
/// knowing how replay clips are saved.
@MainActor
protocol VoiceCommandDetecting: AnyObject {
	var state: VoiceCommandDetectorState { get }
	var onCommand: ((VoiceCommand) -> Void)? { get set }
	var onStateChange: ((VoiceCommandDetectorState) -> Void)? { get set }

	func start() async -> VoiceCommandDetectorState
	func refresh() async -> VoiceCommandDetectorState
	func stop()
}

enum VoiceAuthorizationStatus: Equatable {
	case notDetermined
	case authorized
	case denied
	case restricted
}

enum VoiceRecognitionCapability: Equatable {
	case ready
	case recognizerUnavailable
	case onDeviceRecognitionUnavailable
	case temporarilyUnavailable
}

enum VoiceRecognitionEvent: Equatable {
	case transcription(String, isFinal: Bool)
	case completed
	case failed
}

enum VoiceRecognitionBackendError: Error, Equatable {
	case noAudioInput
	case audioEngineStartup
	case recognizerUnavailable
	case onDeviceRecognitionUnavailable
	case temporarilyUnavailable
}

/// Testable boundary around Apple Speech, TCC, and microphone capture.
@MainActor
protocol AppleSpeechRecognitionProviding: AnyObject {
	var onAvailabilityChange: ((Bool) -> Void)? { get set }

	func speechAuthorizationStatus() -> VoiceAuthorizationStatus
	func requestSpeechAuthorization() async -> VoiceAuthorizationStatus
	func microphoneAuthorizationStatus() -> VoiceAuthorizationStatus
	func requestMicrophoneAuthorization() async -> VoiceAuthorizationStatus
	func capability() -> VoiceRecognitionCapability
	func startRecognition(onEvent: @escaping (VoiceRecognitionEvent) -> Void) throws
	func stopRecognition()
}

struct VoiceCommandRecoveryPolicy: Equatable {
	let maximumAttempts: Int
	let initialDelay: Duration
	let maximumDelay: Duration
	let stableListeningPeriod: Duration

	static let `default` = VoiceCommandRecoveryPolicy(
		maximumAttempts: 5,
		initialDelay: .milliseconds(500),
		maximumDelay: .seconds(8),
		stableListeningPeriod: .seconds(10)
	)
}

/// Apple Speech implementation of the replaceable detector boundary.
/// All recognition requests require on-device processing.
@MainActor
final class AppleSpeechVoiceCommandDetector: VoiceCommandDetecting {
	static let commandPhrase = "hey rewind clip that"
	static let cooldown: Duration = .seconds(3)

	private enum Lifecycle {
		case stopped
		case starting
		case listening
		case recovering
		case unavailable
	}

	private(set) var state: VoiceCommandDetectorState = .stopped
	var onCommand: ((VoiceCommand) -> Void)?
	var onStateChange: ((VoiceCommandDetectorState) -> Void)?

	private let backend: any AppleSpeechRecognitionProviding
	private let recoveryPolicy: VoiceCommandRecoveryPolicy
	private let sleep: @Sendable (Duration) async throws -> Void
	private let clock = ContinuousClock()
	private var lifecycle: Lifecycle = .stopped
	private var wantsToRun = false
	private var operationGeneration: UInt64 = 0
	private var recognitionGeneration: UInt64 = 0
	private var recoveryAttempts = 0
	private var recoveryTask: Task<Void, Never>?
	private var stableListeningTask: Task<Void, Never>?
	private var lastTriggerInstant: ContinuousClock.Instant?

	init(
		backend: (any AppleSpeechRecognitionProviding)? = nil,
		recoveryPolicy: VoiceCommandRecoveryPolicy = .default,
		sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
			try await Task.sleep(for: duration)
		}
	) {
		self.backend = backend ?? SystemAppleSpeechRecognitionBackend()
		self.recoveryPolicy = recoveryPolicy
		self.sleep = sleep
		self.backend.onAvailabilityChange = { [weak self] available in
			self?.handleAvailabilityChange(available)
		}
	}

	func start() async -> VoiceCommandDetectorState {
		wantsToRun = true
		switch lifecycle {
		case .starting, .listening, .recovering:
			return state
		case .stopped, .unavailable:
			return await beginNewOperation()
		}
	}

	func refresh() async -> VoiceCommandDetectorState {
		guard wantsToRun else { return state }
		return await beginNewOperation()
	}

	func stop() {
		wantsToRun = false
		operationGeneration &+= 1
		recognitionGeneration &+= 1
		cancelPendingTasks()
		backend.stopRecognition()
		lifecycle = .stopped
		recoveryAttempts = 0
		publish(.stopped)
	}

	private func beginNewOperation() async -> VoiceCommandDetectorState {
		operationGeneration &+= 1
		let generation = operationGeneration
		recognitionGeneration &+= 1
		cancelPendingTasks()
		backend.stopRecognition()
		recoveryAttempts = 0
		lifecycle = .starting
		return await establishListening(operationGeneration: generation)
	}

	private func establishListening(operationGeneration generation: UInt64) async
		-> VoiceCommandDetectorState
	{
		guard operationIsCurrent(generation) else { return state }

		var speechStatus = backend.speechAuthorizationStatus()
		if speechStatus == .notDetermined {
			publish(.requestingAuthorization)
			speechStatus = await backend.requestSpeechAuthorization()
			guard operationIsCurrent(generation) else { return state }
		}
		guard speechStatus == .authorized else {
			return finishPermissionFailure(speechStatus, permission: .speechRecognition)
		}

		var microphoneStatus = backend.microphoneAuthorizationStatus()
		if microphoneStatus == .notDetermined {
			publish(.requestingAuthorization)
			microphoneStatus = await backend.requestMicrophoneAuthorization()
			guard operationIsCurrent(generation) else { return state }
		}
		guard microphoneStatus == .authorized else {
			return finishPermissionFailure(microphoneStatus, permission: .microphone)
		}

		guard operationIsCurrent(generation) else { return state }
		switch backend.capability() {
		case .ready:
			break
		case .recognizerUnavailable:
			return finishUnavailable(.recognitionServiceUnavailable)
		case .onDeviceRecognitionUnavailable:
			return finishUnavailable(.onDeviceRecognitionUnavailable)
		case .temporarilyUnavailable:
			scheduleRecovery(
				operationGeneration: generation,
				exhaustedReason: .recognitionServiceUnavailable
			)
			return state
		}

		publish(.starting)
		do {
			try startRecognitionSession(operationGeneration: generation)
			return state
		} catch let error as VoiceRecognitionBackendError {
			switch error {
			case .noAudioInput:
				return finishUnavailable(.noAudioInput)
			case .audioEngineStartup:
				scheduleRecovery(
					operationGeneration: generation,
					exhaustedReason: .audioEngineFailure
				)
				return state
			case .recognizerUnavailable, .temporarilyUnavailable:
				scheduleRecovery(
					operationGeneration: generation,
					exhaustedReason: .recognitionServiceUnavailable
				)
				return state
			case .onDeviceRecognitionUnavailable:
				return finishUnavailable(.onDeviceRecognitionUnavailable)
			}
		} catch {
			scheduleRecovery(
				operationGeneration: generation,
				exhaustedReason: .repeatedRecognitionFailures
			)
			return state
		}
	}

	private func startRecognitionSession(operationGeneration generation: UInt64) throws {
		guard operationIsCurrent(generation) else { return }
		recognitionGeneration &+= 1
		let sessionGeneration = recognitionGeneration
		try backend.startRecognition { [weak self] event in
			self?.handleRecognitionEvent(
				event,
				operationGeneration: generation,
				recognitionGeneration: sessionGeneration
			)
		}
		guard operationIsCurrent(generation), recognitionGeneration == sessionGeneration else {
			backend.stopRecognition()
			return
		}
		lifecycle = .listening
		publish(.listening)
		scheduleStableListeningReset(operationGeneration: generation)
	}

	private func handleRecognitionEvent(
		_ event: VoiceRecognitionEvent,
		operationGeneration: UInt64,
		recognitionGeneration: UInt64
	) {
		guard operationIsCurrent(operationGeneration),
		      lifecycle == .listening,
		      self.recognitionGeneration == recognitionGeneration
		else { return }

		switch event {
		case let .transcription(transcript, _):
			guard Self.matchesCommand(in: transcript) else { return }
			let now = clock.now
			if lastTriggerInstant.map({ $0.duration(to: now) >= Self.cooldown }) ?? true {
				lastTriggerInstant = now
				onCommand?(.saveReplay)
			}
			rotateRecognitionTask(operationGeneration: operationGeneration)
		case .completed:
			rotateRecognitionTask(operationGeneration: operationGeneration)
		case .failed:
			scheduleRecovery(
				operationGeneration: operationGeneration,
				exhaustedReason: .repeatedRecognitionFailures
			)
		}
	}

	private func rotateRecognitionTask(operationGeneration generation: UInt64) {
		guard operationIsCurrent(generation) else { return }
		backend.stopRecognition()
		do {
			try startRecognitionSession(operationGeneration: generation)
		} catch let error as VoiceRecognitionBackendError {
			switch error {
			case .noAudioInput:
				_ = finishUnavailable(.noAudioInput)
			case .onDeviceRecognitionUnavailable:
				_ = finishUnavailable(.onDeviceRecognitionUnavailable)
			case .audioEngineStartup:
				scheduleRecovery(
					operationGeneration: generation,
					exhaustedReason: .audioEngineFailure
				)
			case .recognizerUnavailable, .temporarilyUnavailable:
				scheduleRecovery(
					operationGeneration: generation,
					exhaustedReason: .recognitionServiceUnavailable
				)
			}
		} catch {
			scheduleRecovery(
				operationGeneration: generation,
				exhaustedReason: .repeatedRecognitionFailures
			)
		}
	}

	private func scheduleRecovery(
		operationGeneration generation: UInt64,
		exhaustedReason: VoiceCommandUnavailableReason
	) {
		guard operationIsCurrent(generation) else { return }
		backend.stopRecognition()
		recognitionGeneration &+= 1
		stableListeningTask?.cancel()
		stableListeningTask = nil
		recoveryTask?.cancel()

		guard recoveryAttempts < recoveryPolicy.maximumAttempts else {
			_ = finishUnavailable(exhaustedReason)
			return
		}

		recoveryAttempts += 1
		let attempt = recoveryAttempts
		lifecycle = .recovering
		publish(.recovering(attempt: attempt))
		let delay = recoveryDelay(forAttempt: attempt)
		recoveryTask = Task { @MainActor [weak self, sleep] in
			do {
				try await sleep(delay)
			} catch {
				return
			}
			guard let self,
			      !Task.isCancelled,
			      self.operationIsCurrent(generation)
			else { return }
			self.recoveryTask = nil
			_ = await self.establishListening(operationGeneration: generation)
		}
	}

	private func scheduleStableListeningReset(operationGeneration generation: UInt64) {
		guard recoveryAttempts > 0, stableListeningTask == nil else { return }
		let delay = recoveryPolicy.stableListeningPeriod
		stableListeningTask = Task { @MainActor [weak self, sleep] in
			do {
				try await sleep(delay)
			} catch {
				return
			}
			guard let self,
			      !Task.isCancelled,
			      self.operationIsCurrent(generation),
			      self.lifecycle == .listening
			else { return }
			self.recoveryAttempts = 0
			self.stableListeningTask = nil
		}
	}

	private func recoveryDelay(forAttempt attempt: Int) -> Duration {
		let shift = max(0, min(attempt - 1, 20))
		let multiplier = 1 << shift
		let proposed = recoveryPolicy.initialDelay * multiplier
		return min(proposed, recoveryPolicy.maximumDelay)
	}

	private func handleAvailabilityChange(_ available: Bool) {
		guard wantsToRun else { return }
		if available {
			Task { @MainActor [weak self] in
				_ = await self?.refresh()
			}
			return
		}

		operationGeneration &+= 1
		let generation = operationGeneration
		cancelPendingTasks()
		lifecycle = .recovering
		scheduleRecovery(
			operationGeneration: generation,
			exhaustedReason: .recognitionServiceUnavailable
		)
	}

	private func finishPermissionFailure(
		_ status: VoiceAuthorizationStatus,
		permission: VoiceCommandPermission
	) -> VoiceCommandDetectorState {
		switch status {
		case .denied, .notDetermined:
			return finishUnavailable(.permissionDenied(permission))
		case .restricted:
			return finishUnavailable(.permissionRestricted(permission))
		case .authorized:
			return finishUnavailable(.recognitionServiceUnavailable)
		}
	}

	private func finishUnavailable(_ reason: VoiceCommandUnavailableReason)
		-> VoiceCommandDetectorState
	{
		backend.stopRecognition()
		recognitionGeneration &+= 1
		cancelPendingTasks()
		lifecycle = .unavailable
		publish(.unavailable(reason))
		return state
	}

	private func cancelPendingTasks() {
		recoveryTask?.cancel()
		recoveryTask = nil
		stableListeningTask?.cancel()
		stableListeningTask = nil
	}

	private func operationIsCurrent(_ generation: UInt64) -> Bool {
		wantsToRun && operationGeneration == generation
	}

	private func publish(_ newState: VoiceCommandDetectorState) {
		state = newState
		onStateChange?(newState)
	}

	static func matchesCommand(in transcript: String) -> Bool {
		let words = transcript
			.lowercased()
			.components(separatedBy: CharacterSet.alphanumerics.inverted)
			.filter { !$0.isEmpty }
		guard words.count >= 4 else { return false }
		return Array(words.suffix(4)).joined(separator: " ") == commandPhrase
	}
}

@MainActor
final class SystemAppleSpeechRecognitionBackend: NSObject, AppleSpeechRecognitionProviding,
	SFSpeechRecognizerDelegate
{
	var onAvailabilityChange: ((Bool) -> Void)?

	private var recognizer: SFSpeechRecognizer?
	private let audioEngine = AVAudioEngine()
	private let requestSlot = LockedRequestSlot<SFSpeechAudioBufferRecognitionRequest>()
	private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
	private var recognitionTask: SFSpeechRecognitionTask?
	private var hasInstalledTap = false

	func speechAuthorizationStatus() -> VoiceAuthorizationStatus {
		Self.authorizationStatus(from: SFSpeechRecognizer.authorizationStatus())
	}

	func requestSpeechAuthorization() async -> VoiceAuthorizationStatus {
		let status = await withCheckedContinuation { continuation in
			SFSpeechRecognizer.requestAuthorization { status in
				continuation.resume(returning: status)
			}
		}
		return Self.authorizationStatus(from: status)
	}

	func microphoneAuthorizationStatus() -> VoiceAuthorizationStatus {
		switch AVCaptureDevice.authorizationStatus(for: .audio) {
		case .notDetermined: return .notDetermined
		case .authorized: return .authorized
		case .denied: return .denied
		case .restricted: return .restricted
		@unknown default: return .restricted
		}
	}

	func requestMicrophoneAuthorization() async -> VoiceAuthorizationStatus {
		let granted = await AVCaptureDevice.requestAccess(for: .audio)
		return granted ? .authorized : microphoneAuthorizationStatus()
	}

	func capability() -> VoiceRecognitionCapability {
		guard let recognizer = resolveRecognizer() else { return .recognizerUnavailable }
		guard recognizer.supportsOnDeviceRecognition else {
			return .onDeviceRecognitionUnavailable
		}
		return recognizer.isAvailable ? .ready : .temporarilyUnavailable
	}

	func startRecognition(onEvent: @escaping (VoiceRecognitionEvent) -> Void) throws {
		stopRecognition()
		guard let recognizer = resolveRecognizer() else {
			throw VoiceRecognitionBackendError.recognizerUnavailable
		}
		guard recognizer.supportsOnDeviceRecognition else {
			throw VoiceRecognitionBackendError.onDeviceRecognitionUnavailable
		}
		guard recognizer.isAvailable else {
			throw VoiceRecognitionBackendError.temporarilyUnavailable
		}

		try startAudioEngine()
		let request = SFSpeechAudioBufferRecognitionRequest()
		request.requiresOnDeviceRecognition = true
		request.shouldReportPartialResults = true
		request.taskHint = .confirmation
		request.contextualStrings = ["Hey Rewind, clip that"]
		recognitionRequest = request
		requestSlot.attach(request)

		recognitionTask = recognizer.recognitionTask(with: request) { result, error in
			let transcript = result?.bestTranscription.formattedString
			let isFinal = result?.isFinal ?? false
			let didFail = error != nil
			Task { @MainActor in
				if let transcript {
					onEvent(.transcription(transcript, isFinal: isFinal))
				}
				if didFail {
					onEvent(.failed)
				} else if isFinal {
					onEvent(.completed)
				}
			}
		}
	}

	func stopRecognition() {
		// Detach under the same lock used by the audio callback. Once this
		// returns, every in-flight append is complete and no future append can
		// obtain the detached request.
		let detachedRequest = requestSlot.detach()
		let detachedTask = recognitionTask
		recognitionRequest = nil
		recognitionTask = nil

		// Framework calls happen after detachment and outside the lock.
		detachedRequest?.endAudio()
		detachedTask?.cancel()
		stopAudioEngine()
	}

	nonisolated func speechRecognizer(
		_: SFSpeechRecognizer,
		availabilityDidChange available: Bool
	) {
		Task { @MainActor [weak self] in
			self?.onAvailabilityChange?(available)
		}
	}

	private func resolveRecognizer() -> SFSpeechRecognizer? {
		if let recognizer { return recognizer }
		guard let created = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else {
			return nil
		}
		created.delegate = self
		recognizer = created
		return created
	}

	private func startAudioEngine() throws {
		let inputNode = audioEngine.inputNode
		let format = inputNode.outputFormat(forBus: 0)
		guard format.sampleRate > 0, format.channelCount > 0 else {
			throw VoiceRecognitionBackendError.noAudioInput
		}

		if !hasInstalledTap {
			let slot = requestSlot
			inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
				slot.withValue { request in
					request.append(buffer)
				}
			}
			hasInstalledTap = true
		}

		guard !audioEngine.isRunning else { return }
		audioEngine.prepare()
		do {
			try audioEngine.start()
		} catch {
			stopAudioEngine()
			throw VoiceRecognitionBackendError.audioEngineStartup
		}
	}

	private func stopAudioEngine() {
		audioEngine.stop()
		if hasInstalledTap {
			audioEngine.inputNode.removeTap(onBus: 0)
			hasInstalledTap = false
		}
	}

	private static func authorizationStatus(
		from status: SFSpeechRecognizerAuthorizationStatus
	) -> VoiceAuthorizationStatus {
		switch status {
		case .notDetermined: return .notDetermined
		case .authorized: return .authorized
		case .denied: return .denied
		case .restricted: return .restricted
		@unknown default: return .restricted
		}
	}
}

/// Lock-backed ownership slot used by the real-time audio callback. Detaching
/// waits for any current access to finish and prevents all future access.
final class LockedRequestSlot<Value: AnyObject>: @unchecked Sendable {
	private let lock = NSLock()
	private var value: Value?

	func attach(_ value: Value) {
		lock.withLock {
			self.value = value
		}
	}

	func detach() -> Value? {
		lock.withLock {
			let detached = value
			value = nil
			return detached
		}
	}

	func withValue(_ body: (Value) -> Void) {
		lock.withLock {
			guard let value else { return }
			body(value)
		}
	}
}
