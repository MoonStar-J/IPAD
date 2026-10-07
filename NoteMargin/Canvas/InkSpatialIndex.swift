import Foundation
import PencilKit
import UIKit

/// Public appearance fields, including masks and original control points. A
/// creation-date/seed pair narrows candidates, but is not a unique stroke ID:
/// legacy copies and PencilKit partial-erasure fragments can share it.
enum InkStrokeAppearance {
    static func matches(_ lhs: PKStroke, _ rhs: PKStroke) -> Bool {
        if (lhs as PKStrokeReference) === (rhs as PKStrokeReference) { return true }
        let leftPath = lhs.path, rightPath = rhs.path
        guard lhs.ink.inkType == rhs.ink.inkType, lhs.ink.color.isEqual(rhs.ink.color),
              lhs.transform == rhs.transform, lhs.randomSeed == rhs.randomSeed,
              lhs.requiredContentVersion == rhs.requiredContentVersion,
              leftPath.creationDate == rightPath.creationDate, leftPath.count == rightPath.count,
              lhs.renderBounds == rhs.renderBounds else { return false }
        if #available(iOS 27.0, *), lhs.renderGroupID != rhs.renderGroupID || lhs.renderState != rhs.renderState { return false }
        switch (lhs.mask, rhs.mask) {
        case (nil, nil): break
        case let (a?, b?):
            guard a.usesEvenOddFillRule == b.usesEvenOddFillRule, a.cgPath == b.cgPath else { return false }
        default: return false
        }
        // Preserve PencilKit's explicit visible parametric ranges too, even
        // when the path object is shared by partial-erasure fragments.
        guard lhs.maskedPathRanges == rhs.maskedPathRanges else { return false }
        // PKStrokePath is an immutable B-spline model. Shared path identity
        // proves all original point attributes without bridging each point.
        // SDK 27 also publicly guarantees a unique ID for each such path;
        // different points with the same ID are explicitly undefined by SDK.
        if (leftPath as PKStrokePathReference) === (rightPath as PKStrokePathReference) { return true }
        if #available(iOS 27.0, *), leftPath.id == rightPath.id { return true }
        for (a, b) in zip(leftPath, rightPath) {
            guard a.location == b.location, a.timeOffset == b.timeOffset, a.size == b.size,
                  a.opacity == b.opacity, a.force == b.force, a.azimuth == b.azimuth,
                  a.altitude == b.altitude, a.secondaryScale == b.secondaryScale else { return false }
            if #available(iOS 26.0, *), a.threshold != b.threshold { return false }
            if #available(iOS 27.0, *), a.lateralJitter != b.lateralJitter { return false }
        }
        return true
    }

    /// Used only for ambiguous legacy-ID buckets, never to decide equality.
    /// Exact comparison still follows a fingerprint match, so hash collisions
    /// cannot reuse a stale outline or a different native raster.
    static func fingerprint(_ stroke: PKStroke) -> Int {
        var value = Hasher()
        for point in stroke.path {
            value.combine(point.location.x); value.combine(point.location.y)
            value.combine(point.timeOffset)
            value.combine(point.size.width); value.combine(point.size.height)
            value.combine(point.opacity); value.combine(point.force)
            value.combine(point.azimuth); value.combine(point.altitude)
            value.combine(point.secondaryScale)
            if #available(iOS 26.0, *) { value.combine(point.threshold) }
            if #available(iOS 27.0, *) { value.combine(point.lateralJitter) }
        }
        for range in stroke.maskedPathRanges {
            value.combine(range.lowerBound); value.combine(range.upperBound)
        }
        if let mask = stroke.mask {
            value.combine(mask.usesEvenOddFillRule)
            // Mask path equality remains an exact check after this broad
            // fingerprint; do not rely on CF object hashes across wrappers.
        }
        if #available(iOS 27.0, *) {
            value.combine(stroke.renderGroupID)
            value.combine(stroke.renderState?.grainOffset?.x)
            value.combine(stroke.renderState?.grainOffset?.y)
        }
        return value.finalize()
    }
}

