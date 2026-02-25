import AppKit
import Carbon
import SwiftUI

struct SettingsView: View {
  @ObservedObject var appState: AppState
  @State private var didApplyWindowSizing = false

  private var settingsLocked: Bool {
    !appState.permissionState.screenRecording
  }

  var body: some View {
    TabView {
      CaptureSettingsPane(appState: appState, settingsLocked: settingsLocked)
        .tabItem { Label("Capture", systemImage: "record.circle") }

      HotkeysSettingsPane(appState: appState, settingsLocked: settingsLocked)
        .tabItem { Label("Hotkeys", systemImage: "keyboard") }

      FeedbackSettingsPane(appState: appState, settingsLocked: settingsLocked)
        .tabItem { Label("Feedback", systemImage: "speaker.wave.2") }

      IntegrationsSettingsPane(appState: appState, settingsLocked: settingsLocked)
        .tabItem { Label("Integrations", systemImage: "puzzlepiece.extension") }

      AboutSettingsPane()
        .tabItem { Label("About", systemImage: "info.circle") }
    }
    .frame(minWidth: 440, minHeight: 440)
    .background(
      WindowAccessor { window in
        applyNaturalWindowSizeIfNeeded(window)
      }
    )
    .onAppear {
      appState.refreshPermissions()
      if appState.availableResolutions.isEmpty, !appState.isLoadingResolutions {
        appState.refreshResolutions()
      }
    }
  }

  private func applyNaturalWindowSizeIfNeeded(_ window: NSWindow) {
    guard !didApplyWindowSizing else { return }
    didApplyWindowSizing = true

    let naturalSize = NSSize(width: 520, height: 440)
    window.contentMinSize = naturalSize
    window.setContentSize(naturalSize)
  }
}

private struct CaptureSettingsPane: View {
  @ObservedObject var appState: AppState
  let settingsLocked: Bool

  private var replayDurationRange: ClosedRange<Int> {
    Int(AppSettings.replayDurationRange.lowerBound)...Int(AppSettings.replayDurationRange.upperBound)
  }

  private var replayDurationStep: Int {
    max(1, Int(AppSettings.replayDurationStep))
  }

  private var replayDurationSecondsBinding: Binding<Int> {
    Binding(
      get: { Int(appState.replayDuration) },
      set: { newValue in
        let clampedValue = min(max(newValue, replayDurationRange.lowerBound), replayDurationRange.upperBound)
        appState.replayDuration = TimeInterval(clampedValue)
      }
    )
  }

  var body: some View {
    Form {
      if settingsLocked {
        PermissionNoticeRow()
      }

      Section("Recording") {
        LabeledContent("Clip length") {
          Stepper(
            value: replayDurationSecondsBinding,
            in: replayDurationRange,
            step: replayDurationStep
          ) {
            Text("\(Int(appState.replayDuration)) seconds")
              .foregroundStyle(.secondary)
          }
          .frame(width: 200, alignment: .trailing)
        }

        LabeledContent("Always record") {
          Toggle("", isOn: $appState.alwaysRecordEnabled)
            .labelsHidden()
        }
      }
      .disabled(settingsLocked)

      Section("Video") {
        LabeledContent("Resolution") {
          resolutionControl
            .frame(width: 200, alignment: .trailing)
        }

        Picker("Quality", selection: $appState.selectedQuality) {
          ForEach(QualityPreset.presets) { preset in
            Text(preset.label).tag(preset)
          }
        }
        .pickerStyle(.menu)

        Picker("Frame rate", selection: $appState.selectedFrameRate) {
          ForEach(CaptureFrameRate.options) { option in
            Text(option.label).tag(option)
          }
        }
        .pickerStyle(.menu)
      }
      .disabled(settingsLocked)

      Section("Output") {
        Picker("Container", selection: $appState.selectedContainer) {
          ForEach(CaptureContainer.options) { option in
            Text(option.label).tag(option)
          }
        }
        .pickerStyle(.menu)

        Picker("Audio codec", selection: $appState.selectedAudioCodec) {
          ForEach(CaptureAudioCodec.options) { option in
            Text(option.label).tag(option)
          }
        }
        .pickerStyle(.menu)
      }
      .disabled(settingsLocked)
    }
    .formStyle(.grouped)
  }

  @ViewBuilder
  private var resolutionControl: some View {
    if appState.availableResolutions.isEmpty {
      if appState.isLoadingResolutions {
        ProgressView()
          .controlSize(.small)
      } else {
        HStack(spacing: 8) {
          Text(appState.resolutionLoadingMessage ?? "Resolution unavailable")
            .foregroundStyle(.secondary)
          Button("Reload") {
            appState.refreshResolutions()
          }
          .buttonStyle(.link)
        }
      }
    } else {
      Picker("Resolution", selection: $appState.selectedResolution) {
        ForEach(appState.availableResolutions) { resolution in
          Text(resolution.label).tag(Optional(resolution))
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)
    }
  }
}

private struct HotkeysSettingsPane: View {
  @ObservedObject var appState: AppState
  let settingsLocked: Bool

