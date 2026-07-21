import AppKit
@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit
import SwiftUI
import Combine

@MainActor
final class AppState: ObservableObject {
	static let supportsMicrophoneCapture = ProcessInfo.processInfo.isOperatingSystemAtLeast(
		OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
	)

	@Published private(set) var isCapturing = false
	@Published var replayDuration: TimeInterval = 30 {
		didSet {
			guard !isRestoringSettings else { return }
			let clamped = min(
				max(replayDuration, AppSettings.replayDurationRange.lowerBound),
				AppSettings.replayDurationRange.upperBound
			)
			if clamped != replayDuration {
				replayDuration = clamped
				return
			}
			persistSettings()
		}
	}

	@Published private(set) var lastClip: Clip?

	@Published var clipToOpen: Clip?

	/// Login-item state lives in the system (via `SMAppService`), not in app
	/// settings, so this is initialized from and written straight to that store.
	@Published var launchAtLoginEnabled: Bool = LaunchAtLogin.isEnabled {
		didSet {
			guard !isRestoringSettings else { return }
			guard launchAtLoginEnabled != oldValue else { return }
			do {
				try LaunchAtLogin.setEnabled(launchAtLoginEnabled)
			} catch {
				AppLog.error(.app, "Failed to update launch at login:", error)
				isRestoringSettings = true
				launchAtLoginEnabled = oldValue
				isRestoringSettings = false
			}
		}
	}
	@Published private(set) var permissionState = PermissionState()
	@Published private(set) var availableResolutions: [CaptureResolution] = []
	@Published private(set) var isLoadingResolutions = false
	@Published private(set) var resolutionLoadingMessage: String?
	@Published var selectedResolution: CaptureResolution? {
		didSet {
			guard !isRestoringSettings else { return }
			guard selectedResolution != oldValue else { return }
			preferredResolutionID = selectedResolution?.id
			persistSettings()
			restartCaptureSilently()
		}
	}

	@Published var selectedQuality: QualityPreset = .default {
		didSet {
			guard !isRestoringSettings else { return }
			guard selectedQuality != oldValue else { return }
			persistSettings()
			restartCaptureSilently()
		}
	}

	@Published var selectedFrameRate: CaptureFrameRate = .default {
		didSet {
			guard !isRestoringSettings else { return }
			guard selectedFrameRate != oldValue else { return }
			persistSettings()
			restartCaptureSilently()
		}
	}

	@Published var selectedContainer: CaptureContainer = .default {
		didSet {
			guard !isRestoringSettings else { return }
			guard selectedContainer != oldValue else { return }
			persistSettings()
		}
	}

	@Published var selectedAudioCodec: CaptureAudioCodec = .default {
		didSet {
			guard !isRestoringSettings else { return }
			guard selectedAudioCodec != oldValue else { return }
			persistSettings()
			restartCaptureSilently()
		}
	}

	@Published var hotkey: Hotkey = .default {
		didSet {
			guard !isRestoringSettings else { return }
			guard hotkey != oldValue else { return }
			persistSettings()
			updateGlobalHotkeys()
		}
	}

	@Published var startRecordingHotkey: Hotkey = .startRecordingDefault {
		didSet {
			guard !isRestoringSettings else { return }
			guard startRecordingHotkey != oldValue else { return }
			persistSettings()
			updateGlobalHotkeys()
		}
	}

	@Published var alwaysRecordEnabled = AppSettings.default.alwaysRecordEnabled {
		didSet {
			guard !isRestoringSettings else { return }
			guard alwaysRecordEnabled != oldValue else { return }
			persistSettings()
			if alwaysRecordEnabled {
				startCapture()
			}
		}
	}

	@Published var saveFeedbackEnabled = AppSettings.default.saveFeedbackEnabled {
		didSet {
			guard !isRestoringSettings else { return }
			guard saveFeedbackEnabled != oldValue else { return }
			persistSettings()
		}
	}

