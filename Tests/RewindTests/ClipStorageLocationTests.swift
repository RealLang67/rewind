import Foundation
@testable import Rewind
import XCTest

final class ClipStorageLocationTests: XCTestCase {
	func testFolderFallsBackToDefaultWhenNoCustomPath() {
		XCTAssertEqual(
			ClipStorageLocation.folder(outputDirectoryPath: nil).path,
			ClipStorageLocation.defaultFolder.path)
	}

	func testFolderHonorsCustomPath() {
		let custom = "/Users/example/Desktop/Clips"
		XCTAssertEqual(ClipStorageLocation.folder(outputDirectoryPath: custom).path, custom)
	}
}
