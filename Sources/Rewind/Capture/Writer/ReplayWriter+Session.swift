@preconcurrency import AVFoundation

extension ReplayWriter {
    // - Session start ---

    func startSessionIfNeeded() {
        guard !sessionStarted,
            let writer,
            let videoInput,
            writer.status == .unknown
        else { return }
        guard firstVideoPTS.isValid else { return }
        if requiresAudioForSession && !firstAudioPTS.isValid {
            return
        }

        if !writer.startWriting() {
            AppLog.error(.writer, "ReplayWriter.startWriting failed", error: writer.error)
            acceptsMediaData = false
            return
        }

        let referencePTS: CMTime
        if requiresAudioForSession {
            var retainedAudioPTS = firstAudioPTS
            let minCandidatePTS = CMTimeSubtract(firstVideoPTS, Constants.audioSyncTolerance)
            for sample in pendingAudio.samples {
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                if pts >= minCandidatePTS {
                    retainedAudioPTS = pts
                    break
                }
            }
            referencePTS = retainedAudioPTS
            videoPTSOffset =
                retainedAudioPTS.isValid ? CMTimeSubtract(retainedAudioPTS, firstVideoPTS) : .zero
            audioPTSOffsetValid = true
            AppLog.debug(
                .writer, "ReplayWriter: video PTS offset applied: \(videoPTSOffset.seconds * 1000) ms")
        } else {
            referencePTS = firstVideoPTS
        }

        videoPTSOffset = .zero
        audioPTSOffsetValid = true

        sessionStartPTS = referencePTS
        writer.startSession(atSourceTime: referencePTS)
        sessionStarted = true
        audioBufferingEndPTS = CMTimeAdd(referencePTS, Constants.audioBufferingWindow)

        flushPendingVideoSamples(writer: writer, videoInput: videoInput)
        if let audioInput {
            flushPendingAudioSamples(audioInput: audioInput, writer: writer)
        }
        // Mic samples queued before the session started would otherwise sit
        // until the next mic buffer arrives (and be lost if delivery stalls).
        if let micInput {
            drainPendingMicWhileReady(micInput: micInput, writer: writer)
        }
    }

    // - Pending drain / flush ---

    func drainPendingAudioWhileReady(audioInput: AVAssetWriterInput, writer: AVAssetWriter) {
        guard writer.status == .writing, !pendingAudio.isEmpty else { return }
        while audioInput.isReadyForMoreMediaData, let sample = pendingAudio.dequeue() {
            if !appendAdjustedAudioSample(sample, to: audioInput, writer: writer) {
                break
            }
        }
    }

    func drainPendingMicWhileReady(micInput: AVAssetWriterInput, writer: AVAssetWriter) {
        guard writer.status == .writing, !pendingMic.isEmpty else { return }
        let minValidPTS = CMTimeSubtract(sessionStartPTS, Constants.audioSyncTolerance)
        while micInput.isReadyForMoreMediaData, let sample = pendingMic.dequeue() {
            if CMSampleBufferGetPresentationTimeStamp(sample) < minValidPTS { continue }
            if !appendMicSample(sample, to: micInput, writer: writer) { break }
        }
    }

    func drainPendingVideoIfReady(writer: AVAssetWriter, videoInput: AVAssetWriterInput) {
        guard !pendingVideo.isEmpty, writer.status == .writing, videoInput.isReadyForMoreMediaData
        else { return }
        while videoInput.isReadyForMoreMediaData, let sample = pendingVideo.dequeue() {
            appendVideoSample(sample, writer: writer, videoInput: videoInput)
            if !acceptsMediaData { break }
        }
    }

