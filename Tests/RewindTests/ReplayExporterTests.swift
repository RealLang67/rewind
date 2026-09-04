import AVFoundation
import CoreMedia
import CoreVideo
@testable import Rewind
import XCTest

final class ReplayExporterTests: XCTestCase {
	private func makeTempDirectory() throws -> URL {
		let base = FileManager.default.temporaryDirectory
		let dir = base.appendingPathComponent("ReplayExporterTests-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		return dir
	}

	private var audioSettings: [String: Any] {
		[
			AVFormatIDKey: kAudioFormatLinearPCM,
			AVSampleRateKey: 48_000,
			AVNumberOfChannelsKey: 2,
			AVLinearPCMBitDepthKey: 16,
			AVLinearPCMIsFloatKey: false,
			AVLinearPCMIsBigEndianKey: false,
			"AVLinearPCMIsNonInterleaved": false,
		]
	}

	private func makeVideoSampleBuffer(pts: CMTime, size: CGSize = CGSize(width: 320, height: 240)) -> CMSampleBuffer? {
		var pixelBuffer: CVPixelBuffer?
		CVPixelBufferCreate(
			kCFAllocatorDefault,
			Int(size.width),
			Int(size.height),
			kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
			[kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
			&pixelBuffer
		)
		guard let pixelBuffer else { return nil }

		var formatDescription: CMVideoFormatDescription?
		CMVideoFormatDescriptionCreateForImageBuffer(
			allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
			formatDescriptionOut: &formatDescription)
		guard let formatDescription else { return nil }

		var sampleBuffer: CMSampleBuffer?
		var timing = CMSampleTimingInfo(
			duration: CMTime(value: 1, timescale: 60), presentationTimeStamp: pts,
			decodeTimeStamp: .invalid)
		CMSampleBufferCreateForImageBuffer(
			allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, dataReady: true,
			makeDataReadyCallback: nil, refcon: nil, formatDescription: formatDescription,
			sampleTiming: &timing, sampleBufferOut: &sampleBuffer)
		return sampleBuffer
	}

	private func makeAudioSampleBuffer(pts: CMTime, sampleRate: Double = 48_000, numFrames: Int = 1024) -> CMSampleBuffer? {
		var asbd = AudioStreamBasicDescription(
			mSampleRate: sampleRate,
			mFormatID: kAudioFormatLinearPCM,
			mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
			mBytesPerPacket: 4,
			mFramesPerPacket: 1,
			mBytesPerFrame: 4,
			mChannelsPerFrame: 2,
			mBitsPerChannel: 16,
			mReserved: 0
		)
		var formatDescription: CMAudioFormatDescription?
		CMAudioFormatDescriptionCreate(
			allocator: kCFAllocatorDefault,
			asbd: &asbd,
			layoutSize: 0,
			layout: nil,
			magicCookieSize: 0,
			magicCookie: nil,
			extensions: nil,
			formatDescriptionOut: &formatDescription
		)
		guard let formatDescription else { return nil }

		let dataSize = numFrames * 4
		let data = [UInt8](repeating: 0, count: dataSize)

		var blockBuffer: CMBlockBuffer?
		CMBlockBufferCreateWithMemoryBlock(
			allocator: kCFAllocatorDefault,
			memoryBlock: nil,
			blockLength: dataSize,
			blockAllocator: kCFAllocatorDefault,
			customBlockSource: nil,
			offsetToData: 0,
			dataLength: dataSize,
			flags: 0,
			blockBufferOut: &blockBuffer
		)
		guard let blockBuffer else { return nil }
		CMBlockBufferReplaceDataBytes(with: data, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: dataSize)

		var sampleBuffer: CMSampleBuffer?
		var timing = CMSampleTimingInfo(
			duration: CMTime(value: CMTimeValue(numFrames), timescale: CMTimeScale(sampleRate)),
			presentationTimeStamp: pts,
			decodeTimeStamp: .invalid
		)
		CMSampleBufferCreate(
			allocator: kCFAllocatorDefault,
			dataBuffer: blockBuffer,
			dataReady: true,
			makeDataReadyCallback: nil,
			refcon: nil,
			formatDescription: formatDescription,
			sampleCount: numFrames,
			sampleTimingEntryCount: 1,
			sampleTimingArray: &timing,
			sampleSizeEntryCount: 0,
			sampleSizeArray: nil,
			sampleBufferOut: &sampleBuffer
		)
		return sampleBuffer
	}

	func testSegmentStartMatchesFirstVideoPTSWithoutLeadingGap() async throws {
		let directory = try makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }

		let queue = DispatchQueue(label: "ReplayExporterTests.testQueue")
		let writer = ReplayWriter(queue: queue)
		let url = directory.appendingPathComponent("segment1.mov")
		try writer.configure(
			outputURL: url,
			videoSize: CGSize(width: 320, height: 240),
			includeAudio: true,
			audioSettings: audioSettings
		)

		let audioStart = CMTime(value: 1000, timescale: 60) 
		let videoStart = CMTime(value: 1003, timescale: 60) 

		if let audio = makeAudioSampleBuffer(pts: audioStart) {
			writer.appendAudio(audio)
		}
		if let video = makeVideoSampleBuffer(pts: videoStart) {
			writer.appendVideo(video)
		}

		for i in 1...10 {
			let pts = CMTimeAdd(videoStart, CMTime(value: Int64(i), timescale: 60))
			if let frame = makeVideoSampleBuffer(pts: pts) {
				writer.appendVideo(frame)
			}
		}

		let finishedURL = try await writer.finishWriting()
		let asset = AVURLAsset(url: finishedURL)
		let tracks = try await asset.loadTracks(withMediaType: .video)
		XCTAssertFalse(tracks.isEmpty, "Should have a video track")

		if let videoTrack = tracks.first {
			let timeRange = try await videoTrack.load(.timeRange)
			XCTAssertEqual(timeRange.start.seconds, 0.0, accuracy: 0.001)
			XCTAssertEqual(timeRange.duration.seconds, 11.0 / 60.0, accuracy: 0.01)
		}
	}

	func testMultiSegmentExporterStitchesSeamlessly() async throws {
		let directory = try makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }

		let queue = DispatchQueue(label: "ReplayExporterTests.multiSegment")

		let url1 = directory.appendingPathComponent("seg1.mov")
		let writer1 = ReplayWriter(queue: queue)
		try writer1.configure(outputURL: url1, videoSize: CGSize(width: 320, height: 240), includeAudio: true, audioSettings: audioSettings)
		let seg1Start = CMTime(value: 0, timescale: 60)
		for i in 0..<30 {
			let pts = CMTimeAdd(seg1Start, CMTime(value: Int64(i), timescale: 60))
			if let v = makeVideoSampleBuffer(pts: pts) { writer1.appendVideo(v) }
			if let a = makeAudioSampleBuffer(pts: pts) { writer1.appendAudio(a) }
		}
		let finishedURL1 = try await writer1.finishWriting()

		let url2 = directory.appendingPathComponent("seg2.mov")
		let writer2 = ReplayWriter(queue: queue)
		try writer2.configure(outputURL: url2, videoSize: CGSize(width: 320, height: 240), includeAudio: true, audioSettings: audioSettings)
		let seg2Start = CMTime(value: 30, timescale: 60)
		for i in 0..<30 {
			let pts = CMTimeAdd(seg2Start, CMTime(value: Int64(i), timescale: 60))
			if let v = makeVideoSampleBuffer(pts: pts) { writer2.appendVideo(v) }
			if let a = makeAudioSampleBuffer(pts: pts) { writer2.appendAudio(a) }
		}
		let finishedURL2 = try await writer2.finishWriting()

		let segments = [
			ReplaySegment(url: finishedURL1, duration: 0.5),
			ReplaySegment(url: finishedURL2, duration: 0.5)
		]

		let exporter = ReplayExporter()
		let exportURL = try await exporter.export(segments: segments, seconds: 1.0, container: .mov)
		defer { try? FileManager.default.removeItem(at: exportURL) }

		let exportedAsset = AVURLAsset(url: exportURL)
		let videoTracks = try await exportedAsset.loadTracks(withMediaType: .video)
		XCTAssertFalse(videoTracks.isEmpty)
		let duration = try await exportedAsset.load(.duration)
		XCTAssertGreaterThan(duration.seconds, 0.4)
	}

