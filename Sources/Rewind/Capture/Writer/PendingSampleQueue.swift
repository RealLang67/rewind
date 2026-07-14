import CoreMedia

/// Bounded FIFO of sample buffers awaiting the writer. When full it drops the
/// oldest sample to make room and logs periodically so runaway backlogs are
/// visible without flooding the log.
struct PendingSampleQueue {
    private(set) var samples: [CMSampleBuffer] = []
    private(set) var drops = 0

    private let capacity: Int
    private let label: String
    private let logFirst: Int
    private let logInterval: Int

    init(capacity: Int, label: String, logFirst: Int = 1, logInterval: Int) {
        self.capacity = capacity
        self.label = label
        self.logFirst = logFirst
        self.logInterval = logInterval
    }

    var isEmpty: Bool { samples.isEmpty }
    var count: Int { samples.count }
    var first: CMSampleBuffer? { samples.first }

    mutating func enqueue(_ sampleBuffer: CMSampleBuffer) {
        if samples.count < capacity {
            samples.append(sampleBuffer)
            return
        }
        drops += 1
        if drops == logFirst || drops % logInterval == 0 {
            AppLog.debug(.writer, label, "pending buffer full; drops:", drops)
        }
        samples.removeFirst()
        samples.append(sampleBuffer)
    }

    mutating func dequeue() -> CMSampleBuffer? {
        samples.isEmpty ? nil : samples.removeFirst()
    }

    mutating func replaceAll(_ newSamples: [CMSampleBuffer]) {
        samples = newSamples
    }

    mutating func removeAll() {
        samples.removeAll()
        drops = 0
    }
}
