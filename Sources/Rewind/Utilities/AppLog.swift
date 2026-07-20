import Foundation
import OSLog
import AppKit

enum AppLog {
	enum Category: String {
		case app
		case capture
		case writer
		case library
	}

	/// Number of per-session log files to retain. Each app launch writes a new
	/// `session-<timestamp>.log`; older ones beyond this count are pruned so the
	/// always-on error log can never grow without bound.
	private static let maxSessionLogs = 10

	private static let lock = NSLock()
	private nonisolated(unsafe) static var _fileLoggingEnabled: Bool = false

	/// When on, verbose (`info`/`debug`) logs are also written to the session
	/// file. Errors are written regardless of this flag.
	static var fileLoggingEnabled: Bool {
		get {
			lock.lock()
			defer { lock.unlock() }
			return _fileLoggingEnabled
		}
		set {
			lock.lock()
			_fileLoggingEnabled = newValue
			lock.unlock()
		}
	}

	private static let fileLoggerQueue = DispatchQueue(label: "com.rewind.filelogger", qos: .background)

	/// URL of this launch's session log file. Computed once; creating it also
	/// prunes older session files.
	static let sessionLogURL: URL? = {
		let fileManager = FileManager.default
		guard let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
		let logsDir = appSupportURL.appendingPathComponent("Rewind").appendingPathComponent("Logs")
		do {
			try fileManager.createDirectory(at: logsDir, withIntermediateDirectories: true, attributes: nil)
		} catch {
			print("File logger setup: \(error)")
			return nil
		}
		pruneOldSessions(in: logsDir, keeping: maxSessionLogs)
		return logsDir.appendingPathComponent("session-\(sessionTimestamp()).log")
	}()

	private static let fileHandle: FileHandle? = {
		guard let url = sessionLogURL else { return nil }
		let fileManager = FileManager.default
		if !fileManager.fileExists(atPath: url.path) {
			fileManager.createFile(atPath: url.path, contents: nil, attributes: nil)
		}
		do {
			let handle = try FileHandle(forWritingTo: url)
			handle.seekToEndOfFile()
			return handle
		} catch {
			print("File logger setup: \(error)")
			return nil
		}
	}()

	/// Current session's log file, surfaced to the UI ("Reveal Log File in Finder").
	static var logFileURL: URL? { sessionLogURL }

	/// Filename-safe timestamp (no colons) that sorts chronologically as text.
	private static func sessionTimestamp() -> String {
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.timeZone = TimeZone.current
		formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
		return formatter.string(from: Date())
	}

	private static func pruneOldSessions(in directory: URL, keeping keepCount: Int) {
		let fileManager = FileManager.default
		guard let contents = try? fileManager.contentsOfDirectory(
			at: directory, includingPropertiesForKeys: nil
		) else { return }
		let sessions = contents
			.filter { $0.lastPathComponent.hasPrefix("session-") && $0.pathExtension == "log" }
			.sorted { $0.lastPathComponent < $1.lastPathComponent }
		guard sessions.count >= keepCount else { return }
		// Keep the newest (keepCount - 1) so there's room for the file we're about
		// to create; remove the rest.
		let removeCount = sessions.count - (keepCount - 1)
		for url in sessions.prefix(removeCount) {
			try? fileManager.removeItem(at: url)
		}
	}

	/// Guards the one-time diagnostics header write at the top of the session file.
	private nonisolated(unsafe) static var _didWriteSessionHeader = false

	private static func writeToFile(_ message: String, force: Bool = false) {
		guard force || fileLoggingEnabled else { return }
		fileLoggerQueue.async {
			guard let handle = fileHandle else { return }
			let timestamp = ISO8601DateFormatter().string(from: Date())
			let logMessage = "[\(timestamp)] \(message)\n"
			if let data = logMessage.data(using: .utf8) {
				handle.write(data)
			}
		}
	}