	func testManualExportPreservesTheEntireRecording() async throws {
		let directory = try makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }

		let queue = DispatchQueue(label: "ReplayExporterTests.manualRecording")
		let sourceURL = directory.appendingPathComponent("manual-source.mov")
		let writer = ReplayWriter(queue: queue)
		try writer.configure(
			outputURL: sourceURL,
			videoSize: CGSize(width: 320, height: 240),
			includeAudio: false,
			audioSettings: nil
		)

		for frame in 0 ..< 60 {
			let pts = CMTime(value: Int64(frame), timescale: 60)
			if let sample = makeVideoSampleBuffer(pts: pts) {
				writer.appendVideo(sample)
			}
		}

		let finishedURL = try await writer.finishWriting()
		let sourceTime = try await AVURLAsset(url: finishedURL).load(.duration)
		let sourceDuration = sourceTime.seconds
		let exporter = ReplayExporter()
		let outputURL = try await exporter.exportAll(
			segments: [ReplaySegment(url: finishedURL, duration: sourceDuration)],
			container: .mov,
			outputFolder: directory
		)

		let exportedTime = try await AVURLAsset(url: outputURL).load(.duration)
		let exportedDuration = exportedTime.seconds
		XCTAssertEqual(outputURL.deletingLastPathComponent(), directory)
		XCTAssertEqual(exportedDuration, sourceDuration, accuracy: 0.05)
	}
}
