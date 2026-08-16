import Foundation
@testable import Rewind
import XCTest

/// `finishWriting` resumes its continuation from either the writer's completion
/// handler or the timeout, on different queues. Resuming a `CheckedContinuation`
/// twice traps, so a broken guard crashes these tests rather than failing them.
final class ResumeOnceTests: XCTestCase {
	func testOnlyTheFirstResumeIsDelivered() async throws {
		let url = try await withCheckedThrowingContinuation {
			(continuation: CheckedContinuation<URL, Error>) in
			let once = ResumeOnce(continuation)
			once.resume(.success(URL(fileURLWithPath: "/first")))
			// Whatever loses the race must be a no-op, not a second resume.
			once.resume(.success(URL(fileURLWithPath: "/second")))
			once.resume(.failure(CaptureError.writerFinishTimedOut))
		}

		XCTAssertEqual(url.path, "/first")
	}

	func testFailureWinsWhenItArrivesFirst() async {
		do {
			_ = try await withCheckedThrowingContinuation {
				(continuation: CheckedContinuation<URL, Error>) in
				let once = ResumeOnce(continuation)
				once.resume(.failure(CaptureError.writerFinishTimedOut))
				once.resume(.success(URL(fileURLWithPath: "/late")))
			}
			XCTFail("Expected the timeout failure to be delivered")
		} catch {
			XCTAssertEqual(error as? CaptureError, .writerFinishTimedOut)
		}
	}

	func testConcurrentResumesFromManyThreadsResolveExactlyOnce() async throws {
		let url = try await withCheckedThrowingContinuation {
			(continuation: CheckedContinuation<URL, Error>) in
			let once = ResumeOnce(continuation)
			DispatchQueue.global().async {
				DispatchQueue.concurrentPerform(iterations: 64) { index in
					once.resume(.success(URL(fileURLWithPath: "/racer-\(index)")))
				}
			}
		}

		XCTAssertTrue(url.path.hasPrefix("/racer-"))
	}
}
