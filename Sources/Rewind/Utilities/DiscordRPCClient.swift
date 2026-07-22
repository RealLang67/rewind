import Darwin
import Foundation

enum DiscordActivityState: Equatable {
	case idle
	case recording(game: String?, joinURL: String?, artURL: String?)

	var isRecording: Bool {
		if case .recording = self { return true }
		return false
	}

	var name: String {
		switch self {
		case .idle:
			return "Rewind"
		case let .recording(game, _, _):
			if let game, !game.isEmpty { return game }
			return "Rewind"
		}
	}

	var details: String {
		switch self {
		case .idle:
			return "Idling..."
		case let .recording(game, _, _):
			if let game, !game.isEmpty {
				return "Clipping \(game) with Rewind"
			}
			return "Capturing a game"
		}
	}

	var presenceLines: (details: String, state: String?) {
		switch self {
		case .idle:
			return (details, nil)
		case let .recording(game, _, _):
			guard let game, !game.isEmpty else { return (details, nil) }
			return (String("Clipping \(game)".prefix(128)), "with Rewind")
		}
	}

	var gameTitle: String? {
		if case let .recording(game, _, _) = self, let game, !game.isEmpty { return game }
		return nil
	}

	/// A server-join link (Roblox), surfaced as a "Join my game" presence button.
	var joinURL: String? {
		if case let .recording(_, url, _) = self { return url }
		return nil
	}

	var artURL: String? {
		if case let .recording(_, _, url) = self { return url }
		return nil
	}
}