/// Immutable spatial revisions, with exact geometry shared only by strokes
/// whose public appearance is unchanged. The index is a persistent balanced
/// bounding-volume tree: a changed stroke replaces O(log n) nodes rather than
/// rebuilding a page-wide grid. Long offscreen strokes need no "spanning" scan.
/// All users are confined to the canvas/main thread; immutable revisions keep
/// an active eraser/selection's source independent from later committed edits.
final class InkGeometryCache {
    private struct AppearanceKey: Hashable {
        let id: InkStrokeID
        let count: Int
        let ink: String
        let a: CGFloat, b: CGFloat, c: CGFloat, d: CGFloat, tx: CGFloat, ty: CGFloat
        let x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat
        init(_ stroke: PKStroke, bounds: CGRect) {
            id = InkStrokeID(creationDate: stroke.path.creationDate, randomSeed: stroke.randomSeed)
            // UIColor can normalize its backing color representation during a
            // PencilKit storage roundtrip. Exact isEqual is checked later;
            // an Objective-C color hash must not exclude an equal appearance.
            count = stroke.path.count; ink = stroke.ink.inkType.rawValue
            let transform = stroke.transform
            a = transform.a; b = transform.b; c = transform.c; d = transform.d
            tx = transform.tx; ty = transform.ty
            x = bounds.origin.x; y = bounds.origin.y; width = bounds.width; height = bounds.height
        }
    }

    private final class Entry {
        let token: UInt64
        let stroke: PKStroke
        let bounds: CGRect
        // Keep the bridge alive for as long as its identifier is used. A bare
        // ObjectIdentifier does not retain an Objective-C bridge object.
        let reference: PKStrokeReference
        private var appearanceKey: AppearanceKey?
        var geometry: InkStrokeGeometry?
        var visible: Bool?
        var fingerprint: Int?
        init(token: UInt64, stroke: PKStroke) {
            self.token = token; self.stroke = stroke; bounds = stroke.renderBounds
            reference = stroke as PKStrokeReference
        }
        var appearance: AppearanceKey {
            if let appearanceKey { return appearanceKey }
            let created = AppearanceKey(stroke, bounds: bounds)
            appearanceKey = created
            return created
        }
        func appearanceFingerprint() -> Int {
            if let fingerprint { return fingerprint }
            let result = InkStrokeAppearance.fingerprint(stroke)
            fingerprint = result
            return result
        }
    }

    private struct Key: Comparable {
        let x: CGFloat, y: CGFloat
        let token: UInt64
        init(_ entry: Entry) { x = entry.bounds.midX; y = entry.bounds.midY; token = entry.token }
        static func < (lhs: Key, rhs: Key) -> Bool {
            if lhs.x != rhs.x { return lhs.x < rhs.x }
            if lhs.y != rhs.y { return lhs.y < rhs.y }
            return lhs.token < rhs.token
        }
    }

    private final class MatchingBucket {
        var indices: [Int] = []
    }

    private final class Node {
        let entry: Entry
        let key: Key
        let left: Node?, right: Node?
        let height: Int, count: Int
        let bounds: CGRect
        init(_ entry: Entry, left: Node? = nil, right: Node? = nil) {
            self.entry = entry; key = Key(entry); self.left = left; self.right = right
            height = 1 + max(left?.height ?? 0, right?.height ?? 0)
            count = 1 + (left?.count ?? 0) + (right?.count ?? 0)
            bounds = entry.bounds.union(left?.bounds ?? .null).union(right?.bounds ?? .null)
        }
        private var balance: Int { (left?.height ?? 0) - (right?.height ?? 0) }
        private func rotateLeft() -> Node {
            guard let pivot = right else { return self }
            return Node(pivot.entry, left: Node(entry, left: left, right: pivot.left), right: pivot.right)
        }
        private func rotateRight() -> Node {
            guard let pivot = left else { return self }
            return Node(pivot.entry, left: pivot.left, right: Node(entry, left: pivot.right, right: right))
        }
        private func balanced() -> Node {
            if balance > 1 {
                let prepared = (left?.balance ?? 0) < 0 ? Node(entry, left: left?.rotateLeft(), right: right) : self
                return prepared.rotateRight()
            }
            if balance < -1 {
                let prepared = (right?.balance ?? 0) > 0 ? Node(entry, left: left, right: right?.rotateRight()) : self
                return prepared.rotateLeft()
            }
            return self
        }
        static func built(from sorted: [Entry], range: Range<Int>) -> Node? {
            guard !range.isEmpty else { return nil }
            let middle = range.lowerBound + range.count / 2
            return Node(sorted[middle], left: built(from: sorted, range: range.lowerBound..<middle),
                        right: built(from: sorted, range: (middle + 1)..<range.upperBound))
        }
        static func inserting(_ entry: Entry, into node: Node?) -> Node {
            guard let node else { return Node(entry) }
            if Key(entry) < node.key {
                return Node(node.entry, left: inserting(entry, into: node.left), right: node.right).balanced()
            }
            return Node(node.entry, left: node.left, right: inserting(entry, into: node.right)).balanced()
        }
        static func removing(_ key: Key, from node: Node?) -> Node? {
            guard let node else { return nil }
            if key < node.key {
                return Node(node.entry, left: removing(key, from: node.left), right: node.right).balanced()
            }
            if node.key < key {
                return Node(node.entry, left: node.left, right: removing(key, from: node.right)).balanced()
            }
            guard let left = node.left else { return node.right }
            guard let right = node.right else { return node.left }
            var successor = right
            while let next = successor.left { successor = next }
            return Node(successor.entry, left: left, right: removing(successor.key, from: right)).balanced()
        }
        func collect(intersecting rect: CGRect, into tokens: inout [UInt64], visited: inout Int) {
            visited += 1
            guard bounds.intersects(rect) else { return }
            if entry.bounds.intersects(rect) { tokens.append(entry.token) }
            left?.collect(intersecting: rect, into: &tokens, visited: &visited)
            right?.collect(intersecting: rect, into: &tokens, visited: &visited)
        }
        #if DEBUG
        func validTree() -> Bool {
            abs(balance) <= 1 && (left == nil || left!.key < key) && (right == nil || key < right!.key) &&
            bounds == entry.bounds.union(left?.bounds ?? .null).union(right?.bounds ?? .null) &&
            (left?.validTree() ?? true) && (right?.validTree() ?? true)
        }
        #endif
    }

