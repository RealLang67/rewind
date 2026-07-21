import Foundation
import Sentry

/// Thin wrapper around the Sentry SDK for crash and error reporting.
///
/// Kept separate from `AppLog` so the logging layer stays dependency-free; when
/// active it wires itself in as `AppLog`'s breadcrumb and error sinks. A no-op
/// unless a DSN is configured (the `SentryDSN` Info.plist key, set at build time
/// from `SENTRY_DSN`), so local and dev builds never phone home. When a DSN is
/// present, reporting is also gated on the runtime `crashReportingEnabled`
/// preference.
enum CrashReporter {
	private static let lock = NSLock()
	private nonisolated(unsafe) static var running = false

	/// whether a DSN is baked into this build. when false, sentry can never run,
	/// so `AppLog` should install its own fallback crash handlers instead
	static var isConfigured: Bool { resolvedDSN() != nil }

	/// starts Sentry if a DSN is present and the user hasnt opted out. call once,
	/// early at launch, passing the persisted preference
	static func start(enabled: Bool) {
		guard resolvedDSN() != nil else {
			AppLog.info(.app, "Sentry disabled: no DSN configured")
			return
		}
		guard enabled else {
			AppLog.info(.app, "Sentry disabled: crash reporting turned off by user")
			return
		}
		startSDK()
	}

	/// reacts to the user toggling crash reporting at runtime. starts the sdk when
	/// turned on (if a DSN exists) and shuts it down when turned off.
	static func setEnabled(_ enabled: Bool) {
		guard resolvedDSN() != nil else { return }
		if enabled {
			startSDK()
		} else {
			stopSDK()
		}
	}

	// - Lifecycle ---

	private static func startSDK() {
		lock.lock()
		defer { lock.unlock() }
		guard !running, let dsn = resolvedDSN() else { return }

		SentrySDK.start { options in
			options.dsn = dsn
			options.releaseName = releaseName
			options.environment = environment
			options.tracesSampleRate = 1.0
			options.configureProfiling = {
				$0.lifecycle = .trace
				$0.sessionSampleRate = 1.0
			}
			options.sendDefaultPii = false
			options.attachStacktrace = true
			options.enableAppHangTracking = true
			#if DEBUG
				options.debug = true
			#endif
			// strip the home-directory path from every outgoing event
			options.beforeSend = { event in
				scrub(event)
				return event
			}
		}

		running = true
		AppLog.info(.app, "Sentry started. env:", environment, "release:", releaseName)

		// every line becomes a breadcrumb 
		// errors are also captured as issues
		AppLog.breadcrumbReporter = { level, category, message in
			let crumb = Breadcrumb(level: breadcrumbLevel(for: level), category: category)
			crumb.message = redact(message)
			SentrySDK.addBreadcrumb(crumb)
		}
		AppLog.errorReporter = { message in
			SentrySDK.capture(message: redact(message)) { scope in
				scope.setLevel(.error)
			}
		}

		Perf.install { name, operation in
			SentryPerfSpan(SentrySDK.startTransaction(name: name, operation: operation))
		}
	}

	private static func stopSDK() {
		lock.lock()
		defer { lock.unlock() }
		guard running else { return }

		AppLog.breadcrumbReporter = nil
		AppLog.errorReporter = nil
		Perf.install(nil)
		SentrySDK.close()
		running = false
		AppLog.info(.app, "Sentry stopped")
	}

	// - Configuration ---

	private static func resolvedDSN() -> String? {
		clean(Bundle.main.object(forInfoDictionaryKey: "SentryDSN") as? String)
			?? clean(ProcessInfo.processInfo.environment["SENTRY_DSN"])
	}

	private static var releaseName: String {
		let version =
			clean(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
			?? "0.0.0"
		return "rewind@\(version)"
	}

	private static var environment: String {
	    if let env = clean(Bundle.main.object(forInfoDictionaryKey: "SentryEnvironment") as? String)
			?? clean(ProcessInfo.processInfo.environment["SENTRY_ENVIRONMENT"])
		{
			return env
		}
		#if DEBUG
			return "development"
		#else
			return "production"
		#endif
	}

	private static func breadcrumbLevel(for levelString: String) -> SentryLevel {
		switch levelString {
		case "ERROR": return .error
		case "INFO": return .info
		default: return .debug
		}
	}

	private static func clean(_ value: String?) -> String? {
		guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
			!trimmed.isEmpty
		else { return nil }
		return trimmed
	}

	// - PII scrubbing ---

	/// replaces the account's home-directory prefix with `~`
	private static func redact(_ string: String) -> String {
		let home = NSHomeDirectory()
		guard !home.isEmpty else { return string }
		return string.replacingOccurrences(of: home, with: "~")
	}

	private static func scrub(_ event: Event) {
		if let formatted = event.message?.formatted {
			event.message = SentryMessage(formatted: redact(formatted))
		}
		event.breadcrumbs = event.breadcrumbs?.map { crumb in
			if let message = crumb.message {
				crumb.message = redact(message)
			}
			return crumb
		}
		event.exceptions = event.exceptions?.map { exception in
			if let value = exception.value as String? {
				exception.value = redact(value)
			}
			return exception
		}
	}
}

/// adapts a sentry `Span` to the provider-agnostic `PerfSpan` seam 
/// sentry spans are internally thread-safe, so `@unchecked Sendable` is good
private final class SentryPerfSpan: PerfSpan, @unchecked Sendable {
	private let span: any Span

	init(_ span: any Span) {
		self.span = span
	}

	func setTag(_ value: String, forKey key: String) {
		span.setTag(value: value, key: key)
	}

	func setData(_ value: Any, forKey key: String) {
		span.setData(value: value, key: key)
	}

	func child(_ operation: String) -> PerfSpan {
		SentryPerfSpan(span.startChild(operation: operation))
	}

	func finish() {
		span.finish()
	}

	func finish(failed: Bool) {
		span.finish(status: failed ? .internalError : .ok)
	}
}
