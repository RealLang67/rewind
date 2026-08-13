import CoreMedia
import CoreVideo

/// Bounded FIFO of sample buffers awaiting the writer. When full it drops the
/// oldest sample to make room and logs periodically so runaway backlogs are
/// visible without flooding the log.
///
/// The bound is a byte budget as well as a sample count, because a video sample
/// retains its pixel buffer and those differ by an order of magnitude across
/// resolutions: 120 queued frames is 373 MB at 1080p but 1.49 GB at 4K. Counting
/// frames alone made the memory ceiling depend on whatever the user picked.
struct PendingSampleQueue {
    private(set) var samples: [CMSampleBuffer] = []
    /// Byte cost of each entry in `samples`, kept in step so eviction stays O(1).
    private var sizes: [Int] = []
    private(set) var drops = 0
    private(set) var byteCount = 0

    private let capacity: Int
    private let byteBudget: Int
    private let label: String
    private let logFirst: Int
    private let logInterval: Int

    init(capacity: Int, byteBudget: Int, label: String, logFirst: Int = 1, logInterval: Int) {
        self.capacity = capacity
        self.byteBudget = byteBudget
        self.label = label
        self.logFirst = logFirst
        self.logInterval = logInterval
    }

    var isEmpty: Bool { samples.isEmpty }
    var count: Int { samples.count }
    var first: CMSampleBuffer? { samples.first }

    mutating func enqueue(_ sampleBuffer: CMSampleBuffer) {
        samples.append(sampleBuffer)
        sizes.append(Self.byteSize(of: sampleBuffer))
        byteCount += sizes[sizes.count - 1]

        // Always keep the newest sample, even when it alone exceeds the budget —
        // dropping everything would be worse than briefly exceeding the ceiling.
        while samples.count > capacity || (byteCount > byteBudget && samples.count > 1) {
            dropOldest()
        }
    }

    mutating func dequeue() -> CMSampleBuffer? {
        guard !samples.isEmpty else { return nil }
        byteCount -= sizes.removeFirst()
        return samples.removeFirst()
    }

    mutating func replaceAll(_ newSamples: [CMSampleBuffer]) {
        samples = newSamples
        sizes = newSamples.map(Self.byteSize(of:))
        byteCount = sizes.reduce(0, +)
    }

    mutating func removeAll() {
        samples.removeAll()
        sizes.removeAll()
        byteCount = 0
        drops = 0
    }

    private mutating func dropOldest() {
        byteCount -= sizes.removeFirst()
        samples.removeFirst()
        drops += 1
        if drops == logFirst || drops % logInterval == 0 {
            AppLog.debug(
                .writer, label, "pending buffer full; drops:", drops, "bytes:", byteCount)
        }
    }

    /// Memory the sample actually holds on to. For video this is the pixel buffer,
    /// which dwarfs everything else in the queue.
    static func byteSize(of sampleBuffer: CMSampleBuffer) -> Int {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return max(0, CMSampleBufferGetTotalSampleSize(sampleBuffer))
        }

        let dataSize = CVPixelBufferGetDataSize(pixelBuffer)
        if dataSize > 0 { return dataSize }

        // Some planar buffers report a zero data size; add the planes up instead.
        let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
        guard planeCount > 0 else {
            return CVPixelBufferGetBytesPerRow(pixelBuffer) * CVPixelBufferGetHeight(pixelBuffer)
        }
        var total = 0
        for plane in 0 ..< planeCount {
            total +=
                CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
                * CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
        }
        return total
    }
}
