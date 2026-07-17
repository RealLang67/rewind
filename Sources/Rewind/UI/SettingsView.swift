import AppKit
import Carbon
import SwiftUI

struct SettingsView: View {
	@ObservedObject var appState: AppState
	@ObservedObject var updaterController: UpdaterController
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

			UploadSettingsPane(appState: appState, settingsLocked: settingsLocked)
				.tabItem { Label("Upload", systemImage: "icloud.and.arrow.up") }

			AboutSettingsPane(appState: appState, updaterController: updaterController)
				.tabItem { Label("About", systemImage: "info.circle") }
		}
		.frame(minWidth: 440, minHeight: 440)
		.safeAreaInset(edge: .top, spacing: 0) {
			if settingsLocked {
				PermissionCallout()
			}
		}
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
		Int(AppSettings.replayDurationRange.lowerBound) ... Int(AppSettings.replayDurationRange.upperBound)
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
			Section("Recording") {
				LabeledContent {
					Stepper(
						value: replayDurationSecondsBinding,
						in: replayDurationRange,
						step: replayDurationStep
					) {
						Text("\(Int(appState.replayDuration)) seconds")
							.foregroundStyle(.secondary)
					}
					.frame(width: 200, alignment: .trailing)
				} label: {
					HelpLabel("Clip length", help: "Determines how many seconds of video to save when capturing.")
				}

				LabeledContent {
					Toggle("", isOn: $appState.alwaysRecordEnabled)
						.labelsHidden()
						.toggleStyle(.switch)
				} label: {
					HelpLabel("Always record", help: "Automatically saves clips continuously in the background.")
				}

				LabeledContent {
					Toggle("", isOn: $appState.recordMicrophoneEnabled)
						.labelsHidden()
						.toggleStyle(.switch)
						.disabled(!AppState.supportsMicrophoneCapture)
				} label: {
					HelpLabel(
						"Record Microphone",
						help: AppState.supportsMicrophoneCapture
							? "Captures microphone audio. Requires microphone permissions."
							: "Captures microphone audio. Requires macOS 15 or later."
					)
				}
			}
			.disabled(settingsLocked)

			Section("Video") {
				LabeledContent("Resolution") {
					resolutionControl
						.frame(width: 200, alignment: .trailing)
				}

				Picker(selection: $appState.selectedQuality) {
					ForEach(QualityPreset.presets) { preset in
						Text(defaultTaggedLabel(preset.label, isDefault: preset.isDefault)).tag(preset)
					}
				} label: {
					HelpLabel("Quality", help: "Higher quality increases file size but produces clearer video.")
				}
				.pickerStyle(.menu)

				Picker(selection: $appState.selectedFrameRate) {
					ForEach(CaptureFrameRate.options) { option in
						Text(defaultTaggedLabel(option.label, isDefault: option.isDefault)).tag(option)
					}
				} label: {
					HelpLabel("Frame rate", help: "Higher frame rates produce smoother video but use more system resources.")
				}
				.pickerStyle(.menu)
			}
			.disabled(settingsLocked)

			Section("Output") {
				Picker(selection: $appState.selectedContainer) {
					ForEach(CaptureContainer.options) { option in
						Text(defaultTaggedLabel(option.label, isDefault: option.isDefault)).tag(option)
					}
				} label: {
					HelpLabel("Container", help: "Video file format for saved clips (.mp4 or .mov).")
				}
				.pickerStyle(.menu)

				Picker(selection: $appState.selectedAudioCodec) {
					ForEach(CaptureAudioCodec.options) { option in
						Text(defaultTaggedLabel(option.label, isDefault: option.isDefault)).tag(option)
					}
				} label: {
					HelpLabel("Audio codec", help: "Audio encoding format used for saved clips.")
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
					Text(defaultTaggedLabel(resolution.label, isDefault: resolution.isNative))
							.tag(Optional(resolution))
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
			Section {
				HotkeyRecorderRow(title: "Start/Stop recording", hotkey: $appState.startRecordingHotkey)
				HotkeyRecorderRow(title: "Save last clip", hotkey: $appState.hotkey)
			} header: {
				Text("Shortcuts")
			} footer: {
				Text("Press Escape to cancel recording. Shortcuts must include at least one modifier key.")
			}
			.disabled(settingsLocked)
		}
		.formStyle(.grouped)
	}
}