actor DiscordRPCClient {
	private enum DiscordOpcode: Int32 {
		case handshake = 0
		case frame = 1
	}

	private enum Constants {
		static let protocolVersion = 1
		static let connectTimeoutMilliseconds: Int32 = 1500
		static let rewindWebsiteURL = "https://github.com/l1zov/rewind"
		// arRPC mirrors Discord's WebSocket transport 
		static let webSocketPorts = 6463 ... 6472
		static let logoAsset = "rewind-logo"
	}

	private let clientID: String?
	private var enabled = true
	private var fileHandle: FileHandle?
	private var webSocket: URLSessionWebSocketTask?
	private var handshakeCompleted = false
	private let urlSession: URLSession = {
		let config = URLSessionConfiguration.ephemeral
		config.timeoutIntervalForRequest = 2
		return URLSession(configuration: config)
	}()
	private var lastPublishedState: DiscordActivityState?
	/// When the current recording session began, so the presence can show a live
	/// elapsed timer that survives game-name refinements.
	private var recordingStartedAt: Date?

	init(clientID: String? = "1470439515649736865") {
		self.clientID = clientID
	}

	func setEnabled(_ isEnabled: Bool) async {
		enabled = isEnabled
		if isEnabled {
			return
		}

		await clearActivity()
		disconnect()
		lastPublishedState = nil
		recordingStartedAt = nil
	}

	@discardableResult
	func publish(state: DiscordActivityState) async -> Bool {
		guard enabled else { return false }
		guard await ensureConnected() else { return false }
		guard state != lastPublishedState else { return true }

		// Anchor the elapsed timer on the first recording publish and drop it
		// when idle, so refining the game name mid-recording doesn't reset it.
		switch state {
		case .recording:
			if recordingStartedAt == nil { recordingStartedAt = Date() }
		case .idle:
			recordingStartedAt = nil
		}

		// Discord allows up to two presence buttons. Offer the Roblox join link
		// first (when available), then the download link.
		var buttons: [[String: Any]] = []
		if let joinURL = state.joinURL {
			buttons.append(["label": "Join my game", "url": joinURL])
		}
		buttons.append(["label": "Get Rewind", "url": Constants.rewindWebsiteURL])

		var assets: [String: Any] = [:]
		if let artURL = state.artURL, !artURL.isEmpty {
			assets["large_image"] = artURL
			assets["large_text"] = state.gameTitle ?? state.name
			assets["small_image"] = Constants.logoAsset
			assets["small_text"] = "Rewind"
		} else {
			assets["large_image"] = Constants.logoAsset
			assets["large_text"] = state.gameTitle ?? "Rewind"
		}

		let lines = state.presenceLines
		var activity: [String: Any] = [
			"name": state.name,
			"details": lines.details,
			"assets": assets,
			"buttons": buttons,
		]
		if let stateLine = lines.state {
			activity["state"] = stateLine
		}
		if let recordingStartedAt {
			activity["timestamps"] = ["start": Int(recordingStartedAt.timeIntervalSince1970)]
		}

		let nonce = UUID().uuidString
		let payload: [String: Any] = [
			"cmd": "SET_ACTIVITY",
			"nonce": nonce,
			"args": [
				"pid": Int(getpid()),
				"activity": activity,
			],
		]

		do {
			try await sendFrame(payload)
			lastPublishedState = state
			return true
		} catch {
			AppLog.error(.app, "DRPC publish error:", error)
			disconnect()
			return false
		}
	}

	private func clearActivity() async {
		guard await ensureConnected() else { return }
		let payload: [String: Any] = [
			"cmd": "SET_ACTIVITY",
			"nonce": UUID().uuidString,
			"args": [
				"pid": Int(getpid()),
				"activity": NSNull(),
			],
		]

		do {
			try await sendFrame(payload)
		} catch {
			AppLog.debug(.app, "DRPC clear error:", error)
		}
	}

	private func ensureConnected() async -> Bool {
		guard let clientID else {
			AppLog.debug(.app, "DRPC client id not found")
			return false
		}

		if (fileHandle != nil || webSocket != nil), handshakeCompleted {
			return true
		}

		disconnect()
		for path in ipcSocketPaths() {
			guard FileManager.default.fileExists(atPath: path) else { continue }
			do {
				let handle = try connect(to: path)
				fileHandle = handle
				try sendHandshake()
				try waitForReadyDispatch()
				handshakeCompleted = true
				AppLog.info(.app, "DRPC connected:", path)
				return true
			} catch {
				disconnect()
			}
		}

		if await connectWebSocket(clientID: clientID) {
			handshakeCompleted = true
			return true
		}

		return false
	}

	private func connectWebSocket(clientID: String) async -> Bool {
		for port in Constants.webSocketPorts {
			guard let url = URL(string: "ws://127.0.0.1:\(port)/?v=1&client_id=\(clientID)&encoding=json") else { continue }
			var request = URLRequest(url: url)
			// arRPC and Discord both validate the WebSocket Origin
			request.setValue("https://discord.com", forHTTPHeaderField: "Origin")
			let task = urlSession.webSocketTask(with: request)
			task.resume()
			if await readReadyDispatch(on: task) {
				webSocket = task
				AppLog.info(.app, "DRPC connected (websocket):", port)
				return true
			}
			task.cancel(with: .goingAway, reason: nil)
		}
		return false
	}

	private func readReadyDispatch(on task: URLSessionWebSocketTask) async -> Bool {
		guard let message = try? await task.receive(),
		      case let .string(text) = message,
		      let data = text.data(using: .utf8),
		      let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
		else { return false }
		return frame["cmd"] as? String == "DISPATCH" && frame["evt"] as? String == "READY"
	}

	private func sendFrame(_ payload: [String: Any]) async throws {
		if fileHandle != nil {
			try send(opcode: .frame, payload: payload)
			return
		}
		if let webSocket {
			let data = try JSONSerialization.data(withJSONObject: payload)
			try await webSocket.send(.string(String(decoding: data, as: UTF8.self)))
			return
		}
		throw DiscordError.notConnected
	}

	private func ipcSocketPaths() -> [String] {
		var basePaths: [String] = []

		if let tempDir = ProcessInfo.processInfo.environment["TMPDIR"], !tempDir.isEmpty {
			basePaths.append(tempDir)
		}

		let nsTempDirectory = NSTemporaryDirectory()
		if !nsTempDirectory.isEmpty {
			basePaths.append(nsTempDirectory)
		}

		basePaths.append(FileManager.default.temporaryDirectory.path)
		basePaths.append("/tmp")

		var paths: [String] = []
		var seen = Set<String>()
		for basePath in basePaths {
			let normalizedBase = basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath
			for socketIndex in 0 ..< 10 {
				let path = "\(normalizedBase)/discord-ipc-\(socketIndex)"
				if seen.insert(path).inserted {
					paths.append(path)
				}
			}
		}
		return paths
	}

	private func sendHandshake() throws {
		guard let clientID else { return }
		try send(opcode: .handshake, payload: [
			"v": Constants.protocolVersion,
			"client_id": clientID,
		])
	}

	private func send(opcode: DiscordOpcode, payload: [String: Any]) throws {
		guard let fileHandle else { throw DiscordError.notConnected }
		let body = try JSONSerialization.data(withJSONObject: payload)

		var rawOpcode = opcode.rawValue.littleEndian
		var rawLength = Int32(body.count).littleEndian
		var frame = Data(bytes: &rawOpcode, count: MemoryLayout.size(ofValue: rawOpcode))
		frame.append(Data(bytes: &rawLength, count: MemoryLayout.size(ofValue: rawLength)))
		frame.append(body)
		try fileHandle.write(contentsOf: frame)
	}

	private func waitForReadyDispatch() throws {
		guard let fileHandle else { throw DiscordError.notConnected }
		var descriptorState = pollfd(fd: Int32(fileHandle.fileDescriptor), events: Int16(POLLIN), revents: 0)
		let pollResult = Darwin.poll(&descriptorState, 1, Constants.connectTimeoutMilliseconds)

		if pollResult == 0 {
			throw DiscordError.readTimedOut
		}
		if pollResult < 0 {
			throw DiscordError.connectionFailed(errno)
		}

		let header = try readExact(byteCount: 8)
		let opcode: Int32 = header.withUnsafeBytes { bytes in
			Int32(littleEndian: bytes.load(fromByteOffset: 0, as: Int32.self))
		}
		guard DiscordOpcode(rawValue: opcode) == .frame else {
			throw DiscordError.invalidFrame
		}

		let payloadLength: Int = header.withUnsafeBytes { bytes in
			Int(Int32(littleEndian: bytes.load(fromByteOffset: 4, as: Int32.self)))
		}
		guard payloadLength > 0 else {
			throw DiscordError.invalidFrame
		}

		let payloadData = try readExact(byteCount: payloadLength)
		let payloadObject = try JSONSerialization.jsonObject(with: payloadData)
		guard let frame = payloadObject as? [String: Any] else {
			throw DiscordError.invalidFrame
		}

		let command = frame["cmd"] as? String
		let event = frame["evt"] as? String
		guard command == "DISPATCH", event == "READY" else {
			throw DiscordError.handshakeRejected
		}
	}

	private func readExact(byteCount: Int) throws -> Data {
		guard let fileHandle else { throw DiscordError.notConnected }
		var data = Data()
		data.reserveCapacity(byteCount)

		while data.count < byteCount {
			let remaining = byteCount - data.count
			let chunk = try fileHandle.read(upToCount: remaining) ?? Data()
			if chunk.isEmpty {
				throw DiscordError.connectionClosed
			}
			data.append(chunk)
		}

		return data
	}

	private func disconnect() {
		if let fileHandle {
			try? fileHandle.close()
		}
		fileHandle = nil
		webSocket?.cancel(with: .goingAway, reason: nil)
		webSocket = nil
		handshakeCompleted = false
	}

	private func connect(to path: String) throws -> FileHandle {
		let socketDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
		guard socketDescriptor >= 0 else {
			throw DiscordError.socketCreationFailed(errno)
		}

		var address = sockaddr_un()
		address.sun_family = sa_family_t(AF_UNIX)

		let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
		let utf8Path = Array(path.utf8)
		guard utf8Path.count < maxPathLength else {
			Darwin.close(socketDescriptor)
			throw DiscordError.pathTooLong
		}

		withUnsafeMutablePointer(to: &address.sun_path) { pathPtr in
			pathPtr.withMemoryRebound(to: CChar.self, capacity: maxPathLength) { cPath in
				cPath.initialize(repeating: 0, count: maxPathLength)
				for (index, byte) in utf8Path.enumerated() {
					cPath[index] = CChar(bitPattern: byte)
				}
			}
		}

		let addressLength = socklen_t(MemoryLayout<sa_family_t>.size + utf8Path.count + 1)
		let result = withUnsafePointer(to: &address) { addressPtr in
			addressPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
				Darwin.connect(socketDescriptor, sockaddrPtr, addressLength)
			}
		}

		guard result == 0 else {
			let code = errno
			Darwin.close(socketDescriptor)
			throw DiscordError.connectionFailed(code)
		}

		return FileHandle(fileDescriptor: socketDescriptor, closeOnDealloc: true)
	}
}

private enum DiscordError: Error {
	case notConnected
	case socketCreationFailed(Int32)
	case connectionFailed(Int32)
	case pathTooLong
	case invalidFrame
	case handshakeRejected
	case readTimedOut
	case connectionClosed
}