    let drawing: PKDrawing
    private let entries: [Entry]
    private let indicesByToken: [UInt64: Int]
    private let root: Node?
    private let nextToken: UInt64
    private(set) var geometryBuildCount = 0
    #if DEBUG
    private(set) var lastQueryVisitedNodes = 0
    private(set) var lastQueryCandidateCount = 0
    private(set) var updatedIndexEntryCount = 0
    private(set) var reusedEntryCount = 0
    private(set) var reusedPrefixEntryCount = 0
    var indexNodeCount: Int { root?.count ?? 0 }
    var indexHeight: Int { root?.height ?? 0 }
    var hasBalancedIndex: Bool { root?.validTree() ?? true }
    #endif
    @MainActor private var raster: NativeInkRasterCache?
    @MainActor private var inheritedRaster: NativeInkRasterCache?
    @MainActor private var retainedRasterIndices: [Int: Int] = [:]

    @MainActor var nativeRasterCache: NativeInkRasterCache {
        if let raster { return raster }
        let created = NativeInkRasterCache(drawing: drawing)
        if let previous = inheritedRaster {
            created.reuseUnchangedStrokes(from: previous, retainedIndices: retainedRasterIndices)
        }
        raster = created
        inheritedRaster = nil; retainedRasterIndices.removeAll()
        return created
    }