private struct FeedbackSection: View {
	let title: String
	let toggleLabel: String
	@Binding var enabled: Bool
	@Binding var sound: FeedbackSound
	@Binding var volume: Double
	let settingsLocked: Bool
	let onPlay: () -> Void

	private var feedbackVolumeRange: ClosedRange<Int> {
		Int(AppSettings.saveFeedbackVolumeRange.lowerBound) ... Int(AppSettings.saveFeedbackVolumeRange.upperBound)
	}

	private var volumeBinding: Binding<Int> {
		Binding(
			get: { Int(volume.rounded()) },
			set: { newValue in
				let clamped = min(max(newValue, feedbackVolumeRange.lowerBound), feedbackVolumeRange.upperBound)
				volume = Double(clamped)
			}
		)
	}

	var body: some View {
		Section(title) {
			Toggle(toggleLabel, isOn: $enabled)

			Picker("Feedback sound", selection: $sound) {
				ForEach(FeedbackSound.options) { soundOption in
					Text(soundOption.label).tag(soundOption)
				}
			}
			.pickerStyle(.menu)
			.disabled(!enabled)

			LabeledContent("Feedback volume") {
				HStack(spacing: 6) {
					TextField("", value: volumeBinding, format: .number.grouping(.never))
						.textFieldStyle(.roundedBorder)
						.multilineTextAlignment(.trailing)
						.frame(width: 64)
						.help("Range: \(feedbackVolumeRange.lowerBound)-\(feedbackVolumeRange.upperBound)")
						.disabled(!enabled)

					Text("%")
						.foregroundStyle(.secondary)

					Button {
						onPlay()
					} label: {
						Image(systemName: "play.circle")
					}
					.buttonStyle(.plain)
					.padding(.leading, 4)
					.disabled(!enabled)
				}
			}
		}
		.disabled(settingsLocked)
	}
}

private struct FeedbackSettingsPane: View {
	@ObservedObject var appState: AppState
	let settingsLocked: Bool

	var body: some View {
		Form {
			FeedbackSection(
				title: "Save Feedback",
				toggleLabel: "Enable save feedback",
				enabled: $appState.saveFeedbackEnabled,
				sound: $appState.saveFeedbackSound,
				volume: $appState.saveFeedbackVolume,
				settingsLocked: settingsLocked,
				onPlay: { appState.playReplaySavedFeedback() }
			)

			FeedbackSection(
				title: "Recording Start Feedback",
				toggleLabel: "Enable start feedback",
				enabled: $appState.recordingStartFeedbackEnabled,
				sound: $appState.recordingStartFeedbackSound,
				volume: $appState.recordingStartFeedbackVolume,
				settingsLocked: settingsLocked,
				onPlay: { appState.playRecordingStartFeedback() }
			)

			FeedbackSection(
				title: "Recording End Feedback",
				toggleLabel: "Enable end feedback",
				enabled: $appState.recordingEndFeedbackEnabled,
				sound: $appState.recordingEndFeedbackSound,
				volume: $appState.recordingEndFeedbackVolume,
				settingsLocked: settingsLocked,
				onPlay: { appState.playRecordingEndFeedback() }
			)

			FeedbackSection(
				title: "Error Feedback",
				toggleLabel: "Enable error feedback",
				enabled: $appState.errorFeedbackEnabled,
				sound: $appState.errorFeedbackSound,
				volume: $appState.errorFeedbackVolume,
				settingsLocked: settingsLocked,
				onPlay: { appState.playErrorFeedback() }
			)
		}
		.formStyle(.grouped)
	}
}

private struct WindowAccessor: NSViewRepresentable {
	let onResolve: (NSWindow) -> Void

	func makeNSView(context _: Context) -> NSView {
		let view = NSView()
		DispatchQueue.main.async {
			if let window = view.window {
				onResolve(window)
			}
		}
		return view
	}

