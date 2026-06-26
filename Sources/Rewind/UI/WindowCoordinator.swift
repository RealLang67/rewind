@MainActor
final class WindowCoordinator {
	private let onboardingWindowController: OnboardingWindowController
	private let lowStorageWarningWindowController: LowStorageWarningWindowController

	init() {
		onboardingWindowController = OnboardingWindowController()
		lowStorageWarningWindowController = LowStorageWarningWindowController()
	}

	func showOnboardingIfNeeded() {
		onboardingWindowController.showIfNeeded()
	}

	func showLowStorageWarning(_ warningMessage: String) {
		lowStorageWarningWindowController.show(warningMessage: warningMessage)
	}

	func closeLowStorageWarningIfNeeded() {
		lowStorageWarningWindowController.closeIfNeeded()
	}
}
