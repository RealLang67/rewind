@testable import Rewind
import RewindObjCSupport
import XCTest

/// Covers the ScreenCaptureKit stop callback, which macOS 14.7.2–15.3 can invoke
/// with a null error even though the delegate declares it nonnull.
///
/// These call the selector through the Obj-C runtime because Swift cannot express
/// the failure: `stream(_:didStopWithError:)` takes a non-optional `Error`, which
/// no Swift caller can be handed nil.
///
/// Handing the null straight to an `Error?` parameter happens to survive — Swift
/// bridges it to nil. It segfaults at the first real *use* of the value, so the
/// old crash landed downstream in `handleCaptureFailure`, on `localizedDescription`,
/// string interpolation, or an `as NSError` cast. These tests pin the contract that
/// keeps that from being possible: nothing but a plain `String?` leaves the observer.
final class StreamStopObserverTests: XCTestCase {
	private let selector = NSSelectorFromString("stream:didStopWithError:")

	func testNullErrorDoesNotCrashAndReportsNoReason() {
		let observer = RewindStreamStopObserver()

		var callbackCount = 0
		var reported: String?
		observer.onStop = { reason in
			callbackCount += 1
			reported = reason
		}

		XCTAssertTrue(observer.responds(to: selector))
		// Delivers exactly what the framework delivers: a null where the nonnull
		// annotation promises an error.
		observer.perform(selector, with: nil, with: nil)

		XCTAssertEqual(callbackCount, 1, "The stop callback should still fire without an error")
		XCTAssertNil(reported, "A null error must be reported as no reason, not a fabricated one")
	}

	func testRealErrorIsSummarizedIntoAnIndependentString() {
		let observer = RewindStreamStopObserver()

		var reported: String?
		observer.onStop = { reported = $0 }

		let error = NSError(
			domain: "SCStreamErrorDomain",
			code: -3805,
			userInfo: [NSLocalizedDescriptionKey: "The stream stopped"]
		)
		observer.perform(selector, with: nil, with: error)

		let reason = try? XCTUnwrap(reported)
		XCTAssertNotNil(reason)
		XCTAssertTrue(reported?.contains("SCStreamErrorDomain") == true)
		XCTAssertTrue(reported?.contains("-3805") == true)
		XCTAssertTrue(reported?.contains("The stream stopped") == true)
	}

	func testMissingHandlerIsNotAnError() {
		let observer = RewindStreamStopObserver()
		observer.onStop = nil
		observer.perform(selector, with: nil, with: nil)
	}

	func testStreamStoppedErrorDescribesBothCases() {
		XCTAssertEqual(
			CaptureError.streamStopped(reason: nil).errorDescription,
			"Screen capture stopped unexpectedly."
		)
		XCTAssertEqual(
			CaptureError.streamStopped(reason: "boom").errorDescription,
			"Screen capture stopped unexpectedly: boom"
		)
	}
}
