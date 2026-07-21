import Foundation

/// A running performance span. Obtain one from `Perf.transaction`, then `finish`
/// it when the work completes. Every method is a no-op when tracing is inactive,
/// so call sites never have to check whether a reporter is configured.
protocol PerfSpan: AnyObject {
	func setTag(_ value: String, forKey key: String)
	func setData(_ value: Any, forKey key: String)
	func child(_ operation: String) -> PerfSpan
	func finish()
	func finish(failed: Bool)
}

/// Provider-agnostic performance-tracing seam. `CrashReporter` installs the
/// backing factory at launch (wired to Sentry transactions); until then — and in
/// builds with no reporter — `transaction` hands back a no-op span. Keeps the
/// capture/export code free of any direct Sentry dependency.
enum Perf {
	private static let lock = NSLock()
	private nonisolated(unsafe) static var _factory: (@Sendable (String, String) -> PerfSpan)?

	static func install(_ factory: (@Sendable (String, String) -> PerfSpan)?) {
		lock.lock()
		_factory = factory
		lock.unlock()
	}

	static func transaction(_ name: String, operation: String) -> PerfSpan {
		lock.lock()
		let factory = _factory
		lock.unlock()
		return factory?(name, operation) ?? NoopPerfSpan()
	}
}

final class NoopPerfSpan: PerfSpan {
	func setTag(_ value: String, forKey key: String) {}
	func setData(_ value: Any, forKey key: String) {}
	func child(_ operation: String) -> PerfSpan { self }
	func finish() {}
	func finish(failed: Bool) {}
}