	@Published var saveFeedbackVolume = AppSettings.default.saveFeedbackVolume {
		didSet {
			guard !isRestoringSettings else { return }
			guard saveFeedbackVolume != oldValue else { return }
			let clamped = min(
				max(saveFeedbackVolume, AppSettings.saveFeedbackVolumeRange.lowerBound),
				AppSettings.saveFeedbackVolumeRange.upperBound
			)
			if clamped != saveFeedbackVolume {
				saveFeedbackVolume = clamped
				return
			}
			persistSettings()
		}
	}

	@Published var saveFeedbackSound: FeedbackSound = .default {
		didSet {
			guard !isRestoringSettings else { return }
			guard saveFeedbackSound != oldValue else { return }
			soundFeedback.invalidate(.saved)
			persistSettings()
		}
	}

	@Published var recordingStartFeedbackEnabled = AppSettings.default.recordingStartFeedbackEnabled {
		didSet {
			guard !isRestoringSettings else { return }
			guard recordingStartFeedbackEnabled != oldValue else { return }
			persistSettings()
		}
	}

	@Published var recordingStartFeedbackVolume = AppSettings.default.recordingStartFeedbackVolume {
		didSet {
			guard !isRestoringSettings else { return }
			guard recordingStartFeedbackVolume != oldValue else { return }
			let clamped = min(
				max(recordingStartFeedbackVolume, AppSettings.saveFeedbackVolumeRange.lowerBound),
				AppSettings.saveFeedbackVolumeRange.upperBound
			)
			if clamped != recordingStartFeedbackVolume {
				recordingStartFeedbackVolume = clamped
				return
			}
			persistSettings()
		}
	}

	@Published var recordingStartFeedbackSound: FeedbackSound = .defaultStart {
		didSet {
			guard !isRestoringSettings else { return }
			guard recordingStartFeedbackSound != oldValue else { return }
			soundFeedback.invalidate(.recordingStart)
			persistSettings()
		}
	}

	@Published var recordingEndFeedbackEnabled = AppSettings.default.recordingEndFeedbackEnabled {
		didSet {
			guard !isRestoringSettings else { return }
			guard recordingEndFeedbackEnabled != oldValue else { return }
			persistSettings()
		}
	}

	@Published var recordingEndFeedbackVolume = AppSettings.default.recordingEndFeedbackVolume {
		didSet {
			guard !isRestoringSettings else { return }
			guard recordingEndFeedbackVolume != oldValue else { return }
			let clamped = min(
				max(recordingEndFeedbackVolume, AppSettings.saveFeedbackVolumeRange.lowerBound),
				AppSettings.saveFeedbackVolumeRange.upperBound
			)
			if clamped != recordingEndFeedbackVolume {
				recordingEndFeedbackVolume = clamped
				return
			}
			persistSettings()
		}
	}

	@Published var recordingEndFeedbackSound: FeedbackSound = .defaultEnd {
		didSet {
			guard !isRestoringSettings else { return }
			guard recordingEndFeedbackSound != oldValue else { return }
			soundFeedback.invalidate(.recordingEnd)
			persistSettings()
		}
	}

	@Published var errorFeedbackEnabled = AppSettings.default.errorFeedbackEnabled {
		didSet {
			guard !isRestoringSettings else { return }
			guard errorFeedbackEnabled != oldValue else { return }
			persistSettings()
		}
	}

	@Published var errorFeedbackVolume = AppSettings.default.errorFeedbackVolume {
		didSet {
			guard !isRestoringSettings else { return }
			guard errorFeedbackVolume != oldValue else { return }
			let clamped = min(
				max(errorFeedbackVolume, AppSettings.saveFeedbackVolumeRange.lowerBound),
				AppSettings.saveFeedbackVolumeRange.upperBound
			)
			if clamped != errorFeedbackVolume {
				errorFeedbackVolume = clamped
				return
			}
			persistSettings()
			playErrorFeedback()
		}
	}

	@Published var errorFeedbackSound: FeedbackSound = .defaultError {
		didSet {
			guard !isRestoringSettings else { return }
			guard errorFeedbackSound != oldValue else { return }
			soundFeedback.invalidate(.error)
			persistSettings()
			playErrorFeedback()
		}
	}

	@Published var discordRPCEnabled = AppSettings.default.discordRPCEnabled {
		didSet {
			guard !isRestoringSettings else { return }
			guard discordRPCEnabled != oldValue else { return }
			persistSettings()
			Task {
				await discordRPCClient.setEnabled(discordRPCEnabled)
				if discordRPCEnabled {
					self.publishDiscordPresenceWithRetry(for: self.discordActivityState)
				} else {
					discordPresenceRetryTask?.cancel()
					discordPresenceRetryTask = nil
				}
			}
		}
	}

	@Published var recordMicrophoneEnabled = AppSettings.default.recordMicrophoneEnabled {
		didSet {
			guard !isRestoringSettings else { return }
			guard recordMicrophoneEnabled != oldValue else { return }

			if recordMicrophoneEnabled && !Self.supportsMicrophoneCapture {
				recordMicrophoneEnabled = false
				return
			}

			persistSettings()

			if recordMicrophoneEnabled {
				Task {
					do {
						try await PermissionManager.ensureMicrophoneAccess()
						permissionState = PermissionManager.currentState()
					} catch {
						AppLog.error(.app, "Microphone access denied:", error)
						recordMicrophoneEnabled = false
					}
					restartCaptureSilently()
				}
			} else {
				restartCaptureSilently()
			}
		}
	}

	@Published var recordDesktopAudioEnabled = AppSettings.default.recordDesktopAudioEnabled {
		didSet {
			guard !isRestoringSettings else { return }
			guard recordDesktopAudioEnabled != oldValue else { return }
			persistSettings()
			restartCaptureSilently()
		}
	}

	@Published var fileLoggingEnabled = AppSettings.default.fileLoggingEnabled {
		didSet {
			guard !isRestoringSettings else { return }
			guard fileLoggingEnabled != oldValue else { return }
			AppLog.fileLoggingEnabled = fileLoggingEnabled
			persistSettings()
		}
	}

	@Published var crashReportingEnabled = AppSettings.default.crashReportingEnabled {
		didSet {
			guard !isRestoringSettings else { return }
			guard crashReportingEnabled != oldValue else { return }
			CrashReporter.setEnabled(crashReportingEnabled)
			persistSettings()
		}
	}

	/// opt-in to the sparkle `beta` channel
	@Published var betaUpdatesEnabled = AppSettings.default.betaUpdatesEnabled {
		didSet {
			guard !isRestoringSettings else { return }
			guard betaUpdatesEnabled != oldValue else { return }
			persistSettings()
		}
	}

	@Published var catboxEnabled = AppSettings.default.catboxEnabled {
		didSet {
			guard !isRestoringSettings else { return }
			guard catboxEnabled != oldValue else { return }
			persistSettings()
		}
	}

	@Published var litterboxEnabled = AppSettings.default.litterboxEnabled {
		didSet {
			guard !isRestoringSettings else { return }
			guard litterboxEnabled != oldValue else { return }
			persistSettings()
		}
	}

	@Published var outputDirectoryPath: String? {
		didSet {
			guard !isRestoringSettings else { return }
			guard outputDirectoryPath != oldValue else { return }
			persistSettings()
		}
	}

	@Published private(set) var lowStorageWarningMessage: String?

	private let captureManager: CaptureManager
	let clipLibrary: ClipLibrary
	private let discordRPCClient: DiscordRPCClient
	private let hotkeyManager: GlobalHotkeyManager
	private let soundFeedback = SoundFeedbackController()
	private var storageMonitor: StorageMonitor!
	private var discordActivityState: DiscordActivityState = .idle
	private var discordPresenceRetryTask: Task<Void, Never>?
	private let gameDetector = GamePresenceDetector()
	private var gamePresenceTask: Task<Void, Never>?
	private var automaticCaptureRetryTask: Task<Void, Never>?
	/// Keeps the system content picker alive while it is presented (it is only an
	/// observer, so it must be retained). Created lazily on macOS 14+.
	private var contentPicker: Any?
	/// The most recent content selection, reused for silent restarts and automatic
	/// retries so the user is not re-prompted mid-session.
	private var lastContentFilter: UncheckedSendable<SCContentFilter>?
	private var awaitingScreenGrant = false
	private var screenGrantPollTask: Task<Void, Never>?
	private var preferredResolutionID: String?
	private var isRestoringSettings = false
	private var cancellables = Set<AnyCancellable>()

	init(
		captureManager: CaptureManager = CaptureManager(),
		clipLibrary: ClipLibrary = ClipLibrary(),
		discordRPCClient: DiscordRPCClient = DiscordRPCClient(),
		hotkeyManager: GlobalHotkeyManager = .shared
	) {
		self.captureManager = captureManager
		self.clipLibrary = clipLibrary
		self.discordRPCClient = discordRPCClient
		self.hotkeyManager = hotkeyManager

		clipLibrary.objectWillChange.sink { [weak self] _ in
			self?.objectWillChange.send()
		}.store(in: &cancellables)

		permissionState = PermissionManager.currentState()
		let settings = AppSettingsStorage.load()
		isRestoringSettings = true
		replayDuration = settings.replayDuration
		selectedQuality = settings.qualityPreset
		selectedFrameRate = settings.frameRateOption
		selectedContainer = settings.container
		selectedAudioCodec = settings.audioCodec
		preferredResolutionID = settings.resolutionID
		hotkey = settings.hotkey
		startRecordingHotkey = settings.startRecordingHotkey
		alwaysRecordEnabled = settings.alwaysRecordEnabled
		saveFeedbackEnabled = settings.saveFeedbackEnabled
		saveFeedbackVolume = settings.saveFeedbackVolume
		saveFeedbackSound = settings.saveFeedbackSound
		recordingStartFeedbackEnabled = settings.recordingStartFeedbackEnabled
		recordingStartFeedbackVolume = settings.recordingStartFeedbackVolume
		recordingStartFeedbackSound = settings.recordingStartFeedbackSound
		recordingEndFeedbackEnabled = settings.recordingEndFeedbackEnabled
		recordingEndFeedbackVolume = settings.recordingEndFeedbackVolume
		recordingEndFeedbackSound = settings.recordingEndFeedbackSound
		errorFeedbackEnabled = settings.errorFeedbackEnabled
		errorFeedbackVolume = settings.errorFeedbackVolume
		errorFeedbackSound = settings.errorFeedbackSound
		discordRPCEnabled = settings.discordRPCEnabled
		fileLoggingEnabled = settings.fileLoggingEnabled
		crashReportingEnabled = settings.crashReportingEnabled
		betaUpdatesEnabled = settings.betaUpdatesEnabled
		catboxEnabled = settings.catboxEnabled
		litterboxEnabled = settings.litterboxEnabled
		recordMicrophoneEnabled = settings.recordMicrophoneEnabled
		recordDesktopAudioEnabled = settings.recordDesktopAudioEnabled
		outputDirectoryPath = settings.outputDirectoryPath
		isRestoringSettings = false
		AppLog.fileLoggingEnabled = fileLoggingEnabled
		Task { [weak self] in
			await self?.captureManager.setOnCaptureInterruptedHandler { [weak self] error in
				self?.handleCaptureInterrupted(error)
			}
		}
		Task { await loadAvailableResolutions() }
		storageMonitor = StorageMonitor { [weak self] message in
			self?.lowStorageWarningMessage = message
		}
		storageMonitor.start()
		Task {
			await discordRPCClient.setEnabled(discordRPCEnabled)
			self.publishDiscordPresenceWithRetry(for: self.discordActivityState)
		}
	}

	func resetToDefaults() {
		let settings = AppSettings.default
		let wasAlwaysRecording = alwaysRecordEnabled

		isRestoringSettings = true
		replayDuration = settings.replayDuration
		selectedQuality = settings.qualityPreset
		selectedFrameRate = settings.frameRateOption
		selectedContainer = settings.container
		selectedAudioCodec = settings.audioCodec
		preferredResolutionID = settings.resolutionID
		selectedResolution = availableResolutions.first(where: { $0.isNative })
			?? availableResolutions.first
		hotkey = settings.hotkey
		startRecordingHotkey = settings.startRecordingHotkey
		alwaysRecordEnabled = settings.alwaysRecordEnabled
		saveFeedbackEnabled = settings.saveFeedbackEnabled
		saveFeedbackVolume = settings.saveFeedbackVolume
		saveFeedbackSound = settings.saveFeedbackSound
		recordingStartFeedbackEnabled = settings.recordingStartFeedbackEnabled
		recordingStartFeedbackVolume = settings.recordingStartFeedbackVolume
		recordingStartFeedbackSound = settings.recordingStartFeedbackSound
		recordingEndFeedbackEnabled = settings.recordingEndFeedbackEnabled
		recordingEndFeedbackVolume = settings.recordingEndFeedbackVolume
		recordingEndFeedbackSound = settings.recordingEndFeedbackSound
		errorFeedbackEnabled = settings.errorFeedbackEnabled
		errorFeedbackVolume = settings.errorFeedbackVolume
		errorFeedbackSound = settings.errorFeedbackSound
		discordRPCEnabled = settings.discordRPCEnabled
		fileLoggingEnabled = settings.fileLoggingEnabled
		crashReportingEnabled = settings.crashReportingEnabled
		betaUpdatesEnabled = settings.betaUpdatesEnabled
		catboxEnabled = settings.catboxEnabled
		litterboxEnabled = settings.litterboxEnabled
		recordMicrophoneEnabled = settings.recordMicrophoneEnabled
		recordDesktopAudioEnabled = settings.recordDesktopAudioEnabled
		outputDirectoryPath = settings.outputDirectoryPath
		isRestoringSettings = false

		persistSettings()
		AppLog.fileLoggingEnabled = fileLoggingEnabled
		CrashReporter.setEnabled(crashReportingEnabled)
		updateGlobalHotkeys()
		Task { await discordRPCClient.setEnabled(discordRPCEnabled) }
		if wasAlwaysRecording && !alwaysRecordEnabled && isCapturing {
			Task { await stopCaptureAsync() }
		} else {
			restartCaptureSilently()
		}
	}

	func startCapture(isAutomatic: Bool = false) {
		Task { await startCaptureAsync(isAutomatic: isAutomatic) }
	}

	func startAlwaysRecording(isAutomatic: Bool = true) {
		guard alwaysRecordEnabled else { return }
		startCapture(isAutomatic: isAutomatic)
	}

	func stopCapture() {
		guard !alwaysRecordEnabled else { return }
		Task { await stopCaptureAsync() }
	}

	func saveReplay() {
		Task { await saveReplayAsync() }
	}

	func toggleCapture() {
		if isCapturing {
			guard !alwaysRecordEnabled else { return }
			stopCapture()
		} else {
			startCapture(isAutomatic: false)
		}
	}

	func refreshPermissions() {
		Task { await refreshPermissionsAsync() }
	}

	/// Opens the Screen Recording settings pane and watches for the grant, then
	/// relaunches automatically so the user never has to quit and reopen the app.
	func requestScreenRecordingAccess() {
		PermissionManager.openSystemSettings()
		awaitingScreenGrant = true
		screenGrantPollTask?.cancel()
		screenGrantPollTask = Task { @MainActor [weak self] in
			// Back up the app-becomes-active refresh in case the user grants
			// while Rewind is still frontmost. Give up after a few minutes.
			for _ in 0 ..< 200 {
				try? await Task.sleep(nanoseconds: 1_500_000_000)
				guard let self, self.awaitingScreenGrant else { return }
				if PermissionManager.currentState().screenRecording {
					self.relaunchForScreenGrant()
					return
				}
			}
		}
	}

	private func relaunchForScreenGrant() {
		guard awaitingScreenGrant else { return }
		awaitingScreenGrant = false
		screenGrantPollTask?.cancel()
		screenGrantPollTask = nil
		PermissionManager.relaunch()
	}

	func refreshResolutions() {
		Task { await loadAvailableResolutions() }
	}

	private func loadAvailableResolutions() async {
		guard !isLoadingResolutions else { return }

		isLoadingResolutions = true
		resolutionLoadingMessage = nil
		defer { isLoadingResolutions = false }

		let resolutions = await CaptureResolutionProvider.availableResolutions()
		if !resolutions.isEmpty {
			availableResolutions = resolutions

			if let selectedResolutionID = selectedResolution?.id,
			   let currentSelection = resolutions.first(where: { $0.id == selectedResolutionID })
			{
				if selectedResolution != currentSelection {
					selectedResolution = currentSelection
				}
				preferredResolutionID = currentSelection.id
				return
			}

			if let preferredResolutionID,
			   let preferredResolution = resolutions.first(where: {
			   	$0.id == preferredResolutionID
			   })
			{
				selectedResolution = preferredResolution
				return
			}

			if let native = resolutions.first(where: { $0.isNative }) {
				selectedResolution = native
			} else {
				selectedResolution = resolutions.first
			}
			return
		}

		permissionState = PermissionManager.currentState()
		if !permissionState.screenRecording {
			availableResolutions = []
			resolutionLoadingMessage = "Screen recording permission required"
			return
		}

		availableResolutions = []
		resolutionLoadingMessage = "Could not load resolutions"
		AppLog.error(.app, "Resolutions did not load after multiple tries")
	}

