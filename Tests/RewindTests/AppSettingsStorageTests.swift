import XCTest
@testable import Rewind

final class AppSettingsStorageTests: XCTestCase {
  private let storageKey = "settings.app.v1"

  override func setUp() {
    super.setUp()
    UserDefaults.standard.removeObject(forKey: storageKey)
  }

  override func tearDown() {
    UserDefaults.standard.removeObject(forKey: storageKey)
    super.tearDown()
  }

  func testLoadReturnsDefaultWhenNoSettingsExist() {
    let settings = AppSettingsStorage.load()

    XCTAssertEqual(settings.replayDuration, AppSettings.default.replayDuration)
    XCTAssertEqual(settings.resolutionID, AppSettings.default.resolutionID)
    XCTAssertEqual(settings.qualityID, AppSettings.default.qualityID)
    XCTAssertEqual(settings.frameRate, AppSettings.default.frameRate)
    XCTAssertEqual(settings.containerID, AppSettings.default.containerID)
    XCTAssertEqual(settings.audioCodecID, AppSettings.default.audioCodecID)
    XCTAssertEqual(settings.hotkey, AppSettings.default.hotkey)
    XCTAssertEqual(settings.startRecordingHotkey, AppSettings.default.startRecordingHotkey)
    XCTAssertEqual(settings.alwaysRecordEnabled, AppSettings.default.alwaysRecordEnabled)
    XCTAssertEqual(settings.saveFeedbackEnabled, AppSettings.default.saveFeedbackEnabled)
    XCTAssertEqual(settings.saveFeedbackVolume, AppSettings.default.saveFeedbackVolume)
    XCTAssertEqual(settings.saveFeedbackSoundID, AppSettings.default.saveFeedbackSoundID)
    XCTAssertEqual(settings.recordingStartFeedbackEnabled, AppSettings.default.recordingStartFeedbackEnabled)
    XCTAssertEqual(settings.recordingStartFeedbackVolume, AppSettings.default.recordingStartFeedbackVolume)
    XCTAssertEqual(settings.recordingStartFeedbackSoundID, AppSettings.default.recordingStartFeedbackSoundID)
    XCTAssertEqual(settings.recordingEndFeedbackEnabled, AppSettings.default.recordingEndFeedbackEnabled)
    XCTAssertEqual(settings.recordingEndFeedbackVolume, AppSettings.default.recordingEndFeedbackVolume)
    XCTAssertEqual(settings.recordingEndFeedbackSoundID, AppSettings.default.recordingEndFeedbackSoundID)
    XCTAssertEqual(settings.errorFeedbackEnabled, AppSettings.default.errorFeedbackEnabled)
    XCTAssertEqual(settings.errorFeedbackVolume, AppSettings.default.errorFeedbackVolume)
    XCTAssertEqual(settings.errorFeedbackSoundID, AppSettings.default.errorFeedbackSoundID)
    XCTAssertEqual(settings.discordRPCEnabled, AppSettings.default.discordRPCEnabled)
    XCTAssertEqual(settings.useBFrames, AppSettings.default.useBFrames)
  }