	/// Called once at launch (from `setupCrashHandlers`, on the main thread) to
	/// stamp system diagnostics at the top of the session file. Main-thread so
	/// `NSScreen` access is safe.
	private static func beginSession() {
		lock.lock()
		let already = _didWriteSessionHeader
		_didWriteSessionHeader = true
		lock.unlock()
		guard !already else { return }
		writeToFile(diagnosticsReport(), force: true)
	}

	static func setupCrashHandlers() {
		_ = fileHandle
		beginSession()

		NSSetUncaughtExceptionHandler { exception in
			AppLog.logCrash("Uncaught Exception: \(exception.name.rawValue)\nReason: \(exception.reason ?? "nil")\nUser Info: \(exception.userInfo ?? [:])\nCall Stack:\n\(exception.callStackSymbols.joined(separator: "\n"))")
		}

		let signals: [Int32] = [SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS, SIGPIPE]
		for sig in signals {
			signal(sig) { signal in
				AppLog.logCrash("Application crashed with signal: \(signal)\nCall Stack:\n\(Thread.callStackSymbols.joined(separator: "\n"))")
				exit(signal)
			}
		}
	}

	private static func logCrash(_ message: String) {
		let timestamp = ISO8601DateFormatter().string(from: Date())
		let logMessage = "[\(timestamp)] [CRASH] \(message)\n"

		if let data = logMessage.data(using: .utf8), let handle = fileHandle {
			handle.seekToEndOfFile()
			handle.write(data)
			handle.synchronizeFile()
		}
	}

	private static func diagnosticsReport() -> String {
		var diagnostics = [String]()
		diagnostics.append("--- Rewind Diagnostics ---")

		let processInfo = ProcessInfo.processInfo
		diagnostics.append("Rewind Version: \(appVersion)")
		diagnostics.append("OS Version: \(processInfo.operatingSystemVersionString)")

		var size = 0
		sysctlbyname("hw.model", nil, &size, nil, 0)
		var model = [CChar](repeating: 0, count: size)
		sysctlbyname("hw.model", &model, &size, nil, 0)
		let modelString = String(decoding: model.map { UInt8(bitPattern: $0) }.dropLast(), as: UTF8.self)
		diagnostics.append("Mac Model: \(modelString)")

		size = 0
		sysctlbyname("hw.machine", nil, &size, nil, 0)
		var machine = [CChar](repeating: 0, count: size)
		sysctlbyname("hw.machine", &machine, &size, nil, 0)
		let archString = String(decoding: machine.map { UInt8(bitPattern: $0) }.dropLast(), as: UTF8.self)
		diagnostics.append("CPU Arch: \(archString)")

		diagnostics.append("App Path: \(Bundle.main.bundlePath)")

		let perm = CGPreflightScreenCaptureAccess()
		diagnostics.append("Screen Capture Permission: \(perm ? "Granted" : "Denied")")

		let screens = NSScreen.screens
		diagnostics.append("Available Displays: \(screens.count)")
		for (index, screen) in screens.enumerated() {
			diagnostics.append("Display \(index): \(screen.frame.width)x\(screen.frame.height)")
		}

		let settings = AppSettingsStorage.load()
		diagnostics.append("--- Capture Settings ---")
		diagnostics.append("Replay Duration: \(Int(settings.replayDuration))s")
		diagnostics.append("Resolution: \(settings.resolutionID ?? "Native")")
		diagnostics.append("Quality: \(settings.qualityPreset.label)")
		diagnostics.append("Frame Rate: \(settings.frameRate) fps")
		diagnostics.append("Container: \(settings.container.label)")
		diagnostics.append("Audio Codec: \(settings.audioCodec.label)")
		diagnostics.append("Record Microphone: \(settings.recordMicrophoneEnabled ? "Yes" : "No")")
		diagnostics.append("Record Desktop Audio: \(settings.recordDesktopAudioEnabled ? "Yes" : "No")")

		diagnostics.append("--------------------------")
		return diagnostics.joined(separator: "\n")
	}

