import Foundation
import QuartzCore
import os

/// DEBUG-only counters/signposts describe our work around PencilKit. They do
/// not measure physical Pencil-to-photon latency and never contain ink data.
@MainActor enum DrawingEngineMetrics {
    enum Phase: String, CaseIterable { case shapeRaster, eraserBegin, eraserCommit, toolSwitch, save }
    #if DEBUG
    private(set) static var phaseMilliseconds: [String: [Double]] = [:]
    private static let log = OSLog(subsystem: "com.notemargin.drawing", category: .pointsOfInterest)
    private(set) static var drawingCallbacks = 0
    private(set) static var snapshotCount = 0
    private(set) static var snapshotMilliseconds = 0.0
    private(set) static var inkTileRasters = 0
    private(set) static var eraseBatches = 0
    private(set) static var eraseMilliseconds = 0.0
    static func reset() {
        phaseMilliseconds = [:]; inkTileRasters = 0
        drawingCallbacks = 0; snapshotCount = 0; snapshotMilliseconds = 0
        eraseBatches = 0; eraseMilliseconds = 0
    }
    #endif

    static func measure<T>(_ phase: Phase, _ operation: () throws -> T) rethrows -> T {
        #if DEBUG
        let start = CACurrentMediaTime()
        defer {
            // Bounded diagnostics, never stroke data or credentials.
            var values = phaseMilliseconds[phase.rawValue, default: []]
            if values.count == 128 { values.removeFirst() }
            values.append((CACurrentMediaTime() - start) * 1000)
            phaseMilliseconds[phase.rawValue] = values
        }
        #endif
        return try operation()
    }

    static func inkTileRendered() {
        #if DEBUG
        inkTileRasters += 1
        #endif
    }
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
