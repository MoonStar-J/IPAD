import Foundation

/// Run independently of UIKit/PencilKit:
/// swiftc -O -D SHAPE_RECOGNITION_STANDALONE -module-cache-path /private/tmp/note-margin-shape-module-cache
///   NoteMargin/Canvas/ShapeRecognition.swift scripts/shape_recognition_checks.swift -o /private/tmp/note-margin-shape-checks
/// /private/tmp/note-margin-shape-checks
func checkShapeRecognition() throws {
    var checks = 0
    func check(_ condition: @autoclosure () -> Bool, _ description: String) throws {
        checks += 1
        if !condition() { throw NSError(domain: "ShapeRecognition: " + description, code: 1) }
    }
    let recognizer = ShapeRecognizer()
    func curve(a: Double, b: Double, count: Int = 161, turns: Double = 1, noise: Double = 0) -> [CGPoint] {
        (0..<count).map { index in
            let theta = Double(index) / Double(count - 1) * 2 * .pi * turns
            let variation = 1 + noise * sin(theta * 7) + noise * 0.4 * cos(theta * 13)
            return CGPoint(x: a * cos(theta) * variation, y: b * sin(theta) * variation)
        }
    }
    func polygon(_ vertices: [CGPoint], sideSamples: Int = 32) -> [CGPoint] {
        var points = [CGPoint]()
        for (a, b) in zip(vertices, vertices.dropFirst()) {
            for i in 0..<sideSamples {
                let t = Double(i) / Double(sideSamples)
                points.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        points.append(vertices.last!)
        return points
    }
    func transformed(_ points: [CGPoint], scale: Double, angle: Double, offset: CGPoint) -> [CGPoint] {
        let c = cos(angle), s = sin(angle)
        return points.map { CGPoint(x: offset.x + scale * ($0.x * c - $0.y * s),
                                    y: offset.y + scale * ($0.x * s + $0.y * c)) }
    }
    let line = (0..<90).map { i in CGPoint(x: Double(i) * 2, y: sin(Double(i) * 0.15) * 0.4) }
    let rectangle = polygon([CGPoint(x: -80, y: -40), CGPoint(x: 80, y: -40),
                             CGPoint(x: 80, y: 40), CGPoint(x: -80, y: 40), CGPoint(x: -80, y: -40)])
    let square = polygon([CGPoint(x: -60, y: -60), CGPoint(x: 60, y: -60),
                          CGPoint(x: 60, y: 60), CGPoint(x: -60, y: 60), CGPoint(x: -60, y: -60)])
    let fixtures: [(ShapeKind, [CGPoint])] = [(.line, line), (.circle, curve(a: 60, b: 60)),
        (.circle, curve(a: 60, b: 60, noise: 0.014)), (.ellipse, curve(a: 100, b: 44)),
        (.ellipse, curve(a: 110, b: 24, noise: 0.008)), (.rectangle, rectangle), (.rectangle, square)]
    // Regression: a slightly flattened hand circle was previously forced to an ellipse.
    for ratio in [1.0, 1.08, 1.14, 1.18, 1.35, 1.7, 2.4] {
        let expected: ShapeKind = ratio <= 1.18 ? .circle : .ellipse
        for noise in [0.0, 0.008] { for angle in [0.0, 0.51, 1.7] { for scale in [0.2, 1.0, 8.0] {
            var points = curve(a: 80 * ratio, b: 80, noise: noise)
            points[points.count - 1] = CGPoint(x: points[0].x + 0.6, y: points[0].y + 0.3)
            let result = recognizer.recognize(documentPoints: transformed(points, scale: scale, angle: angle, offset: CGPoint(x: -1800, y: 2900)))
            try check(result?.kind == expected, "near-circle ratio=\(ratio), noise=\(noise), angle=\(angle), scale=\(scale)")
        } } }
    }
    for (kind, points) in fixtures {
        for scale in [0.003, 1.0, 120.0] {
            for angle in [0.0, 0.37, 1.57, 2.8] {
                let source = transformed(points, scale: scale, angle: angle, offset: CGPoint(x: 400, y: 70_000))
                let before = source
                let result = recognizer.recognize(documentPoints: source)
                try check(result?.kind == kind, "\(kind) survives scale \(scale), rotation \(angle), deep translation; got \(String(describing: result?.kind))")
                try check(zip(source, before).allSatisfy { $0.x == $1.x && $0.y == $1.y }, "recognition does not mutate input")
                try check((result?.confidence ?? 0) >= 0.88 && (result?.normalizedError ?? 1) < 0.03,
                          "accepted shape carries conservative confidence and normalized fit error")
                try check((result?.fittedPoints.count ?? 0) <= 65 && (result?.fittedPoints.count ?? 0) >= 2,
                          "fitted geometry is bounded and suitable for stroke-model integration")
                let inverse = result!.fittedPoints.map { p -> CGPoint in
                    let x = (p.x - 400) / scale, y = (p.y - 70_000) / scale
                    return CGPoint(x: x * cos(angle) + y * sin(angle), y: -x * sin(angle) + y * cos(angle))
                }
                let base = recognizer.recognize(documentPoints: points)!
                // Closed shapes may choose an equivalent axis or starting corner.
                let maximumDistance = inverse.map { p in base.fittedPoints.map { hypot(p.x - $0.x, p.y - $0.y) }.min()! }.max()!
                try check(maximumDistance < 0.15, "fitted geometry is equivariant under the document transform (distance \(maximumDistance))")
            }
        }
        let reversed = recognizer.recognize(documentPoints: points.reversed())
        try check(reversed?.kind == kind, "clockwise/counterclockwise and line direction are supported")
    }
    let unevenCircle = curve(a: 80, b: 80).enumerated().flatMap { i, point in Array(repeating: point, count: i < 60 ? 15 : 1) }
    try check(recognizer.recognize(documentPoints: unevenCircle)?.kind == .circle, "coalesced sampling and dwell density do not bias fitting")
    let noisyRectangle = rectangle.enumerated().map { i, p in CGPoint(x: p.x + sin(Double(i) * 1.1) * 0.35,
                                                                      y: p.y + cos(Double(i) * 0.7) * 0.35) }
    try check(recognizer.recognize(documentPoints: noisyRectangle)?.kind == .rectangle, "small realistic corner/side noise remains a rectangle")
    let openArc = curve(a: 50, b: 50, turns: 0.70)
    let doubleLoop = curve(a: 50, b: 50, turns: 2)
    let figureEight = (0...180).map { i in
        let t = Double(i) / 180 * 2 * .pi
        return CGPoint(x: sin(t) * 70, y: sin(2 * t) * 45)
    }
    let spiral = (0...180).map { i in
        let t = Double(i) / 180 * 4 * .pi, r = 20 + Double(i) / 4
        return CGPoint(x: cos(t) * r, y: sin(t) * r)
    }
    let triangle = polygon([CGPoint(x: -80, y: 50), CGPoint(x: 0, y: -70), CGPoint(x: 80, y: 50), CGPoint(x: -80, y: 50)])
    try check(recognizer.recognize(documentPoints: triangle)?.kind == .triangle, "triangle is supported")
    // Recorded regression families: start in the middle of an edge, winding,
    // rotation, imperfect closure, sparse corners, and a short terminal tail.
    let scalene = polygon([CGPoint(x: -90,y: 60),CGPoint(x: -25,y: -70),CGPoint(x: 110,y: 60),CGPoint(x: -90,y: 60)])
    for (kind, path) in [(ShapeKind.triangle, triangle), (.triangle, scalene), (.rectangle, rectangle), (.rectangle, square)] {
        let loop = Array(path.dropLast())
        for shift in [0, 13, 43, 77] {
            var shifted = Array(loop[shift...])+Array(loop[..<shift]); shifted.append(shifted[0])
            for direction in [shifted, Array(shifted.reversed())] {
                let rotated = transformed(direction, scale: 1, angle: 0.61, offset: CGPoint(x: 500,y: 400))
                try check(recognizer.recognize(documentPoints: rotated)?.kind == kind, "\(kind) cyclic shift \(shift), rotation, winding")
                var open = rotated; open.removeLast(2)
                try check(recognizer.recognize(documentPoints: open)?.kind == kind, "\(kind) relative closure gap at shift \(shift)")
            }
        }
        var tail=path
        let end=path.last!
        for i in 1...6 { tail.append(CGPoint(x:end.x,y:end.y+Double(i))) }
        try check(recognizer.recognize(documentPoints: tail)?.kind == kind, "\(kind) small terminal excursion after a proven closed loop")
        var arrow=path
        for i in 1...30 { arrow.append(CGPoint(x:end.x+Double(i)*2,y:end.y+Double(i)*2)) }
        try check(recognizer.recognize(documentPoints: arrow) == nil, "\(kind) genuine long protrusion is not discarded")
    }
    let bulgedRectangle = rectangle.enumerated().map { i,p in
        CGPoint(x:p.x,y:p.y + (i < 32 ? -8 * pow(sin(Double(i)/32 * .pi), 8) : 0))
    }
    try check(recognizer.recognize(documentPoints: bulgedRectangle)?.kind == .rectangle, "side fit resists localized outward bulge that biased the old enclosing box")
    let jitteredTriangle = scalene + (1...100).map { i in CGPoint(x:scalene[0].x+0.05*sin(Double(i)),y:scalene[0].y+0.05*cos(Double(i))) }
    try check(recognizer.recognize(documentPoints:jitteredTriangle)?.kind == .triangle, "stationary endpoint noise does not dominate polygon fit")
    let parallelogram = polygon([CGPoint(x: -80, y: -40), CGPoint(x: 30, y: -40), CGPoint(x: 80, y: 40),
                                 CGPoint(x: -30, y: 40), CGPoint(x: -80, y: -40)])
    let zigzag = polygon([CGPoint(x: 0, y: 0), CGPoint(x: 30, y: 60), CGPoint(x: 60, y: 0),
                         CGPoint(x: 90, y: 60), CGPoint(x: 120, y: 0)])
    let three = (0...160).map { i in
        let t = Double(i) / 160 * 4 * .pi
        return CGPoint(x: cos(t) * 25, y: Double(i) / 2 + sin(t) * 12)
    }
    let retracedLine = polygon([CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 20, y: 0), CGPoint(x: 120, y: 0)])
    let bowedLine = (0...100).map { i in CGPoint(x: Double(i), y: 14 * sin(Double(i) / 100 * .pi)) }
    for (name, points) in ["open arc": openArc, "double loop": doubleLoop, "figure eight": figureEight,
                            "spiral": spiral, "parallelogram": parallelogram,
                            "handwritten zigzag": zigzag, "handwritten 3": three, "retraced line": retracedLine,
                            "bowed line": bowedLine] {
        try check(recognizer.recognize(documentPoints: points) == nil, "conservative rejection of \(name)")
    }
    for points in [[], [CGPoint(x: 0, y: 0)], Array(repeating: CGPoint(x: 6, y: 8), count: 500),
                   [CGPoint(x: 0, y: 0), CGPoint(x: Double.nan, y: 1)], [CGPoint(x: 0, y: 0), CGPoint(x: Double.infinity, y: 1)]] {
        try check(recognizer.recognize(documentPoints: points) == nil, "invalid and stationary input is rejected")
    }
    let twoPointLine = recognizer.recognize(documentPoints: [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 100)])
    try check(twoPointLine?.kind == .line && twoPointLine?.fittedPoints.count == 2, "two-point lines remain minimal")
    var strict = ShapeRecognizer(); strict.configuration.minimumConfidence = 1.01
    try check(strict.recognize(documentPoints: line) == nil, "caller-specified conservative acceptance threshold is honored")

    // Measurements isolate recognition (input array creation is outside timing).
    // A linear input scan is expected; expensive fitting remains capped at 128.
    func elapsed(_ points: [CGPoint], count: Int) -> Double {
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<count { _ = recognizer.recognize(documentPoints: points) }
        return (ProcessInfo.processInfo.systemUptime - start) / Double(count)
    }
    let short = curve(a: 100, b: 55, count: 16_001), long = curve(a: 100, b: 55, count: 64_001)
    _ = recognizer.recognize(documentPoints: long)
    let shortSeconds = elapsed(short, count: 8), longSeconds = elapsed(long, count: 8)
    let ordinarySeconds = elapsed(curve(a: 100, b: 55), count: 100)
    let huge = curve(a: 100, b: 55, count: 500_001)
    let hugeStart = ProcessInfo.processInfo.systemUptime
    let hugeResult = recognizer.recognize(documentPoints: huge)
    let hugeSeconds = ProcessInfo.processInfo.systemUptime - hugeStart
    try check(hugeResult?.kind == .ellipse && hugeResult?.fittedPoints.count == 65,
              "half-million-point input produces bounded fitted geometry")
    try check(longSeconds < max(0.002, shortSeconds) * 8, "input scan scales linearly rather than fitting all source points")
    try check(hugeSeconds < 2 && ordinarySeconds < 0.05, "synthetic recognition has no unbounded latency")
    print("PASS: \(checks) shape recognition checks")
    print(String(format: "Measured macOS optimized pure Swift: ordinary=%.3fms; 16k=%.3fms; 64k=%.3fms; 500k=%.3fms; fittedMax=65",
                 ordinarySeconds * 1_000, shortSeconds * 1_000, longSeconds * 1_000, hugeSeconds * 1_000))
    print("These are geometry CPU timings, not Apple Pencil input-to-display latency or device-frame measurements.")
}

#if SHAPE_RECOGNITION_STANDALONE
@main struct ShapeRecognitionChecksMain {
    static func main() throws { try checkShapeRecognition() }
}
#endif
