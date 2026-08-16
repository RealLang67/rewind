import AppKit
@testable import Rewind
import XCTest

/// Records how often the (expensive) generator actually ran, and how many ran at
/// the same time.
private actor GenerationRecorder {
	private(set) var calls = 0
	private(set) var peakConcurrency = 0
	private var active = 0
	private var delay: Duration = .zero

	init(delay: Duration = .zero) {
		self.delay = delay
	}

	func begin() async {
		calls += 1
		active += 1
		peakConcurrency = max(peakConcurrency, active)
		if delay > .zero {
			try? await Task.sleep(for: delay)
		}
		active -= 1
	}
}

@MainActor
final class ClipThumbnailCacheTests: XCTestCase {
	private var directory: URL!

	override func setUpWithError() throws {
		directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("thumb-tests-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws {
		try? FileManager.default.removeItem(at: directory)
	}

	// - Helpers ---

	private func makeImage() -> NSImage {
		let image = NSImage(size: NSSize(width: 16, height: 9))
		image.lockFocus()
		NSColor.systemTeal.setFill()
		NSRect(x: 0, y: 0, width: 16, height: 9).fill()
		image.unlockFocus()
		return image
	}

	/// A stand-in for the clip file itself; only its modification date matters here.
	private func makeClip() throws -> Clip {
		let url = directory.appendingPathComponent("\(UUID().uuidString).mov")
		try Data("not really a movie".utf8).write(to: url)
		return Clip(url: url, duration: 30)
	}

	private func makeCache(recorder: GenerationRecorder) -> ClipThumbnailCache {
		let image = makeImage()
		return ClipThumbnailCache(directory: directory) { _, _ in
			await recorder.begin()
			return UncheckedSendable(image)
		}
	}

	// - Tests ---

	func testGeneratesOnceThenServesFromMemory() async throws {
		let clip = try makeClip()
		let recorder = GenerationRecorder()
		let cache = makeCache(recorder: recorder)

		let first = await cache.thumbnail(for: clip)
		let second = await cache.thumbnail(for: clip)
		let third = await cache.thumbnail(for: clip)

		XCTAssertNotNil(first)
		XCTAssertNotNil(second)
		XCTAssertNotNil(third)
		let calls = await recorder.calls
		XCTAssertEqual(calls, 1, "Repeat lookups must not decode the clip again")
	}

	func testSurvivesANewCacheInstanceViaDisk() async throws {
		let clip = try makeClip()

		let firstRecorder = GenerationRecorder()
		_ = await makeCache(recorder: firstRecorder).thumbnail(for: clip)
		let firstCalls = await firstRecorder.calls
		XCTAssertEqual(firstCalls, 1)

		// A fresh instance stands in for the next app launch: nothing in memory,
		// but the thumbnail is still on disk.
		let secondRecorder = GenerationRecorder()
		let reloaded = await makeCache(recorder: secondRecorder).thumbnail(for: clip)

		XCTAssertNotNil(reloaded)
		let secondCalls = await secondRecorder.calls
		XCTAssertEqual(secondCalls, 0, "A relaunch should read the stored thumbnail, not rebuild it")
	}

	func testClipRewrittenAfterCachingIsRegenerated() async throws {
		let clip = try makeClip()
		let recorder = GenerationRecorder()

		_ = await makeCache(recorder: recorder).thumbnail(for: clip)

		// Trimming rewrites the clip in place, which bumps its modification date.
		try FileManager.default.setAttributes(
			[.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: clip.url.path
		)

		let secondRecorder = GenerationRecorder()
		_ = await makeCache(recorder: secondRecorder).thumbnail(for: clip)

		let calls = await secondRecorder.calls
		XCTAssertEqual(calls, 1, "A newer clip file must invalidate the stored thumbnail")
	}

	func testInvalidateClearsMemoryAndDisk() async throws {
		let clip = try makeClip()
		let recorder = GenerationRecorder()
		let cache = makeCache(recorder: recorder)

		_ = await cache.thumbnail(for: clip)
		cache.invalidate(clipID: clip.id)
		_ = await cache.thumbnail(for: clip)

		let calls = await recorder.calls
		XCTAssertEqual(calls, 2, "After invalidation the thumbnail must be rebuilt")

		cache.invalidate(clipID: clip.id)
		let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
			.filter { $0.hasSuffix(".jpg") }
		XCTAssertTrue(leftovers.isEmpty, "Invalidation should remove the stored file too")
	}

	func testConcurrentRequestsForOneClipShareASingleGeneration() async throws {
		let clip = try makeClip()
		let recorder = GenerationRecorder(delay: .milliseconds(50))
		let cache = makeCache(recorder: recorder)

		await withTaskGroup(of: Bool.self) { group in
			for _ in 0 ..< 12 {
				group.addTask { await cache.thumbnail(for: clip) != nil }
			}
			for await produced in group {
				XCTAssertTrue(produced)
			}
		}

		let calls = await recorder.calls
		XCTAssertEqual(calls, 1, "Every cell asking at once should share one decode")
	}

	func testManyDistinctClipsStayWithinTheConcurrencyCap() async throws {
		let clips = try (0 ..< 24).map { _ in try makeClip() }
		let recorder = GenerationRecorder(delay: .milliseconds(20))
		let cache = makeCache(recorder: recorder)

		// Also proves the slot hand-off in releaseGenerationSlot() cannot deadlock:
		// this would hang rather than fail if a waiter were never resumed.
		await withTaskGroup(of: Void.self) { group in
			for clip in clips {
				group.addTask { _ = await cache.thumbnail(for: clip) }
			}
			await group.waitForAll()
		}

		let calls = await recorder.calls
		let peak = await recorder.peakConcurrency
		XCTAssertEqual(calls, clips.count)
		XCTAssertLessThanOrEqual(peak, 2, "Generation must stay capped so it can't starve the encoder")
		XCTAssertGreaterThan(peak, 0)
	}
}
