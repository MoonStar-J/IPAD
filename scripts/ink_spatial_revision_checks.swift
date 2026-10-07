import Foundation
import PencilKit
import QuartzCore
import UIKit

/// Added separately from the before/after benchmark so the baseline can still
/// compile against the former cache. Uses real production revisions and tiles.
@MainActor func checkInkSpatialRevisions() throws -> Int {
    var checks = 0
    func check(_ condition: Bool, _ message: String) throws {
        try PDFIntegrationChecks.check(condition, "ink spatial revisions: " + message)
        checks += 1
    }
    func stroke(_ index: Int) -> PKStroke {
        let x = CGFloat(index % 16) * 40 + 64, y = CGFloat(index / 16) * 48 + 64
        let points = (0..<5).map { offset in
            PKStrokePoint(location: CGPoint(x: x + CGFloat(offset) * 6, y: y + (offset.isMultiple(of: 2) ? 0 : 3)),
                          timeOffset: Double(offset) * 0.015, size: CGSize(width: 3, height: 3),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.pen, color: .black),
                        path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 5_000 + Double(index))),
                        randomSeed: UInt32(index + 1))
    }
    func expected(_ drawing: PKDrawing, _ rect: CGRect) -> [Int] {
        drawing.strokes.indices.filter { drawing.strokes[$0].renderBounds.intersects(rect) }
    }
    let original = PKDrawing(strokes: (0..<128).map(stroke))
    let originalBytes = original.dataRepresentation()
    let cache = InkGeometryCache(drawing: original)
    _ = cache.geometry(at: 0); _ = cache.geometry(at: 100)
    let originalQuery = original.strokes[0].renderBounds.insetBy(dx: -2, dy: -2)
    let originalCandidates = cache.candidates(intersecting: originalQuery)
    let initialRaster = cache.nativeRasterCache
    let initialTiles = initialRaster.tiles(for: 0, visible: originalQuery, scale: 2)
    try check(!initialTiles.isEmpty, "fixture has editable native ink tiles")

    let appended = PKDrawing(strokes: original.strokes + [stroke(128)])
    let appendedCache = cache.updated(to: appended)
    _ = appendedCache.geometry(at: 0); _ = appendedCache.geometry(at: 100)
    try check(appendedCache.geometryBuildCount == 0, "append retains exact geometry of unchanged strokes")
    try check(appendedCache.candidates(intersecting: originalQuery) == originalCandidates, "append preserves old spatial answers")
    #if DEBUG
    try check(appendedCache.updatedIndexEntryCount == 1 && appendedCache.reusedEntryCount == 128,
              "append changes one tree entry rather than rebuilding 128 entries")
    try check(appendedCache.reusedPrefixEntryCount == 128, "exact append prefix avoids general identity buckets")
    try check(appendedCache.hasBalancedIndex && appendedCache.indexNodeCount == 129, "append maintains AVL invariants")
    #endif

    // Two lazy revisions compose index mappings without forcing a raster cache
    // or retaining a chain of old document revisions.
    let reorderedStrokes = Array(appended.strokes.reversed())
    let reordered = PKDrawing(strokes: reorderedStrokes)
    let reorderedCache = appendedCache.updated(to: reordered)
    let indexOfOriginal = reorderedStrokes.count - 1
    _ = reorderedCache.geometry(at: indexOfOriginal)
    try check(reorderedCache.geometryBuildCount == 0, "reordering remaps cached geometry to its new index")
    let reorderedRaster = reorderedCache.nativeRasterCache
    let reusedTiles = reorderedRaster.tiles(for: indexOfOriginal, visible: originalQuery, scale: 2)
    try check(reorderedRaster.rasterizationCount == 0 && reusedTiles.count == initialTiles.count,
              "lazy revision composition reuses native tiles at the remapped index")
    #if DEBUG
    try check(reorderedCache.updatedIndexEntryCount == 0, "reordering does not mutate spatial entries")
    #endif

    var movedStrokes = reordered.strokes
    movedStrokes[indexOfOriginal].transform = CGAffineTransform(translationX: -700, y: -300)
    let moved = PKDrawing(strokes: movedStrokes)
    let movedCache = reorderedCache.updated(to: moved)
    let movedQuery = moved.strokes[indexOfOriginal].renderBounds.insetBy(dx: -2, dy: -2)
    try check(movedCache.candidates(intersecting: movedQuery) == [indexOfOriginal], "move inserts the updated bounds")
    try check(!movedCache.candidates(intersecting: originalQuery).contains(indexOfOriginal), "move removes stale bounds")
    _ = movedCache.geometry(at: indexOfOriginal)
    try check(movedCache.geometryBuildCount == 1, "move invalidates only the changed exact geometry")
    #if DEBUG
    try check(movedCache.updatedIndexEntryCount == 2 && movedCache.reusedEntryCount == 128,
              "move removes and inserts one stroke")
    #endif
    let erased = StrokeEraserTransaction(drawing: moved, width: 8, geometryCache: movedCache)
    let movedMidpoint = CGPoint(x: 76, y: 64).applying(moved.strokes[indexOfOriginal].transform)
    erased.extend(to: movedMidpoint)
    try check(erased.erasedIndices == [indexOfOriginal], "eraser hits moved ink using updated bounds and geometry")
    let removed = erased.remainingDrawing
    let removedCache = movedCache.updated(to: removed)
    try check(removedCache.candidates(intersecting: movedQuery).isEmpty, "commit deletes the one affected index entry")
    #if DEBUG
    try check(removedCache.updatedIndexEntryCount == 1 && removedCache.hasBalancedIndex,
              "erase commit preserves balanced untouched branches")
    #endif
    try check(cache.candidates(intersecting: originalQuery) == originalCandidates &&
              reorderedCache.candidates(intersecting: originalQuery) == [indexOfOriginal],
              "older active interaction snapshots remain unchanged after move and erase")
    try check(original.dataRepresentation() == originalBytes, "index and preview never modify canonical drawing bytes")

    // Old releases copied creationDate/randomSeed. One-to-one matching must
    // retain duplicate membership, transforms, and independently changed masks.
    let first = stroke(0)
    var translated = first; translated.transform = CGAffineTransform(translationX: 300, y: 0)
    let duplicateDrawing = PKDrawing(strokes: [first, translated, first])
    let duplicateCache = InkGeometryCache(drawing: duplicateDrawing)
    for index in 0..<3 { _ = duplicateCache.geometry(at: index) }
    try check(duplicateCache.candidates(intersecting: originalQuery) == [0, 2], "equal IDs do not merge separate canonical entries")
    var recolored = first; recolored.ink = PKInk(.pen, color: .red)
    try check(!InkStrokeAppearance.matches(first, recolored) && !InkStrokeAppearance.matches(first, translated),
              "shared path identity does not bypass changed ink or transform")
    var reconstructed = first
    reconstructed.path = PKStrokePath(controlPoints: Array(first.path), creationDate: first.path.creationDate)
    try check(InkStrokeAppearance.matches(first, reconstructed), "new path identity with identical original points passes exact fallback")
    let duplicateReorder = PKDrawing(strokes: [translated, first])
    let duplicateRevision = duplicateCache.updated(to: duplicateReorder)
    for index in 0..<2 { _ = duplicateRevision.geometry(at: index) }
    try check(duplicateRevision.geometryBuildCount == 0 && duplicateRevision.candidates(intersecting: originalQuery) == [1],
              "duplicate deletion/reordering consumes each prior entry at most once")
    #if DEBUG
    try check(duplicateRevision.reusedEntryCount == 2 && duplicateRevision.updatedIndexEntryCount == 1,
              "legacy collision deletion is a one-entry spatial change")
    #endif

    let rewrappedStrokes = duplicateDrawing.strokes.map { source -> PKStroke in
        if #available(iOS 27.0, *) {
            return PKStroke(ink: source.ink, path: source.path, transform: source.transform, mask: source.mask,
                            randomSeed: source.randomSeed, id: source.id,
                            renderGroupID: source.renderGroupID, renderState: source.renderState)
        }
        return PKStroke(ink: source.ink, path: source.path, transform: source.transform, mask: source.mask, randomSeed: source.randomSeed)
    }
    for (old, new) in zip(duplicateDrawing.strokes, rewrappedStrokes) {
        try check(InkStrokeAppearance.matches(old, new), "rewrapped fixture has exactly unchanged public appearance")
    }
    let rewrappedCache = duplicateCache.updated(to: PKDrawing(strokes: rewrappedStrokes))
    for index in rewrappedStrokes.indices { _ = rewrappedCache.geometry(at: index) }
    try check(rewrappedCache.geometryBuildCount == 0, "exactly rewrapped duplicate appearances reuse every outline")
    #if DEBUG
    try check(rewrappedCache.reusedEntryCount == 3 && rewrappedCache.updatedIndexEntryCount == 0,
              "exact appearance fallback preserves separate colliding entries")
    #endif

    // A storage roundtrip may quantize PencilKit's public point attributes or
    // normalize its ink. Only actually equal appearance may reuse an outline;
    // a stable ID alone must never override those differences.
    let decoded = try PKDrawing(data: duplicateDrawing.dataRepresentation())
    let decodedCache = duplicateCache.updated(to: decoded)
    let reusedSameSnapshot = decodedCache === duplicateCache
    let decodedBuildsBeforeAccess = decodedCache.geometryBuildCount
    let decodedFresh = InkGeometryCache(drawing: decoded)
    let beforeRoundtrip = duplicateDrawing.strokes, afterRoundtrip = decoded.strokes
    try check(beforeRoundtrip.count == afterRoundtrip.count, "storage roundtrip preserves stroke count")
    var exactMatches = Set<Int>()
    for stroke in afterRoundtrip {
        if let old = beforeRoundtrip.indices.first(where: { !exactMatches.contains($0) && InkStrokeAppearance.matches(beforeRoundtrip[$0], stroke) }) {
            exactMatches.insert(old)
        }
    }
    var roundtripChanges: [String: Int] = [:]
    func changed(_ field: String, _ differs: Bool) { if differs { roundtripChanges[field, default: 0] += 1 } }
    for (before, after) in zip(beforeRoundtrip, afterRoundtrip) {
        changed("inkType", before.ink.inkType != after.ink.inkType)
        changed("inkColor", !before.ink.color.isEqual(after.ink.color))
        changed("inkColorHash", before.ink.color.hash != after.ink.color.hash)
        changed("inkTypeRawValue", before.ink.inkType.rawValue != after.ink.inkType.rawValue)
        changed("creationDateHash", before.path.creationDate.hashValue != after.path.creationDate.hashValue)
        changed("pointFingerprint", InkStrokeAppearance.fingerprint(before) != InkStrokeAppearance.fingerprint(after))
        changed("transform", before.transform != after.transform)
        changed("randomSeed", before.randomSeed != after.randomSeed)
        changed("contentVersion", before.requiredContentVersion != after.requiredContentVersion)
        changed("creationDate", before.path.creationDate != after.path.creationDate)
        changed("pointCount", before.path.count != after.path.count)
        changed("renderBounds", before.renderBounds != after.renderBounds)
        changed("maskedRanges", before.maskedPathRanges != after.maskedPathRanges)
        if #available(iOS 27.0, *) {
            changed("renderGroup", before.renderGroupID != after.renderGroupID)
            changed("renderState", before.renderState != after.renderState)
        }
        for (a, b) in zip(before.path, after.path) {
            changed("pointLocation", a.location != b.location)
            changed("pointTimeOffset", a.timeOffset != b.timeOffset)
            changed("pointSize", a.size != b.size)
            changed("pointOpacity", a.opacity != b.opacity)
            changed("pointForce", a.force != b.force)
            changed("pointAzimuth", a.azimuth != b.azimuth)
            changed("pointAltitude", a.altitude != b.altitude)
            changed("pointSecondaryScale", a.secondaryScale != b.secondaryScale)
            if #available(iOS 26.0, *) { changed("pointThreshold", a.threshold != b.threshold) }
            if #available(iOS 27.0, *) { changed("pointLateralJitter", a.lateralJitter != b.lateralJitter) }
        }
    }
    // Synthetic data only: field names and counts, no points, image, or content.
    var diagnostic: [String: Any] = ["changedFieldCounts": roundtripChanges, "exactAppearanceMatches": exactMatches.count,
                                   "reusedSameSnapshot": reusedSameSnapshot, "geometryBuildsBeforeAccess": decodedBuildsBeforeAccess]
    #if DEBUG
    diagnostic["reusedEntries"] = decodedCache.reusedEntryCount
    diagnostic["updatedIndexEntries"] = decodedCache.updatedIndexEntryCount
    #endif
    let diagnosticData = try JSONSerialization.data(withJSONObject: diagnostic, options: [.prettyPrinted, .sortedKeys])
    try diagnosticData.write(to: PDFIntegrationChecks.directory.appendingPathComponent("ink-spatial-roundtrip-diagnostics.json"), options: .atomic)
    for index in afterRoundtrip.indices {
        let retained = decodedCache.geometry(at: index), fresh = decodedFresh.geometry(at: index)
        try check(retained.path == fresh.path && retained.bounds == fresh.bounds && retained.opacity == fresh.opacity,
                  "decoded cache geometry equals freshly built decoded geometry")
    }
    if reusedSameSnapshot {
        try check(exactMatches.count == afterRoundtrip.count, "same drawing snapshot fast path preserves every exact appearance")
    }
    try check(decodedCache.geometryBuildCount - decodedBuildsBeforeAccess == afterRoundtrip.count - exactMatches.count,
              "serialized strokes reuse only exact appearance and rebuild every changed outline")
    #if DEBUG
    if !reusedSameSnapshot {
        try check(decodedCache.reusedEntryCount == exactMatches.count &&
                  decodedCache.updatedIndexEntryCount == 2 * (afterRoundtrip.count - exactMatches.count),
                  "decoded duplicate reconciliation is one-to-one and invalidates actual appearance changes")
    }
    #endif

    if #available(iOS 27.0, *) {
        let jitteredPoints = first.path.map { point in
            PKStrokePoint(location: point.location, timeOffset: point.timeOffset, size: point.size,
                          opacity: point.opacity, force: point.force, azimuth: point.azimuth, altitude: point.altitude,
                          secondaryScale: point.secondaryScale, threshold: point.threshold, lateralJitter: point.lateralJitter + 0.25)
        }
        var jittered = first
        jittered.path = PKStrokePath(controlPoints: jitteredPoints, creationDate: first.path.creationDate)
        try check(!InkStrokeAppearance.matches(first, jittered), "native lateral jitter is part of appearance equality")
        let jitteredCache = duplicateCache.updated(to: PKDrawing(strokes: [jittered, translated, first]))
        _ = jitteredCache.geometry(at: 0)
        try check(jitteredCache.geometryBuildCount == 1, "changed native jitter cannot reuse the old stroke entry")
        #if DEBUG
        try check(jitteredCache.reusedEntryCount == 2, "jitter edit retains unrelated canonical entries")
        #endif
    }

    var masked = first
    masked.mask = UIBezierPath(rect: CGRect(x: 62, y: 58, width: 14, height: 16))
    let maskedDrawing = PKDrawing(strokes: [masked, translated, first])
    let maskedCache = duplicateCache.updated(to: maskedDrawing)
    let freshMasked = InkGeometryCache(drawing: maskedDrawing)
    let leftHalf = CGRect(x: 61, y: 58, width: 14, height: 16)
    let rightHalf = CGRect(x: 80, y: 58, width: 12, height: 16)
    try check(maskedCache.indices(intersecting: leftHalf) == freshMasked.indices(intersecting: leftHalf),
              "mask revision preserves exact visible selection on the retained side")
    try check(maskedCache.indices(intersecting: rightHalf) == [2], "masked-out ink is not selected even with a colliding ID")
    #if DEBUG
    try check(maskedCache.reusedEntryCount == 2, "partial erasure invalidates only the masked stroke")
    #endif

    let broadPoints = [CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 100)].enumerated().map {
        PKStrokePoint(location: $0.element, timeOffset: Double($0.offset), size: CGSize(width: 80, height: 60),
                      opacity: 0.7, force: 0.8, azimuth: 0, altitude: .pi / 2)
    }
    let broadPath = PKStrokePath(controlPoints: broadPoints, creationDate: Date(timeIntervalSince1970: 8_000))
    var broadStroke = PKStroke(ink: PKInk(.marker, color: .orange), path: broadPath,
                               mask: UIBezierPath(rect: CGRect(x: 60, y: 50, width: 90, height: 100)), randomSeed: 91)
    let broadDrawing = PKDrawing(strokes: [broadStroke])
    let broadCache = InkGeometryCache(drawing: broadDrawing)
    let thickEdge = CGRect(x: 96, y: 120, width: 8, height: 4)
    let clippedEnd = CGRect(x: 188, y: 98, width: 8, height: 4)
    try check(broadCache.indices(intersecting: thickEdge) == [0], "thick nib edge survives conservative broad-phase culling")
    try check(broadCache.indices(intersecting: clippedEnd).isEmpty, "thick erased mask region remains unselectable")
    broadStroke.transform = CGAffineTransform(a: 0.8, b: 0.2, c: -0.15, d: 1.2, tx: 300, ty: 500)
    let broadMoved = PKDrawing(strokes: [broadStroke])
    let broadRevision = broadCache.updated(to: broadMoved)
    let edgePoint = CGPoint(x: 100, y: 122).applying(broadStroke.transform)
    let edgeEraser = StrokeEraserTransaction(drawing: broadMoved, width: 4, geometryCache: broadRevision)
    edgeEraser.extend(to: edgePoint)
    try check(edgeEraser.erasedIndices == [0], "transformed thick masked nib is erasable at its visible edge")
    try check(broadCache.indices(intersecting: thickEdge) == [0], "thick mask transform leaves the earlier snapshot untouched")

    // Mixed insert/delete/transform batches exercise rotations and index remaps.
    // Compare the broad phase against exhaustive renderBounds on every query.
    var revision = removedCache
    var revisionStrokes = removed.strokes
    for round in 0..<12 {
        if !revisionStrokes.isEmpty { revisionStrokes.remove(at: (round * 7) % revisionStrokes.count) }
        var added = stroke(200 + round)
        added.transform = CGAffineTransform(translationX: CGFloat(round * 33 - 300), y: CGFloat(round * 19 - 200))
        revisionStrokes.insert(added, at: min(round, revisionStrokes.count))
        if round.isMultiple(of: 3) { revisionStrokes.reverse() }
        let drawing = PKDrawing(strokes: revisionStrokes)
        revision = revision.updated(to: drawing)
        for sample in 0..<12 {
            let rect = CGRect(x: sample * 58 - 100, y: (round * 71 + sample * 37) % 550 - 70, width: 95, height: 120)
            try check(revision.candidates(intersecting: rect) == expected(drawing, rect), "incremental tree equals exhaustive bounds after mixed commits")
        }
        #if DEBUG
        let maximumHeight = 2 * Int(ceil(log2(Double(revisionStrokes.count + 1))))
        try check(revision.hasBalancedIndex && revision.indexHeight <= maximumHeight && revision.indexNodeCount == revisionStrokes.count,
                  "mixed commits keep logarithmic balanced height")
        #endif
    }
    let empty = revision.updated(to: PKDrawing())
    try check(empty.candidates(intersecting: CGRect(x: -1_000, y: -1_000, width: 10_000, height: 10_000)).isEmpty,
              "deleting all ink leaves a valid empty index")
    #if DEBUG
    try check(empty.indexNodeCount == 0 && empty.hasBalancedIndex, "empty tree validates")
    #endif

    // All huge bounds are remote: the tree rejects the root, independently of
    // stroke count. This case formerly scanned every spanning stroke per sample.
    var remoteStrokes: [PKStroke] = []
    for index in 0..<1_000 {
        let points = [CGPoint(x: CGFloat(200_000 + index * 100), y: 200_000), CGPoint(x: CGFloat(270_000 + index * 100), y: 270_000)].enumerated().map {
            PKStrokePoint(location: $0.element, timeOffset: Double($0.offset), size: CGSize(width: 3, height: 3),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        remoteStrokes.append(PKStroke(ink: PKInk(.pen, color: .black),
                                     path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: Double(index))),
                                     randomSeed: UInt32(index)))
    }
    let remote = InkGeometryCache(drawing: PKDrawing(strokes: remoteStrokes))
    try check(remote.candidates(intersecting: CGRect(x: 0, y: 0, width: 20, height: 20)).isEmpty,
              "offscreen long bounds do not become pointer candidates")
    #if DEBUG
    try check(remote.lastQueryVisitedNodes == 1 && remote.lastQueryCandidateCount == 0,
              "offscreen long strokes are rejected in one node visit")
    #endif
    try check(remote.geometryBuildCount == 0, "offscreen long strokes do not create exact paths")
    return checks
}