    init(drawing: PKDrawing) {
        self.drawing = drawing
        entries = drawing.strokes.enumerated().map { Entry(token: UInt64($0.offset), stroke: $0.element) }
        nextToken = UInt64(entries.count)
        indicesByToken = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($0.element.token, $0.offset) })
        let sorted = entries.filter { Self.valid($0.bounds) }.sorted { Key($0) < Key($1) }
        root = Node.built(from: sorted, range: sorted.indices)
    }

    private init(drawing: PKDrawing, entries: [Entry], root: Node?, nextToken: UInt64) {
        self.drawing = drawing; self.entries = entries; self.root = root; self.nextToken = nextToken
        indicesByToken = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($0.element.token, $0.offset) })
    }

    /// Called at a committed interaction boundary, not for every Pencil sample.
    /// One cheap identity/metadata pass reconciles positional PencilKit indices;
    /// unchanged entries retain exact geometry and untouched tree branches.
    @MainActor func updated(to drawing: PKDrawing) -> InkGeometryCache {
        if self.drawing == drawing { return self }
        let strokes = drawing.strokes
        // Native append and suffix erasure usually preserve an exact common
        // prefix. Verify it; never infer equality from count, date, or IDs alone.
        // This avoids allocating per-stroke dictionary buckets on that path.
        var prefix = 0
        while prefix < min(entries.count, strokes.count),
              InkStrokeAppearance.matches(entries[prefix].stroke, strokes[prefix]) { prefix += 1 }
        var byReference: [ObjectIdentifier: [Int]] = [:]
        var byAppearance: [AppearanceKey: [Int]] = [:]
        for index in prefix..<entries.count {
            byReference[ObjectIdentifier(entries[index].reference), default: []].append(index)
        }
        var hasAppearanceIndex = false
        var consumed = Array(repeating: false, count: entries.count)
        var fingerprints: [AppearanceKey: [Int: MatchingBucket]] = [:]
        var next = nextToken
        var revised: [Entry] = []
        revised.reserveCapacity(strokes.count)
        var retained: [Int: Int] = [:]
        retained.reserveCapacity(min(entries.count, strokes.count))
        for index in 0..<prefix {
            consumed[index] = true; retained[index] = index; revised.append(entries[index])
        }
        var newEntries: [Entry] = []
        for newIndex in prefix..<strokes.count {
            let stroke = strokes[newIndex]
            let reference = ObjectIdentifier(stroke as PKStrokeReference)
            var match: Int?
            while let old = byReference[reference]?.popLast() {
                if !consumed[old] { match = old; break }
            }
            if match == nil {
                if !hasAppearanceIndex {
                    // Normal append-only snapshots preserve existing public
                    // references. Avoid reading ink/path/color metadata for
                    // every retained stroke merely to match the new last one.
                    for old in entries.indices where !consumed[old] {
                        byAppearance[entries[old].appearance, default: []].append(old)
                    }
                    hasAppearanceIndex = true
                }
                let appearance = AppearanceKey(stroke, bounds: stroke.renderBounds)
                if let possible = byAppearance[appearance] {
                    if possible.count == 1 {
                        let old = possible[0]
                        if !consumed[old], InkStrokeAppearance.matches(entries[old].stroke, stroke) { match = old }
                    } else {
                        // Colliding legacy IDs remain one-to-one. Hashing each
                        // ambiguous path once avoids a quadratic point scan.
                        if fingerprints[appearance] == nil {
                            var grouped: [Int: MatchingBucket] = [:]
                            for old in possible where !consumed[old] {
                                let fingerprint = entries[old].appearanceFingerprint()
                                if grouped[fingerprint] == nil { grouped[fingerprint] = MatchingBucket() }
                                grouped[fingerprint]?.indices.append(old)
                            }
                            fingerprints[appearance] = grouped
                        }
                        let fingerprint = InkStrokeAppearance.fingerprint(stroke)
                        if let candidates = fingerprints[appearance]?[fingerprint] {
                            while let old = candidates.indices.last, consumed[old] { candidates.indices.removeLast() }
                            if let position = candidates.indices.lastIndex(where: { !consumed[$0] && InkStrokeAppearance.matches(entries[$0].stroke, stroke) }) {
                                match = candidates.indices[position]
                                candidates.indices.swapAt(position, candidates.indices.count - 1)
                                candidates.indices.removeLast()
                            }
                        }
                    }
                }
            }
            if let old = match {
                consumed[old] = true; retained[old] = newIndex; revised.append(entries[old])
            } else {
                let entry = Entry(token: next, stroke: stroke)
                next += 1; revised.append(entry); newEntries.append(entry)
            }
        }
        var revisedRoot = root
        var changes = 0
        for old in entries.indices where !consumed[old] && Self.valid(entries[old].bounds) {
            revisedRoot = Node.removing(Key(entries[old]), from: revisedRoot); changes += 1
        }
        for entry in newEntries where Self.valid(entry.bounds) {
            revisedRoot = Node.inserting(entry, into: revisedRoot); changes += 1
        }
        let result = InkGeometryCache(drawing: drawing, entries: revised, root: revisedRoot, nextToken: next)
        #if DEBUG
        result.updatedIndexEntryCount = changes; result.reusedEntryCount = retained.count; result.reusedPrefixEntryCount = prefix
        #endif
        // Do not force a raster cache to exist merely to update the index, and
        // never retain a chain of old document/cache revisions. If an inherited
        // raster is still lazy, compose its proven mapping into this revision.
        if let raster {
            result.inheritedRaster = raster; result.retainedRasterIndices = retained
        } else if let inheritedRaster {
            result.inheritedRaster = inheritedRaster
            for (source, current) in retainedRasterIndices {
                if let newIndex = retained[current] { result.retainedRasterIndices[source] = newIndex }
            }
        }
        return result
    }

    private static func valid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isEmpty && rect.minX.isFinite && rect.minY.isFinite && rect.maxX.isFinite && rect.maxY.isFinite &&
        abs(rect.minX) < 1e12 && abs(rect.minY) < 1e12 && abs(rect.maxX) < 1e12 && abs(rect.maxY) < 1e12
    }
    func geometry(at index: Int) -> InkStrokeGeometry {
        precondition(entries.indices.contains(index))
        let entry = entries[index]
        if let geometry = entry.geometry { return geometry }
        let created = InkStrokeGeometry(stroke: entry.stroke)
        entry.geometry = created; geometryBuildCount += 1
        return created
    }
    func candidates(intersecting rect: CGRect) -> [Int] {
        guard Self.valid(rect) else { return [] }
        var tokens: [UInt64] = [], visited = 0
        root?.collect(intersecting: rect, into: &tokens, visited: &visited)
        let result = tokens.compactMap { indicesByToken[$0] }.sorted()
        #if DEBUG
        lastQueryVisitedNodes = visited; lastQueryCandidateCount = result.count
        #endif
        return result
    }
    private func hasVisibleSamples(at index: Int) -> Bool {
        let entry = entries[index]
        if let visible = entry.visible { return visible }
        let stroke = entry.stroke
        let visible = stroke.ink.color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)).cgColor.alpha > 0 &&
            stroke.path.contains { point in
                point.location.x.isFinite && point.location.y.isFinite &&
                point.size.width.isFinite && point.size.height.isFinite &&
                point.opacity.isFinite && point.opacity > 0 && point.size.width > 0 && point.size.height > 0
            }
        entry.visible = visible
        return visible
    }
    func indices(intersecting rect: CGRect) -> Set<Int> {
        guard Self.valid(rect) else { return [] }
        var queryPath: CGPath?
        return Set(candidates(intersecting: rect).filter { index in
            guard hasVisibleSamples(at: index) else { return false }
            let entry = entries[index]
            if entry.stroke.mask == nil && rect.contains(entry.bounds) { return true }
            let shape = geometry(at: index)
            guard shape.opacity > 0, !shape.path.isEmpty else { return false }
            if queryPath == nil { queryPath = CGPath(rect: rect, transform: nil) }
            return shape.path.intersects(queryPath!)
        })
    }
    func indices(intersecting path: CGPath) -> Set<Int> {
        let queryBounds = path.boundingBoxOfPath
        return Set(candidates(intersecting: queryBounds).filter { index in
            guard hasVisibleSamples(at: index) else { return false }
            let entry = entries[index]
            if entry.stroke.mask == nil, queryBounds.contains(entry.bounds),
               path.contains(CGPoint(x: entry.bounds.midX, y: entry.bounds.midY)),
               CGPath(rect: entry.bounds, transform: nil).subtracting(path).isEmpty { return true }
            let shape = geometry(at: index)
            return shape.opacity > 0 && !shape.path.isEmpty && shape.path.intersects(path)
        })
    }
}

