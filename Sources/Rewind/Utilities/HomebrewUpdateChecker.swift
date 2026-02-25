import AppKit
import Foundation

final class HomebrewUpdateChecker {
  private static let caskURL = URL(
    string: "https://raw.githubusercontent.com/l1zov/homebrew-tap/main/Casks/rewind-app.rb"
  )!
  private static let caskToken = "rewind-app"

  private var didCheckAtLaunch = false
  private let session: URLSession

  init(session: URLSession = .shared) {
    self.session = session
  }

  @MainActor
  func checkForUpdatesAtLaunch() {
    guard !didCheckAtLaunch else { return }
    didCheckAtLaunch = true

    guard let currentVersion = Self.currentVersion() else {
      AppLog.debug(.app, "No app version found")
      return
    }

    Task(priority: .utility) { [session] in
      do {
        guard let latestVersion = try await Self.fetchRemoteVersion(using: session) else {
          AppLog.debug(.app, "No cask version found")
          return
        }

        guard Self.isNewerVersion(latestVersion, than: currentVersion) else {
          AppLog.debug(
            .app,
            "No update available.",
            "Current:",
            currentVersion,
            "Latest:",
            latestVersion
          )
          return
        }

        await MainActor.run {
          Self.presentUpdateAlert(
            currentVersion: currentVersion,
            latestVersion: latestVersion
          )
        }
      } catch {
        AppLog.debug(.app, "Update checking error:", error.localizedDescription)
      }
    }
  }

  private static func fetchRemoteVersion(using session: URLSession) async throws -> String? {
    var request = URLRequest(url: caskURL)
    request.timeoutInterval = 6

    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else { return nil }
    guard (200 ... 299).contains(httpResponse.statusCode) else { return nil }
    guard let body = String(data: data, encoding: .utf8) else { return nil }
    return parseCaskVersion(from: body)
  }

  private static func parseCaskVersion(from caskBody: String) -> String? {
    let pattern = #"(?m)^\s*version\s+"([^"]+)"\s*$"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(caskBody.startIndex..<caskBody.endIndex, in: caskBody)
    guard let match = regex.firstMatch(in: caskBody, range: range) else { return nil }
    guard let valueRange = Range(match.range(at: 1), in: caskBody) else { return nil }

    let rawVersion = caskBody[valueRange]
      .split(separator: ",", maxSplits: 1, omittingEmptySubsequences: true)
      .first
      .map(String.init)

    return normalizedVersion(rawVersion)
  }

  private static func currentVersion() -> String? {
    let shortVersion = normalizedVersion(
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    ) ?? normalizedVersion(ProcessInfo.processInfo.environment["REWIND_VERSION"])

    if let shortVersion {
      return shortVersion
    }

    return normalizedVersion(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
  }

  private static func normalizedVersion(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func isNewerVersion(_ lhs: String, than rhs: String) -> Bool {
    lhs.compare(rhs, options: [.numeric, .caseInsensitive]) == .orderedDescending
  }

  @MainActor
  private static func presentUpdateAlert(
    currentVersion: String,
    latestVersion: String
  ) {
    let updateCommand = "brew update && brew upgrade --cask l1zov/tap/\(caskToken)"
    let tapURL = URL(string: "https://github.com/l1zov/homebrew-tap")

    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = "Update Available"
    alert.informativeText =
      "Rewind \(latestVersion) is available (you are on \(currentVersion)). "
      + "Run this command in Terminal:\n\n\(updateCommand)"
    alert.addButton(withTitle: "Copy Update Command")
    alert.addButton(withTitle: "Open Tap")
    alert.addButton(withTitle: "Later")

    NSApp.activate(ignoringOtherApps: true)
    let response = alert.runModal()

    if response == .alertFirstButtonReturn {
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      pasteboard.setString(updateCommand, forType: .string)
      return
    }

    if response == .alertSecondButtonReturn, let tapURL {
      NSWorkspace.shared.open(tapURL)
    }
  }
}
