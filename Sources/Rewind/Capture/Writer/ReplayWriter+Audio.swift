@preconcurrency import AVFoundation

extension ReplayWriter {
    // - Microphone ---

    func appendMic(_ sampleBuffer: CMSampleBuffer) {
        let buffer = UncheckedSendable(sampleBuffer)
        onQueue { [weak self] in
            self?.appendMicOnQueue(buffer.value)
        }
    }

    private func appendMicOnQueue(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard acceptsMediaData else { return }
        guard let micInput, let writer else { return }
        if writer.status == .failed {
            AppLog.error(.writer, "ReplayWriter.appendMic writer failed", error: writer.error)
            acceptsMediaData = false
            return
        }

        logFirstMicBufferIfNeeded(sampleBuffer)

        // ScreenCaptureKit may deliver the mic in a format that doesn't match the
        // encoder input, so transcode to LPCM first; appending a mismatched buffer
        // raises an NSException that crashes the app.
        guard let converted = micConverter?.convert(sampleBuffer) else {
            if !droppedNonLPCMMicLogged {
                droppedNonLPCMMicLogged = true
                let fmt =
                    CMSampleBufferGetFormatDescription(sampleBuffer)
                    .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }?
                    .mFormatID ?? 0
                AppLog.error(
                    .writer, "ReplayWriter.appendMic dropping mic buffer (conversion failed); fmt:",
                    fmt)
            }
            return
        }

        // Buffer mic samples until the session starts so leading audio isn't lost.
        guard sessionStarted, writer.status == .writing, sessionStartPTS.isValid else {
            pendingMic.enqueue(converted)
            return
        }

        // Tight tolerance; samples before session start are rejected by the writer.
        let pts = CMSampleBufferGetPresentationTimeStamp(converted)
        if pts < CMTimeSubtract(sessionStartPTS, Constants.audioSyncTolerance) {
            return
        }

        if !pendingMic.isEmpty {
            pendingMic.enqueue(converted)
            drainPendingMicWhileReady(micInput: micInput, writer: writer)
            return
        }

