import AVFoundation
import AppKit

/// Generates a clip's grid thumbnail once and reuses it afterwards, in memory and
/// on disk.
///
/// Decoding a frame costs roughly 70ms, and `LazyVGrid` throws away a cell's
/// `@State` when it scrolls out of view — so without this every scroll pass
/// re-decoded every visible clip. That work also lands on the same media hardware
/// the live encoder is using, so an uncached library could starve a recording in
/// progress. Generation is capped at two at a time for the same reason.
actor ClipThumbnailCache {
	static let shared = ClipThumbnailCache()

	/// Matches the grid cell, which never displays larger than this.
	static let thumbnailSize = CGSize(width: 480, height: 270)
	private static let compressionQuality = 0.8

	private let directory: URL
	private let generate: @Sendable (URL, CGSize) async -> NSImage?
	private let memory = NSCache<NSString, NSImage>()

	/// Shares one generation between every cell asking for the same clip.
	private var inFlight: [UUID: Task<NSImage?, Never>] = [:]

	private let maxConcurrentGenerations = 2
	private var runningGenerations = 0
	private var waiting: [CheckedContinuation<Void, Never>] = []

	init(
		directory: URL? = nil,
		generate: @escaping @Sendable (URL, CGSize) async -> NSImage? = ClipThumbnailCache
			.decodeFirstFrame
	) {
		if let directory {
			self.directory = directory
		} else {
			let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
				.first ?? FileManager.default.temporaryDirectory
			self.directory = base
				.appendingPathComponent("Rewind", isDirectory: true)
				.appendingPathComponent("Thumbnails", isDirectory: true)
		}
		self.generate = generate
		memory.countLimit = 300
		try? FileManager.default.createDirectory(
			at: self.directory, withIntermediateDirectories: true
		)
	}

	func thumbnail(for clip: Clip) async -> NSImage? {
		let key = clip.id.uuidString as NSString
		if let cached = memory.object(forKey: key) {
			return cached
		}
		if let existing = inFlight[clip.id] {
			return await existing.value
		}

		let task = Task<NSImage?, Never> { [weak self] in
			await self?.load(clip: clip) ?? nil
		}
		inFlight[clip.id] = task
		let image = await task.value
		inFlight[clip.id] = nil
		return image
	}

	/// Drops a clip's thumbnail. Trimming rewrites the clip in place, so the
	/// cached frame no longer represents it.
	func invalidate(clipID: UUID) {
		memory.removeObject(forKey: clipID.uuidString as NSString)
		try? FileManager.default.removeItem(at: fileURL(for: clipID))
	}

	// - Loading ---

	private func load(clip: Clip) async -> NSImage? {
		if let onDisk = loadFromDisk(clip: clip) {
			memory.setObject(onDisk, forKey: clip.id.uuidString as NSString)
			return onDisk
		}

		await acquireGenerationSlot()
		let generated = await generate(clip.url, Self.thumbnailSize)
		releaseGenerationSlot()

		guard let generated else { return nil }
		memory.setObject(generated, forKey: clip.id.uuidString as NSString)
		writeToDisk(generated, clipID: clip.id)
		return generated
	}

	/// Returns the stored thumbnail only when it is at least as new as the clip,
	/// so a trimmed clip regenerates instead of showing its old first frame.
	private func loadFromDisk(clip: Clip) -> NSImage? {
		let thumbnailURL = fileURL(for: clip.id)
		guard let thumbnailDate = modificationDate(of: thumbnailURL) else { return nil }
		if let clipDate = modificationDate(of: clip.url), clipDate > thumbnailDate {
			return nil
		}
		guard let data = try? Data(contentsOf: thumbnailURL) else { return nil }
		return NSImage(data: data)
	}

	private func writeToDisk(_ image: NSImage, clipID: UUID) {
		guard let data = Self.jpegData(from: image) else { return }
		try? data.write(to: fileURL(for: clipID), options: .atomic)
	}

	private func fileURL(for clipID: UUID) -> URL {
		directory.appendingPathComponent("\(clipID.uuidString).jpg")
	}

	private func modificationDate(of url: URL) -> Date? {
		try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
	}

	// - Generation throttle ---

	private func acquireGenerationSlot() async {
		if runningGenerations < maxConcurrentGenerations {
			runningGenerations += 1
			return
		}
		await withCheckedContinuation { continuation in
			waiting.append(continuation)
		}
		// The slot was handed over directly by releaseGenerationSlot().
	}

	private func releaseGenerationSlot() {
		if waiting.isEmpty {
			runningGenerations -= 1
		} else {
			// Pass the slot straight to the next waiter so the count stays exact.
			waiting.removeFirst().resume()
		}
	}

	// - Helpers ---

	static func decodeFirstFrame(url: URL, size: CGSize) async -> NSImage? {
		let asset = AVURLAsset(url: url)
		let generator = AVAssetImageGenerator(asset: asset)
		generator.appliesPreferredTrackTransform = true
		generator.maximumSize = size
		do {
			let cgImage = try await generator.image(at: .zero).image
			return NSImage(
				cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height)
			)
		} catch {
			AppLog.debug(.library, "Thumbnail generation failed for", url.lastPathComponent)
			return nil
		}
	}

	static func jpegData(from image: NSImage) -> Data? {
		guard let tiff = image.tiffRepresentation,
		      let bitmap = NSBitmapImageRep(data: tiff)
		else { return nil }
		return bitmap.representation(
			using: .jpeg, properties: [.compressionFactor: compressionQuality]
		)
	}
}
