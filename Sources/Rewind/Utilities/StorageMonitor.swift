import Foundation

/// Periodically checks free disk space on the volume that holds the clip output
/// folder and reports a low-storage warning message (or nil) through `onChange`.
@MainActor
final class StorageMonitor {
    private enum Constants {
        static let thresholdBytes: Int64 = 5 * 1024 * 1024 * 1024
        static let refreshIntervalNanos: UInt64 = 30 * 1_000_000_000
    }

    private let onChange: @MainActor (String?) -> Void
    private var task: Task<Void, Never>?

    init(onChange: @escaping @MainActor (String?) -> Void) {
        self.onChange = onChange
    }

    deinit {
        task?.cancel()
    }

    func start() {
        refresh()
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Constants.refreshIntervalNanos)
                if Task.isCancelled { break }
                self?.refresh()
            }
        }
    }

    func refresh() {
        onChange(currentWarning())
    }

    private func currentWarning() -> String? {
        guard let freeBytes = availableBytes() else { return nil }
        guard freeBytes < Constants.thresholdBytes else { return nil }
        return "Low disk space: \(ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)) left."
    }

    private func availableBytes() -> Int64? {
        let fileManager = FileManager.default
        let targetURL = nearestExistingDirectory(ClipStorageLocation.current())

        if let resourceValues = try? targetURL.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ]) {
            if let availableForImportantUsage = resourceValues.volumeAvailableCapacityForImportantUsage {
                return availableForImportantUsage
            }
            if let availableCapacity = resourceValues.volumeAvailableCapacity {
                return Int64(availableCapacity)
            }
        }

        if let attributes = try? fileManager.attributesOfFileSystem(forPath: targetURL.path),
            let freeSize = attributes[.systemFreeSize] as? NSNumber
        {
            return freeSize.int64Value
        }

        return nil
    }

    /// the output folder may not exist yet, but free space is a property of the
    /// volume, so any existing ancestor on that volume gives the right answer
    private func nearestExistingDirectory(_ url: URL) -> URL {
        let fileManager = FileManager.default
        var candidate = url.standardizedFileURL
        while !fileManager.fileExists(atPath: candidate.path) {
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { break }
            candidate = parent
        }
        return candidate
    }
}
