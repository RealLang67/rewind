import AVFoundation
import CoreMedia
import CoreVideo
@testable import Rewind
import XCTest

/// The queue holds video samples, which retain their pixel buffers, so its bound
/// has to be expressed in bytes: 120 frames means 373 MB at 1080p but 1.49 GB at 4K.
final class PendingSampleQueueTests: XCTestCase {
	private func makeVideoSample(width: Int, height: Int) throws -> CMSampleBuffer {
		var pixelBuffer: CVPixelBuffer?
		CVPixelBufferCreate(
			kCFAllocatorDefault,
			width,
			height,
			kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
			nil,
			&pixelBuffer
		)
		let buffer = try XCTUnwrap(pixelBuffer)

		var formatDescription: CMVideoFormatDescription?
		CMVideoFormatDescriptionCreateForImageBuffer(
			allocator: kCFAllocatorDefault, imageBuffer: buffer,
			formatDescriptionOut: &formatDescription
		)
		let format = try XCTUnwrap(formatDescription)

		var sampleBuffer: CMSampleBuffer?
		var timing = CMSampleTimingInfo(
			duration: CMTime(value: 1, timescale: 60),
			presentationTimeStamp: .zero,
			decodeTimeStamp: .invalid
		)
		CMSampleBufferCreateForImageBuffer(
			allocator: kCFAllocatorDefault, imageBuffer: buffer, dataReady: true,
			makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
			sampleTiming: &timing, sampleBufferOut: &sampleBuffer
		)
		return try XCTUnwrap(sampleBuffer)
	}

	private func makeQueue(capacity: Int, byteBudget: Int) -> PendingSampleQueue {
		PendingSampleQueue(
			capacity: capacity, byteBudget: byteBudget, label: "test", logInterval: 1_000
		)
	}

	// - Sizing ---

	func testByteSizeReflectsThePixelBuffer() throws {
		let small = try makeVideoSample(width: 64, height: 64)
		let large = try makeVideoSample(width: 256, height: 256)

		let smallBytes = PendingSampleQueue.byteSize(of: small)
		let largeBytes = PendingSampleQueue.byteSize(of: large)

		XCTAssertGreaterThan(smallBytes, 0)
		// NV12 is 1.5 bytes per pixel, so 16x the pixels is roughly 16x the memory.
		XCTAssertGreaterThan(largeBytes, smallBytes * 8)
	}

	// - Eviction ---

	func testEvictsOldestOnceTheByteBudgetIsExceeded() throws {
		let sample = try makeVideoSample(width: 128, height: 128)
		let frameBytes = PendingSampleQueue.byteSize(of: sample)

		// Room for three frames, but a count cap that would allow far more.
		var queue = makeQueue(capacity: 500, byteBudget: frameBytes * 3)
		for _ in 0 ..< 20 {
			queue.enqueue(try makeVideoSample(width: 128, height: 128))
		}

		XCTAssertLessThanOrEqual(queue.byteCount, frameBytes * 3)
		XCTAssertEqual(queue.count, 3, "The byte budget should bind before the count cap")
		XCTAssertEqual(queue.drops, 17)
	}

	func testCountCapStillAppliesForTinySamples() throws {
		let sample = try makeVideoSample(width: 16, height: 16)
		var queue = makeQueue(capacity: 4, byteBudget: PendingSampleQueue.byteSize(of: sample) * 1_000)

		for _ in 0 ..< 10 {
			queue.enqueue(try makeVideoSample(width: 16, height: 16))
		}

		XCTAssertEqual(queue.count, 4, "The count cap should bind when samples are small")
	}

	func testASingleOversizedSampleIsKept() throws {
		var queue = makeQueue(capacity: 100, byteBudget: 1)

		queue.enqueue(try makeVideoSample(width: 128, height: 128))

		XCTAssertEqual(queue.count, 1, "Dropping to empty would be worse than exceeding the budget")
		XCTAssertGreaterThan(queue.byteCount, 1)
	}

	// - Accounting ---

	func testDequeueReleasesItsBytes() throws {
		var queue = makeQueue(capacity: 100, byteBudget: .max)
		for _ in 0 ..< 4 {
			queue.enqueue(try makeVideoSample(width: 64, height: 64))
		}
		let full = queue.byteCount
		XCTAssertGreaterThan(full, 0)

		XCTAssertNotNil(queue.dequeue())
		XCTAssertLessThan(queue.byteCount, full)

		while queue.dequeue() != nil {}
		XCTAssertEqual(queue.byteCount, 0, "Draining the queue must zero the byte count")
		XCTAssertTrue(queue.isEmpty)
	}

	func testReplaceAllRecomputesTheByteCount() throws {
		var queue = makeQueue(capacity: 100, byteBudget: .max)
		for _ in 0 ..< 5 {
			queue.enqueue(try makeVideoSample(width: 64, height: 64))
		}

		let replacement = [try makeVideoSample(width: 64, height: 64)]
		queue.replaceAll(replacement)

		XCTAssertEqual(queue.count, 1)
		XCTAssertEqual(queue.byteCount, PendingSampleQueue.byteSize(of: replacement[0]))
	}

	func testRemoveAllResetsEverything() throws {
		var queue = makeQueue(capacity: 2, byteBudget: .max)
		for _ in 0 ..< 6 {
			queue.enqueue(try makeVideoSample(width: 64, height: 64))
		}
		XCTAssertGreaterThan(queue.drops, 0)

		queue.removeAll()

		XCTAssertTrue(queue.isEmpty)
		XCTAssertEqual(queue.byteCount, 0)
		XCTAssertEqual(queue.drops, 0)
	}

	// - The ceiling this exists to enforce ---

	func testCeilingNoLongerScalesWithResolution() throws {
		// A 4K frame is ~12.4 MB; the shipped budget must keep the queue well under
		// the ~1.5 GB that 120 uncapped 4K frames used to reach.
		let budget = ReplayWriter.Constants.maxPendingVideoBytes
		var queue = makeQueue(
			capacity: ReplayWriter.Constants.maxPendingVideoSamples, byteBudget: budget
		)

		for _ in 0 ..< 40 {
			queue.enqueue(try makeVideoSample(width: 640, height: 360))
		}

		XCTAssertLessThanOrEqual(queue.byteCount, budget)
		XCTAssertLessThan(budget, 512 * 1_024 * 1_024, "Budget should stay clear of jetsam range")
	}
}
