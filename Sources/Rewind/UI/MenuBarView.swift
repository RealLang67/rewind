import AppKit
import SwiftUI

struct MenuBarView: View {
  @ObservedObject var appState: AppState

  var body: some View {
    Button(recordingButtonTitle) {
      appState.toggleCapture()
    }
    .disabled(recordingButtonDisabled)
    .applyHotkey(appState.startRecordingHotkey)

    Button("Save Last \(Int(appState.replayDuration))s") {
      appState.saveReplay()
    }
    .disabled(!appState.isCapturing)
    .applyHotkey(appState.hotkey)

    Divider()

    Menu("Replay Duration") {
      ForEach(replayDurationOptions, id: \.self) { duration in
        Toggle(
          "\(duration)s",
          isOn: Binding(
            get: {
              Int(appState.replayDuration) == duration
            },
            set: { isEnabled in
              if isEnabled {
                appState.replayDuration = TimeInterval(duration)
              }
            }
          )
        )
        .toggleStyle(.checkbox)
        .help("Set replay duration to \(duration) seconds")
      }
    }

    Menu("Resolution") {
      resolutionMenuContent
    }
    .disabled(!appState.permissionState.screenRecording)

    Menu("Quality") {
      ForEach(QualityPreset.presets) { preset in
        Toggle(
          preset.label,
          isOn: Binding(
            get: {
              appState.selectedQuality.id == preset.id
            },
            set: { isEnabled in
              if isEnabled {
                appState.selectedQuality = preset
              }
            }
          )
        )
        .toggleStyle(.checkbox)
      }
    }
    .disabled(!appState.permissionState.screenRecording)

    Button("Show in Finder") {
      showLastClipInFinder()
    }
    .disabled(appState.lastClip == nil)

    if !appState.permissionState.screenRecording {
      Divider()
      Button("⚠ Screen Recording Required") {
        PermissionManager.openSystemSettings()
      }
    }

    Divider()

    settingsMenuItem

    Button("Quit Rewind") {
      NSApp.terminate(nil)
    }
    .keyboardShortcut("q", modifiers: .command)
  }

  private var replayDurationOptions: [Int] {
    var durations = AppSettings.replayDurationQuickOptions
    let currentDuration = Int(appState.replayDuration)
    if !durations.contains(currentDuration) {
      durations.append(currentDuration)
      durations.sort()
    }
    return durations
  }

  private var recordingButtonTitle: String {
    if appState.alwaysRecordEnabled {
      return appState.isCapturing ? "Recording (Always)" : "Start Recording"
    }
    return appState.isCapturing ? "Stop Recording" : "Start Recording"
  }

  private var recordingButtonDisabled: Bool {
    appState.alwaysRecordEnabled && appState.isCapturing
  }

  @ViewBuilder
  private var resolutionMenuContent: some View {
    if appState.availableResolutions.isEmpty {
      if appState.isLoadingResolutions {
        Text("Loading…")
      } else {
        if let resolutionLoadingMessage = appState.resolutionLoadingMessage {
          Text(resolutionLoadingMessage)
        }
        Button("Refresh Resolutions") {
          appState.refreshResolutions()
        }
      }
    } else {
      ForEach(appState.availableResolutions) { resolution in
        Toggle(
          resolution.label,
          isOn: Binding(
            get: {
              appState.selectedResolution?.id == resolution.id
            },
            set: { isEnabled in
              if isEnabled {
                appState.selectedResolution = resolution
              }
            }
          )
        )
        .toggleStyle(.checkbox)
      }
      Divider()
      Button("Refresh Resolutions") {
        appState.refreshResolutions()
      }
    }
  }

  private func showLastClipInFinder() {
    guard let clip = appState.lastClip else { return }
    
    let scriptSource = """
    tell application "Finder"
        activate
        reveal POSIX file "\(clip.url.path)"
    end tell
    """
    
    if let script = NSAppleScript(source: scriptSource) {
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if error == nil {
            return
        }
    }
    
    // fallback
    NSWorkspace.shared.activateFileViewerSelecting([clip.url])
    if let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
      finder.activate(options: [.activateIgnoringOtherApps])
    }
  }

  @Environment(\.openWindow) private var openWindow

  @ViewBuilder
  private var settingsMenuItem: some View {
    if #available(macOS 14.0, *) {
      OpenSettingsMenuItem()
    } else {
      Button("Settings…") {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "settings-fallback")
      }
      .keyboardShortcut(",", modifiers: .command)
    }
  }
}

@available(macOS 14.0, *)
private struct OpenSettingsMenuItem: View {
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    Button("Settings…") {
      NSApp.activate(ignoringOtherApps: true)
      DispatchQueue.main.async {
        openSettings()
      }
    }
    .keyboardShortcut(",", modifiers: .command)
  }
}

private extension View {
  @ViewBuilder
  func applyHotkey(_ hotkey: Hotkey) -> some View {
    if let keyEquivalent = hotkey.keyEquivalent {
      keyboardShortcut(keyEquivalent, modifiers: hotkey.eventModifiers)
    } else {
      self
    }
  }
}

private extension Hotkey {
  var keyEquivalent: KeyEquivalent? {
    guard let keyCharacter = menuKeyEquivalent.first else { return nil }
    return KeyEquivalent(keyCharacter)
  }

  var eventModifiers: EventModifiers {
    EventModifiers(modifierFlags)
  }
}

private extension EventModifiers {
  init(_ modifierFlags: NSEvent.ModifierFlags) {
    var eventModifiers: EventModifiers = []
    if modifierFlags.contains(.command) {
      eventModifiers.insert(.command)
    }
    if modifierFlags.contains(.shift) {
      eventModifiers.insert(.shift)
    }
    if modifierFlags.contains(.option) {
      eventModifiers.insert(.option)
    }
    if modifierFlags.contains(.control) {
      eventModifiers.insert(.control)
    }
    self = eventModifiers
  }
}