  func testSaveThenLoadPersistsValues() {
    let expected = AppSettings(
      replayDuration: 45,
      resolutionID: "1920x1080",
      qualityID: "very-high",
      frameRate: 30,
      containerID: "mp4",
      audioCodecID: CaptureAudioCodec.aac.id,
      hotkey: Hotkey(keyCode: 0, modifiers: Hotkey.default.modifiers),
      startRecordingHotkey: Hotkey.startRecordingDefault,
      alwaysRecordEnabled: true,
      saveFeedbackEnabled: false,
      saveFeedbackVolume: 15,
      saveFeedbackSoundID: FeedbackSound.pop.id,
      recordingStartFeedbackEnabled: false,
      recordingStartFeedbackVolume: 25,
      recordingStartFeedbackSoundID: FeedbackSound.ping.id,
      recordingEndFeedbackEnabled: true,
      recordingEndFeedbackVolume: 35,
      recordingEndFeedbackSoundID: FeedbackSound.cling.id,
      errorFeedbackEnabled: true,
      errorFeedbackVolume: 45,
      errorFeedbackSoundID: FeedbackSound.pop.id,
      discordRPCEnabled: false,
      useBFrames: false
    )

    AppSettingsStorage.save(expected)
    let loaded = AppSettingsStorage.load()

    XCTAssertEqual(loaded.replayDuration, expected.replayDuration)
    XCTAssertEqual(loaded.resolutionID, expected.resolutionID)
    XCTAssertEqual(loaded.qualityID, expected.qualityID)
    XCTAssertEqual(loaded.frameRate, expected.frameRate)
    XCTAssertEqual(loaded.containerID, expected.containerID)
    XCTAssertEqual(loaded.audioCodecID, expected.audioCodecID)
    XCTAssertEqual(loaded.hotkey, expected.hotkey)
    XCTAssertEqual(loaded.startRecordingHotkey, expected.startRecordingHotkey)
    XCTAssertEqual(loaded.alwaysRecordEnabled, expected.alwaysRecordEnabled)
    XCTAssertEqual(loaded.saveFeedbackEnabled, expected.saveFeedbackEnabled)
    XCTAssertEqual(loaded.saveFeedbackVolume, expected.saveFeedbackVolume)
    XCTAssertEqual(loaded.saveFeedbackSoundID, expected.saveFeedbackSoundID)
    XCTAssertEqual(loaded.recordingStartFeedbackEnabled, expected.recordingStartFeedbackEnabled)
    XCTAssertEqual(loaded.recordingStartFeedbackVolume, expected.recordingStartFeedbackVolume)
    XCTAssertEqual(loaded.recordingStartFeedbackSoundID, expected.recordingStartFeedbackSoundID)
    XCTAssertEqual(loaded.recordingEndFeedbackEnabled, expected.recordingEndFeedbackEnabled)
    XCTAssertEqual(loaded.recordingEndFeedbackVolume, expected.recordingEndFeedbackVolume)
    XCTAssertEqual(loaded.recordingEndFeedbackSoundID, expected.recordingEndFeedbackSoundID)
    XCTAssertEqual(loaded.errorFeedbackEnabled, expected.errorFeedbackEnabled)
    XCTAssertEqual(loaded.errorFeedbackVolume, expected.errorFeedbackVolume)
    XCTAssertEqual(loaded.errorFeedbackSoundID, expected.errorFeedbackSoundID)
    XCTAssertEqual(loaded.discordRPCEnabled, expected.discordRPCEnabled)
    XCTAssertEqual(loaded.useBFrames, expected.useBFrames)
  }

  func testLoadClearsStoredValuesAndReturnsDefaultWhenStoredSettingsAreInvalid() throws {
    let invalid = AppSettings(
      replayDuration: 500,
      resolutionID: "jldsjkjdhsk",
      qualityID: "dsjdjhhdha",
      frameRate: 999,
      containerID: "hhkkhhklllllll",
      audioCodecID: "nope",
      hotkey: Hotkey(keyCode: 999, modifiers: 0),
      startRecordingHotkey: Hotkey(keyCode: 998, modifiers: 0),
      alwaysRecordEnabled: true,
      saveFeedbackEnabled: true,
      saveFeedbackVolume: 300,
      saveFeedbackSoundID: "1234556789blahhhh",
      recordingStartFeedbackEnabled: true,
      recordingStartFeedbackVolume: 300,
      recordingStartFeedbackSoundID: "1234556789blahhhh",
      recordingEndFeedbackEnabled: true,
      recordingEndFeedbackVolume: 300,
      recordingEndFeedbackSoundID: "1234556789blahhhh",
      errorFeedbackEnabled: true,
      errorFeedbackVolume: 300,
      errorFeedbackSoundID: "1234556789blahhhh",
      discordRPCEnabled: false,
      useBFrames: false
    )
    let data = try JSONEncoder().encode(invalid)
    UserDefaults.standard.set(data, forKey: storageKey)

    let loaded = AppSettingsStorage.load()

    XCTAssertNil(UserDefaults.standard.object(forKey: storageKey))
    XCTAssertEqual(loaded.replayDuration, AppSettings.default.replayDuration)
    XCTAssertEqual(loaded.resolutionID, AppSettings.default.resolutionID)
    XCTAssertEqual(loaded.qualityID, AppSettings.default.qualityID)
    XCTAssertEqual(loaded.frameRate, AppSettings.default.frameRate)
    XCTAssertEqual(loaded.containerID, AppSettings.default.containerID)
    XCTAssertEqual(loaded.audioCodecID, AppSettings.default.audioCodecID)
    XCTAssertEqual(loaded.hotkey, AppSettings.default.hotkey)
    XCTAssertEqual(loaded.startRecordingHotkey, AppSettings.default.startRecordingHotkey)
    XCTAssertEqual(loaded.alwaysRecordEnabled, AppSettings.default.alwaysRecordEnabled)
    XCTAssertEqual(loaded.saveFeedbackEnabled, AppSettings.default.saveFeedbackEnabled)
    XCTAssertEqual(loaded.saveFeedbackVolume, AppSettings.default.saveFeedbackVolume)
    XCTAssertEqual(loaded.saveFeedbackSoundID, AppSettings.default.saveFeedbackSoundID)
    XCTAssertEqual(loaded.recordingStartFeedbackEnabled, AppSettings.default.recordingStartFeedbackEnabled)
    XCTAssertEqual(loaded.recordingStartFeedbackVolume, AppSettings.default.recordingStartFeedbackVolume)
    XCTAssertEqual(loaded.recordingStartFeedbackSoundID, AppSettings.default.recordingStartFeedbackSoundID)
    XCTAssertEqual(loaded.recordingEndFeedbackEnabled, AppSettings.default.recordingEndFeedbackEnabled)
    XCTAssertEqual(loaded.recordingEndFeedbackVolume, AppSettings.default.recordingEndFeedbackVolume)
    XCTAssertEqual(loaded.recordingEndFeedbackSoundID, AppSettings.default.recordingEndFeedbackSoundID)
    XCTAssertEqual(loaded.errorFeedbackEnabled, AppSettings.default.errorFeedbackEnabled)
    XCTAssertEqual(loaded.errorFeedbackVolume, AppSettings.default.errorFeedbackVolume)
    XCTAssertEqual(loaded.errorFeedbackSoundID, AppSettings.default.errorFeedbackSoundID)
    XCTAssertEqual(loaded.discordRPCEnabled, AppSettings.default.discordRPCEnabled)
    XCTAssertEqual(loaded.useBFrames, AppSettings.default.useBFrames)
  }

