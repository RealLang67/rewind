@preconcurrency import AVFoundation
import Foundation
@preconcurrency import ScreenCaptureKit

actor CaptureManager {
    private enum Constants {
        static let rotationFrameDelayNanos: UInt64 = 50_000_000
        static let fileReadyAttempts = 10
        static let fileReadyDelayNanos: UInt64 = 50_000_000
        static let nanosPerSecond: Double = 1_000_000_000
    }

    private let screenCapture: ScreenCaptureService
    private let captureQueue: DispatchQueue
    private let writerQueue: DispatchQueue
    /// active writer receiving samples (accessed via nonisolated helper for callbacks)
    private var activeWriter: ReplayWriter
    /// standby writer pre-configured for instant switchover
    private var standbyWriter: ReplayWriter?
    private let replayBuffer = ReplayBuffer()
    private let exporter = ReplayExporter()
    private var isRunning = false
    private var isSaving = false
    private var isStopping = false
    private var rotationTask: Task<Void, Never>?
    private let segmentDuration: TimeInterval = 10
    private let maxBufferDuration: TimeInterval = 120
    private var currentQuality: QualityPreset = .default
    private var currentFrameRate: Int = CaptureFrameRate.default.framesPerSecond
    private var currentAudioCodec: CaptureAudioCodec = .default
    private var recordMicrophoneEnabled: Bool = false
    private var recordDesktopAudioEnabled: Bool = true
    private var onCaptureInterrupted: (@MainActor (Error) -> Void)?

    /// thread-safe reference to current writer for use in callbacks
    /// sses lock-based synchronization so it can be safely accessed from nonisolated contexts
    private let currentWriterLock = NSLock()
    private nonisolated(unsafe) var _currentWriter: ReplayWriter?
    private nonisolated var currentWriter: ReplayWriter? {
        get {
            currentWriterLock.withLock { _currentWriter }
        }
        set {
            currentWriterLock.withLock { _currentWriter = newValue }
        }
    }

    init() {
        // sse userInteractive QoS for real-time capture processing
        let queue = DispatchQueue(label: "rewind.capture.samples", qos: .userInteractive)
        captureQueue = queue
        let audioQueue = DispatchQueue(label: "rewind.capture.audio", qos: .userInteractive)
        // dedicated writer queue keeps encoding work off the capture callback queue.
        writerQueue = DispatchQueue(label: "rewind.capture.writer", qos: .userInitiated)
        screenCapture = ScreenCaptureService(sampleQueue: queue, audioQueue: audioQueue)
        activeWriter = ReplayWriter(queue: writerQueue)
        screenCapture.onCaptureStopped = { [weak self] error in
            guard let self, let error else { return }
            Task {
                await self.handleCaptureFailure(error, label: "Capture stream stopped")
            }
        }
    }

    func setOnCaptureInterruptedHandler(_ handler: (@MainActor (Error) -> Void)?) {
        onCaptureInterrupted = handler
    }

    func start(
        contentFilter: UncheckedSendable<SCContentFilter>? = nil,
        resolution: CaptureResolution? = nil,
        quality: QualityPreset = .default,
        frameRate: Int = CaptureFrameRate.default.framesPerSecond,
        audioCodec: CaptureAudioCodec = .default,
        recordMicrophoneEnabled: Bool = false,
        recordDesktopAudioEnabled: Bool = true
    ) async throws {
        guard !isRunning else { return }
        currentQuality = quality
        currentFrameRate = frameRate
        currentAudioCodec = audioCodec
        self.recordMicrophoneEnabled = recordMicrophoneEnabled
        self.recordDesktopAudioEnabled = recordDesktopAudioEnabled

        let transaction = Perf.transaction("capture.start", operation: "task")
        transaction.setTag(quality.id, forKey: "quality")
        transaction.setData(frameRate, forKey: "frame_rate")
        transaction.setData(recordMicrophoneEnabled, forKey: "record_microphone")
        transaction.setData(recordDesktopAudioEnabled, forKey: "record_desktop_audio")

        do {
            let streamSpan = transaction.child("stream_start")
            try await screenCapture.startCapture(
                contentFilter: contentFilter,
                resolution: resolution,
                quality: quality,
                frameRate: frameRate,
                recordMicrophone: recordMicrophoneEnabled,
                recordDesktopAudio: recordDesktopAudioEnabled
            )
            streamSpan.finish()
            let writerSpan = transaction.child("configure_writer")
            try configureActiveWriter()
            currentWriter = activeWriter
            screenCapture.onVideoSampleBuffer = { [weak self] sampleBuffer in
                self?.currentWriter?.appendVideo(sampleBuffer)
            }
            screenCapture.onAudioSampleBuffer = { [weak self] sampleBuffer in
                self?.currentWriter?.appendAudio(sampleBuffer)
            }
            screenCapture.onMicSampleBuffer = { [weak self] sampleBuffer in
                self?.currentWriter?.appendMic(sampleBuffer)
            }
            isRunning = true
            prepareStandbyWriter()
            startRotationLoop()
            writerSpan.finish()
            transaction.finish()
        } catch {
            transaction.finish(failed: true)
            await resetCaptureState()
            throw error
        }
    }

    func stop() async {
        guard isRunning else { return }
        await stopCapturePipeline()
    }

    func saveReplay(seconds: TimeInterval, container: CaptureContainer = .default) async throws
        -> URL
    {
        guard isRunning else { throw CaptureError.noFramesCaptured }
        guard !isSaving else { throw CaptureError.saveInProgress }
        isSaving = true
        defer { isSaving = false }

        AppLog.info(.capture, "Save replay start. seconds:", seconds)
        let transaction = Perf.transaction("replay.save", operation: "task")
        transaction.setTag(container.id, forKey: "container")
        transaction.setData(seconds, forKey: "requested_seconds")

        var sourceURL: URL?
        var sourceURLAddedToBuffer = false
        do {
            let rotateSpan = transaction.child("rotate")
            sourceURL = try await rotateWriterSeamlessly()
            rotateSpan.finish()
        } catch {
            Self.logError("Replay rotation failed", error)
            transaction.finish(failed: true)
            throw error
        }

        var segmentsToUnlock: [ReplaySegment] = []
        do {
            guard let sourceURL else { throw CaptureError.writerUnavailable }
            AppLog.debug(.capture, "Replay source ready:", sourceURL.lastPathComponent)
            let prepareSpan = transaction.child("prepare")
            try await waitForFileReady(at: sourceURL)
            let duration = try await loadDuration(of: sourceURL)
            let removed = await replayBuffer.appendSegment(
                url: sourceURL, duration: duration, maxDuration: maxBufferDuration)
            sourceURLAddedToBuffer = true
            removeFiles(removed)
            let segments = await replayBuffer.latestSegments(totalDuration: seconds)
            segmentsToUnlock = segments
            prepareSpan.setData(segments.count, forKey: "segment_count")
            prepareSpan.finish()

            let exportSpan = transaction.child("export")
            let exportURL = try await exporter.export(
                segments: segments, seconds: seconds, container: container)
            exportSpan.finish()

            await replayBuffer.unlockSegments(segmentsToUnlock)
            if let size = try? FileManager.default.attributesOfItem(atPath: exportURL.path)[.size] as? Int {
                transaction.setData(size, forKey: "output_bytes")
            }
            AppLog.info(.capture, "Save replay success:", exportURL.lastPathComponent)
            transaction.finish()
            return exportURL
        } catch {
            // Always unlock segments on failure
            if !segmentsToUnlock.isEmpty {
                await replayBuffer.unlockSegments(segmentsToUnlock)
            }
            if let sourceURL, !sourceURLAddedToBuffer {
                removeFiles([sourceURL])
            }
            Self.logError("Export failed", error)
            transaction.finish(failed: true)
            throw error
        }
    }

    /// configures the active writer with a new output file
    private func configureActiveWriter() throws {
        guard let size = screenCapture.displaySize else {
            throw CaptureError.noDisplay
        }
        let outputURL = makeSegmentURL()
        try activeWriter.configure(
            outputURL: outputURL,
            videoSize: size,
            includeAudio: recordDesktopAudioEnabled,
            audioSettings: captureAudioSettings,
            quality: currentQuality,
            frameRate: currentFrameRate,
            recordMicrophone: recordMicrophoneEnabled
        )
    }

    /// pre-configures the standby writer for instant switchover
    private func prepareStandbyWriter() {
        guard let size = screenCapture.displaySize else { return }
        let writer = ReplayWriter(queue: writerQueue)
        let outputURL = makeSegmentURL()
        do {
            try writer.configure(
                outputURL: outputURL,
                videoSize: size,
                includeAudio: recordDesktopAudioEnabled,
                audioSettings: captureAudioSettings,
                quality: currentQuality,
                frameRate: currentFrameRate,
                recordMicrophone: recordMicrophoneEnabled
            )
            standbyWriter = writer
        } catch {
            Self.logError("Failed to prepare standby writer", error)
            standbyWriter = nil
        }
    }

    /// seamlessly rotates to the standby writer and returns the finished segment URL.
    private func rotateWriterSeamlessly() async throws -> URL {
        // ensure standby is ready, or prepare it now
        if standbyWriter == nil {
            prepareStandbyWriter()
        }
        guard let newWriter = standbyWriter else {
            throw CaptureError.writerUnavailable
        }

        // atomically switch the writer reference (callbacks will pick up new writer)
        let oldWriter = activeWriter
        activeWriter = newWriter
        standbyWriter = nil

        // update currentWriter atomically; this is what callbacks use
        currentWriter = newWriter

        // small delay to ensure the new writer receives at least one frame
        // before we finish the old writer (prevents black frame at segment boundary)
        try? await Task.sleep(nanoseconds: Constants.rotationFrameDelayNanos)  // 50ms = ~3 frames at 60fps

        // finish the old writer and prepare next standby in background
        let sourceURL = try await oldWriter.finishWriting()
        prepareStandbyWriter()
        return sourceURL
    }

    private func makeSegmentURL() -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Rewind", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("Rewind_live_\(UUID().uuidString).mov")
    }

    private var captureAudioSettings: [String: Any] {
        switch currentAudioCodec.id {
        case CaptureAudioCodec.aac.id:
            return [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000,
            ]
        default:
            return [
                AVFormatIDKey: kAudioFormatAppleLossless,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitDepthHintKey: 16,
            ]
        }
    }

    private func waitForFileReady(at url: URL) async throws {
        let fm = FileManager.default
        for _ in 0..<Constants.fileReadyAttempts {
            if let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? NSNumber,
                size.intValue > 0
            {
                return
            }
            try await Task.sleep(nanoseconds: Constants.fileReadyDelayNanos)
        }
        throw CaptureError.noFramesCaptured
    }

    private func loadDuration(of url: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else {
            throw CaptureError.invalidDuration
        }
        return seconds
    }

    private static func logError(_ label: String, _ error: Error) {
        AppLog.error(.capture, label, error: error)
    }

    private func startRotationLoop() {
        rotationTask?.cancel()
        rotationTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(
                    nanoseconds: UInt64(segmentDuration * Constants.nanosPerSecond))
                if Task.isCancelled { break }
                await self.rotateSegment()
            }
        }
    }

    private func rotateSegment() async {
        guard isRunning else { return }

        let sourceURL: URL
        do {
            sourceURL = try await rotateWriterSeamlessly()
        } catch {
            await handleCaptureFailure(error, label: "Rotation failed")
            return
        }

        do {
            try await waitForFileReady(at: sourceURL)
            let duration = try await loadDuration(of: sourceURL)
            let removed = await replayBuffer.appendSegment(
                url: sourceURL, duration: duration, maxDuration: maxBufferDuration)
            removeFiles(removed)
        } catch {
            removeFiles([sourceURL])
            await handleCaptureFailure(error, label: "Rotation post-processing failed")
        }
    }

    private func handleCaptureFailure(_ error: Error, label: String) async {
        guard isRunning, !isStopping else { return }
        Self.logError(label, error)
        await stopCapturePipeline()
        if let onCaptureInterrupted {
            await onCaptureInterrupted(error)
        }
    }

    private func stopCapturePipeline() async {
        if isStopping { return }
        isStopping = true
        defer { isStopping = false }
        await resetCaptureState()
    }

    private func resetCaptureState() async {
        rotationTask?.cancel()
        rotationTask = nil
        screenCapture.onVideoSampleBuffer = nil
        screenCapture.onAudioSampleBuffer = nil
        screenCapture.onMicSampleBuffer = nil
        currentWriter = nil
        await screenCapture.stopCapture()
        if let url = try? await activeWriter.finishWriting() {
            removeFiles([url])
        }
        standbyWriter = nil
        let urls = await replayBuffer.clear()
        removeFiles(urls)
        cleanupTemporaryLiveSegments()
        isSaving = false
        isRunning = false
    }

    private func removeFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let fm = FileManager.default
        for url in urls {
            try? fm.removeItem(at: url)
        }
    }

    private func cleanupTemporaryLiveSegments() {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Rewind", isDirectory: true)
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        else {
            return
        }
        for url in urls where url.lastPathComponent.hasPrefix("Rewind_live_") {
            try? fm.removeItem(at: url)
        }
    }
}
