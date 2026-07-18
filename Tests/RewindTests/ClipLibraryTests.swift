import Foundation
@testable import Rewind
import XCTest

private actor TestClipStore: ClipStore {
	private let fetchResult: Result<[Clip], Error>
	private var saved: [Clip] = []
	private var deleted: [UUID] = []

	init(fetchResult: Result<[Clip], Error>) {
		self.fetchResult = fetchResult
	}

	func fetchAll() async throws -> [Clip] {
		try fetchResult.get()
	}

	func save(clip: Clip) async throws -> Clip {
		saved.append(clip)
		return clip
	}

	func delete(id: UUID) async throws {
		deleted.append(id)
	}

	func savedClips() -> [Clip] {
		saved
	}

	func deletedIDs() -> [UUID] {
		deleted
	}
}

private enum ClipLibraryTestError: Error {
	case fetchFailed
}

@MainActor
final class ClipLibraryTests: XCTestCase {
	private func waitForLoadCompletion(_ library: ClipLibrary, timeout: TimeInterval = 1.0) async {
		let deadline = Date().addingTimeInterval(timeout)
		while library.isLoading, Date() < deadline {
			try? await Task.sleep(nanoseconds: 10_000_000)
		}
		XCTAssertFalse(library.isLoading, "Expected initial clip load to complete")
	}

	private func makeClipFileInMovies() throws -> URL {
		try makeClipFile(in: ClipStorageLocation.defaultFolder)
	}

	private func makeTempFolder() throws -> URL {
		let folder = FileManager.default.temporaryDirectory
			.appendingPathComponent("ClipLibraryTests-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		return folder
	}

	private func makeClipFile(in folder: URL) throws -> URL {
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		let url = folder.appendingPathComponent("ClipLibraryTests-\(UUID().uuidString).mov")
		FileManager.default.createFile(atPath: url.path, contents: Data([1, 2, 3]))
		return url
	}

	func testInitLoadsClipsFromStore() async throws {
		let fileURL = try makeClipFileInMovies()
		defer { try? FileManager.default.removeItem(at: fileURL) }
		let expectedClip = Clip(url: fileURL, duration: 12)
		let store = TestClipStore(fetchResult: .success([expectedClip]))

		let library = ClipLibrary(store: store)
		await waitForLoadCompletion(library)

		XCTAssertNil(library.loadError)
		XCTAssertEqual(library.clips.count, 1)
		XCTAssertEqual(library.clips.first?.id, expectedClip.id)
		XCTAssertEqual(library.clips.first?.url, expectedClip.url)
		let deleted = await store.deletedIDs()
		XCTAssertTrue(deleted.isEmpty)
	}

	func testInitPrunesClipsWhoseFileIsMissing() async throws {
		let presentURL = try makeClipFileInMovies()
		defer { try? FileManager.default.removeItem(at: presentURL) }
		let presentClip = Clip(url: presentURL, duration: 10)
		let missingClip = Clip(url: URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).mov"), duration: 8)
		let store = TestClipStore(fetchResult: .success([presentClip, missingClip]))

		let library = ClipLibrary(store: store)
		await waitForLoadCompletion(library)

		XCTAssertNil(library.loadError)
		XCTAssertEqual(library.clips.map(\.id), [presentClip.id])
		let deleted = await store.deletedIDs()
		XCTAssertEqual(deleted, [missingClip.id])
	}

	func testInitSetsLoadErrorWhenFetchFails() async {
		let store = TestClipStore(fetchResult: .failure(ClipLibraryTestError.fetchFailed))

		let library = ClipLibrary(store: store)
		await waitForLoadCompletion(library)

		XCTAssertTrue(library.clips.isEmpty)
		XCTAssertNotNil(library.loadError)
	}

	func testDeleteClipRemovesFileRowAndPublishedEntry() async throws {
		let fileURL = try makeClipFileInMovies()
		defer { try? FileManager.default.removeItem(at: fileURL) }
		let clip = Clip(url: fileURL, duration: 5)
		let store = TestClipStore(fetchResult: .success([clip]))

		let library = ClipLibrary(store: store)
		await waitForLoadCompletion(library)
		XCTAssertEqual(library.clips.count, 1)

		await library.deleteClip(clip)

		XCTAssertTrue(library.clips.isEmpty)
		XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
		let deleted = await store.deletedIDs()
		XCTAssertEqual(deleted, [clip.id])
	}

	func testAddClipSavesToStoreAndPublishedCollection() async throws {
		let folder = try makeTempFolder()
		defer { try? FileManager.default.removeItem(at: folder) }
		let store = TestClipStore(fetchResult: .success([]))
		let library = ClipLibrary(store: store, outputDirectory: { folder })
		await waitForLoadCompletion(library)

		let sourceURL = try makeClipFile(in: folder)

		let clip = try await library.addClip(url: sourceURL, duration: 27.5)

		XCTAssertEqual(clip.url, sourceURL)
		XCTAssertEqual(clip.duration, 27.5)
		XCTAssertEqual(library.clips.count, 1)
		XCTAssertEqual(library.clips.first?.id, clip.id)

		let saved = await store.savedClips()
		XCTAssertEqual(saved.count, 1)
		XCTAssertEqual(saved.first?.id, clip.id)
		XCTAssertEqual(saved.first?.duration, 27.5)
	}

	func testAddClipKeepsFileInCustomOutputDirectory() async throws {
		let customFolder = try makeTempFolder()
		defer { try? FileManager.default.removeItem(at: customFolder) }
		let store = TestClipStore(fetchResult: .success([]))
		let library = ClipLibrary(store: store, outputDirectory: { customFolder })
		await waitForLoadCompletion(library)

		let sourceURL = try makeClipFile(in: customFolder)

		let clip = try await library.addClip(url: sourceURL, duration: 12)

		XCTAssertEqual(clip.url, sourceURL, "A clip already in the configured folder must not be relocated")
		XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
	}

	func testAddClipRelocatesFileFromOutsideConfiguredDirectory() async throws {
		let configuredFolder = try makeTempFolder()
		let externalFolder = try makeTempFolder()
		defer {
			try? FileManager.default.removeItem(at: configuredFolder)
			try? FileManager.default.removeItem(at: externalFolder)
		}
		let store = TestClipStore(fetchResult: .success([]))
		let library = ClipLibrary(store: store, outputDirectory: { configuredFolder })
		await waitForLoadCompletion(library)

		let sourceURL = try makeClipFile(in: externalFolder)

		let clip = try await library.addClip(url: sourceURL, duration: 8)

		XCTAssertTrue(
			ClipStorageLocation.contains(clip.url, folder: configuredFolder),
			"A clip added from outside the configured folder must be moved into it")
		XCTAssertTrue(FileManager.default.fileExists(atPath: clip.url.path))
		XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
	}
}
