import Foundation
import Sentry

/// Thin wrapper around the Sentry SDK for crash and error reporting.
///
/// Kept separate from `AppLog` so the logging layer stays dependency-free — at
/// launch this wires itself in as `AppLog`'s error sink. Reporting is a no-op
/// unless a DSN is configured (via the `SentryDSN` Info.plist key, populated at
/// build time from the `SENTRY_DSN` environment variable), so local and dev
/// builds without a DSN never phone home.
enum CrashReporter {
	private static let lock = NSLock()
	private nonisolated(unsafe) static var started = false

	/// Starts Sentry when a DSN is present, and forwards error-level `AppLog`
	/// entries to it as breadcrumbs. Crashes and unhandled exceptions are captured
	/// automatically by the SDK. Safe to call once, early at launch.
	static func start() {
		lock.lock()
		defer { lock.unlock() }
		guard !started else { return }

		guard let dsn = resolvedDSN() else {
			AppLog.info(.app, "Sentry disabled: no DSN configured")
			return
		}

		SentrySDK.start { options in
			options.dsn = dsn
			options.releaseName = releaseName
			options.environment = environment
			// Crashes and errors only — no performance tracing, no PII.
			options.tracesSampleRate = 0.0
			options.sendDefaultPii = false
			options.attachStacktrace = true
			options.enableAppHangTracking = true
			#if DEBUG
				options.debug = true
			#endif
			// Redact the user's home directory from outgoing events so local file
			// paths in error messages don't leak the account name.
			options.beforeSend = { event in
				scrub(event)
				return event
			}
		}

		started = true
		AppLog.info(.app, "Sentry started. env:", environment, "release:", releaseName)

		// Enrich crash reports with the trail of error logs leading up to them.
		AppLog.errorReporter = { message in
			let crumb = Breadcrumb(level: .error, category: "log")
			crumb.message = message
			SentrySDK.addBreadcrumb(crumb)
		}
	}

	// MARK: - Configuration

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
		if let env = clean(ProcessInfo.processInfo.environment["SENTRY_ENVIRONMENT"]) {
			return env
		}
		#if DEBUG
			return "development"
		#else
			return "production"
		#endif
	}

	private static func clean(_ value: String?) -> String? {
		guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
			!trimmed.isEmpty
		else { return nil }
		return trimmed
	}

	/// Replaces the account's home-directory prefix in the event message with `~`.
	private static func scrub(_ event: Event) {
		let home = NSHomeDirectory()
		guard !home.isEmpty, let formatted = event.message?.formatted,
			formatted.contains(home)
		else { return }
		event.message = SentryMessage(formatted: formatted.replacingOccurrences(of: home, with: "~"))
	}
}