/// One contact holds one immutable source/index. Samples only query the swept
/// neighborhood and accumulate affected IDs; a new PKDrawing is made at commit.
@MainActor
final class StrokeEraserTransaction {
    let original: PKDrawing
    let width: CGFloat
    let geometryCache: InkGeometryCache
    private(set) var erasedIndices = Set<Int>()
    private var previousPoint: CGPoint?

    init(drawing: PKDrawing, width: CGFloat, geometryCache: InkGeometryCache? = nil) {
        original = drawing
        self.width = width.isFinite && width > 0 ? width : 12
        if let geometryCache, geometryCache.drawing == drawing { self.geometryCache = geometryCache }
        else { self.geometryCache = InkGeometryCache(drawing: drawing) }
    }
    var remainingDrawing: PKDrawing {
        PKDrawing(strokes: original.strokes.enumerated().compactMap { erasedIndices.contains($0.offset) ? nil : $0.element })
    }
    var erasedDrawing: PKDrawing {
        PKDrawing(strokes: original.strokes.enumerated().compactMap { erasedIndices.contains($0.offset) ? $0.element : nil })
    }
    func extend(to point: CGPoint) { extend(along: [point]) }
    func extend(along points: [CGPoint]) {
        let center = CGMutablePath()
        var first: CGPoint?, last: CGPoint?
        var count = 0
        for point in points where point.x.isFinite && point.y.isFinite {
            if first == nil { first = point; center.move(to: previousPoint ?? point) }
            center.addLine(to: point); last = point; count += 1
        }
        guard let first, let last else { return }
        if previousPoint == nil && count == 1 { center.addLine(to: CGPoint(x: first.x + 0.0001, y: first.y)) }
        previousPoint = last
        let sweep = center.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 2)
        for index in geometryCache.candidates(intersecting: sweep.boundingBoxOfPath) where !erasedIndices.contains(index) {
            let shape = geometryCache.geometry(at: index)
            if shape.opacity > 0 && !shape.path.isEmpty && shape.path.intersects(sweep) { erasedIndices.insert(index) }
        }
    }
}
