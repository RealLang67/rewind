import SwiftUI

@main
struct RewindApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @ObservedObject private var appState: AppState

  init() {
    _appState = ObservedObject(initialValue: AppCompositionRoot.shared.appState)
  }

  var body: some Scene {
    MenuBarExtra("Rewind", systemImage: "backward.end.fill") {
      MenuBarView(appState: appState)
    }

    Settings {
      SettingsView(appState: appState)
    }
    .defaultSize(width: 520, height: 440)
  }
}
