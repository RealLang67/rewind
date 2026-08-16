import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
	private let shownKey = "ui.onboarding.shown.v2"
	private let userDefaults: UserDefaults
	private var window: NSWindow?
	private var onDismiss: (() -> Void)?

	var shouldShow: Bool {
		userDefaults.bool(forKey: shownKey) == false
	}

	init(userDefaults: UserDefaults = .standard) {
		self.userDefaults = userDefaults
		super.init()
	}

	func showIfNeeded(onDismiss: (() -> Void)? = nil) {
		guard shouldShow else { return }
		show(onDismiss: onDismiss)
	}

	func windowWillClose(_ notification: Notification) {
		userDefaults.set(true, forKey: shownKey)
		let callback = onDismiss
		onDismiss = nil
		callback?()
	}

	func show(onDismiss: (() -> Void)? = nil) {
		self.onDismiss = onDismiss

		if window == nil {
			let view = OnboardingView(
				close: { [weak self] in
					self?.window?.close()
				}
			)
			let hostingController = NSHostingController(rootView: view)

			let window = NSWindow(contentViewController: hostingController)
			window.title = "Onboarding"
			window.styleMask = [.titled, .closable]
			window.isReleasedWhenClosed = false
			window.setContentSize(NSSize(width: 520, height: 340))
			window.center()
			window.delegate = self
			self.window = window
		}

		NSApp.setActivationPolicy(.regular)
		window?.center()
		window?.makeKeyAndOrderFront(nil)
		window?.orderFrontRegardless()
		NSApp.activate(ignoringOtherApps: true)
	}
}
