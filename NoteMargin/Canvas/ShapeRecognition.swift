import Foundation

enum ShapeKind: String, Sendable { case line, circle, ellipse, triangle, rectangle }

/// Immutable document-space output. These samples are fitted geometry, never
/// predicted input; the caller owns preview, commit, and undo of the source ink.
struct ShapeRecognitionResult: Sendable {
    let kind: ShapeKind
    let confidence: Double
    let normalizedError: Double
    let fittedPoints: [CGPoint]
}

protocol ShapeRecognizing: Sendable {
    func recognize(documentPoints: [CGPoint]) -> ShapeRecognitionResult?
}

/// Recognition runs only on a completed/held stroke snapshot, outside the input
/// and rendering path. Two linear input passes create at most 128 arc-length
/// samples. All fitting, hull, and coverage work is bounded by that sample count.
/// Coordinates are centered and normalized before fitting, including deep PDFs.
struct ShapeRecognizer: ShapeRecognizing {
    struct Configuration: Sendable {
        var minimumConfidence: Double = 0.88
        var maximumSampleCount: Int = 128
        var maximumPreferredCircleAxisRatio: Double = 1.24
        var circleFitErrorAllowance: Double = 0.022
    }
    var configuration = Configuration()

    func recognize(documentPoints: [CGPoint]) -> ShapeRecognitionResult? {
        guard let input = Prepared(documentPoints, limit: min(256, max(32, configuration.maximumSampleCount))) else { return nil }
        if let line = fitLine(input) { return result(line, input) }
        let contour = closedContour(input)
        guard contour.points.count >= 12, contour.closure <= 0.12,
              contour.length > 1.8 else { return nil }
        var candidates = [Candidate]()
        if let triangle = fitPolygon(contour, sides: 3) { candidates.append(triangle) }
        if let rectangle = fitPolygon(contour, sides: 4) { candidates.append(rectangle) }
        let ellipse = fitEllipse(contour)
        let circle = fitCircle(contour)
        // Prefer the simpler circle only when it explains the contour nearly as
        // well. The existing closure, coverage, winding and confidence gates stay.
        if let circle, circle.confidence >= configuration.minimumConfidence,
           ellipse == nil || (ellipse!.ratio <= configuration.maximumPreferredCircleAxisRatio &&
               circle.error - ellipse!.candidate.error <= configuration.circleFitErrorAllowance) {
            candidates.append(circle)
        } else if let ellipse { candidates.append(ellipse.candidate) }
        let selected = candidates.filter { $0.confidence >= configuration.minimumConfidence }.max { $0.confidence < $1.confidence }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--shape-diagnostics") {
            let descriptions = candidates.map { "\($0.kind.rawValue):error=\($0.error),confidence=\($0.confidence)" }
            print("Shape candidates=\(descriptions) selected=\(selected?.kind.rawValue ?? "none") rejected=\(selected == nil ? "closure/edge/coverage/confidence gate" : "none")")
        }
        #endif
        return selected.flatMap { result($0, contour) }
    }

    private func result(_ candidate: Candidate, _ input: Prepared) -> ShapeRecognitionResult? {
        guard candidate.confidence >= configuration.minimumConfidence else { return nil }
        return ShapeRecognitionResult(kind: candidate.kind, confidence: candidate.confidence,
                                      normalizedError: candidate.error,
                                      fittedPoints: candidate.points.map { CGPoint(x: input.origin.x + $0.x * input.scale,
                                                                                  y: input.origin.y + $0.y * input.scale) })
    }

    private struct Candidate {
        var kind: ShapeKind
        var error: Double
        var confidence: Double
        var points: [CGPoint]
    }
    private struct Prepared {
        let origin: CGPoint
        let scale: Double
        let points: [CGPoint]
        let length: Double
        var closure: Double { distance(points[0], points[points.count - 1]) }
        init?(_ source: [CGPoint], limit: Int) {
            guard source.count >= 2 else { return nil }
            var minX = Double.infinity, maxX = -Double.infinity
            var minY = Double.infinity, maxY = -Double.infinity, length = 0.0
            var previous = source[0]
            for point in source {
                guard point.x.isFinite, point.y.isFinite else { return nil }
                minX = min(minX, point.x); maxX = max(maxX, point.x)
                minY = min(minY, point.y); maxY = max(maxY, point.y)
                length += distance(point, previous); previous = point
            }
            let scale = hypot(maxX - minX, maxY - minY)
            guard scale.isFinite, length.isFinite, scale > 1e-12, length > 1e-12 else { return nil }
            origin = CGPoint(x: minX + (maxX - minX) / 2, y: minY + (maxY - minY) / 2)
            self.scale = scale; self.length = length / scale
            // Uniform arc-length samples prevent dwell/coalescing density from
            // biasing PCA and fits. Discard no valid input when measuring length.
            let count = min(limit, max(2, source.count)), step = length / Double(count - 1)
            var sampled = [source[0]], accumulated = 0.0, next = step
            sampled.reserveCapacity(count)
            previous = source[0]
            for point in source.dropFirst() {
                let segment = distance(point, previous)
                if segment > 0 {
                    while next <= accumulated + segment && sampled.count < count - 1 {
                        let t = (next - accumulated) / segment
                        sampled.append(CGPoint(x: previous.x + (point.x - previous.x) * t,
                                               y: previous.y + (point.y - previous.y) * t))
                        next += step
                    }
                }
                accumulated += segment; previous = point
            }
            sampled.append(source[source.count - 1])
            let origin = self.origin
            points = sampled.map { CGPoint(x: ($0.x - origin.x) / scale, y: ($0.y - origin.y) / scale) }
        }
    }

    private func fitLine(_ input: Prepared) -> Candidate? {
        let points = input.points
        let center = mean(points)
        let angle = principalAngle(points, center: center), c = cos(angle), s = sin(angle)
        var squared = 0.0, maximum = 0.0, low = Double.infinity, high = -Double.infinity
        for p in points {
            let x = p.x - center.x, y = p.y - center.y
            let along = x * c + y * s, across = abs(-x * s + y * c)
            low = min(low, along); high = max(high, along)
            squared += across * across; maximum = max(maximum, across)
        }
        let error = sqrt(squared / Double(points.count))
        let endpointDistance = distance(points[0], points[points.count - 1])
        guard error <= 0.018, maximum <= 0.045, endpointDistance > 0.8,
              input.length / endpointDistance <= 1.10 else { return nil }
        let forward = (points.last!.x - points[0].x) * c + (points.last!.y - points[0].y) * s >= 0
        let extents = forward ? [low, high] : [high, low]
        return Candidate(kind: .line, error: error, confidence: max(0, 1 - 3 * error - maximum),
                         points: extents.map { CGPoint(x: center.x + $0 * c, y: center.y + $0 * s) })
    }

    private func fitCircle(_ input: Prepared) -> Candidate? {
        // Algebraic least squares: 2cx*x + 2cy*y + k = x² + y².
        guard let solution = leastSquares(input.points.map { [2 * $0.x, 2 * $0.y, 1] },
                                          input.points.map { $0.x * $0.x + $0.y * $0.y }) else { return nil }
        let center = CGPoint(x: solution[0], y: solution[1])
        let radiusSquared = solution[2] + center.x * center.x + center.y * center.y
        guard radiusSquared > 0 else { return nil }
        let radius = sqrt(radiusSquared)
        return evaluateCurve(input, center: center, a: radius, b: radius, angle: 0, kind: .circle)
    }

    private func fitEllipse(_ input: Prepared) -> (candidate: Candidate, ratio: Double)? {
        let center = mean(input.points), angle = principalAngle(input.points, center: center)
        let c = cos(angle), s = sin(angle)
        let local = input.points.map { p in
            CGPoint(x: (p.x - center.x) * c + (p.y - center.y) * s,
                    y: -(p.x - center.x) * s + (p.y - center.y) * c)
        }
        // Center/axes fitted in the covariance frame; the xy term keeps this a
        // general conic fit rather than assuming PCA gives the exact ellipse axes.
        guard let fit = leastSquares(local.map { [$0.x * $0.x, $0.x * $0.y, $0.y * $0.y, $0.x, $0.y] },
                                     Array(repeating: 1, count: local.count)) else { return nil }
        let aa = fit[0], bb = fit[1] / 2, cc = fit[2], determinant = aa * cc - bb * bb
        guard aa > 0, cc > 0, determinant > 1e-10 else { return nil }
        let cx = (bb * fit[4] - cc * fit[3]) / (2 * determinant)
        let cy = (bb * fit[3] - aa * fit[4]) / (2 * determinant)
        let k = 1 + aa * cx * cx + 2 * bb * cx * cy + cc * cy * cy
        let discriminant = hypot(aa - cc, 2 * bb)
        let lambdaSmall = (aa + cc - discriminant) / 2, lambdaLarge = (aa + cc + discriminant) / 2
        guard k > 0, lambdaSmall > 0 else { return nil }
        let a = sqrt(k / lambdaSmall), b = sqrt(k / lambdaLarge)
        guard a.isFinite, b.isFinite, a / b <= 6, b >= 0.065 else { return nil }
        // Eigenvector of the smaller eigenvalue is the major axis.
        let localAngle = abs(bb) > 1e-10 ? atan2(lambdaSmall - aa, bb) : (aa <= cc ? 0 : .pi / 2)
        let fittedCenter = CGPoint(x: center.x + cx * c - cy * s, y: center.y + cx * s + cy * c)
        guard let candidate = evaluateCurve(input, center: fittedCenter, a: a, b: b,
                                            angle: angle + localAngle, kind: .ellipse) else { return nil }
        return (candidate, a / b)
    }

    private func evaluateCurve(_ input: Prepared, center: CGPoint, a: Double, b: Double,
                               angle: Double, kind: ShapeKind) -> Candidate? {
        let c = cos(angle), s = sin(angle)
        var angles = [Double](), squared = 0.0, maximum = 0.0
        angles.reserveCapacity(input.points.count)
        for p in input.points {
            let x = (p.x - center.x) * c + (p.y - center.y) * s
            let y = -(p.x - center.x) * s + (p.y - center.y) * c
            let theta = atan2(y / b, x / a)
            // Distance to the radial projection, normalized by document bounds.
            let error = hypot(x - a * cos(theta), y - b * sin(theta))
            squared += error * error; maximum = max(maximum, error); angles.append(theta)
        }
        let error = sqrt(squared / Double(angles.count))
        guard error <= 0.026, maximum <= 0.065,
              let winding = singleTraversal(angles, period: 2 * .pi), winding.backtracking <= 0.035 else { return nil }
        let sorted = angles.map { $0 < 0 ? $0 + 2 * .pi : $0 }.sorted()
        var largestGap = sorted[0] + 2 * .pi - sorted.last!
        for pair in zip(sorted, sorted.dropFirst()) { largestGap = max(largestGap, pair.1 - pair.0) }
        guard largestGap <= 0.5 else { return nil }
        let h = pow((a - b) / (a + b), 2)
        let perimeter = .pi * (a + b) * (1 + 3 * h / (10 + sqrt(4 - 3 * h)))
        guard (0.88...1.14).contains(input.length / perimeter) else { return nil }
        let sign = winding.forward ? 1.0 : -1.0, start = angles[0]
        let fitted = (0...64).map { i -> CGPoint in
            let t = start + sign * 2 * .pi * Double(i) / 64
            return CGPoint(x: center.x + a * cos(t) * c - b * sin(t) * s,
                           y: center.y + a * cos(t) * s + b * sin(t) * c)
        }
        return Candidate(kind: kind, error: error,
                         confidence: max(0, 1 - 2.5 * error - maximum - input.closure * 0.15 - winding.backtracking), points: fitted)
    }

    /// The hull proposes corners; it is not evidence of a polygon by itself.
    /// Every candidate must also explain the ordered stroke and visit all edges.
    private func fitPolygon(_ input: Prepared, sides: Int) -> Candidate? {
        var vertices = convexHull(input.points)
        guard vertices.count >= sides else { return rejectPolygon(sides, "insufficient corner evidence") }
        func projection(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> (CGPoint, Double) {
            let dx = b.x-a.x, dy = b.y-a.y, length2 = dx*dx+dy*dy
            let t = length2 > 0 ? max(0, min(1, ((p.x-a.x)*dx+(p.y-a.y)*dy)/length2)) : 0
            return (CGPoint(x: a.x+t*dx, y: a.y+t*dy), t)
        }
        while vertices.count > sides {
            let index = vertices.indices.min { i, j in
                distance(vertices[i], projection(vertices[i], vertices[(i+vertices.count-1)%vertices.count], vertices[(i+1)%vertices.count]).0) <
                distance(vertices[j], projection(vertices[j], vertices[(j+vertices.count-1)%vertices.count], vertices[(j+1)%vertices.count]).0)
            }!
            vertices.remove(at: index)
        }
        // Fit straight sides from interior samples, then intersect neighboring
        // lines. This recovers corners lost between arc-length samples and avoids
        // the old enclosing-box bias from a single outward wobble.
        for _ in 0..<2 {
            var groups = Array(repeating: [CGPoint](), count: sides)
            for p in input.points {
                let side = vertices.indices.min { distance(p, projection(p, vertices[$0], vertices[($0+1)%sides]).0) < distance(p, projection(p, vertices[$1], vertices[($1+1)%sides]).0) }!
                let t = projection(p, vertices[side], vertices[(side+1)%sides]).1
                if t > 0.08 && t < 0.92 { groups[side].append(p) }
            }
            guard groups.allSatisfy({ $0.count >= 4 }) else { return rejectPolygon(sides, "insufficient samples on a side") }
            let lines = groups.map { points -> (CGPoint, CGPoint) in
                let center = mean(points), angle = principalAngle(points, center: center)
                return (center, CGPoint(x: cos(angle), y: sin(angle)))
            }
            var fitted = [CGPoint]()
            for i in 0..<sides {
                let (a,u) = lines[(i+sides-1)%sides], (b,v) = lines[i]
                let cross = u.x*v.y-u.y*v.x
                guard abs(cross) > 0.20 else { return rejectPolygon(sides, "nearly parallel adjacent edges") }
                let t = ((b.x-a.x)*v.y-(b.y-a.y)*v.x)/cross
                fitted.append(CGPoint(x: a.x+t*u.x, y: a.y+t*u.y))
            }
            vertices = fitted
        }
        if sides == 4 {
            // Only rectify a quadrilateral when its fitted edges support right
            // angles. A slanted parallelogram is never forced into a rectangle.
            let edges = vertices.indices.map { i -> CGPoint in
                let a=vertices[i], b=vertices[(i+1)%4], d=distance(a,b)
                return CGPoint(x: (b.x-a.x)/max(d,1e-12), y: (b.y-a.y)/max(d,1e-12))
            }
            guard edges.indices.allSatisfy({ abs(edges[$0].x*edges[($0+1)%4].x+edges[$0].y*edges[($0+1)%4].y) < 0.14 }) else { return rejectPolygon(sides, "no right-angle evidence") }
            let x = edges[0].x-edges[2].x+edges[1].y-edges[3].y
            let y = edges[0].y-edges[2].y-edges[1].x+edges[3].x
            let angle = atan2(y,x), c=cos(angle), s=sin(angle)
            let local = vertices.map { CGPoint(x:$0.x*c+$0.y*s,y:-$0.x*s+$0.y*c) }
            let left=(local[0].x+local[3].x)/2, right=(local[1].x+local[2].x)/2
            let top=(local[0].y+local[1].y)/2, bottom=(local[2].y+local[3].y)/2
            vertices = [CGPoint(x:left,y:top),CGPoint(x:right,y:top),CGPoint(x:right,y:bottom),CGPoint(x:left,y:bottom)].map { CGPoint(x:$0.x*c-$0.y*s,y:$0.x*s+$0.y*c) }
        }
        let lengths = vertices.indices.map { distance(vertices[$0],vertices[($0+1)%sides]) }
        guard let small=lengths.min(), small >= 0.10 else { return rejectPolygon(sides, "degenerate short edge") }
        let perimeter=lengths.reduce(0,+)
        guard (0.88...1.12).contains(input.length/perimeter) else { return rejectPolygon(sides, "perimeter mismatch") }
        var area=0.0
        for i in vertices.indices { let a=vertices[i],b=vertices[(i+1)%sides]; area += a.x*b.y-a.y*b.x }
        guard abs(area)>0.08 else { return rejectPolygon(sides, "degenerate area") }
        var positions=[Double](), square=0.0, maximum=0.0
        var corners=Array(repeating: Double.infinity,count:sides), occupancy=Array(repeating:0,count:sides)
        for p in input.points {
            for i in vertices.indices { corners[i]=min(corners[i],distance(p,vertices[i])) }
            let projections=vertices.indices.map { projection(p,vertices[$0],vertices[($0+1)%sides]) }
            let side=vertices.indices.min { distance(p,projections[$0].0)<distance(p,projections[$1].0) }!
            let error=distance(p,projections[side].0)
            square += error*error; maximum=max(maximum,error); occupancy[side]+=1
            positions.append(lengths.prefix(side).reduce(0,+)+projections[side].1*lengths[side])
        }
        let error=sqrt(square/Double(input.points.count))
        guard error<=0.016, maximum<=0.045, corners.allSatisfy({$0<=small*0.16}), occupancy.allSatisfy({$0>=4}),
              let traversal=singleTraversal(positions,period:perimeter), traversal.backtracking<=0.025 else { return rejectPolygon(sides, "edge/corner coverage or traversal", error: error) }
        let sorted=positions.sorted()
        var gap=sorted[0]+perimeter-sorted.last!
        for (a,b) in zip(sorted,sorted.dropFirst()) { gap=max(gap,b-a) }
        guard gap<=perimeter*0.10 else { return rejectPolygon(sides, "missing perimeter segment", error: error) }
        let start=vertices.indices.min { distance(vertices[$0],input.points[0])<distance(vertices[$1],input.points[0]) }!
        let direction=traversal.forward ? 1 : -1
        let fitted=(0...sides).map { vertices[(start+direction*$0+2*sides)%sides] }
        return Candidate(kind:sides==3 ? .triangle : .rectangle, error:error,
                         confidence:max(0,1-3*error-maximum-traversal.backtracking),points:fitted)
    }

    private func rejectPolygon(_ sides: Int, _ reason: String, error: Double? = nil) -> Candidate? {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--shape-diagnostics") {
            print("Shape candidate=\(sides == 3 ? "triangle" : "rectangle") rejected=\(reason) error=\(error.map(String.init(describing:)) ?? "not fitted")")
        }
        #endif
        return nil
    }

    /// Only remove a small terminal excursion AFTER an almost closed complete
    /// loop. Internal protrusions and a long arrow/tail remain rejection evidence.
    private func closedContour(_ input: Prepared) -> Prepared {
        let p=input.points
        guard p.count>20 else { return input }
        var tail=0.0, best: Int?
        for i in stride(from:p.count-2,through:Int(Double(p.count)*0.85),by:-1) {
            tail += distance(p[i],p[i+1])
            if tail>0.10 { break }
            if distance(p[i],p[0])<0.025, input.length-tail>1.8 { best=i }
        }
        guard let best, best<p.count-3,
              distance(p.last!,p[0])>0.025 else { return input }
        let source=p.prefix(best+1).map { CGPoint(x:input.origin.x+$0.x*input.scale,y:input.origin.y+$0.y*input.scale) }
        return Prepared(source,limit:configuration.maximumSampleCount) ?? input
    }

    private func singleTraversal(_ positions: [Double], period: Double) -> (forward: Bool, backtracking: Double)? {
        var signed = 0.0, absolute = 0.0
        for (a, b) in zip(positions, positions.dropFirst()) {
            var delta = b - a
            while delta > period / 2 { delta -= period }
            while delta < -period / 2 { delta += period }
            signed += delta; absolute += abs(delta)
        }
        guard (0.86...1.10).contains(abs(signed) / period) else { return nil }
        return (signed > 0, max(0, absolute - abs(signed)) / (2 * period))
    }

    private func mean(_ points: [CGPoint]) -> CGPoint {
        let sum = points.reduce(CGPoint(x: 0, y: 0)) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / Double(points.count), y: sum.y / Double(points.count))
    }
    private func principalAngle(_ points: [CGPoint], center: CGPoint) -> Double {
        var xx = 0.0, yy = 0.0, xy = 0.0
        for p in points { let x = p.x - center.x, y = p.y - center.y; xx += x * x; yy += y * y; xy += x * y }
        return 0.5 * atan2(2 * xy, xx - yy)
    }
    private func leastSquares(_ rows: [[Double]], _ values: [Double]) -> [Double]? {
        guard let size = rows.first?.count else { return nil }
        var matrix = Array(repeating: Array(repeating: 0.0, count: size + 1), count: size)
        for (row, value) in zip(rows, values) {
            for i in 0..<size {
                for j in 0..<size { matrix[i][j] += row[i] * row[j] }
                matrix[i][size] += row[i] * value
            }
        }
        for column in 0..<size {
            let pivot = (column..<size).max { abs(matrix[$0][column]) < abs(matrix[$1][column]) }!
            guard abs(matrix[pivot][column]) > 1e-12 else { return nil }
            matrix.swapAt(column, pivot)
            let divisor = matrix[column][column]
            for j in column...size { matrix[column][j] /= divisor }
            for i in 0..<size where i != column {
                let factor = matrix[i][column]
                for j in column...size { matrix[i][j] -= factor * matrix[column][j] }
            }
        }
        let solution = matrix.map { $0[size] }
        return solution.allSatisfy(\.isFinite) ? solution : nil
    }
    private func convexHull(_ points: [CGPoint]) -> [CGPoint] {
        let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        func cross(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Double {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }
        func half(_ input: [CGPoint]) -> [CGPoint] {
            var result = [CGPoint]()
            for p in input {
                while result.count >= 2 && cross(result[result.count - 2], result.last!, p) <= 0 { result.removeLast() }
                result.append(p)
            }
            return result
        }
        let lower = half(sorted), upper = half(sorted.reversed())
        return Array(lower.dropLast()) + Array(upper.dropLast())
    }
}

private func distance(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }
