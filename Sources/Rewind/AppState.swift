@preconcurrency import AVFoundation
import AppKit
import SwiftUI

@MainActor
final class AppState: ObservableObject {
  private enum StorageWarning {
    static let thresholdBytes: Int64 = 5 * 1024 * 1024 * 1024
  }

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
    }
  }
  @Published var selectedQuality: QualityPreset = .default {
    didSet {
      guard !isRestoringSettings else { return }
      guard selectedQuality != oldValue else { return }
      persistSettings()
    }
  }
  @Published var selectedFrameRate: CaptureFrameRate = .default {
    didSet {
      guard !isRestoringSettings else { return }
      guard selectedFrameRate != oldValue else { return }
      persistSettings()
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
      replaySavedSound = nil
      replaySavedBoostSound = nil
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
      recordingStartSound = nil
      recordingStartBoostSound = nil
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
      recordingEndSound = nil
      recordingEndBoostSound = nil
      persistSettings()
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

  @Published var useBFrames = AppSettings.default.useBFrames {
    didSet {
      guard !isRestoringSettings else { return }
      guard useBFrames != oldValue else { return }
      persistSettings()
    }
  }

  @Published private(set) var lowStorageWarningMessage: String?

  private let captureManager: CaptureManager
  private let clipLibrary: ClipLibrary
  private let discordRPCClient: DiscordRPCClient
  private let hotkeyManager: GlobalHotkeyManager
  private var replaySavedSound: NSSound?
  private var replaySavedBoostSound: NSSound?
  private var recordingStartSound: NSSound?
  private var recordingStartBoostSound: NSSound?
  private var recordingEndSound: NSSound?
  private var recordingEndBoostSound: NSSound?
  private var discordActivityState: DiscordActivityState = .idle
  private var discordPresenceRetryTask: Task<Void, Never>?
  private var preferredResolutionID: String?
  private var isRestoringSettings = false
  private var isTerminatingForCaptureIssue = false
 
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
    discordRPCEnabled = settings.discordRPCEnabled
    useBFrames = settings.useBFrames
    isRestoringSettings = false
    Task { [weak self] in
      await self?.captureManager.setOnCaptureInterruptedHandler { error in
        self?.handleCaptureInterrupted(error)
      }
    }
    Task { await loadAvailableResolutions() }
    refreshStorageWarning()
    Task {
      await discordRPCClient.setEnabled(discordRPCEnabled)
      self.publishDiscordPresenceWithRetry(for: self.discordActivityState)
    }
  }

  func startCapture() {
    Task { await startCaptureAsync() }
  }

  func startAlwaysRecording() {
    guard alwaysRecordEnabled else { return }
    startCapture()
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
      startCapture()
    }
  }

  func refreshPermissions() {
    Task { await refreshPermissionsAsync() }
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
         let currentSelection = resolutions.first(where: { $0.id == selectedResolutionID }) {
        if selectedResolution != currentSelection {
          selectedResolution = currentSelection
        }
        preferredResolutionID = currentSelection.id
        return
      }

      if let preferredResolutionID,
         let preferredResolution = resolutions.first(where: { $0.id == preferredResolutionID }) {
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

  private func startCaptureAsync() async {
    do {
      try await PermissionManager.ensureScreenAccess()
      permissionState = PermissionManager.currentState()
      try await captureManager.start(
        resolution: selectedResolution,
        quality: selectedQuality,
        frameRate: selectedFrameRate.framesPerSecond,
        audioCodec: selectedAudioCodec,
        useBFrames: useBFrames
      )
      isCapturing = true
      updateDiscordActivity(.recording)
      playRecordingStartFeedback()
    } catch {
      isCapturing = false
      updateDiscordActivity(.idle)
    }
  }

  private func stopCaptureAsync() async {
    await captureManager.stop()
    isCapturing = false
    updateDiscordActivity(.idle)
    playRecordingEndFeedback()
  }

  private func saveReplayAsync() async {
    do {
      let url = try await captureManager.saveReplay(seconds: replayDuration, container: selectedContainer)
      let clipDuration = try await resolvedClipDuration(for: url)
      let clip = try await clipLibrary.addClip(url: url, duration: clipDuration)
      lastClip = clip
      playReplaySavedFeedback()
    } catch {
      print("Save replay failed:", error)
    }
  }

  private func updateDiscordActivity(_ state: DiscordActivityState) {
    guard discordActivityState != state else { return }
    discordActivityState = state
    publishDiscordPresenceWithRetry(for: state)
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

  private func playFeedback(
    enabled: Bool,
    volume: Double,
    sound: FeedbackSound,
    defaultSoundName: String,
    cachedSound: NSSound?,
    cachedBoostSound: NSSound?,
    updateCache: (NSSound?, NSSound?) -> Void
  ) {
    guard enabled else { return }

    let soundName = sound.id == "default" ? defaultSoundName : sound.systemSoundName

    let primary: NSSound
    if let cached = cachedSound {
      primary = cached
    } else {
      if let newSound = NSSound(named: NSSound.Name(soundName)) {
        primary = newSound
      } else {
        let sourceFileURL = URL(fileURLWithPath: #filePath)
        let rootURL = sourceFileURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let devURL = rootURL.appendingPathComponent("Resources/Sounds/\(soundName).wav")
        if let newSound = NSSound(contentsOf: devURL, byReference: true) {
          primary = newSound
        } else {
          let rootDevURL = rootURL.appendingPathComponent("Resources/\(soundName).wav")
          if let newSound = NSSound(contentsOf: rootDevURL, byReference: true) {
            primary = newSound
          } else {
            return
          }
        }
      }
    }

    let boost: NSSound?
    if let cachedBoost = cachedBoostSound {
      boost = cachedBoost
    } else {
      boost = primary.copy() as? NSSound
    }

    updateCache(primary, boost)

    let normalizedVolume = volume / 100
    let primaryVolume = Float(min(1, normalizedVolume * 1.25))
    let boostMix = max(0, normalizedVolume - 0.55) / 0.45
    let boostVolume = Float(min(1, boostMix * 0.9))

    primary.stop()
    primary.volume = primaryVolume
    primary.play()

    if boostVolume > 0, let boost = boost {
      boost.stop()
      boost.volume = boostVolume
      boost.play()
    }
  }

  func playReplaySavedFeedback() {
    playFeedback(
      enabled: saveFeedbackEnabled,
      volume: saveFeedbackVolume,
      sound: saveFeedbackSound,
      defaultSoundName: "save",
      cachedSound: replaySavedSound,
      cachedBoostSound: replaySavedBoostSound
    ) { [weak self] primary, boost in
      self?.replaySavedSound = primary
      self?.replaySavedBoostSound = boost
    }
  }

  func playRecordingStartFeedback() {
    playFeedback(
      enabled: recordingStartFeedbackEnabled,
      volume: recordingStartFeedbackVolume,
      sound: recordingStartFeedbackSound,
      defaultSoundName: "start",
      cachedSound: recordingStartSound,
      cachedBoostSound: recordingStartBoostSound
    ) { [weak self] primary, boost in
      self?.recordingStartSound = primary
      self?.recordingStartBoostSound = boost
    }
  }

  func playRecordingEndFeedback() {
    playFeedback(
      enabled: recordingEndFeedbackEnabled,
      volume: recordingEndFeedbackVolume,
      sound: recordingEndFeedbackSound,
      defaultSoundName: "end",
      cachedSound: recordingEndSound,
      cachedBoostSound: recordingEndBoostSound
    ) { [weak self] primary, boost in
      self?.recordingEndSound = primary
      self?.recordingEndBoostSound = boost
    }
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
  }

  private func handleCaptureInterrupted(_ error: Error) {
    isCapturing = false
    updateDiscordActivity(.idle)
    AppLog.error(.app, "Capture interrupted:", error)
    guard alwaysRecordEnabled, !isTerminatingForCaptureIssue else { return }
    isTerminatingForCaptureIssue = true
    NSApp.terminate(nil)
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
        discordRPCEnabled: discordRPCEnabled,
        useBFrames: useBFrames
      )
    )
  }

  private func refreshStorageWarning() {
    guard let freeBytes = availableStorageBytes() else {
      lowStorageWarningMessage = nil
      return
    }

    if freeBytes < StorageWarning.thresholdBytes {
      lowStorageWarningMessage = "Low disk space: \(formattedStorage(freeBytes)) left."
    } else {
      lowStorageWarningMessage = nil
    }
  }

  private func availableStorageBytes() -> Int64? {
    let fileManager = FileManager.default
    let targetURL = fileManager.urls(for: .moviesDirectory, in: .userDomainMask).first
      ?? fileManager.homeDirectoryForCurrentUser

    if let resourceValues = try? targetURL.resourceValues(forKeys: [
      .volumeAvailableCapacityForImportantUsageKey,
      .volumeAvailableCapacityKey
    ]) {
      if let availableForImportantUsage = resourceValues.volumeAvailableCapacityForImportantUsage {
        return availableForImportantUsage
      }
      if let availableCapacity = resourceValues.volumeAvailableCapacity {
        return Int64(availableCapacity)
      }
    }

    if let attributes = try? fileManager.attributesOfFileSystem(forPath: targetURL.path),
       let freeSize = attributes[.systemFreeSize] as? NSNumber {
      return freeSize.int64Value
    }

    return nil
  }

  private func formattedStorage(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }
}
