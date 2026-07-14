@preconcurrency import AVFoundation

/// Transcodes microphone sample buffers into the LPCM layout the mic encoder
/// input requires. ScreenCaptureKit may deliver the mic in a mismatched format
/// (channel count, sample rate, float vs int); appending a mismatched buffer to
/// the writer raises an NSException, so every buffer is converted first.
///
/// Not thread-safe: instances are confined to the writer queue.
final class MicrophoneConverter {
    private let audioSettings: [String: Any]?
    private var converter: AVAudioConverter?
    private var converterSourceFormat: AVAudioFormat?
    private var targetFormat: AVAudioFormat?
    private var targetFormatDescription: CMAudioFormatDescription?

    init(audioSettings: [String: Any]?) {
        self.audioSettings = audioSettings
    }

    /// Returns the buffer converted to the target LPCM layout, or nil if the
    /// source is unsupported or conversion fails (caller drops the buffer).
    func convert(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard CMSampleBufferGetNumSamples(sampleBuffer) > 0,
            let sourceDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
            let targetFormat = targetFormatIfNeeded()
        else { return nil }
        let sourceFormat = AVAudioFormat(cmAudioFormatDescription: sourceDesc)

        // already exactly the target layout; append as-is
        if sourceFormat.isEqual(targetFormat) { return sampleBuffer }

        if converter == nil || !(converterSourceFormat?.isEqual(sourceFormat) ?? false) {
            converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
            converterSourceFormat = sourceFormat
        }
        guard let converter,
            let inputBuffer = inputBuffer(from: sampleBuffer, sourceFormat: sourceFormat)
        else { return nil }

        let sourceFrames = Double(max(CMSampleBufferGetNumSamples(sampleBuffer), 1))
        let ratio = targetFormat.sampleRate / max(sourceFormat.sampleRate, 1)
        let capacity = AVAudioFrameCount((sourceFrames * ratio).rounded(.up)) + 1_024
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity)
        else { return nil }

        var conversionError: NSError?
        var suppliedInput = false
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }
        guard status != .error, conversionError == nil, outputBuffer.frameLength > 0 else {
            return nil
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        return timedSampleBuffer(from: outputBuffer, presentationTimeStamp: pts)
    }

    /// LPCM layout the mic encoder input expects, derived from the configured
    /// audio settings. A compressed encoder (AAC/ALAC) accepts any LPCM layout,
    /// so we use 48 kHz / stereo / Int16 interleaved; an LPCM encoder requires
    /// the appended buffer to match the output settings exactly, so we build the
    /// format straight from those settings.
    private func targetFormatIfNeeded() -> AVAudioFormat? {
        if let targetFormat { return targetFormat }
        let sampleRate =
            (audioSettings?[AVSampleRateKey] as? Double)
            ?? (audioSettings?[AVSampleRateKey] as? Int).map(Double.init)
            ?? 48_000
        let channels = (audioSettings?[AVNumberOfChannelsKey] as? Int).map(UInt32.init) ?? 2
        let formatID =
            (audioSettings?[AVFormatIDKey] as? UInt32)
            ?? (audioSettings?[AVFormatIDKey] as? Int).map(UInt32.init)

        let format: AVAudioFormat?
        if formatID == kAudioFormatLinearPCM, let audioSettings {
            format = AVAudioFormat(settings: audioSettings)
        } else {
            format = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: sampleRate,
                channels: AVAudioChannelCount(max(channels, 1)), interleaved: true)
        }
        targetFormat = format
        return format
    }

    /// Cached `CMAudioFormatDescription` for the (constant) mic target format,
    /// so we don't recreate one on every converted buffer.
    private func targetFormatDescriptionIfNeeded(for format: AVAudioFormat)
        -> CMAudioFormatDescription?
    {
        if let targetFormatDescription { return targetFormatDescription }
        var asbd = format.streamDescription.pointee
        var description: CMAudioFormatDescription?
        guard
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                magicCookieSize: 0, magicCookie: nil, extensions: nil,
                formatDescriptionOut: &description) == noErr,
            let description
        else { return nil }
        targetFormatDescription = description
        return description
    }

    /// Wraps a mic sample buffer's LPCM payload into an `AVAudioPCMBuffer` for
    /// converter input. ScreenCaptureKit delivers the microphone as LPCM;
    /// compressed sources are unsupported (returns nil so the buffer is dropped
    /// rather than fed to a mis-sized decode path).
    private func inputBuffer(from sampleBuffer: CMSampleBuffer, sourceFormat: AVAudioFormat)
        -> AVAudioPCMBuffer?
    {
        guard sourceFormat.streamDescription.pointee.mFormatID == kAudioFormatLinearPCM else {
            return nil
        }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frames)
        else { return nil }
        pcm.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
        return status == noErr ? pcm : nil
    }

    /// Builds a timed `CMSampleBuffer` around a converted LPCM buffer, preserving
    /// the source presentation timestamp so mic audio stays aligned.
    private func timedSampleBuffer(
        from pcmBuffer: AVAudioPCMBuffer, presentationTimeStamp pts: CMTime
    ) -> CMSampleBuffer? {
        guard let formatDescription = targetFormatDescriptionIfNeeded(for: pcmBuffer.format)
        else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(pcmBuffer.format.sampleRate)),
            presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        guard
            CMSampleBufferCreate(
                allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
                makeDataReadyCallback: nil, refcon: nil, formatDescription: formatDescription,
                sampleCount: CMItemCount(pcmBuffer.frameLength), sampleTimingEntryCount: 1,
                sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
                sampleBufferOut: &sampleBuffer) == noErr,
            let sampleBuffer
        else { return nil }

        guard
            CMSampleBufferSetDataBufferFromAudioBufferList(
                sampleBuffer, blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0,
                bufferList: pcmBuffer.audioBufferList) == noErr
        else { return nil }

        return sampleBuffer
    }
}
