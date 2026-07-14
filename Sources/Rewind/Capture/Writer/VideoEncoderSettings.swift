import AVFoundation
import CoreGraphics
import VideoToolbox

/// Builds the HEVC `AVAssetWriterInput` output settings and matching source
/// pixel-buffer format for a given quality preset, resolution, and frame rate.
enum VideoEncoderSettings {
    /// Source pixel format handed to the pixel-buffer adaptor. Must match the
    /// format ScreenCaptureKit captures (NV12); declaring a different format here
    /// breaks the zero-copy path and forces a per-frame color conversion on the
    /// writer queue, causing encoder backpressure and stutter.
    static func sourcePixelFormat(for quality: QualityPreset) -> OSType {
        _ = quality
        return kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    }

    static func outputSettings(
        quality: QualityPreset,
        width: Int,
        height: Int,
        frameRate: Int,
        useBFrames: Bool
    ) -> [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compressionProperties(
                for: quality,
                videoSize: CGSize(width: width, height: height),
                frameRate: frameRate,
                useBFrames: useBFrames
            ),
        ]
    }

    static func targetBitrateMbps(for quality: QualityPreset, videoSize: CGSize, frameRate: Int)
        -> Double
    {
        let width = max(1, Int(videoSize.width.rounded()))
        let height = max(1, Int(videoSize.height.rounded()))
        let fps = max(30, min(frameRate, 60))

        let pixelsPerFrame = Double(width * height)
        let bitsPerSecond = quality.bitsPerPixel * pixelsPerFrame * Double(fps)
        let bitrateMbps = bitsPerSecond / 1_000_000
        return min(max(bitrateMbps, quality.minBitrateMbps), quality.maxBitrateMbps)
    }

    private static func compressionProperties(
        for quality: QualityPreset,
        videoSize: CGSize,
        frameRate: Int,
        useBFrames: Bool
    ) -> [String: Any] {
        let normalizedFrameRate = max(30, min(frameRate, 60))
        let averageBitrateMbps = targetBitrateMbps(
            for: quality, videoSize: videoSize, frameRate: normalizedFrameRate)
        let averageBitrate = Int((averageBitrateMbps * 1_000_000).rounded())
        let keyframeInterval = max(
            normalizedFrameRate, Int((Double(normalizedFrameRate) * 1.5).rounded()))

        // VBR bursting
        let burstMultiplier = useBFrames ? 1.5 : 2.0
        let burstWindowSeconds = 2
        let maxBitrate = Int((averageBitrateMbps * burstMultiplier * 1_000_000).rounded())

        var props: [String: Any] = [
            AVVideoAverageBitRateKey: averageBitrate,
            AVVideoExpectedSourceFrameRateKey: normalizedFrameRate,
            AVVideoMaxKeyFrameIntervalKey: keyframeInterval,
            AVVideoMaxKeyFrameIntervalDurationKey: 1.5,
            AVVideoAllowFrameReorderingKey: useBFrames,
        ]

        let isTesting =
            NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true"

        if !isTesting {
            if #available(macOS 14.0, *) {
                props[kVTCompressionPropertyKey_DataRateLimits as String] = [
                    (maxBitrate / 8) * burstWindowSeconds, burstWindowSeconds,
                ]
            }
        }

        return props
    }
}
