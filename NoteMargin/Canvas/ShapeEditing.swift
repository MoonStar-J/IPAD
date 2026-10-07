import Foundation
import CoreGraphics

// The endpoint, drag-offset and corner-resize math below is adapted from
// Excalidraw, commit ed10ac7dca7e40f3f4a31269b4bfba980d0db41e (MIT).
// Copyright (c) 2020 Excalidraw. Full notice: ThirdParty/Excalidraw-LICENSE.txt.
// See docs/fixtures/shape-editing-validation.json for the exact source branches.
// UIKit/PencilKit presentation and input ownership are NoteMargin-specific.

struct ShapeEditFrame: Equatable {
    var center: CGPoint
    var width: CGFloat
    var height: CGFloat
    var angle: CGFloat

    init(center: CGPoint, width: CGFloat, height: CGFloat, angle: CGFloat) {
        self.center = center; self.width = width; self.height = height; self.angle = angle
    }
    init(result: ShapeRecognitionResult) {
        let points = result.fittedPoints
        let unique = Array(points.dropLast())
        if result.kind == .rectangle || result.kind == .triangle {
            let edges = zip(points, points.dropFirst()).map { CGPoint(x: $1.x - $0.x, y: $1.y - $0.y) }
            let edge = edges.max { hypot($0.x, $0.y) < hypot($1.x, $1.y) } ?? CGPoint(x: 1, y: 0)
            angle = atan2(edge.y, edge.x)
        } else if result.kind == .ellipse {
            let mean = unique.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x / CGFloat(unique.count), y: $0.y + $1.y / CGFloat(unique.count)) }
            var xx: CGFloat = 0, xy: CGFloat = 0, yy: CGFloat = 0
            for p in unique { let x = p.x - mean.x, y = p.y - mean.y; xx += x*x; xy += x*y; yy += y*y }
            angle = atan2(2*xy, xx-yy) / 2
        } else { angle = 0 }
        let rotation = angle
        let rotated = points.map { ShapeEditMath.rotate($0, angle: -rotation) }
        let minX = rotated.map(\.x).min() ?? 0, maxX = rotated.map(\.x).max() ?? 0
        let minY = rotated.map(\.y).min() ?? 0, maxY = rotated.map(\.y).max() ?? 0
        width = maxX-minX; height = maxY-minY
        center = ShapeEditMath.rotate(CGPoint(x: (minX+maxX)/2, y: (minY+maxY)/2), angle: angle)
    }
    var corners: [CGPoint] {
        [CGPoint(x: -width/2, y: -height/2), CGPoint(x: width/2, y: -height/2),
         CGPoint(x: width/2, y: height/2), CGPoint(x: -width/2, y: height/2)].map {
            let p = ShapeEditMath.rotate($0, angle: angle)
            return CGPoint(x: center.x+p.x, y: center.y+p.y)
        }
    }
    func applying(_ transform: CGAffineTransform) -> ShapeEditFrame {
        let scale = hypot(transform.a, transform.b)
        return ShapeEditFrame(center: center.applying(transform), width: width*scale,
                              height: height*scale, angle: angle+atan2(transform.b, transform.a))
    }
}

enum ShapeEditMath {
    static func rotate(_ p: CGPoint, angle: CGFloat) -> CGPoint {
        CGPoint(x: p.x*cos(angle)-p.y*sin(angle), y: p.x*sin(angle)+p.y*cos(angle))
    }
    // handlePointDragging -> createPointAt -> movePoints, one unbound point,
    // no grid/angle snapping. The new-stroke path has a zero pointer offset.
    static func lineEndpoint(pointer: CGPoint, pointerOffset: CGPoint = .zero) -> CGPoint? {
        let p = CGPoint(x: pointer.x-pointerOffset.x, y: pointer.y-pointerOffset.y)
        return p.x.isFinite && p.y.isFinite ? p : nil
    }
    // dragSelectedElements / updateElementCoords: always relative to pointer-down.
    static func translation(start: CGPoint, current: CGPoint) -> CGAffineTransform {
        guard current.x.isFinite, current.y.isFinite else { return .identity }
        return CGAffineTransform(translationX: current.x-start.x, y: current.y-start.y)
    }
}

struct ShapeResizeDrag {
    let frame: ShapeEditFrame
    let corner: Int
    let pointerOffset: CGPoint
    let anchor: CGPoint
    let minimumScale: CGFloat

    init(frame: ShapeEditFrame, corner: Int, pointer: CGPoint, minimumSize: CGFloat = 2) {
        self.frame = frame; self.corner = corner
        let handle = frame.corners[corner]
        pointerOffset = CGPoint(x: pointer.x-handle.x, y: pointer.y-handle.y)
        anchor = frame.corners[(corner+2)%4]
        minimumScale = min(1, max(0.001, minimumSize / max(0.001, min(frame.width, frame.height))))
    }
    func transform(to pointer: CGPoint) -> CGAffineTransform {
        guard pointer.x.isFinite, pointer.y.isFinite, frame.width > 0, frame.height > 0 else { return .identity }
        // getResizeOffsetXY, then inverse object rotation as in
        // getNextSingleWidthAndHeightFromPointer. Visual handle padding is absent.
        let p = CGPoint(x: pointer.x-pointerOffset.x-anchor.x, y: pointer.y-pointerOffset.y-anchor.y)
        let local = ShapeEditMath.rotate(p, angle: -frame.angle)
        let sx = local.x * ([1,2].contains(corner) ? 1 : -1) / frame.width
        let sy = local.y * ([2,3].contains(corner) ? 1 : -1) / frame.height
        // Excalidraw corner/aspect-ratio branch uses max(widthRatio,heightRatio).
        // Intentional difference: no reflection. Crossing either anchored edge
        // clamps the ONE common scale, instead of independently changing axes.
        let scale = sx <= 0 || sy <= 0 ? minimumScale : max(minimumScale, min(1_000, max(sx,sy)))
        // Equivalent to resizeSingleElement/getResizedOrigin with the opposite
        // corner fixed; a similarity transform preserves every triangle angle.
        return CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                 tx: anchor.x*(1-scale), ty: anchor.y*(1-scale))
    }
}
