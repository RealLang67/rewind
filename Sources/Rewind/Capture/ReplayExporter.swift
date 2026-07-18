@preconcurrency import AVFoundation
import Foundation

/// Stitches buffered replay segments into a single composition and exports the
/// requested trailing `seconds` as a passthrough clip in the chosen container.
struct ReplayExporter {
    func export(
        segments: [ReplaySegment],
        seconds: TimeInterval,
        container: CaptureContainer
    ) async throws -> URL {
        guard !segments.isEmpty else { throw CaptureError.noFramesCaptured }

        let composition = AVMutableComposition()
        let videoTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        var audioTracks: [AVMutableCompositionTrack] = []

        var cursor = CMTime.zero
        var appliedTransform = false
        for segment in segments {
            let asset = AVURLAsset(url: segment.url)
            _ = try await asset.load(.tracks)
            let assetDuration = try await asset.load(.duration)
            var videoDuration = assetDuration
            var audioDuration = assetDuration

            let sourceVideo = try await asset.loadTracks(withMediaType: .video).first
            let sourceAudioTracks = try await asset.loadTracks(withMediaType: .audio)

            while audioTracks.count < sourceAudioTracks.count {
                if let newTrack = composition.addMutableTrack(
                    withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                {
                    audioTracks.append(newTrack)
                } else {
                    break
                }
            }

            if let sourceVideo, let videoTrack {
                videoDuration = try await sourceVideo.load(.timeRange).duration
                if !appliedTransform {
                    let transform = try await sourceVideo.load(.preferredTransform)
                    videoTrack.preferredTransform = transform
                    appliedTransform = true
                }
            }
            if let firstSourceAudio = sourceAudioTracks.first {
                audioDuration = try await firstSourceAudio.load(.timeRange).duration
            }
            let minDuration = CMTimeMinimum(videoDuration, audioDuration)
            let segmentDuration =
                minDuration.isValid && minDuration > .zero ? minDuration : assetDuration
            let timeRange = CMTimeRange(start: .zero, duration: segmentDuration)
            if let sourceVideo, let videoTrack {
                try videoTrack.insertTimeRange(timeRange, of: sourceVideo, at: cursor)
            }
            for (index, sourceAudio) in sourceAudioTracks.enumerated() {
                if index < audioTracks.count {
                    try audioTracks[index].insertTimeRange(timeRange, of: sourceAudio, at: cursor)
                }
            }
            if assetDuration.isValid, segmentDuration.isValid {
                let delta = CMTimeSubtract(assetDuration, segmentDuration)
                let mismatchThreshold = CMTime(seconds: 0.02, preferredTimescale: 1_000)
                if delta > mismatchThreshold {
                    AppLog.debug(
                        .capture, "Export: segment duration mismatch. asset:", assetDuration.seconds,
                        "video:", videoDuration.seconds, "audio:", audioDuration.seconds)
                }
            }
            cursor = cursor + segmentDuration
        }

        let totalSeconds = cursor.seconds
        guard totalSeconds.isFinite, totalSeconds > 0 else {
            throw CaptureError.noFramesCaptured
        }
        let clipSeconds = max(0, min(seconds, totalSeconds))
        guard clipSeconds > 0 else {
            throw CaptureError.noFramesCaptured
        }
        let timescale = cursor.timescale == 0 ? CMTimeScale(600) : cursor.timescale
        let startTime = CMTime(
            seconds: max(totalSeconds - clipSeconds, 0), preferredTimescale: timescale)
        let timeRange = CMTimeRange(
            start: startTime, duration: CMTime(seconds: clipSeconds, preferredTimescale: timescale))

        let defaultFolder =
            FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Rewind", isDirectory: true)
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(
                "Rewind", isDirectory: true)
        let folder: URL
        if let customPath = AppSettingsStorage.load().outputDirectoryPath {
            folder = URL(fileURLWithPath: customPath)
        } else {
            folder = defaultFolder
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let exportURL = folder.appendingPathComponent(
            "Rewind_\(UUID().uuidString).\(container.fileExtension)")
        try? FileManager.default.removeItem(at: exportURL)

        do {
            return try await exportWithPassthrough(
                asset: composition,
                timeRange: timeRange,
                outputURL: exportURL,
                container: container
            )
        } catch {
            try? FileManager.default.removeItem(at: exportURL)
            throw error
        }
    }

    private func exportWithPassthrough(
        asset: AVAsset,
        timeRange: CMTimeRange,
        outputURL: URL,
        container: CaptureContainer
    ) async throws -> URL {
        guard
            let exportSession = AVAssetExportSession(
                asset: asset, presetName: AVAssetExportPresetPassthrough)
        else {
            throw CaptureError.exportFailed
        }

        guard exportSession.supportedFileTypes.contains(container.avFileType) else {
            throw CaptureError.exportFailed
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = container.avFileType
        exportSession.timeRange = timeRange
        exportSession.shouldOptimizeForNetworkUse = false

        let session = UncheckedSendable(exportSession)
        return try await withCheckedThrowingContinuation { continuation in
            session.value.exportAsynchronously {
                switch session.value.status {
                case .completed:
                    continuation.resume(returning: outputURL)
                case .failed, .cancelled:
                    try? FileManager.default.removeItem(at: outputURL)
                    continuation.resume(throwing: session.value.error ?? CaptureError.exportFailed)
                default:
                    try? FileManager.default.removeItem(at: outputURL)
                    continuation.resume(throwing: CaptureError.exportFailed)
                }
            }
        }
    }
}
