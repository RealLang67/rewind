import CoreMedia

/// Produces LPCM silence sample buffers used to pad audio gaps so the encoded
/// timeline stays continuous.
enum AudioSilenceGenerator {
    static func silenceSampleBuffer(
        formatDescription: CMAudioFormatDescription,
        asbd: AudioStreamBasicDescription,
        numFrames: Int,
        pts: CMTime
    ) -> CMSampleBuffer? {
        guard numFrames > 0 else { return nil }
        let bytesPerFrame: UInt32
        if asbd.mBytesPerFrame > 0 {
            bytesPerFrame = asbd.mBytesPerFrame
        } else {
            let bytesPerSample = max(1, asbd.mBitsPerChannel / 8)
            bytesPerFrame = bytesPerSample * max(1, asbd.mChannelsPerFrame)
        }
        let dataLength = Int(bytesPerFrame) * numFrames
        guard dataLength > 0 else { return nil }

        var blockBuffer: CMBlockBuffer?
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: dataLength,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataLength,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else { return nil }
        CMBlockBufferAssureBlockMemory(blockBuffer)
        CMBlockBufferFillDataBytes(
            with: 0,
            blockBuffer: blockBuffer,
            offsetIntoDestination: 0,
            dataLength: dataLength
        )

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(asbd.mSampleRate.rounded())),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var sampleSize = size_t(bytesPerFrame)
        let createStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: numFrames,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard createStatus == noErr, let sampleBuffer else { return nil }
        return sampleBuffer
    }
}
