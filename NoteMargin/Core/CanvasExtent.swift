import Foundation

struct CanvasViewport: Codable, Equatable {
    var center: CGPoint
    var zoom: Double
}

/// Finite scroll working range, independent of persisted document coordinates.
/// Empty travel only changes four numbers, never allocates a page-sized surface.
enum CanvasExtent {
    static func expanded(_ current: CGRect, around visible: CGRect) -> CGRect {
        guard visible.minX.isFinite, visible.minY.isFinite, visible.width.isFinite,
              visible.height.isFinite, visible.width > 0, visible.height > 0 else { return current }
        if current.insetBy(dx: visible.width/2, dy: visible.height/2).contains(visible) { return current }
        return current.union(visible.insetBy(dx: -visible.width*1.5, dy: -visible.height*1.5))
    }
    static func usedBounds(ink: CGRect, elements: [PageElement]) -> CGRect {
        var used = ink
        for e in elements { used = used.union(CGRect(x: e.x, y: e.y, width: e.width, height: e.height)) }
        return used.isNull || used.isEmpty ? CGRect(x: 0, y: 0, width: 768, height: 1024) : used.insetBy(dx: -32, dy: -32)
    }
    static func exportPages(_ used: CGRect, size: CGSize = CGSize(width: 768, height: 1024)) throws -> [CGRect] {
        guard used.width.isFinite, used.height.isFinite, used.width > 0, used.height > 0 else { throw CocoaError(.fileWriteUnknown) }
        let columns = ceil(used.width/size.width), rows = ceil(used.height/size.height)
        guard columns * rows <= 10_000 else { throw CocoaError(.fileWriteOutOfSpace) }
        return (0..<Int(rows)).flatMap { row in (0..<Int(columns)).map { col in
            CGRect(x: used.minX+Double(col)*size.width, y: used.minY+Double(row)*size.height, width: size.width, height: size.height)
        } }
    }
}
