import Combine
import Foundation
import Sparkle

@MainActor
final class UpdaterController: ObservableObject {
  let updaterController: SPUStandardUpdaterController

  var updater: SPUUpdater {
    updaterController.updater
  }

  init() {
    updaterController = SPUStandardUpdaterController(
      startingUpdater: true,
      updaterDelegate: nil,
      userDriverDelegate: nil
    )
  }

  func checkForUpdates() {
    updaterController.checkForUpdates(nil)
  }
}