	private func startCaptureAsync(isAutomatic: Bool = false) async {
		if !isAutomatic {
			automaticCaptureRetryTask?.cancel()
		}
		do {
			try await PermissionManager.ensureScreenAccess()
			permissionState = PermissionManager.currentState()

			// On a manual start, let the user choose what to capture. Automatic
			// starts (retries) silently reuse the last selection so recording can
			// resume without interrupting the user.
			let contentFilter: UncheckedSendable<SCContentFilter>?
			if isAutomatic {
				contentFilter = lastContentFilter
			} else if #available(macOS 14.0, *) {
				do {
					contentFilter = try await presentContentPicker()
					lastContentFilter = contentFilter
				} catch is ContentSharingPicker.Cancelled {
					// User dismissed the picker; abort the start without an error.
					return
				}
			} else {
				contentFilter = nil
			}

			try await captureManager.start(
				contentFilter: contentFilter,
				resolution: selectedResolution,
				quality: selectedQuality,
				frameRate: selectedFrameRate.framesPerSecond,
				audioCodec: selectedAudioCodec,
				recordMicrophoneEnabled: recordMicrophoneEnabled,
				recordDesktopAudioEnabled: recordDesktopAudioEnabled
			)
			isCapturing = true
			updateDiscordActivity(.recording(game: nil, joinURL: nil))
			playRecordingStartFeedback()
			automaticCaptureRetryTask?.cancel()
		} catch {
			isCapturing = false
			updateDiscordActivity(.idle)

			if isAutomatic {
				AppLog.error(.app, "Automatic capture start failed", error)
				scheduleCaptureRetry()
				return
			}

			playErrorFeedback()

			let alert = NSAlert()
			alert.messageText = "Rewind failed to start capture"
			alert.informativeText =
				"Rewind could not start recording: \(error.localizedDescription)"
			alert.alertStyle = .critical
			alert.addButton(withTitle: "OK")

			NSApp.activate(ignoringOtherApps: true)
			alert.runModal()
		}
	}

	private func stopCaptureAsync() async {
		automaticCaptureRetryTask?.cancel()
		await captureManager.stop()
		isCapturing = false
		updateDiscordActivity(.idle)
		playRecordingEndFeedback()
	}

	/// Presents the macOS content picker and returns the chosen filter, boxed so it
	/// can cross into the capture actor. Retains the picker for the presentation.
	@available(macOS 14.0, *)
	private func presentContentPicker() async throws -> UncheckedSendable<SCContentFilter> {
		let picker = ContentSharingPicker()
		contentPicker = picker
		defer { contentPicker = nil }
		return try await picker.pick()
	}

	private func restartCaptureSilently() {
		guard isCapturing else { return }
		Task {
			await captureManager.stop()
			do {
				try await captureManager.start(
					contentFilter: lastContentFilter,
					resolution: selectedResolution,
					quality: selectedQuality,
					frameRate: selectedFrameRate.framesPerSecond,
					audioCodec: selectedAudioCodec,
					recordMicrophoneEnabled: recordMicrophoneEnabled,
					recordDesktopAudioEnabled: recordDesktopAudioEnabled
				)
			} catch {
				isCapturing = false
				updateDiscordActivity(.idle)
				playErrorFeedback()
				AppLog.error(.app, "Silent restart failed:", error)
			}
		}
	}

	private func saveReplayAsync() async {
		do {
			let url = try await captureManager.saveReplay(
				seconds: replayDuration, container: selectedContainer
			)
			let clipDuration = try await resolvedClipDuration(for: url)
			let clip = try await clipLibrary.addClip(url: url, duration: clipDuration)
			lastClip = clip
			playReplaySavedFeedback()
			refreshStorageWarning()
		} catch {
			AppLog.error(.app, "Save replay failed:", error)
			playErrorFeedback()
		}
	}

	private func updateDiscordActivity(_ state: DiscordActivityState) {
		let previous = discordActivityState
		guard previous != state else { return }
		discordActivityState = state
		publishDiscordPresenceWithRetry(for: state)

		// Only manage the game poller on the idle<->recording transition, not
		// when the poller itself refines the game name (recording -> recording).
		if state.isRecording, !previous.isRecording {
			startGamePresenceUpdates()
		} else if !state.isRecording, previous.isRecording {
			gamePresenceTask?.cancel()
			gamePresenceTask = nil
		}
	}

	/// While recording, periodically look up the game being played and fold it
	/// into the Discord presence so it reads "Clipping <game>".
	private func startGamePresenceUpdates() {
		gamePresenceTask?.cancel()
		gamePresenceTask = Task { @MainActor [weak self] in
			while !Task.isCancelled {
				guard let self, self.isCapturing, self.discordRPCEnabled,
				      self.discordActivityState.isRecording else { return }
				let presence = await self.gameDetector.currentGame()
				if self.discordActivityState.isRecording {
					self.updateDiscordActivity(.recording(game: presence?.name, joinURL: presence?.joinURL))
				}
				try? await Task.sleep(nanoseconds: 10_000_000_000)
			}
		}
	}

	private func publishDiscordPresenceWithRetry(for state: DiscordActivityState) {
		guard discordRPCEnabled else { return }

		discordPresenceRetryTask?.cancel()
		discordPresenceRetryTask = Task { @MainActor [weak self] in
			guard let self else { return }

			while !Task.isCancelled {
				guard self.discordRPCEnabled, self.discordActivityState == state else { return }
				let published = await self.discordRPCClient.publish(state: state)
				if published { return }
				try? await Task.sleep(nanoseconds: 2_000_000_000)
			}
		}
	}

	func playReplaySavedFeedback() {
		soundFeedback.play(
			.saved,
			enabled: saveFeedbackEnabled,
			volume: saveFeedbackVolume,
			sound: saveFeedbackSound,
			defaultSoundName: "save"
		)
	}

	func playRecordingStartFeedback() {
		soundFeedback.play(
			.recordingStart,
			enabled: recordingStartFeedbackEnabled,
			volume: recordingStartFeedbackVolume,
			sound: recordingStartFeedbackSound,
			defaultSoundName: "start"
		)
	}

	func playRecordingEndFeedback() {
		soundFeedback.play(
			.recordingEnd,
			enabled: recordingEndFeedbackEnabled,
			volume: recordingEndFeedbackVolume,
			sound: recordingEndFeedbackSound,
			defaultSoundName: "end"
		)
	}

	func playErrorFeedback() {
		soundFeedback.play(
			.error,
			enabled: errorFeedbackEnabled,
			volume: errorFeedbackVolume,
			sound: errorFeedbackSound,
			defaultSoundName: "error"
		)
	}

	private func resolvedClipDuration(for url: URL) async throws -> TimeInterval {
		let asset = AVURLAsset(url: url)
		do {
			let duration = try await asset.load(.duration)
			let seconds = CMTimeGetSeconds(duration)
			if seconds.isFinite, seconds > 0 {
				return seconds
			}
		} catch {
			AppLog.info(.app, "Couldnt read export clip duration", error)
			throw error
		}
		throw CaptureError.invalidDuration
	}

	private func refreshPermissionsAsync() async {
		permissionState = PermissionManager.currentState()
		// If the user just granted Screen Recording (typically detected when the
		// app becomes active again), relaunch to apply it.
		if awaitingScreenGrant, permissionState.screenRecording {
			relaunchForScreenGrant()
		}
	}

	private func handleCaptureInterrupted(_ error: Error) {
		isCapturing = false
		updateDiscordActivity(.idle)
		playErrorFeedback()
		AppLog.error(.app, "Capture interrupted:", error)
		scheduleCaptureRetry()
	}

	private func scheduleCaptureRetry() {
		automaticCaptureRetryTask?.cancel()
		automaticCaptureRetryTask = Task { @MainActor [weak self] in
			guard let self else { return }
			try? await Task.sleep(nanoseconds: 2_000_000_000)
			if Task.isCancelled { return }
			if !self.isCapturing {
				self.startCapture(isAutomatic: true)
			}
		}
	}

	private func updateGlobalHotkeys() {
		hotkeyManager.updateHotkeys(
			saveReplay: hotkey,
			recordToggle: startRecordingHotkey
		)
	}

	private func persistSettings() {
		AppSettingsStorage.save(
			AppSettings(
				replayDuration: replayDuration,
				resolutionID: preferredResolutionID,
				qualityID: selectedQuality.id,
				frameRate: selectedFrameRate.framesPerSecond,
				containerID: selectedContainer.id,
				audioCodecID: selectedAudioCodec.id,
				hotkey: hotkey,
				startRecordingHotkey: startRecordingHotkey,
				alwaysRecordEnabled: alwaysRecordEnabled,
				saveFeedbackEnabled: saveFeedbackEnabled,
				saveFeedbackVolume: saveFeedbackVolume,
				saveFeedbackSoundID: saveFeedbackSound.id,
				recordingStartFeedbackEnabled: recordingStartFeedbackEnabled,
				recordingStartFeedbackVolume: recordingStartFeedbackVolume,
				recordingStartFeedbackSoundID: recordingStartFeedbackSound.id,
				recordingEndFeedbackEnabled: recordingEndFeedbackEnabled,
				recordingEndFeedbackVolume: recordingEndFeedbackVolume,
				recordingEndFeedbackSoundID: recordingEndFeedbackSound.id,
				errorFeedbackEnabled: errorFeedbackEnabled,
				errorFeedbackVolume: errorFeedbackVolume,
				errorFeedbackSoundID: errorFeedbackSound.id,
				discordRPCEnabled: discordRPCEnabled,
				fileLoggingEnabled: fileLoggingEnabled,
				crashReportingEnabled: crashReportingEnabled,
				betaUpdatesEnabled: betaUpdatesEnabled,
				catboxEnabled: catboxEnabled,
				litterboxEnabled: litterboxEnabled,
				recordMicrophoneEnabled: recordMicrophoneEnabled,
				recordDesktopAudioEnabled: recordDesktopAudioEnabled,
				outputDirectoryPath: outputDirectoryPath
			)
		)
	}

	private func refreshStorageWarning() {
		storageMonitor.refresh()
	}
}
