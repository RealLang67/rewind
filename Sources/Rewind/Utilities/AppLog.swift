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

	private static let lock = NSLock()
	private nonisolated(unsafe) static var _fileLoggingEnabled: Bool = false

	static var fileLoggingEnabled: Bool {
		get {
			lock.lock()
			defer { lock.unlock() }
			return _fileLoggingEnabled
		}
		set {
			lock.lock()
			let changed = _fileLoggingEnabled != newValue
			_fileLoggingEnabled = newValue
			lock.unlock()
			if changed {
				if newValue {
					dumpDiagnostics()
				}
			}
		}
	}

	private static let fileLoggerQueue = DispatchQueue(label: "com.rewind.filelogger", qos: .background)
	private static let fileHandle: FileHandle? = {
		let fileManager = FileManager.default
		guard let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
		let logsDir = appSupportURL.appendingPathComponent("Rewind").appendingPathComponent("Logs")
		do {
			try fileManager.createDirectory(at: logsDir, withIntermediateDirectories: true, attributes: nil)
			let logFileURL = logsDir.appendingPathComponent("app.log")
			if !fileManager.fileExists(atPath: logFileURL.path) {
				fileManager.createFile(atPath: logFileURL.path, contents: nil, attributes: nil)
			}
			let handle = try FileHandle(forWritingTo: logFileURL)
			handle.seekToEndOfFile()
			return handle
		} catch {
			print("File logger setup: \(error)")
			return nil
		}
	}()

	static var logFileURL: URL? {
		let fileManager = FileManager.default
		guard let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
		return appSupportURL.appendingPathComponent("Rewind").appendingPathComponent("Logs").appendingPathComponent("app.log")
	}

	private static func writeToFile(_ message: String) {
		guard fileLoggingEnabled else { return }
		fileLoggerQueue.async {
			guard let handle = fileHandle else { return }
			let timestamp = ISO8601DateFormatter().string(from: Date())
			let logMessage = "[\(timestamp)] \(message)\n"
			if let data = logMessage.data(using: .utf8) {
				handle.write(data)
			}
		}
	}

	static func setupCrashHandlers() {
		_ = fileHandle

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

	static func dumpDiagnostics() {
		guard fileLoggingEnabled else { return }
		var diagnostics = [String]()
		diagnostics.append("--- Rewind Diagnostics ---")
		
		let processInfo = ProcessInfo.processInfo
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

		diagnostics.append("--------------------------")
		
		let joined = diagnostics.joined(separator: "\n")
		writeToFile(joined)
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

		if fileLoggingEnabled {
			let levelString: String
			switch level {
			case .error: levelString = "ERROR"
			case .info: levelString = "INFO"
			case .debug: levelString = "DEBUG"
			default: levelString = "LOG"
			}
			writeToFile("[\(category.rawValue)] [\(levelString)] \(message)")
		}
	}
}
