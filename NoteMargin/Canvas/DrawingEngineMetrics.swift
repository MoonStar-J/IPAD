import Foundation
import QuartzCore
import os

/// DEBUG-only counters/signposts describe our work around PencilKit. They do
/// not measure physical Pencil-to-photon latency and never contain ink data.
@MainActor enum DrawingEngineMetrics {
    #if DEBUG
    private static let log = OSLog(subsystem: "com.notemargin.drawing", category: .pointsOfInterest)
    private(set) static var drawingCallbacks = 0
    private(set) static var snapshotCount = 0
    private(set) static var snapshotMilliseconds = 0.0
    private(set) static var eraseBatches = 0
    private(set) static var eraseMilliseconds = 0.0
    static func reset() {
        drawingCallbacks = 0; snapshotCount = 0; snapshotMilliseconds = 0
        eraseBatches = 0; eraseMilliseconds = 0
    }
    #endif

    static func drawingChanged() {
        #if DEBUG
        drawingCallbacks += 1
        #endif
    }
    static func snapshot<T>(_ operation: () -> T) -> T {
        #if DEBUG
        let id = OSSignpostID(log: log), start = CACurrentMediaTime()
        os_signpost(.begin, log: log, name: "Committed ink snapshot", signpostID: id)
        defer {
            snapshotCount += 1; snapshotMilliseconds += (CACurrentMediaTime() - start) * 1000
            os_signpost(.end, log: log, name: "Committed ink snapshot", signpostID: id)
        }
        #endif
        return operation()
    }
    static func erasing<T>(_ operation: () -> T) -> T {
        #if DEBUG
        let id = OSSignpostID(log: log), start = CACurrentMediaTime()
        os_signpost(.begin, log: log, name: "Eraser batch", signpostID: id)
        defer {
            eraseBatches += 1; eraseMilliseconds += (CACurrentMediaTime() - start) * 1000
            os_signpost(.end, log: log, name: "Eraser batch", signpostID: id)
        }
        #endif
        return operation()
    }
}
