import Foundation
import PencilKit
import QuartzCore
import UIKit

// This file is concatenated into the isolated simulator integration fixture.
// It calls production types directly and never reads or changes a user's notes.
// Durations below are CPU wall time, not Pencil-to-display or frame latency.
private struct DrawingPerformanceTiming: Codable {
    let operations: Int
    let totalMilliseconds: Double
    let medianMilliseconds: Double
    let p95Milliseconds: Double
    let maximumMilliseconds: Double

    init(_ milliseconds: [Double]) {
        let sorted = milliseconds.sorted()
        operations = sorted.count
        totalMilliseconds = sorted.reduce(0, +)
        medianMilliseconds = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        p95Milliseconds = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
        maximumMilliseconds = sorted.last ?? 0
    }
}

private struct DrawingPerformanceCase: Codable {
    let totalStrokes: Int
    let indexBuildMilliseconds: Double
    let uncachedEraserBeginMilliseconds: Double
    let cachedEraserBegin: DrawingPerformanceTiming
    let localQuery: DrawingPerformanceTiming
    let localCandidatesMinimum: Int
    let localCandidatesMaximum: Int
    let localCandidatesTotal: Int
    let firstPassEraserExtend: DrawingPerformanceTiming
    let repeatedEraserExtend: DrawingPerformanceTiming
    let geometryBuildsFirstPass: Int
    let geometryBuildsRepeatedPass: Int
    let erasedStrokes: Int
    let commitRemainingDrawingMilliseconds: Double
    let oneStrokeRasterMilliseconds: Double
    let appendedDrawingRasterCacheReconciliationMilliseconds: Double
    let unchangedStrokeReusedWithoutRasterization: Bool
    let appendedSpatialCacheReconciliationMilliseconds: Double
    let appendedSpatialRasterReuseMilliseconds: Double
    let appendedSpatialEntryChanges: Int?
    let appendedSpatialEntriesReused: Int?
    let appendedSpatialPrefixEntriesReused: Int?
    let longDurationCoalescedEraserBatches: DrawingPerformanceTiming
    let offscreenSpanningQuery: DrawingPerformanceTiming
    let offscreenSpanningReturnedCandidates: Int
    let entireDocumentQuery: DrawingPerformanceTiming
}

private struct DrawingPerformanceEmptyCase: Codable {
    let indexBuildMilliseconds: Double
    let query: DrawingPerformanceTiming
    let eraserExtend: DrawingPerformanceTiming
}

private struct DrawingPerformanceReport: Codable {
    let measurementScope: String
    let operatingSystem: String
    let environment: String
    let processorCount: Int
    let empty: DrawingPerformanceEmptyCase
    let cases: [DrawingPerformanceCase]
}

