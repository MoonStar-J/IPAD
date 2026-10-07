import Foundation
import CoreGraphics

@main struct ShapeEditingMathChecks {
    static func main() throws {
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            precondition(condition, message)
        }
        func close(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a-b) < 0.000001 }
        func point(_ object: Any?) -> CGPoint { let v=object as! [Double]; return CGPoint(x:v[0],y:v[1]) }
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let json = try JSONSerialization.jsonObject(with:data) as! [String:Any]
        for item in json["cases"] as! [[String:Any]] {
            let frame=ShapeEditFrame(center:point(item["center"]),width:item["width"] as! Double,height:item["height"] as! Double,angle:item["angle"] as! Double)
            let corner=item["corner"] as! Int
            let drag=ShapeResizeDrag(frame:frame,corner:corner,pointer:point(item["grab"]))
            let transform=drag.transform(to:point(item["pointer"])), after=frame.applying(transform)
            let expected=point(item["expectedCenter"]),offset=point(item["offset"])
            check(close(after.center.x,expected.x) && close(after.center.y,expected.y),"upstream getResizedOrigin center")
            check(close(after.width,item["expectedWidth"] as! Double) && close(after.height,item["expectedHeight"] as! Double),"upstream corner aspect dimensions")
            check(close(drag.pointerOffset.x,offset.x) && close(drag.pointerOffset.y,offset.y),"upstream handle grab offset")
            let fixed=drag.anchor.applying(transform)
            check(close(fixed.x,drag.anchor.x) && close(fixed.y,drag.anchor.y),"opposite corner fixed")
            let identity=drag.transform(to:point(item["grab"]))
            check(close(identity.a,1) && close(identity.tx,0) && close(identity.ty,0),"grabbing handle does not jump")
            // Intentional divergence from upstream reflections: clamp one scale.
            let crossed=CGPoint(x:drag.anchor.x-drag.pointerOffset.x-1000,y:drag.anchor.y-drag.pointerOffset.y-1000)
            let zero=drag.transform(to:CGPoint(x:drag.anchor.x+drag.pointerOffset.x,y:drag.anchor.y+drag.pointerOffset.y))
            check(zero.a>0 && close(zero.a,zero.d) && close(zero.a,drag.minimumScale),"zero area uses one positive minimum scale")
            let t=drag.transform(to:crossed)
            check(t.a>0 && close(t.a,t.d) && t.tx.isFinite && t.ty.isFinite,"crossing never reflects or creates NaN")
            // A non-equilateral triangle must preserve every side ratio, also rotated.
            let triangle=[CGPoint(x:2,y:4),CGPoint(x:60,y:12),CGPoint(x:30,y:75)]
            for i in 0..<3 {
                let a=triangle[i],b=triangle[(i+1)%3],c=a.applying(transform),d=b.applying(transform)
                check(close(hypot(c.x-d.x,c.y-d.y)/hypot(a.x-b.x,a.y-b.y),transform.a),"triangle similarity")
            }
            for zoom in [CGFloat(0.5),1,4] {
                let p=point(item["pointer"]),screen=CGPoint(x:p.x*zoom-32,y:p.y*zoom+71)
                let document=screen.applying(CGAffineTransform(a:zoom,b:0,c:0,d:zoom,tx:-32,ty:71).inverted())
                check(close(drag.transform(to:document).a,transform.a),"zoom does not change document geometry")
            }
        }
        for item in json["translations"] as! [[String:Any]] {
            let t=ShapeEditMath.translation(start:point(item["start"]),current:point(item["pointer"]))
            let value=point(item["original"]).applying(t),expected=point(item["expected"])
            check(close(value.x,expected.x) && close(value.y,expected.y),"upstream original + total pointer delta")
        }
        for item in json["endpoints"] as! [[String:Any]] {
            let value=ShapeEditMath.lineEndpoint(pointer:point(item["pointer"]),pointerOffset:point(item["offset"]))!,expected=point(item["expected"])
            check(close(value.x,expected.x) && close(value.y,expected.y),"upstream createPointAt/movePoints selected endpoint")
            check(point(item["start"]) == CGPoint(x:20,y:40),"upstream does not move start")
        }
        check(ShapeEditMath.lineEndpoint(pointer:CGPoint(x:Double.nan,y:3)) == nil,"invalid input rejected")
        check(ShapeEditMath.lineEndpoint(pointer:.zero) == .zero,"zero length endpoint is finite")
        print("PASS: \(checks) geometry checks; 344 cases execute extracted upstream functions with adapters; no-reflection/zoom/triangle checks are app-specific")
    }
}