	func updateNSView(_ nsView: NSView, context _: Context) {
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
			Section("Connections") {
				Toggle(isOn: $appState.discordRPCEnabled) {
					HelpLabel("Enable Discord RPC", help: "Shows your recording status on your Discord profile.")
				}
			}
			.disabled(settingsLocked)
		}
		.formStyle(.grouped)
	}
}

private struct UploadSettingsPane: View {
	@ObservedObject var appState: AppState
	let settingsLocked: Bool

	var body: some View {
		Form {
			Section {
				Toggle(isOn: $appState.catboxEnabled) {
					HelpLabel("Catbox.moe", help: "Enable uploading clips to Catbox.moe (permanent).")
				}
				Toggle(isOn: $appState.litterboxEnabled) {
					HelpLabel("Litterbox", help: "Enable uploading clips to Litterbox (expiration configurable on upload).")
				}
			} header: {
				Text("Providers")
			} footer: {
				Text("By enabling a provider, you agree to their respective Terms of Service and Privacy Policy.")
			}
			.disabled(settingsLocked)
		}
		.formStyle(.grouped)
	}
}

private struct AboutSettingsPane: View {
	@ObservedObject var appState: AppState
	@ObservedObject var updaterController: UpdaterController
	@State private var showingResetConfirmation = false

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

				Button("Check for Updates...") {
					updaterController.checkForUpdates()
				}
				.liquidGlassButtonStyle()
				.disabled(!updaterController.updater.canCheckForUpdates)
			}

			Section("Advanced") {
				Toggle(isOn: $appState.fileLoggingEnabled) {
					HelpLabel("Enable verbose file logging", help: "Writes detailed debug logs to disk for troubleshooting.")
				}
				
				Button("Reveal Log File in Finder") {
					if let url = AppLog.logFileURL {
						NSWorkspace.shared.activateFileViewerSelecting([url])
					}
				}
				.liquidGlassButtonStyle()

				Button("Reset to Defaults...", role: .destructive) {
					showingResetConfirmation = true
				}
				.liquidGlassButtonStyle()
			}
		}
		.formStyle(.grouped)
		.confirmationDialog(
			"Reset all settings to their defaults?",
			isPresented: $showingResetConfirmation,
			titleVisibility: .visible
		) {
			Button("Reset to Defaults", role: .destructive) {
				appState.resetToDefaults()
			}
			Button("Cancel", role: .cancel) {}
		}
	}
}

private func defaultTaggedLabel(_ label: String, isDefault: Bool) -> String {
	isDefault ? "\(label) (Default)" : label
}

private struct HelpLabel: View {
	let title: String
	let help: String
	@State private var isHovering = false
	@State private var hoverTask: Task<Void, Never>?

	init(_ title: String, help: String) {
		self.title = title
		self.help = help
	}

	var body: some View {
		HStack(spacing: 4) {
			Text(title)
			Image(systemName: "questionmark.circle")
				.foregroundStyle(isHovering ? .primary : .secondary)
				.onHover { hovering in
					hoverTask?.cancel()
					if hovering {
						hoverTask = Task {
							try? await Task.sleep(nanoseconds: 500_000_000)
							if !Task.isCancelled {
								isHovering = true
							}
						}
					} else {
						isHovering = false
					}
				}
				.popover(isPresented: $isHovering, arrowEdge: .top) {
					Text(help)
						.lineLimit(nil)
						.frame(width: 220, alignment: .leading)
						.padding(10)
				}
		}
	}
}

private struct PermissionCallout: View {
	var body: some View {
		HStack(spacing: 12) {
			Image(systemName: "lock.fill")
				.font(.title3)
				.foregroundStyle(.secondary)

			VStack(alignment: .leading, spacing: 2) {
				Text("Screen recording permission required")
					.font(.callout.weight(.medium))
				Text("Grant access to change capture settings.")
					.font(.caption)
					.foregroundStyle(.secondary)
			}

			Spacer(minLength: 8)

			Button("Open System Settings") {
				PermissionManager.openSystemSettings()
			}
			.buttonStyle(.borderedProminent)
			.controlSize(.small)
		}
		.padding(12)
		.liquidGlassCard(cornerRadius: 14)
		.padding(.horizontal)
		.padding(.top, 8)
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