    func flushPendingAudioSamples(audioInput: AVAssetWriterInput, writer: AVAssetWriter) {
        guard !pendingAudio.isEmpty else { return }

        if firstAudioPTS.isValid, firstVideoPTS.isValid, firstAudioPTS < firstVideoPTS {
            let audioVideoOffset = CMTimeSubtract(firstVideoPTS, firstAudioPTS)
            AppLog.debug(
                .writer, "ReplayWriter: audio-video offset:", audioVideoOffset.seconds * 1000,
                "ms (audio started earlier)")
        }

        let minValidPTS = sessionStartPTS
        var droppedCount = 0
        var remaining: [CMSampleBuffer] = []
        for sample in pendingAudio.samples {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            if pts < minValidPTS {
                droppedCount += 1
                continue
            }
            remaining.append(sample)
        }

        pendingAudio.replaceAll(remaining)
        if droppedCount > 0 {
            AppLog.debug(.writer, "ReplayWriter: flushed pending audio, dropped:", droppedCount)
        }
        drainPendingAudioWhileReady(audioInput: audioInput, writer: writer)
    }

    func flushPendingVideoSamples(writer: AVAssetWriter, videoInput: AVAssetWriterInput) {
        guard !pendingVideo.isEmpty else { return }
        let minValidPTS = CMTimeSubtract(sessionStartPTS, Constants.videoSyncTolerance)

        var appendedCount = 0
        var droppedCount = 0
        var remaining: [CMSampleBuffer] = []
        for sample in pendingVideo.samples {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            if pts < minValidPTS {
                droppedCount += 1
                continue
            }
            if videoInput.isReadyForMoreMediaData {
                appendVideoSample(sample, writer: writer, videoInput: videoInput)
                if acceptsMediaData {
                    appendedCount += 1
                } else {
                    remaining.append(sample)
                    break
                }
            } else {
                remaining.append(sample)
            }
        }

        pendingVideo.replaceAll(remaining)
        if appendedCount > 0 || droppedCount > 0 {
            AppLog.debug(
                .writer, "ReplayWriter: flushed", appendedCount, "pending video samples, dropped:",
                droppedCount)
        }
    }

    // - Finish ---

    func finishWriting() async throws -> URL {
        let result = try await withThrowingTaskGroup(of: URL.self) { group in
            group.addTask {
                try await self.finishWritingInternal()
            }
            group.addTask {
                try await Task.sleep(
                    nanoseconds: UInt64(Constants.finishWritingTimeout * 1_000_000_000))
                throw CaptureError.exportFailed
            }
            guard let result = try await group.next() else {
                throw CaptureError.writerUnavailable
            }
            group.cancelAll()
            return result
        }
        return result
    }

    private func finishWritingInternal() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.onQueue {
                guard let writer = self.writer, let outputURL = self.outputURL else {
                    AppLog.debug(.writer, "ReplayWriter.finishWriting: writer unavailable.")
                    continuation.resume(throwing: CaptureError.writerUnavailable)
                    return
                }

                guard self.sessionStarted else {
                    AppLog.debug(.writer, "ReplayWriter.finishWriting: no session started.")
                    self.resetState()
                    continuation.resume(throwing: CaptureError.noFramesCaptured)
                    return
                }

                AppLog.debug(
                    .writer, "ReplayWriter.finishWriting: start. status:", writer.status.rawValue)

                // Give any samples still queued from backpressure one last chance
                // to reach the writer before their inputs are marked finished —
                // otherwise they're silently dropped by resetState() below.
                if let videoInput = self.videoInput {
                    self.drainPendingVideoIfReady(writer: writer, videoInput: videoInput)
                }
                if let audioInput = self.audioInput {
                    self.drainPendingAudioWhileReady(audioInput: audioInput, writer: writer)
                }
                if let micInput = self.micInput {
                    self.drainPendingMicWhileReady(micInput: micInput, writer: writer)
                }

                self.acceptsMediaData = false
                self.videoInput?.markAsFinished()
                self.audioInput?.markAsFinished()
                self.micInput?.markAsFinished()
                let writerBox = UncheckedSendable(writer)
                writer.finishWriting { [self] in
                    // dispatch back to our queue to safely access state
                    self.onQueue {
                        let writer = writerBox.value
                        let error = writer.error
                        if let error {
                            AppLog.error(.writer, "ReplayWriter.finishWriting: failed.", error: error)
                        } else {
                            AppLog.debug(.writer, "ReplayWriter.finishWriting: success.")
                        }
                        self.resetState()

                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: outputURL)
                        }
                    }
                }
            }
        }
    }
}