  func testLoadFallsBackToDefaultWhenStoredBlobIsInvalid() {
    UserDefaults.standard.set(Data([0x00, 0x01, 0x02]), forKey: storageKey)

    let loaded = AppSettingsStorage.load()

    XCTAssertNil(UserDefaults.standard.object(forKey: storageKey))
    XCTAssertEqual(loaded.replayDuration, AppSettings.default.replayDuration)
    XCTAssertEqual(loaded.qualityID, AppSettings.default.qualityID)
    XCTAssertEqual(loaded.frameRate, AppSettings.default.frameRate)
    XCTAssertEqual(loaded.containerID, AppSettings.default.containerID)
    XCTAssertEqual(loaded.audioCodecID, AppSettings.default.audioCodecID)
    XCTAssertEqual(loaded.hotkey, AppSettings.default.hotkey)
    XCTAssertEqual(loaded.startRecordingHotkey, AppSettings.default.startRecordingHotkey)
    XCTAssertEqual(loaded.alwaysRecordEnabled, AppSettings.default.alwaysRecordEnabled)
    XCTAssertEqual(loaded.saveFeedbackEnabled, AppSettings.default.saveFeedbackEnabled)
    XCTAssertEqual(loaded.saveFeedbackVolume, AppSettings.default.saveFeedbackVolume)
    XCTAssertEqual(loaded.saveFeedbackSoundID, AppSettings.default.saveFeedbackSoundID)
    XCTAssertEqual(loaded.recordingStartFeedbackEnabled, AppSettings.default.recordingStartFeedbackEnabled)
    XCTAssertEqual(loaded.recordingStartFeedbackVolume, AppSettings.default.recordingStartFeedbackVolume)
    XCTAssertEqual(loaded.recordingStartFeedbackSoundID, AppSettings.default.recordingStartFeedbackSoundID)
    XCTAssertEqual(loaded.recordingEndFeedbackEnabled, AppSettings.default.recordingEndFeedbackEnabled)
    XCTAssertEqual(loaded.recordingEndFeedbackVolume, AppSettings.default.recordingEndFeedbackVolume)
    XCTAssertEqual(loaded.recordingEndFeedbackSoundID, AppSettings.default.recordingEndFeedbackSoundID)
    XCTAssertEqual(loaded.errorFeedbackEnabled, AppSettings.default.errorFeedbackEnabled)
    XCTAssertEqual(loaded.errorFeedbackVolume, AppSettings.default.errorFeedbackVolume)
    XCTAssertEqual(loaded.errorFeedbackSoundID, AppSettings.default.errorFeedbackSoundID)
    XCTAssertEqual(loaded.discordRPCEnabled, AppSettings.default.discordRPCEnabled)
    XCTAssertEqual(loaded.useBFrames, AppSettings.default.useBFrames)
  }

  func testSaveClearsStorageWhenSettingsAreInvalid() {
    let invalid = AppSettings(
      replayDuration: AppSettings.default.replayDuration,
      resolutionID: AppSettings.default.resolutionID,
      qualityID: "old-balanced-id",
      frameRate: AppSettings.default.frameRate,
      containerID: AppSettings.default.containerID,
      audioCodecID: AppSettings.default.audioCodecID,
      hotkey: AppSettings.default.hotkey,
      startRecordingHotkey: AppSettings.default.startRecordingHotkey,
      alwaysRecordEnabled: AppSettings.default.alwaysRecordEnabled,
      saveFeedbackEnabled: AppSettings.default.saveFeedbackEnabled,
      saveFeedbackVolume: AppSettings.default.saveFeedbackVolume,
      saveFeedbackSoundID: AppSettings.default.saveFeedbackSoundID,
      recordingStartFeedbackEnabled: AppSettings.default.recordingStartFeedbackEnabled,
      recordingStartFeedbackVolume: AppSettings.default.recordingStartFeedbackVolume,
      recordingStartFeedbackSoundID: AppSettings.default.recordingStartFeedbackSoundID,
      recordingEndFeedbackEnabled: AppSettings.default.recordingEndFeedbackEnabled,
      recordingEndFeedbackVolume: AppSettings.default.recordingEndFeedbackVolume,
      recordingEndFeedbackSoundID: AppSettings.default.recordingEndFeedbackSoundID,
      errorFeedbackEnabled: AppSettings.default.errorFeedbackEnabled,
      errorFeedbackVolume: AppSettings.default.errorFeedbackVolume,
      errorFeedbackSoundID: AppSettings.default.errorFeedbackSoundID,
      discordRPCEnabled: AppSettings.default.discordRPCEnabled,
      useBFrames: AppSettings.default.useBFrames
    )

    AppSettingsStorage.save(invalid)

    XCTAssertNil(UserDefaults.standard.object(forKey: storageKey))
  }
}
