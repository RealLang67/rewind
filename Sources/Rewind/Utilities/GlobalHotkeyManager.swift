import AppKit
import Carbon

@MainActor
final class GlobalHotkeyManager {
	static let shared = GlobalHotkeyManager()

	private let hotKeySignature = OSType(0x5257_4E44) // "RWND"
	private let saveReplayHotKeyId: UInt32 = 1
	private let startRecordingHotKeyId: UInt32 = 2
	private let stopRecordingHotKeyId: UInt32 = 3
	private var saveReplayHotKeyRef: EventHotKeyRef?
	private var startRecordingHotKeyRef: EventHotKeyRef?
	private var stopRecordingHotKeyRef: EventHotKeyRef?
	private var eventHandler: EventHandlerRef?
	private var saveReplayHotkey: Hotkey? = .default
	private var startRecordingHotkey: Hotkey = .startRecordingDefault
	private var stopRecordingHotkey: Hotkey = .stopRecordingDefault
	private var isSuspended = false
	private var onSaveReplay: (() -> Void)?
	private var onStartRecording: (() -> Void)?
	private var onStopRecording: (() -> Void)?

	func configureActions(
		onSaveReplay: (() -> Void)?,
		onStartRecording: (() -> Void)?,
		onStopRecording: (() -> Void)?
	) {
		self.onSaveReplay = onSaveReplay
		self.onStartRecording = onStartRecording
		self.onStopRecording = onStopRecording
	}

	func register(
		saveReplayHotkey: Hotkey? = .default,
		startRecordingHotkey: Hotkey = .startRecordingDefault,
		stopRecordingHotkey: Hotkey = .stopRecordingDefault
	) {
		self.saveReplayHotkey = saveReplayHotkey
		self.startRecordingHotkey = startRecordingHotkey
		self.stopRecordingHotkey = stopRecordingHotkey
		unregister()
		guard !isSuspended else { return }

		var eventType = EventTypeSpec(
			eventClass: OSType(kEventClassKeyboard),
			eventKind: UInt32(kEventHotKeyPressed)
		)

		let installStatus = InstallEventHandler(
			GetEventDispatcherTarget(),
			{ _, event, userData in
				guard let userData else { return noErr }
				let manager = Unmanaged<GlobalHotkeyManager>
					.fromOpaque(userData)
					.takeUnretainedValue()
				var hotKeyID = EventHotKeyID()
				let status = GetEventParameter(
					event,
					EventParamName(kEventParamDirectObject),
					EventParamType(typeEventHotKeyID),
					nil,
					MemoryLayout<EventHotKeyID>.size,
					nil,
					&hotKeyID
				)
				guard status == noErr else { return noErr }
				let signature = hotKeyID.signature
				let id = hotKeyID.id
				Task { @MainActor in
					manager.handleHotKey(signature: signature, id: id)
				}
				return noErr
			},
			1,
			&eventType,
			UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
			&eventHandler
		)
		guard installStatus == noErr else {
			AppLog.error(.app, "Install hotkey event handler error, status:", installStatus)
			eventHandler = nil
			return
		}

		if let saveReplayHotkey {
			registerHotKey(
				saveReplayHotkey,
				id: saveReplayHotKeyId,
				store: &saveReplayHotKeyRef,
				actionName: "save replay"
			)
		}
		registerHotKey(
			startRecordingHotkey,
			id: startRecordingHotKeyId,
			store: &startRecordingHotKeyRef,
			actionName: "start recording"
		)
		registerHotKey(
			stopRecordingHotkey,
			id: stopRecordingHotKeyId,
			store: &stopRecordingHotKeyRef,
			actionName: "stop recording"
		)

		if saveReplayHotKeyRef == nil,
		   startRecordingHotKeyRef == nil,
		   stopRecordingHotKeyRef == nil,
		   let eventHandler
		{
			RemoveEventHandler(eventHandler)
			self.eventHandler = nil
		}
	}

	func unregister() {
		if let saveReplayHotKeyRef {
			UnregisterEventHotKey(saveReplayHotKeyRef)
			self.saveReplayHotKeyRef = nil
		}

		if let startRecordingHotKeyRef {
			UnregisterEventHotKey(startRecordingHotKeyRef)
			self.startRecordingHotKeyRef = nil
		}

		if let stopRecordingHotKeyRef {
			UnregisterEventHotKey(stopRecordingHotKeyRef)
			self.stopRecordingHotKeyRef = nil
		}

		if let eventHandler {
			RemoveEventHandler(eventHandler)
			self.eventHandler = nil
		}
	}

	func updateHotkeys(saveReplay: Hotkey?, startRecording: Hotkey, stopRecording: Hotkey) {
		register(
			saveReplayHotkey: saveReplay,
			startRecordingHotkey: startRecording,
			stopRecordingHotkey: stopRecording
		)
	}

	/// Temporarily releases every global shortcut while a Settings row is
	/// listening for a replacement. Updates made while suspended are remembered
	/// and registered together when capture ends.
	func suspend() {
		guard !isSuspended else { return }
		isSuspended = true
		unregister()
	}

	func resume() {
		guard isSuspended else { return }
		isSuspended = false
		register(
			saveReplayHotkey: saveReplayHotkey,
			startRecordingHotkey: startRecordingHotkey,
			stopRecordingHotkey: stopRecordingHotkey
		)
	}

	private func registerHotKey(
		_ hotkey: Hotkey,
		id: UInt32,
		store ref: inout EventHotKeyRef?,
		actionName: String
	) {
		let hotKeyID = EventHotKeyID(signature: hotKeySignature, id: id)
		let registerStatus = RegisterEventHotKey(
			hotkey.keyCode,
			hotkey.modifiers,
			hotKeyID,
			GetEventDispatcherTarget(),
			0,
			&ref
		)
		guard registerStatus == noErr else {
			AppLog.error(
				.app,
				"Register global hotkey for",
				actionName,
				"status:",
				registerStatus,
				"keyCode:",
				hotkey.keyCode,
				"modifiers:",
				hotkey.modifiers
			)
			ref = nil
			return
		}
	}

	private func handleHotKey(signature: OSType, id: UInt32) {
		guard signature == hotKeySignature else { return }

		switch id {
		case saveReplayHotKeyId:
			onSaveReplay?()
		case startRecordingHotKeyId:
			onStartRecording?()
		case stopRecordingHotKeyId:
			onStopRecording?()
		default:
			return
		}
	}
}