  var body: some View {
    Form {
      if settingsLocked {
        PermissionNoticeRow()
      }

      Section("Shortcuts") {
        HotkeyRecorderRow(title: "Start/Stop recording", hotkey: $appState.startRecordingHotkey)
        HotkeyRecorderRow(title: "Save last clip", hotkey: $appState.hotkey)
      }
      .disabled(settingsLocked)

      Section {
        Text("Press Escape to cancel recording. Shortcuts must include at least one modifier key.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }
}

private struct FeedbackSettingsPane: View {
  @ObservedObject var appState: AppState
  let settingsLocked: Bool

  private var feedbackVolumeRange: ClosedRange<Int> {
    Int(AppSettings.saveFeedbackVolumeRange.lowerBound)...Int(AppSettings.saveFeedbackVolumeRange.upperBound)
  }

  private var feedbackVolumeInputBinding: Binding<Int> {
    Binding(
      get: {
        Int(appState.saveFeedbackVolume.rounded())
      },
      set: { newValue in
        let clampedValue = min(max(newValue, feedbackVolumeRange.lowerBound), feedbackVolumeRange.upperBound)
        appState.saveFeedbackVolume = Double(clampedValue)
      }
    )
  }

  var body: some View {
    Form {
      if settingsLocked {
        PermissionNoticeRow()
      }

      Section("Save Feedback") {
        Toggle("Enable save feedback", isOn: $appState.saveFeedbackEnabled)

        Picker("Feedback sound", selection: $appState.saveFeedbackSound) {
          ForEach(SaveFeedbackSound.options) { sound in
            Text(sound.label).tag(sound)
          }
        }
        .pickerStyle(.menu)
        .disabled(!appState.saveFeedbackEnabled)

        LabeledContent("Feedback volume") {
          HStack(spacing: 6) {
            TextField("", value: feedbackVolumeInputBinding, format: .number.grouping(.never))
              .textFieldStyle(.roundedBorder)
              .multilineTextAlignment(.trailing)
              .frame(width: 64)
              .help("Range: \(feedbackVolumeRange.lowerBound)-\(feedbackVolumeRange.upperBound)")
            .disabled(!appState.saveFeedbackEnabled)

            Text("%")
              .foregroundStyle(.secondary)
          }
        }
      }
      .disabled(settingsLocked)
    }
    .formStyle(.grouped)
  }
}

private struct WindowAccessor: NSViewRepresentable {
  let onResolve: (NSWindow) -> Void

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    DispatchQueue.main.async {
      if let window = view.window {
        onResolve(window)
      }
    }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    DispatchQueue.main.async {
      if let window = nsView.window {
        onResolve(window)
      }
    }
  }
}

private struct IntegrationsSettingsPane: View {
  @ObservedObject var appState: AppState
  let settingsLocked: Bool

  var body: some View {
    Form {
      if settingsLocked {
        PermissionNoticeRow()
      }

      Section("Connections") {
        Toggle("Enable Discord RPC", isOn: $appState.discordRPCEnabled)
      }
      .disabled(settingsLocked)
    }
    .formStyle(.grouped)
  }
}

private struct AboutSettingsPane: View {
  private var appVersion: String {
    let shortVersion = normalizedVersion(
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    ) ?? normalizedVersion(ProcessInfo.processInfo.environment["REWIND_VERSION"])

    let buildVersion = normalizedVersion(
      Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    )

    if let shortVersion {
      if let buildVersion, buildVersion != shortVersion {
        return "\(shortVersion) (\(buildVersion))"
      }
      return shortVersion
    }

    if let buildVersion {
      return buildVersion
    }

    return "Dev"
  }

  private func normalizedVersion(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  var body: some View {
    Form {
      Section("Rewind") {
        LabeledContent("Version") {
          Text(appVersion)
        }
      }
    }
    .formStyle(.grouped)
  }
}

private struct PermissionNoticeRow: View {
  var body: some View {
    Section {
      VStack(alignment: .leading, spacing: 8) {
        Label("Screen recording permission is required to change capture settings.", systemImage: "lock.fill")
          .font(.callout)
          .foregroundStyle(.secondary)

        Button("Open System Settings") {
          PermissionManager.openSystemSettings()
        }
      }
      .padding(.vertical, 2)
    }
  }
}

private struct HotkeyRecorderRow: View {
  let title: String
  @Binding var hotkey: Hotkey
  @State private var isRecording = false
  @State private var monitor: Any?

  var body: some View {
    LabeledContent(title) {
      HStack(spacing: 10) {
        Text(isRecording ? "Press keys..." : hotkey.displayString)
          .foregroundStyle(.secondary)
          .monospaced()

        Button(isRecording ? "Cancel" : "Record") {
          if isRecording {
            stopRecording()
          } else {
            startRecording()
          }
        }
        .controlSize(.small)
      }
    }
    .onDisappear {
      stopRecording()
    }
  }

  private func startRecording() {
    isRecording = true
    if monitor != nil { return }

    monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
      guard isRecording else { return event }

      if event.keyCode == UInt16(kVK_Escape) {
        stopRecording()
        return nil
      }

      let relevantFlags = event.modifierFlags.intersection([.command, .shift, .option, .control])
      if relevantFlags.isEmpty {
        return nil
      }

      hotkey = Hotkey(keyCode: UInt32(event.keyCode), modifiers: relevantFlags.carbonModifiers)
      stopRecording()
      return nil
    }
  }

  private func stopRecording() {
    isRecording = false
    if let monitor {
      NSEvent.removeMonitor(monitor)
      self.monitor = nil
    }
  }
}