	private static var appVersion: String {
		func normalized(_ value: String?) -> String? {
			guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
				!trimmed.isEmpty
			else { return nil }
			return trimmed
		}

		let shortVersion = normalized(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
			?? normalized(ProcessInfo.processInfo.environment["REWIND_VERSION"])
		let buildVersion = normalized(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)

		if let shortVersion {
			if let buildVersion, buildVersion != shortVersion {
				return "\(shortVersion) (\(buildVersion))"
			}
			return shortVersion
		}
		return buildVersion ?? "Dev"
	}

	private static let subsystem: String = Bundle.main.bundleIdentifier ?? "Rewind"

	private static let appLogger = Logger(subsystem: subsystem, category: Category.app.rawValue)
	private static let captureLogger = Logger(subsystem: subsystem, category: Category.capture.rawValue)
	private static let writerLogger = Logger(subsystem: subsystem, category: Category.writer.rawValue)
	private static let libraryLogger = Logger(subsystem: subsystem, category: Category.library.rawValue)

	private static let debugEnabled: Bool = {
		#if DEBUG
			let value = ProcessInfo.processInfo.environment["REWIND_DEBUG_LOGS"]
			return value == "1" || value?.lowercased() == "true"
		#else
			return false
		#endif
	}()

	private static let consoleMirrorEnabled: Bool = {
		#if DEBUG
			let value = ProcessInfo.processInfo.environment["REWIND_DEBUG_LOGS"]
			return value == "1" || value?.lowercased() == "true"
		#else
			return false
		#endif
	}()

	static func debug(_ category: Category, _ items: Any..., separator: String = " ") {
		guard debugEnabled || fileLoggingEnabled else { return }
		log(category, items, separator: separator, level: .debug)
	}

	static func debug(_ category: Category, items: [Any], separator: String = " ") {
		guard debugEnabled || fileLoggingEnabled else { return }
		log(category, items, separator: separator, level: .debug)
	}

	static func info(_ category: Category, _ items: Any..., separator: String = " ") {
		log(category, items, separator: separator, level: .info)
	}

	static func info(_ category: Category, items: [Any], separator: String = " ") {
		log(category, items, separator: separator, level: .info)
	}

	static func error(_ category: Category, _ items: Any..., separator: String = " ") {
		log(category, items, separator: separator, level: .error)
	}

	static func error(_ category: Category, items: [Any], separator: String = " ") {
		log(category, items, separator: separator, level: .error)
	}

	/// Logs `error` under `label` with its `NSError` domain/code/userInfo. Error
	/// logs are always persisted to the session file, so failures stay debuggable
	/// on machines where verbose logging is off.
	static func error(_ category: Category, _ label: String, error: Error?) {
		guard let error else {
			log(category, [label, "no error info."], separator: " ", level: .error)
			return
		}
		let nsError = error as NSError
		log(
			category,
			[label, "domain:", nsError.domain, "code:", nsError.code, "userInfo:", nsError.userInfo],
			separator: " ",
			level: .error
		)
	}

	private static func log(_ category: Category, _ items: [Any], separator: String, level: OSLogType) {
		let message = items.map { String(describing: $0) }.joined(separator: separator)
		let logger: Logger
		switch category {
		case .app:
			logger = appLogger
		case .capture:
			logger = captureLogger
		case .writer:
			logger = writerLogger
		case .library:
			logger = libraryLogger
		}

		switch level {
		case .error:
			logger.error("\(message, privacy: .public)")
		case .info:
			logger.info("\(message, privacy: .public)")
		default:
			logger.debug("\(message, privacy: .public)")
		}

		if consoleMirrorEnabled {
			print("[\(category.rawValue)] \(message)")
		}

		let levelString: String
		switch level {
		case .error: levelString = "ERROR"
		case .info: levelString = "INFO"
		case .debug: levelString = "DEBUG"
		default: levelString = "LOG"
		}
		// Errors are always persisted so field failures are debuggable even when
		// verbose file logging is off; info/debug honor `fileLoggingEnabled`.
		writeToFile("[\(category.rawValue)] [\(levelString)] \(message)", force: level == .error)
	}
}
