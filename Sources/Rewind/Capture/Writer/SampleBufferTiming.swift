import CoreMedia

/// Pure timing transforms applied to capture sample buffers before they are
/// handed to the asset writer.
enum SampleBufferTiming {
    /// Shifts a video sample's PTS/DTS by `offset` and fills in a default
    /// duration where the source left it invalid.
    static func adjustedVideo(_ sampleBuffer: CMSampleBuffer, offset: CMTime, defaultFrameRate: Int)
        -> CMSampleBuffer
    {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return sampleBuffer }
        var timingInfo = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer, entryCount: count, arrayToFill: &timingInfo, entriesNeededOut: &count)

        let defaultDuration = CMTime(value: 1, timescale: Int32(defaultFrameRate))

        for i in 0..<count {
            if timingInfo[i].presentationTimeStamp.isValid {
                timingInfo[i].presentationTimeStamp = CMTimeAdd(
                    timingInfo[i].presentationTimeStamp, offset)
            }
            if timingInfo[i].decodeTimeStamp.isValid {
                timingInfo[i].decodeTimeStamp = CMTimeAdd(timingInfo[i].decodeTimeStamp, offset)
            }
            if !timingInfo[i].duration.isValid || timingInfo[i].duration == .zero {
                timingInfo[i].duration = defaultDuration
            }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil, sampleBuffer: sampleBuffer, sampleTimingEntryCount: count,
            sampleTimingArray: &timingInfo, sampleBufferOut: &out)
        return out ?? sampleBuffer
    }

    /// Rewrites a sample's timing so it starts exactly at `endPTS`, removing the
    /// small gaps/overlaps that otherwise accumulate as drift (e.g. after
    /// sample-rate conversion). No-op when `endPTS` is invalid or already aligned.
    static func snapped(_ sampleBuffer: CMSampleBuffer, relativeTo endPTS: CMTime) -> CMSampleBuffer
    {
        guard endPTS.isValid else { return sampleBuffer }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let delta = CMTimeSubtract(pts, endPTS)

        if CMTimeAbsoluteValue(delta) < CMTime(value: 1, timescale: 100_000) {
            return sampleBuffer
        }

        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return sampleBuffer }
        var timingInfo = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer, entryCount: count, arrayToFill: &timingInfo, entriesNeededOut: &count)

        let basePTS = timingInfo[0].presentationTimeStamp
        let baseDTS = timingInfo[0].decodeTimeStamp

        for i in 0..<count {
            if timingInfo[i].presentationTimeStamp.isValid {
                let diff =
                    basePTS.isValid
                    ? CMTimeSubtract(timingInfo[i].presentationTimeStamp, basePTS) : .zero
                timingInfo[i].presentationTimeStamp = CMTimeAdd(endPTS, diff)
            }
            if timingInfo[i].decodeTimeStamp.isValid {
                let diff =
                    baseDTS.isValid
                    ? CMTimeSubtract(timingInfo[i].decodeTimeStamp, baseDTS) : .zero
                timingInfo[i].decodeTimeStamp = CMTimeAdd(endPTS, diff)
            }
        }

        var newSample: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil, sampleBuffer: sampleBuffer, sampleTimingEntryCount: count,
            sampleTimingArray: &timingInfo, sampleBufferOut: &newSample)
        return newSample ?? sampleBuffer
    }

    /// Duration of an audio sample, falling back to `sampleRate` when the buffer
    /// carries no explicit duration.
    static func audioDuration(of sampleBuffer: CMSampleBuffer, sampleRate: Double?) -> CMTime? {
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        if duration.isValid, duration > .zero {
            return duration
        }
        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        if numSamples > 0, let sampleRate, sampleRate > 0 {
            return CMTime(value: CMTimeValue(numSamples), timescale: CMTimeScale(sampleRate.rounded()))
        }
        return nil
    }
}
