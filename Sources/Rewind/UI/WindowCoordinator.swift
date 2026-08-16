import AppKit

@MainActor
final class WindowCoordinator {
	private let onboardingWindowController: OnboardingWindowController
	private let lowStorageWarningWindowController: LowStorageWarningWindowController

	var shouldShowOnboarding: Bool {
		onboardingWindowController.shouldShow
	}

	init() {
		onboardingWindowController = OnboardingWindowController()
		lowStorageWarningWindowController = LowStorageWarningWindowController()
	}

	func showOnboardingIfNeeded(onDismiss: (() -> Void)? = nil) {
		onboardingWindowController.showIfNeeded(onDismiss: onDismiss)
	}

	func showOnboarding(onDismiss: (() -> Void)? = nil) {
		onboardingWindowController.show(onDismiss: onDismiss)
	}

	func showLowStorageWarning(_ warningMessage: String) {
		lowStorageWarningWindowController.show(warningMessage: warningMessage)
	}

	func closeLowStorageWarningIfNeeded() {
		lowStorageWarningWindowController.closeIfNeeded()
	}
}
