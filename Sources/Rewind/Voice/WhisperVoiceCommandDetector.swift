@preconcurrency import AVFoundation
import Foundation

/// Offline phrase detector backed by the Universal 2 `whisper-cli` helper
/// bundled by `scripts/build-whisper-helper.sh`.
@MainActor
final class WhisperVoiceCommandDetector: VoiceCommandDetecting {
	private static let cooldown: Duration = .seconds(3)
	private let engine = AVAudioEngine()
	private let accumulator = WhisperAudioAccumulator()
	private let clock = ContinuousClock()
	private var lastTrigger: ContinuousClock.Instant?
	private var isRunning = false
	private var hasInstalledTap = false
	private var transcriptionTask: Task<Void, Never>?

	private(set) var state: VoiceCommandDetectorState = .stopped
	var onCommand: ((VoiceCommand) -> Void)?
	var onStateChange: ((VoiceCommandDetectorState) -> Void)?

	func start() async -> VoiceCommandDetectorState {
		guard !isRunning else { return state }
		guard let runtime = Self.runtimeURLs() else {
			return publish(.unavailable(.whisperRuntimeUnavailable))
		}
		let access = AVCaptureDevice.authorizationStatus(for: .audio)
		if access == .notDetermined {
			publish(.requestingAuthorization)
			guard await AVCaptureDevice.requestAccess(for: .audio) else {
				return publish(.unavailable(.permissionDenied(.microphone)))
			}
		} else if access != .authorized {
			return publish(.unavailable(access == .restricted
				? .permissionRestricted(.microphone)
				: .permissionDenied(.microphone)))
		}

		let node = engine.inputNode
		let format = node.outputFormat(forBus: 0)
		guard format.sampleRate > 0, format.channelCount > 0 else {
			return publish(.unavailable(.noAudioInput))
		}
		accumulator.configure(sampleRate: format.sampleRate) { [weak self, runtime] samples in
			Task { @MainActor [weak self] in
				self?.transcribe(samples, runtime: runtime)
			}
		}
		let accumulator = accumulator
		let tap: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { buffer, _ in
			accumulator.append(buffer)
		}
		node.installTap(onBus: 0, bufferSize: 1_024, format: format, block: tap)
		hasInstalledTap = true
		do {
			engine.prepare()
			try engine.start()
			isRunning = true
			return publish(.listening)
		} catch {
			stop()
			return publish(.unavailable(.audioEngineFailure))
		}
	}

	func refresh() async -> VoiceCommandDetectorState {
		stop()
		return await start()
	}

	func stop() {
		isRunning = false
		transcriptionTask?.cancel()
		transcriptionTask = nil
		engine.stop()
		if hasInstalledTap {
			engine.inputNode.removeTap(onBus: 0)
			hasInstalledTap = false
		}
		accumulator.reset()
		_ = publish(.stopped)
	}

	private func transcribe(_ segment: WhisperAudioSegment, runtime: WhisperRuntimeURLs) {
		guard isRunning, transcriptionTask == nil else { return }
		transcriptionTask = Task { [weak self] in
			let transcript = await Task.detached(priority: .utility) {
				WhisperCLI.transcribe(segment: segment, runtime: runtime)
			}.value
			guard let self, !Task.isCancelled else { return }
			self.transcriptionTask = nil
			guard let transcript, AppleSpeechVoiceCommandDetector.matchesCommand(in: transcript) else { return }
			let now = self.clock.now
			guard self.lastTrigger.map({ $0.duration(to: now) >= Self.cooldown }) ?? true else { return }
			self.lastTrigger = now
			self.onCommand?(.saveReplay)
		}
	}

	@discardableResult
	private func publish(_ state: VoiceCommandDetectorState) -> VoiceCommandDetectorState {
		self.state = state
		onStateChange?(state)
		return state
	}

	private static func runtimeURLs() -> WhisperRuntimeURLs? {
		guard let root = Bundle.main.resourceURL?.appendingPathComponent("Whisper"),
			FileManager.default.isExecutableFile(atPath: root.appendingPathComponent("whisper-cli").path),
			FileManager.default.fileExists(atPath: root.appendingPathComponent("ggml-tiny.en.bin").path)
		else { return nil }
		return WhisperRuntimeURLs(helper: root.appendingPathComponent("whisper-cli"), model: root.appendingPathComponent("ggml-tiny.en.bin"))
	}
}

private struct WhisperRuntimeURLs: Sendable {
	let helper: URL
	let model: URL
}

private struct WhisperAudioSegment: Sendable {
	let samples: [Float]
	let sampleRate: Double
}

