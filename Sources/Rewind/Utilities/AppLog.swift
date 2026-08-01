import Foundation
import OSLog
import AppKit
@preconcurrency import CocoaLumberjack
import CocoaLumberjackSwift

enum AppLog {
	enum Category: String {
		case app
		case capture
		case writer
		case library
	}

	private static let maxFileSize: UInt64 = 5 * 1024 * 1024
	private static let rollingFrequency: TimeInterval = 60 * 60 * 24
	private static let maxLogFiles: UInt = 5

	private static let lock = NSLock()
	private nonisolated(unsafe) static var _fileLoggingEnabled: Bool = false

	/// When on, verbose (`info`/`debug`) logs are also written to the log file.
	/// Errors are written regardless of this flag.
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


	private nonisolated(unsafe) static let fileLogger: DDFileLogger = {
		let fileManager = FileManager.default
		let logsDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
			.map { $0.appendingPathComponent("Rewind").appendingPathComponent("Logs") }

		let logFileManager: DDLogFileManagerDefault
		if let logsDir {
			try? fileManager.createDirectory(at: logsDir, withIntermediateDirectories: true)
			logFileManager = DDLogFileManagerDefault(logsDirectory: logsDir.path)
		} else {
			logFileManager = DDLogFileManagerDefault()
		}
		logFileManager.maximumNumberOfLogFiles = maxLogFiles

		let logger = DDFileLogger(logFileManager: logFileManager)
		logger.maximumFileSize = maxFileSize
		logger.rollingFrequency = rollingFrequency
		return logger
	}()


	static var logFileURL: URL? {
		fileLogger.currentLogFileInfo.map { URL(fileURLWithPath: $0.filePath) }
	}


	private nonisolated(unsafe) static var _didWriteSessionHeader = false

	private static func writeToFile(_ message: String, level: OSLogType, force: Bool = false) {
		guard force || level == .error || fileLoggingEnabled else { return }
		switch level {
		case .error:
			DDLogError("\(message)")
		case .info:
			DDLogInfo("\(message)")
		default:
			DDLogDebug("\(message)")
		}
	}

	/// Called once at launch (from `startFileLogging`, on the main thread) to
	/// stamp system diagnostics at the top of the session. Main-thread so
	/// `NSScreen` access is safe.
	private static func beginSession() {
		lock.lock()
		let already = _didWriteSessionHeader
		_didWriteSessionHeader = true
		lock.unlock()
		guard !already else { return }
		writeToFile(diagnosticsReport(), level: .info, force: true)
	}

	/// starts file logging and stamps the session diagnostics header. always safe
	/// to call once at launch; installs no crash handlers
	static func startFileLogging() {
		// `.all` - level gating is done in `writeToFile`, not by the logger
		DDLog.add(fileLogger, with: .all)
		beginSession()
		// a broken pipe/socket must never terminate the app
		signal(SIGPIPE, SIG_IGN)
	}

	/// writes a final crash record to the log file on uncaught exceptions/signals
	/// a fallback for when Sentry isnt active; it installs its own handlers, so
	/// dont call this while the crash reporter is running
	static func installFallbackCrashHandlers() {
		NSSetUncaughtExceptionHandler { exception in
			AppLog.logCrash("Uncaught Exception: \(exception.name.rawValue)\nReason: \(exception.reason ?? "nil")\nUser Info: \(exception.userInfo ?? [:])\nCall Stack:\n\(exception.callStackSymbols.joined(separator: "\n"))")
		}

		let signals: [Int32] = [SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS]
		for sig in signals {
			signal(sig) { signal in
				AppLog.logCrash("Application crashed with signal: \(signal)\nCall Stack:\n\(Thread.callStackSymbols.joined(separator: "\n"))")
				// `_exit`, not `exit` because exit's atexit/stdio teardown isnt signal-safe
				_exit(signal)
			}
		}
	}

	private static func logCrash(_ message: String) {
		DDLogError("[CRASH] \(message)")
		// Flush synchronously so the crash record survives the imminent exit.
		DDLog.flushLog()
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
		writeToFile("[\(category.rawValue)] [\(levelString)] \(message)", level: level)
	}
}