        if micInput.isReadyForMoreMediaData {
            _ = appendMicSample(converted, to: micInput, writer: writer)
        } else {
            pendingMic.enqueue(converted)
        }
    }

    private func logFirstMicBufferIfNeeded(_ sampleBuffer: CMSampleBuffer) {
        guard !loggedFirstMicBuffer else { return }
        loggedFirstMicBuffer = true
        if let asbd = CMSampleBufferGetFormatDescription(sampleBuffer)
            .flatMap({ CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee })
        {
            AppLog.debug(
                .writer, "ReplayWriter.appendMic source ASBD:", "sr:", asbd.mSampleRate, "ch:",
                asbd.mChannelsPerFrame, "fmt:", asbd.mFormatID, "isLPCM:",
                asbd.mFormatID == kAudioFormatLinearPCM, "flags:", asbd.mFormatFlags,
                "bytesPerFrame:", asbd.mBytesPerFrame)
        } else {
            AppLog.debug(.writer, "ReplayWriter.appendMic source format: unavailable")
        }
    }

    func appendMicSample(
        _ sampleBuffer: CMSampleBuffer, to micInput: AVAssetWriterInput, writer: AVAssetWriter
    ) -> Bool {
        // Snap to a continuous timeline so resampled buffers don't accumulate drift.
        let snapped = SampleBufferTiming.snapped(sampleBuffer, relativeTo: lastMicEndPTS)
        if !micInput.append(snapped) {
            logAudioAppendFailure(
                label: "ReplayWriter.appendMic append failed",
                writer: writer,
                audioInput: micInput,
                sampleBuffer: snapped
            )
            acceptsMediaData = false
            return false
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(snapped)
        if let duration = SampleBufferTiming.audioDuration(of: snapped, sampleRate: audioSampleRate),
            duration.isValid, duration > .zero
        {
            lastMicEndPTS = CMTimeAdd(pts, duration)
        } else {
            lastMicEndPTS = pts
        }
        return true
    }

    // - System audio ---

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        let buffer = UncheckedSendable(sampleBuffer)
        onQueue { [weak self] in
            self?.appendAudioOnQueue(buffer.value)
        }
    }

    private func appendAudioOnQueue(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard acceptsMediaData else { return }
        guard let writer else { return }
        guard let audioInput else {
            if includeAudio, !missingAudioInputLogged {
                AppLog.error(.writer, "ReplayWriter.appendAudio missing audio input; dropping audio.")
                logAudioFormat(sampleBuffer)
                missingAudioInputLogged = true
            }
            return
        }

        if writer.status == .failed {
            logAudioAppendFailure(
                label: "ReplayWriter.appendAudio writer failed",
                writer: writer,
                audioInput: audioInput,
                sampleBuffer: sampleBuffer
            )
            acceptsMediaData = false
            return
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !firstAudioPTS.isValid || pts < firstAudioPTS {
            firstAudioPTS = pts
        }

        // buffer audio samples until session starts to prevent audio loss
        guard sessionStarted, writer.status == .writing, sessionStartPTS.isValid else {
            pendingAudio.enqueue(sampleBuffer)
            startSessionIfNeeded()
            return
        }

        // buffer a short window after session start to tighten alignment
        if audioBufferingEndPTS.isValid, pts < audioBufferingEndPTS {
            pendingAudio.enqueue(sampleBuffer)
            return
        }
        if audioBufferingEndPTS.isValid {
            audioBufferingEndPTS = .invalid
            flushPendingAudioSamples(audioInput: audioInput, writer: writer)
        }

        if !loggedFirstAudioBuffer {
            logAudioFormat(sampleBuffer)
            loggedFirstAudioBuffer = true
        }

        if lastAudioEndPTS.isValid, pts > lastAudioEndPTS {
            let gap = CMTimeSubtract(pts, lastAudioEndPTS)
            if gap > Constants.audioGapThreshold {
                fillAudioGapIfNeeded(
                    gap: gap, audioInput: audioInput, writer: writer, startPTS: lastAudioEndPTS)
            }
        }

        if !pendingAudio.isEmpty {
            pendingAudio.enqueue(sampleBuffer)
            drainPendingAudioWhileReady(audioInput: audioInput, writer: writer)
            return
        }

        // tight tolerance; audio should not be significantly before our session start
        if pts < CMTimeSubtract(sessionStartPTS, Constants.audioSyncTolerance) {
            return
        }

        if audioInput.isReadyForMoreMediaData {
            _ = appendAdjustedAudioSample(sampleBuffer, to: audioInput, writer: writer)
            drainPendingAudioWhileReady(audioInput: audioInput, writer: writer)
        } else {
            pendingAudio.enqueue(sampleBuffer)
        }
    }

    func appendAdjustedAudioSample(
        _ sampleBuffer: CMSampleBuffer, to audioInput: AVAssetWriterInput, writer: AVAssetWriter
    ) -> Bool {
        let snappedSample = SampleBufferTiming.snapped(sampleBuffer, relativeTo: lastAudioEndPTS)
        if !audioInput.append(snappedSample) {
            logAudioAppendFailure(
                label: "ReplayWriter.appendAudio append failed",
                writer: writer,
                audioInput: audioInput,
                sampleBuffer: snappedSample
            )
            acceptsMediaData = false
            return false
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(snappedSample)
        if let duration = SampleBufferTiming.audioDuration(
            of: snappedSample, sampleRate: audioSampleRate), duration.isValid, duration > .zero
        {
            lastAudioEndPTS = CMTimeAdd(pts, duration)
        } else {
            lastAudioEndPTS = pts
        }
        return true
    }

    private func fillAudioGapIfNeeded(
        gap: CMTime,
        audioInput: AVAssetWriterInput,
        writer: AVAssetWriter,
        startPTS: CMTime
    ) {
        guard let format = audioFormatDescription,
            let asbd = audioASBD,
            asbd.mFormatID == kAudioFormatLinearPCM,
            (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0,
            let audioSampleRate,
            audioSampleRate > 0
        else {
            AppLog.debug(
                .writer, "ReplayWriter.appendAudio gap:", gap.seconds * 1000,
                "ms (silence padding unavailable)")
            return
        }

        let gapSeconds = min(gap.seconds, Constants.maxGapSeconds)
        let totalFrames = Int((gapSeconds * audioSampleRate).rounded())
        guard totalFrames > 0 else { return }

        let maxFramesPerBuffer = max(
            1, Int((Constants.silenceChunkSeconds * audioSampleRate).rounded()))
        var remainingFrames = totalFrames
        var cursorPTS = startPTS
        while remainingFrames > 0 {
            let frames = min(remainingFrames, maxFramesPerBuffer)
            if let silence = AudioSilenceGenerator.silenceSampleBuffer(
                formatDescription: format,
                asbd: asbd,
                numFrames: frames,
                pts: cursorPTS
            ) {
                if audioInput.isReadyForMoreMediaData {
                    _ = appendAdjustedAudioSample(silence, to: audioInput, writer: writer)
                } else {
                    pendingAudio.enqueue(silence)
                }
            }
            let duration = CMTime(
                value: CMTimeValue(frames), timescale: CMTimeScale(audioSampleRate.rounded()))
            cursorPTS = CMTimeAdd(cursorPTS, duration)
            remainingFrames -= frames
        }
    }

    private func logAudioFormat(_ sampleBuffer: CMSampleBuffer) {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
        else {
            AppLog.debug(.writer, "ReplayWriter.appendAudio format: unavailable")
            return
        }
        audioSampleRate = asbd.mSampleRate
        audioFormatDescription = format
        audioASBD = asbd
        AppLog.debug(
            .writer, "ReplayWriter.appendAudio ASBD: sr:", asbd.mSampleRate, "ch:",
            asbd.mChannelsPerFrame, "fmt:", asbd.mFormatID, "flags:", asbd.mFormatFlags,
            "bytesPerFrame:", asbd.mBytesPerFrame)
    }

    private func logAudioAppendFailure(
        label: String,
        writer: AVAssetWriter,
        audioInput: AVAssetWriterInput,
        sampleBuffer: CMSampleBuffer
    ) {
        AppLog.error(
            .writer, label, "status:", writer.status.rawValue, "ready:",
            audioInput.isReadyForMoreMediaData)
        AppLog.error(.writer, "ReplayWriter.appendAudio writer.error", error: writer.error)
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        AppLog.error(.writer, "ReplayWriter.appendAudio PTS:", pts.seconds)
    }
}