private final class WhisperAudioAccumulator: @unchecked Sendable {
	private let lock = NSLock()
	private var sampleRate = 0.0
	private var samples: [Float] = []
	private var peak: Float = 0
	private var onSegment: (@Sendable (WhisperAudioSegment) -> Void)?
	private let segmentLength = 2.5
	private let activationPeak: Float = 0.015

	func configure(sampleRate: Double, onSegment: @escaping @Sendable (WhisperAudioSegment) -> Void) {
		lock.withLock {
			self.sampleRate = sampleRate
			self.onSegment = onSegment
		}
	}

	func reset() {
		lock.withLock {
			samples.removeAll(keepingCapacity: false)
			peak = 0
			onSegment = nil
		}
	}

	func append(_ buffer: AVAudioPCMBuffer) {
		guard let channels = buffer.floatChannelData else { return }
		let frameCount = Int(buffer.frameLength)
		guard frameCount > 0 else { return }
		let copied = Array(UnsafeBufferPointer(start: channels[0], count: frameCount))
		let localPeak = copied.reduce(Float.zero) { max($0, abs($1)) }
		var completed: WhisperAudioSegment?
		var callback: (@Sendable (WhisperAudioSegment) -> Void)?
		lock.withLock {
			guard sampleRate > 0 else { return }
			samples.append(contentsOf: copied)
			peak = max(peak, localPeak)
			guard Double(samples.count) / sampleRate >= segmentLength else { return }
			if peak >= activationPeak { completed = WhisperAudioSegment(samples: samples, sampleRate: sampleRate) }
			let overlap = min(samples.count, Int(sampleRate * 0.5))
			samples = Array(samples.suffix(overlap))
			peak = 0
			callback = onSegment
		}
		if let completed, let callback { callback(completed) }
	}
}

private enum WhisperCLI {
	static func transcribe(segment: WhisperAudioSegment, runtime: WhisperRuntimeURLs) -> String? {
		let temporary = FileManager.default.temporaryDirectory
			.appendingPathComponent("rewind-voice-\(UUID().uuidString).wav")
		defer { try? FileManager.default.removeItem(at: temporary) }
		guard writeWAV(segment: segment, to: temporary) else { return nil }
		let process = Process()
		process.executableURL = runtime.helper
		process.arguments = ["-m", runtime.model.path, "-f", temporary.path, "-l", "en", "-nt", "-t", "2"]
		let output = Pipe()
		process.standardOutput = output
		process.standardError = FileHandle.nullDevice
		do { try process.run() } catch { return nil }
		process.waitUntilExit()
		guard process.terminationStatus == 0 else { return nil }
		return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
	}

	private static func writeWAV(segment: WhisperAudioSegment, to url: URL) -> Bool {
		let targetRate = 16_000.0
		let ratio = segment.sampleRate / targetRate
		var pcm = Data()
		for index in stride(from: 0.0, to: Double(segment.samples.count), by: ratio) {
			let sourceIndex = min(Int(index), segment.samples.count - 1)
			let value = Int16(max(-1, min(1, segment.samples[sourceIndex])) * Float(Int16.max)).littleEndian
			withUnsafeBytes(of: value) { pcm.append(contentsOf: $0) }
		}
		var wav = Data("RIFF".utf8)
		let fileSize = UInt32(36 + pcm.count).littleEndian
		withUnsafeBytes(of: fileSize) { wav.append(contentsOf: $0) }
		wav.append(Data("WAVEfmt ".utf8))
		let fmtSize = UInt32(16).littleEndian
		let audioFormat = UInt16(1).littleEndian
		let channels = UInt16(1).littleEndian
		let rate = UInt32(targetRate).littleEndian
		let byteRate = UInt32(targetRate * 2).littleEndian
		let blockAlign = UInt16(2).littleEndian
		let bits = UInt16(16).littleEndian
		for value in [fmtSize] { withUnsafeBytes(of: value) { wav.append(contentsOf: $0) } }
		for value in [audioFormat, channels] { withUnsafeBytes(of: value) { wav.append(contentsOf: $0) } }
		for value in [rate, byteRate] { withUnsafeBytes(of: value) { wav.append(contentsOf: $0) } }
		for value in [blockAlign, bits] { withUnsafeBytes(of: value) { wav.append(contentsOf: $0) } }
		wav.append(Data("data".utf8))
		let dataSize = UInt32(pcm.count).littleEndian
		withUnsafeBytes(of: dataSize) { wav.append(contentsOf: $0) }
		wav.append(pcm)
		do { try wav.write(to: url, options: .atomic); return true } catch { return false }
	}
}
