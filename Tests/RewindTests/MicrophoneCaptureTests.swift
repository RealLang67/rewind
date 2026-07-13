import AVFoundation
import CoreMedia
import CoreVideo
@testable import Rewind
import XCTest

final class MicrophoneCaptureTests: XCTestCase {
	private func makeTempDirectory() throws -> URL {
		let base = FileManager.default.temporaryDirectory
		let dir = base.appendingPathComponent("MicrophoneCaptureTests-\(UUID().uuidString)", isDirectory: true)
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

	private func makeVideoSampleBuffer(pts: CMTime, size: CGSize = CGSize(width: 32, height: 32)) -> CMSampleBuffer? {
		var pixelBuffer: CVPixelBuffer?
		CVPixelBufferCreate(
			kCFAllocatorDefault,
			Int(size.width),
			Int(size.height),
			kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
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
			allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
			magicCookieSize: 0, magicCookie: nil, extensions: nil,
			formatDescriptionOut: &formatDescription)
		guard let formatDescription else { return nil }

		let bytesPerFrame = Int(asbd.mBytesPerFrame)
		let dataLength = bytesPerFrame * numFrames
		var blockBuffer: CMBlockBuffer?
		CMBlockBufferCreateWithMemoryBlock(
			allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: dataLength,
			blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
			dataLength: dataLength, flags: 0, blockBufferOut: &blockBuffer)
		guard let blockBuffer else { return nil }
		CMBlockBufferFillDataBytes(
			with: 0, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: dataLength)

		var sampleBuffer: CMSampleBuffer?
		var timing = CMSampleTimingInfo(
			duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
			presentationTimeStamp: pts, decodeTimeStamp: .invalid)
		var sampleSize = size_t(bytesPerFrame)
		CMSampleBufferCreateReady(
			allocator: kCFAllocatorDefault, dataBuffer: blockBuffer,
			formatDescription: formatDescription, sampleCount: numFrames,
			sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
			sampleSizeArray: &sampleSize, sampleBufferOut: &sampleBuffer)
		return sampleBuffer
	}

	private func finishAndCountAudioTracks(_ writer: ReplayWriter) async throws -> Int {
		let outputURL = try await writer.finishWriting()
		defer { try? FileManager.default.removeItem(at: outputURL) }
		let asset = AVURLAsset(url: outputURL)
		let tracks = try await asset.loadTracks(withMediaType: .audio)
		return tracks.count
	}

	func testConfigureWithMicrophoneEnabledWritesSeparateMicTrack() async throws {
		let directory = try makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }

		let writer = ReplayWriter(queue: DispatchQueue(label: "MicrophoneCaptureTests.withMic"))
		try writer.configure(
			outputURL: directory.appendingPathComponent("with-mic.mov"),
			videoSize: CGSize(width: 32, height: 32),
			includeAudio: true,
			audioSettings: audioSettings,
			recordMicrophone: true
		)

		guard let video = makeVideoSampleBuffer(pts: .zero),
			let systemAudio = makeAudioSampleBuffer(pts: .zero),
			let micAudio = makeAudioSampleBuffer(pts: .zero)
		else {
			XCTFail("Failed to construct sample buffers")
			return
		}

		writer.appendVideo(video)
		writer.appendAudio(systemAudio)
		writer.appendMic(micAudio)

		try await Task.sleep(nanoseconds: 200_000_000)

		let audioTrackCount = try await finishAndCountAudioTracks(writer)
		XCTAssertEqual(audioTrackCount, 2, "Expected separate system-audio and microphone tracks")
	}

	func testConfigureWithMicrophoneDisabledWritesSingleAudioTrack() async throws {
		let directory = try makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }

		let writer = ReplayWriter(queue: DispatchQueue(label: "MicrophoneCaptureTests.withoutMic"))
		try writer.configure(
			outputURL: directory.appendingPathComponent("without-mic.mov"),
			videoSize: CGSize(width: 32, height: 32),
			includeAudio: true,
			audioSettings: audioSettings,
			recordMicrophone: false
		)

		guard let video = makeVideoSampleBuffer(pts: .zero),
			let systemAudio = makeAudioSampleBuffer(pts: .zero),
			let micAudio = makeAudioSampleBuffer(pts: .zero)
		else {
			XCTFail("Failed to construct sample buffers")
			return
		}

		writer.appendVideo(video)
		writer.appendAudio(systemAudio)
		// mic samples should be silently dropped when microphone recording is disabled.
		writer.appendMic(micAudio)

		try await Task.sleep(nanoseconds: 200_000_000)

		let audioTrackCount = try await finishAndCountAudioTracks(writer)
		XCTAssertEqual(audioTrackCount, 1, "Mic track should not be written when disabled")
	}

	func testAppendMicBeforeConfigureDoesNotCrashOrAffectFinishWriting() async {
		let writer = ReplayWriter(queue: DispatchQueue(label: "MicrophoneCaptureTests.unconfigured"))
		guard let micAudio = makeAudioSampleBuffer(pts: .zero) else {
			XCTFail("Failed to construct sample buffer")
			return
		}

		writer.appendMic(micAudio)

		do {
			_ = try await writer.finishWriting()
			XCTFail("Expected finishWriting to throw")
		} catch let error as CaptureError {
			XCTAssertEqual(error, .writerUnavailable)
		} catch {
			XCTFail("Expected CaptureError, got \(type(of: error))")
		}
	}

	func testAppSettingsRoundTripsRecordMicrophoneEnabled() {
		let defaults = UserDefaults.standard
		let storageKey = "settings.app.v1"
		defaults.removeObject(forKey: storageKey)
		defer { defaults.removeObject(forKey: storageKey) }

		var settings = AppSettings.default
		settings.recordMicrophoneEnabled = true
		AppSettingsStorage.save(settings)

		let loaded = AppSettingsStorage.load()
		XCTAssertTrue(loaded.recordMicrophoneEnabled)
	}
}