/// Deterministic correctness + timing fixtures for the actual eraser/index/cache.
/// No absolute timing assertion: CI/simulator timing is not a device SLA. Compare
/// identical cases before/after a change and profile real Pencil input separately.
@MainActor func checkDrawingPerformance(reportName: String = "drawing-performance.json") throws -> Int {
    var checks = 0
    func check(_ condition: Bool, _ message: String) throws {
        try PDFIntegrationChecks.check(condition, "drawing performance: " + message)
        checks += 1
    }
    func timed<T>(_ body: () -> T) -> (T, Double) {
        let start = CACurrentMediaTime()
        let value = body()
        return (value, (CACurrentMediaTime() - start) * 1000)
    }
    func sampleStroke(index: Int, long: Bool = false) -> PKStroke {
        let origin = long
            ? CGPoint(x: 200_000 + CGFloat(index) * 96, y: 200_000)
            : CGPoint(x: 64 + CGFloat(index % 25) * 40, y: 64 + CGFloat(index / 25) * 48)
        let local: [CGPoint] = long
            ? [.zero, CGPoint(x: 70_000, y: 70_000)]
            : [.zero, CGPoint(x: 6, y: -3), CGPoint(x: 12, y: 3), CGPoint(x: 18, y: -2), CGPoint(x: 24, y: 0)]
        let points = local.enumerated().map { offset, point in
            PKStrokePoint(location: CGPoint(x: origin.x + point.x, y: origin.y + point.y),
                          timeOffset: Double(offset) * 0.015,
                          size: CGSize(width: 3, height: 3), opacity: 1,
                          force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.pen, color: .black),
                        path: PKStrokePath(controlPoints: points,
                                           creationDate: Date(timeIntervalSince1970: 10_000 + Double(index))),
                        randomSeed: UInt32(truncatingIfNeeded: index + 1))
    }
    // An empty page is a common first-writing state, not a special bypass of
    // the real index and transaction implementations.
    let (emptyCache, emptyBuildMilliseconds) = timed { InkGeometryCache(drawing: PKDrawing()) }
    let emptyEraser = StrokeEraserTransaction(drawing: emptyCache.drawing, width: 8, geometryCache: emptyCache)
    var emptyQueries: [Double] = [], emptyExtends: [Double] = []
    for operation in 0..<180 {
        let query = CGRect(x: operation, y: operation / 2, width: 20, height: 20)
        let (candidates, duration) = timed { emptyCache.candidates(intersecting: query) }
        emptyQueries.append(duration)
        try check(candidates.isEmpty, "empty-page query remains empty")
        let (_, extend) = timed { emptyEraser.extend(to: CGPoint(x: operation, y: operation / 2)) }
        emptyExtends.append(extend)
    }
    try check(emptyEraser.erasedIndices.isEmpty && emptyEraser.remainingDrawing.strokes.isEmpty && emptyCache.geometryBuildCount == 0,
              "empty eraser contact never constructs or adds ink")
    let emptyResult = DrawingPerformanceEmptyCase(indexBuildMilliseconds: emptyBuildMilliseconds,
                                                  query: DrawingPerformanceTiming(emptyQueries), eraserExtend: DrawingPerformanceTiming(emptyExtends))
    var results: [DrawingPerformanceCase] = []
    for count in [1, 100, 1_000, 5_000] {
        let strokes = (0..<count).map { sampleStroke(index: $0) }
        let drawing = PKDrawing(strokes: strokes)
        // Serialization is intentionally outside all measured input/query work.
        let originalBytes = drawing.dataRepresentation()
        let (cache, indexMilliseconds) = timed { InkGeometryCache(drawing: drawing) }
        try check(cache.geometryBuildCount == 0, "index creation does not construct (count) exact stroke paths")
        let (uncached, uncachedBeginMilliseconds) = timed { StrokeEraserTransaction(drawing: drawing, width: 8) }
        try check(uncached.geometryCache.geometryBuildCount == 0, "an unused eraser transaction preserves lazy geometry")

        var cachedBeginMilliseconds: [Double] = []
        for _ in 0..<30 {
            let (transaction, duration) = timed { StrokeEraserTransaction(drawing: drawing, width: 8, geometryCache: cache) }
            cachedBeginMilliseconds.append(duration)
            try check(transaction.geometryCache === cache, "unchanged source reuses its document index")
        }

        var queryMilliseconds: [Double] = []
        var candidateCounts: [Int] = []
        for operation in 0..<180 {
            let index = (operation * 37) % count
            let query = strokes[index].renderBounds.insetBy(dx: -3, dy: -3)
            let (candidates, duration) = timed { cache.candidates(intersecting: query) }
            queryMilliseconds.append(duration)
            candidateCounts.append(candidates.count)
            try check(candidates == [index], "localized query returns its one nearby stroke among (count)")
        }
        try check(cache.geometryBuildCount == 0, "spatial queries alone never create exact paths")

        // Same local scribble for every document size: total page size grows,
        // nearby candidates do not. Later visits must reuse/skip exact geometry.
        let visitedCount = min(10, count)
        let transaction = StrokeEraserTransaction(drawing: drawing, width: 8, geometryCache: cache)
        var firstPassMilliseconds: [Double] = []
        for index in 0..<visitedCount {
            let documentPoint = CGPoint(x: 76 + CGFloat(index) * 40, y: 64)
            let (_, duration) = timed { transaction.extend(to: documentPoint) }
            firstPassMilliseconds.append(duration)
        }
        let builtFirst = cache.geometryBuildCount
        try check(transaction.erasedIndices == Set(0..<visitedCount), "coalesced local sweep hits only crossed ink")
        try check(builtFirst == visitedCount, "narrow phase builds only the (visitedCount) local strokes")
        var repeatMilliseconds: [Double] = []
        for operation in 0..<120 {
            let index = operation.isMultiple(of: 2) ? 0 : visitedCount - 1
            let documentPoint = CGPoint(x: 76 + CGFloat(index) * 40, y: 64)
            let (_, duration) = timed { transaction.extend(to: documentPoint) }
            repeatMilliseconds.append(duration)
        }
        let builtRepeated = cache.geometryBuildCount - builtFirst
        try check(builtRepeated == 0, "repeat erasing does not reconstruct already affected paths")
        let (remaining, commitMilliseconds) = timed { transaction.remainingDrawing }
        try check(remaining.strokes.count == count - visitedCount, "one commit preserves all untouched strokes")
        try check(transaction.original.dataRepresentation() == originalBytes, "eraser preview preserves its canonical source")

        // Compare equivalent view-space samples after conversion at overview and
        // high zoom. The current eraser width is explicitly document-constant.
        for zoom: CGFloat in [0.5, 1, 4] {
            let camera = CGAffineTransform(a: zoom, b: 0, c: 0, d: zoom, tx: -137, ty: 83)
            let documentPoint = CGPoint(x: 76, y: 64)
            let viewPoint = documentPoint.applying(camera)
            let converted = viewPoint.applying(camera.inverted())
            let zoomed = StrokeEraserTransaction(drawing: drawing, width: 8, geometryCache: cache)
            zoomed.extend(to: converted)
            try check(zoomed.erasedIndices == [0], "document eraser coordinates survive zoom (zoom)")
        }

        // One small native texture is enough to measure cache reconciliation
        // independently of whole-page raster cost. No source image is logged.
        let raster = cache.nativeRasterCache
        let visible = strokes[0].renderBounds.insetBy(dx: -3, dy: -3)
        let (originalTiles, rasterMilliseconds) = timed { raster.tiles(for: 0, visible: visible, scale: 2) }
        try check(!originalTiles.isEmpty, "native raster fixture produces a bounded stroke tile")
        let appended = PKDrawing(strokes: strokes + [sampleStroke(index: count)])
        let (nextRaster, reconcileMilliseconds) = timed {
            let next = NativeInkRasterCache(drawing: appended)
            next.reuseUnchangedStrokes(from: raster)
            return next
        }
        let beforeReuse = nextRaster.rasterizationCount
        let reusedTiles = nextRaster.tiles(for: 0, visible: visible, scale: 2)
        let reused = nextRaster.rasterizationCount == beforeReuse && reusedTiles.count == originalTiles.count
        try check(reused, "appending one stroke reuses unchanged native textures")

        // Actual host path after a committed append: one metadata reconcile,
        // changed index entries only, then lazy native tile reuse from its
        // proven mapping. Keep the legacy measurement above for baseline parity.
        let (nextGeometry, spatialReconcileMilliseconds) = timed { cache.updated(to: appended) }
        let (_, spatialRasterReuseMilliseconds) = timed {
            _ = nextGeometry.nativeRasterCache.tiles(for: 0, visible: visible, scale: 2)
        }
        try check(nextGeometry.nativeRasterCache.rasterizationCount == 0,
                  "host incremental append uses the proven native raster mapping")
        _ = nextGeometry.geometry(at: 0)
        try check(nextGeometry.geometryBuildCount == 0, "host incremental append retains nearby exact geometry")
        #if DEBUG
        let spatialChanges: Int? = nextGeometry.updatedIndexEntryCount
        let spatialReused: Int? = nextGeometry.reusedEntryCount
        let spatialPrefixReused: Int? = nextGeometry.reusedPrefixEntryCount
        try check(spatialChanges == 1 && spatialReused == count, "one appended stroke changes one spatial entry")
        #else
        let spatialChanges: Int? = nil, spatialReused: Int? = nil, spatialPrefixReused: Int? = nil
        #endif

        // 2,400 pointer samples arrive in 300 coalesced callbacks. Preparation
        // and assertions stay outside timings; no synthetic points are dropped.
        let batches: [[CGPoint]] = (0..<300).map { batch in
            (0..<8).map { offset in
                let fraction = CGFloat((batch * 8 + offset) % 120) / 119
                let progress = batch.isMultiple(of: 2) ? fraction : 1 - fraction
                return CGPoint(x: 76 + CGFloat(visitedCount - 1) * 40 * progress, y: 64)
            }
        }
        let continuous = StrokeEraserTransaction(drawing: drawing, width: 8, geometryCache: cache)
        var longBatchMilliseconds: [Double] = []
        for batch in batches {
            let (_, duration) = timed { continuous.extend(along: batch) }
            longBatchMilliseconds.append(duration)
        }
        try check(continuous.erasedIndices == Set(0..<visitedCount), "long coalesced contact preserves the same complete local hits")
        try check(cache.geometryBuildCount == builtFirst, "long coalesced contact does not rebuild cached geometry")

        // Adversarial existing-grid case: every long stroke exceeds the grid's
        // footprint limit, but every one is far outside this small query. This
        // exposes global spanning-list work even when zero candidates are hit.
        let spanning = PKDrawing(strokes: (0..<count).map { sampleStroke(index: $0, long: true) })
        let spanningCache = InkGeometryCache(drawing: spanning)
        let emptyRect = CGRect(x: 0, y: 0, width: 12, height: 12)
        var spanningMilliseconds: [Double] = []
        var spanningCandidates = 0
        for _ in 0..<120 {
            let (candidates, duration) = timed { spanningCache.candidates(intersecting: emptyRect) }
            spanningMilliseconds.append(duration); spanningCandidates += candidates.count
        }
        try check(spanningCandidates == 0 && spanningCache.geometryBuildCount == 0,
                  "offscreen long strokes never produce false candidates or exact geometry")
        var entireMilliseconds: [Double] = []
        for _ in 0..<12 {
            let (candidates, duration) = timed {
                cache.candidates(intersecting: CGRect(x: -1_000, y: -1_000, width: 1_000_000, height: 1_000_000))
            }
            entireMilliseconds.append(duration)
            try check(candidates.count == count, "large viewport returns every visible stroke without dropping data")
        }
        try check(drawing.dataRepresentation() == originalBytes, "query/raster/zoom benchmarking never changes original ink")
        results.append(DrawingPerformanceCase(totalStrokes: count, indexBuildMilliseconds: indexMilliseconds,
            uncachedEraserBeginMilliseconds: uncachedBeginMilliseconds,
            cachedEraserBegin: DrawingPerformanceTiming(cachedBeginMilliseconds),
            localQuery: DrawingPerformanceTiming(queryMilliseconds),
            localCandidatesMinimum: candidateCounts.min() ?? 0,
            localCandidatesMaximum: candidateCounts.max() ?? 0,
            localCandidatesTotal: candidateCounts.reduce(0, +),
            firstPassEraserExtend: DrawingPerformanceTiming(firstPassMilliseconds),
            repeatedEraserExtend: DrawingPerformanceTiming(repeatMilliseconds),
            geometryBuildsFirstPass: builtFirst, geometryBuildsRepeatedPass: builtRepeated,
            erasedStrokes: transaction.erasedIndices.count,
            commitRemainingDrawingMilliseconds: commitMilliseconds,
            oneStrokeRasterMilliseconds: rasterMilliseconds,
            appendedDrawingRasterCacheReconciliationMilliseconds: reconcileMilliseconds,
            unchangedStrokeReusedWithoutRasterization: reused,
            appendedSpatialCacheReconciliationMilliseconds: spatialReconcileMilliseconds,
            appendedSpatialRasterReuseMilliseconds: spatialRasterReuseMilliseconds,
            appendedSpatialEntryChanges: spatialChanges, appendedSpatialEntriesReused: spatialReused,
            appendedSpatialPrefixEntriesReused: spatialPrefixReused,
            longDurationCoalescedEraserBatches: DrawingPerformanceTiming(longBatchMilliseconds),
            offscreenSpanningQuery: DrawingPerformanceTiming(spanningMilliseconds),
            offscreenSpanningReturnedCandidates: spanningCandidates,
            entireDocumentQuery: DrawingPerformanceTiming(entireMilliseconds)))
    }
    #if targetEnvironment(simulator)
    let environment = "iOS Simulator; synthetic production method calls; not physical Apple Pencil latency"
    #else
    let environment = "iOS device; synthetic production method calls; not physical Apple Pencil latency"
    #endif
    let report = DrawingPerformanceReport(
        measurementScope: "Monotonic elapsed CPU-operation wall time; excludes fixture generation, assertions, and serialization. No frame, allocation, GPU, or Pencil-to-display latency claim.",
        operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
        environment: environment, processorCount: ProcessInfo.processInfo.processorCount, empty: emptyResult, cases: results)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(report).write(to: PDFIntegrationChecks.directory.appendingPathComponent(reportName), options: .atomic)
    return checks
}
