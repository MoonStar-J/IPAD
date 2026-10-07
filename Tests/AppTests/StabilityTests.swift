import XCTest
import PencilKit
import PDFKit
@testable import NoteMargin

@MainActor final class StabilityTests: XCTestCase {
    func store() throws -> NoteStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Stability-"+UUID().uuidString)
        return try NoteStore(repository: LibraryRepository(root: root))
    }
    func stroke(_ points: [CGPoint], color: UIColor = .black) -> PKStroke {
        PKStroke(ink: PKInk(.pen, color: color), path: PKStrokePath(controlPoints: points.enumerated().map { i,p in
            PKStrokePoint(location: p, timeOffset: Double(i)*0.01, size: CGSize(width: 2,height: 2), opacity: 1, force: 1, azimuth: 0, altitude: .pi/2)
        }, creationDate: Date()))
    }
    func testStationaryJitterDoesNotEnterShapeFit() {
        var contact = ShapeCompletionContact(zoom: 2, offset: .zero)
        for i in 0..<80 { contact.append(.init(documentPoint: CGPoint(x: Double(i)*2,y: 20), timestamp: Double(i)*0.01, expectingUpdates: 0)) }
        for i in 0..<60 { contact.append(.init(documentPoint: CGPoint(x: 158+sin(Double(i))*0.4,y: 20+cos(Double(i))*0.4), timestamp: 0.8+Double(i)*0.01, expectingUpdates: 0)) }
        XCTAssertLessThan(contact.recognitionSamples.count, 85)
        XCTAssertEqual(ShapeRecognizer().recognize(documentPoints: contact.recognitionSamples.map(\.documentPoint))?.kind, .line)
        let old = contact.lastMovement
        for i in 0..<20 { contact.append(.init(documentPoint: CGPoint(x: 158+Double(i)*0.4,y: 20), timestamp: 1.4+Double(i)*0.01, expectingUpdates: 0)) }
        XCTAssertGreaterThan(contact.lastMovement,old)
    }
    func testHanddrawnPolygonsAndCounterexamples() {
        // Unequal sample density, wobble, edge-middle starts,
        // opposite winding, scale and rotation. Not perfect-vertex fixtures.
        let contours: [(ShapeKind,[CGPoint])] = [(.rectangle,[CGPoint(x:0,y:0),CGPoint(x:210,y:2),CGPoint(x:212,y:150),CGPoint(x:-1,y:148)]),
            (.triangle,[CGPoint(x:100,y:0),CGPoint(x:205,y:180),CGPoint(x:0,y:177)])]
        for (kind,vertices) in contours {
            var points: [CGPoint] = []
            for i in vertices.indices {
                let a = vertices[i],b = vertices[(i+1)%vertices.count]
                for j in 0..<50 {
                    let t = Double(j)/50
                    points.append(CGPoint(x:a.x+(b.x-a.x)*t+sin(Double(j)*0.8)*0.7,y:a.y+(b.y-a.y)*t+cos(Double(j)*0.9)*0.7))
                }
            }
            for reverse in [false,true] { for scale in [0.3,1.0,4.0] { for angle in [0.0,0.63,1.8] {
                let start = Array(points.dropFirst(23))+Array(points.prefix(23))
                let loop = (reverse ? Array(start.reversed()) : start) + [reverse ? start.last! : start[0]]
                let transformed = loop.map { p in CGPoint(x:900+scale*(p.x*cos(angle)-p.y*sin(angle)),y:-600+scale*(p.x*sin(angle)+p.y*cos(angle))) }
                XCTAssertEqual(ShapeRecognizer().recognize(documentPoints: transformed)?.kind,kind,"\(kind) reverse=\(reverse) scale=\(scale) angle=\(angle)")
            } } }
        }
        for points in [[CGPoint(x:0,y:0),CGPoint(x:50,y:100),CGPoint(x:100,y:0),CGPoint(x:150,y:100)],
                       (0..<180).map { CGPoint(x:Double($0), y:sin(Double($0)*0.15)*30) }] {
            XCTAssertNil(ShapeRecognizer().recognize(documentPoints: points))
        }
    }
    func testRoundedCornersClosureGapAndJitter() throws {
        for (kind,vertices) in [(ShapeKind.triangle,[CGPoint(x:100,y:0),CGPoint(x:205,y:180),CGPoint(x:0,y:177)]),
                               (.rectangle,[CGPoint(x:0,y:0),CGPoint(x:210,y:0),CGPoint(x:210,y:150),CGPoint(x:0,y:150)])] {
            func mix(_ a:CGPoint,_ b:CGPoint,_ t:Double)->CGPoint { CGPoint(x:a.x+(b.x-a.x)*t,y:a.y+(b.y-a.y)*t) }
            var rounded=[CGPoint]()
            for i in vertices.indices {
                let previous=vertices[(i+vertices.count-1)%vertices.count], corner=vertices[i], next=vertices[(i+1)%vertices.count]
                let entry=mix(corner,previous,0.06),exit=mix(corner,next,0.06)
                for j in 0..<10 { let t=Double(j)/10;rounded.append(mix(mix(entry,corner,t),mix(corner,exit,t),t)) }
                let end=mix(next,corner,0.06)
                for j in 0..<35 { var p=mix(exit,end,Double(j)/35);p.y += sin(Double(j))*0.6;rounded.append(p) }
            }
            let loop=Array(rounded.dropFirst(18))+Array(rounded.prefix(18))
            for reverse in [false,true] {
                var samples=reverse ? Array(loop.reversed()):loop
                samples.append(CGPoint(x:samples[0].x+1,y:samples[0].y+1))
                XCTAssertEqual(ShapeRecognizer().recognize(documentPoints:samples)?.kind,kind)
            }
        }
    }
    func testLateEstimatesDoNotRequireAnotherDrawingRevision() async throws {
        let canvas = PKCanvasView(frame: CGRect(x:0,y:0,width:500,height:600))
        let host = UIView(frame:canvas.frame);host.addSubview(canvas)
        var now = 0.0;var fire: (@MainActor () -> Void)?
        let scheduler = ShapeHoldScheduler(now: { now }, schedule: { _, action in fire=action;return { fire=nil } })
        let controller = ShapeCompletionController(scheduler:scheduler)
        controller.attach(to:canvas);controller.isEnabled=true
        let points = (0..<60).map { CGPoint(x:50+Double($0)*3,y:100) }
        let original = PKDrawing(strokes:[stroke(points)])
        var commits = 0
        controller.onCompletion = { _,_,drawing,_ in commits += 1;canvas.drawing=drawing;return true }
        controller.inputBegan(.init(documentPoint:points[0],timestamp:0,expectingUpdates:0),zoom:1,offset:.zero)
        controller.nativeBegan(previousStrokeCount:0)
        for i in 1..<points.count {
            now=Double(i)*0.01
            controller.inputMoved(.init(documentPoint:points[i],timestamp:now,estimationIndex:i,expectingUpdates:1))
        }
        now=1.2;fire?()
        for _ in 0..<100 where controller.phase != .snapped { try await Task.sleep(for:.milliseconds(5)) }
        XCTAssertEqual(controller.phase,.snapped)
        canvas.drawing=original
        controller.nativeEnded(drawing:original,revision:1)
        controller.inputEnded(.init(documentPoint:points.last!,timestamp:1.3,expectingUpdates:0))
        for _ in 0..<30 where commits == 0 { await Task.yield() }
        XCTAssertEqual(commits,1,"unresolved estimates must not permanently block commit")
        for i in 1..<points.count { controller.inputEstimated(.init(documentPoint:points[i],timestamp:Double(i)*0.01,estimationIndex:i,expectingUpdates:0)) }
        await Task.yield();XCTAssertEqual(commits,1)
        // A rendered commit is sufficient without an undocumented drawing echo.
        controller.nativeFinishedRendering()
        await Task.yield()
        controller.invalidate()
    }
    func testSingleImportCancellationAndConsumption() async throws {
        let store = try store(), flow = PDFImportFlow()
        let renderer = UIGraphicsPDFRenderer(bounds:CGRect(x:0,y:0,width:300,height:400))
        let data = renderer.pdfData { output in output.beginPage();output.beginPage() }
        flow.start(store:store,folderID:nil,projectID:nil) { PDFImportContents(title:"one selection",data:data) }
        for _ in 0..<100 where flow.preparing { await Task.yield() }
        guard case .options(let prepared) = flow.stage else { return XCTFail("first selection did not reach options") }
        XCTAssertEqual(prepared.pages.count,2)
        let id = try XCTUnwrap(flow.create(layout:.continuous,store:store))
        XCTAssertNil(flow.create(layout:.continuous,store:store))
        XCTAssertEqual(store.library.notebooks.count,1)
        XCTAssertNotNil(try store.drawing(noteID:id,pageID:store.note(id)!.pages[0].id))
        flow.start(store:store,folderID:nil,projectID:nil) { try await Task.sleep(for:.milliseconds(20));return PDFImportContents(title:"cancelled",data:data) }
        flow.cancel()
        try await Task.sleep(for:.milliseconds(30))
        if case .sources = flow.stage {} else { XCTFail("late result after cancellation") }
        XCTAssertEqual(store.library.notebooks.count,1)
        flow.start(store:store,folderID:nil,projectID:nil) { throw URLError(.notConnectedToInternet) }
        for _ in 0..<100 where flow.preparing { await Task.yield() }
        guard case .failed = flow.stage else { return XCTFail("cloud read error lost") }
        XCTAssertEqual(store.library.notebooks.count,1)
        flow.start(store:store,folderID:nil,projectID:nil) { PDFImportContents(title:"retry",data:data) }
        for _ in 0..<100 where flow.preparing { await Task.yield() }
        XCTAssertNotNil(flow.create(layout:.paged,store:store))
        XCTAssertEqual(store.library.notebooks.count,2)
    }
    func testDriveRequestAndCallbackValidation() throws {
        let oauth = try GoogleDriveOAuth(clientID:"123.apps.googleusercontent.com",scheme:"com.googleusercontent.apps.123")
        let query = URLComponents(url:oauth.authorization(selectAccount:true),resolvingAgainstBaseURL:false)!.queryItems!
        let values = Dictionary(uniqueKeysWithValues:query.map{($0.name,$0.value!)})
        XCTAssertEqual(values["scope"],GoogleDriveOAuth.scope)
        XCTAssertEqual(values["trigger_onepick"],"true")
        XCTAssertEqual(values["code_challenge_method"],"S256")
        XCTAssertEqual(values["mimetypes"],"application/pdf")
        let valid = URL(string:oauth.redirect.absoluteString+"?state=\(oauth.state)&code=single-use&picked_file_ids=pdf_123")!
        XCTAssertEqual(try oauth.callback(valid).fileID,"pdf_123")
        XCTAssertThrowsError(try oauth.callback(URL(string:valid.absoluteString+"&state=duplicate")!))
        XCTAssertThrowsError(try oauth.callback(URL(string:valid.absoluteString.replacingOccurrences(of:oauth.state,with:"wrong"))!))
    }
    func testDockAvoidsControlsAndUsesFinalOrientation() {
        let viewport=CGRect(x:0,y:0,width:900,height:1000)
        let controls=[CGRect(x:12,y:12,width:280,height:44),CGRect(x:550,y:12,width:338,height:44),CGRect(x:12,y:940,width:200,height:44)]
        for p in [CGPoint(x:60,y:15),CGPoint(x:880,y:500),CGPoint(x:100,y:985),CGPoint(x:800,y:15)] {
            let placement=ToolDock.resolve(point:p,viewport:viewport,obstacles:controls,expanded:true)!
            let frame=CGRect(x:placement.center.x-placement.size.width/2,y:placement.center.y-placement.size.height/2,width:placement.size.width,height:placement.size.height)
            XCTAssertTrue(viewport.contains(frame));XCTAssertTrue(controls.allSatisfy{!frame.intersects($0)})
            XCTAssertEqual(placement.size.width < placement.size.height,placement.dock.edge.isVertical)
        }
        XCTAssertFalse(ToolDock.resolve(point:CGPoint(x:50,y:50),viewport:CGRect(x:0,y:0,width:110,height:110),obstacles:[],expanded:true)!.expanded)
    }
    func testShapeMetadataReselectTransformUndoAndReload() throws {
        try checkShapeMetadata(infinite: false)
    }
    func testInfiniteShapeMetadataAcrossOriginChange() throws {
        try checkShapeMetadata(infinite: true)
    }
    private func checkShapeMetadata(infinite: Bool) throws {
        let store = try store()
        let id = try XCTUnwrap(store.createNote(title: "shape",paper:.ruled,cover:.blue,folderID:nil,infinite:infinite))
        let note=store.note(id)!,page=note.pages[0]
        let session=DrawingSession();session.load(noteID:id,pageID:page.id,store:store)
        let host=CanvasHostView(session:session);host.frame=CGRect(x:0,y:0,width:800,height:1000)
        host.configure(note:note,page:page,store:store,fingerDrawing:false,editingObjects:false,toolsVisible:true,onSelect:{_ in},onMove:{_,_,_ in},onTurnPage:{_ in false})
        host.layoutIfNeeded()
        let points=(0...100).map { i in CGPoint(x:300+cos(Double(i)*2 * .pi/100)*90,y:350+sin(Double(i)*2 * .pi/100)*90) }
        let result=try XCTUnwrap(ShapeRecognizer().recognize(documentPoints:points))
        let drawing=PKDrawing(strokes:[stroke(points)])
        let native=drawing.strokes[0]
        let metadata=InkShape(strokeID:InkStrokeID(native),kind:result.kind.rawValue,points:result.fittedPoints,fingerprint:DrawingSession.fingerprint(native))
        let window=UIWindow(frame:host.frame)
        let controller=UIViewController();window.rootViewController=controller
        controller.view.addSubview(host);window.makeKeyAndVisible()
        defer { window.isHidden=true }
        session.canvas.becomeFirstResponder()
        XCTAssertNotNil(session.undoManager)
        session.undoManager?.groupsByEvent=false
        session.undoManager?.beginUndoGrouping()
        session.commitDrawing(drawing,action:"도형 보정",shapes:[metadata])
        session.undoManager?.endUndoGrouping()
        host.selectInk(in:drawing.bounds.insetBy(dx:-10,dy:-10))
        XCTAssertTrue(host.hasAutomaticShapeSelection)
        host.clearInkSelection();host.selectInk(in:drawing.bounds.insetBy(dx:-10,dy:-10))
        XCTAssertTrue(host.hasAutomaticShapeSelection)
        session.undoManager?.beginUndoGrouping()
        host.transformSelectedInk(CGAffineTransform(translationX:120,y:60),action:"필기 이동")
        session.undoManager?.endUndoGrouping()
        let moved=session.drawing
        XCTAssertNotNil(session.shape(for:moved.strokes[0]))
        if infinite {
            session.setCanvasOrigin(CGPoint(x:8192,y:8192))
            XCTAssertTrue(host.hasAutomaticShapeSelection,"display-origin changes must not discard the logical selection")
            XCTAssertNotNil(session.shape(for:session.drawing.strokes[0]))
        }
        session.undo();XCTAssertEqual(session.drawing,drawing)
        XCTAssertEqual(session.inkShapes,[metadata])
        session.redo();XCTAssertEqual(session.drawing,moved)
        XCTAssertTrue(store.flushDrawings())
        let restored=try store.drawing(noteID:id,pageID:page.id)
        XCTAssertNotNil(session.shape(for:restored.strokes[0]))
        var erased=restored.strokes[0]
        erased.mask=UIBezierPath(rect:CGRect(x:0,y:0,width:100,height:100))
        XCTAssertNil(session.shape(for:erased),"broken geometry is not still a semantic shape")
        let pageBytes=try JSONEncoder().encode(store.note(id)!.pages[0])
        XCTAssertEqual(try JSONDecoder().decode(NotePage.self,from:pageBytes).inkShapes,session.inkShapes)
    }
    func testCanvasReplacementPreservesInputPolicy() throws {
        let store = try store()
        let first = try XCTUnwrap(store.createNote(title: "first", paper: .ruled, cover: .blue, folderID: nil))
        let second = try XCTUnwrap(store.createNote(title: "second", paper: .ruled, cover: .blue, folderID: nil, infinite: true))
        let session = DrawingSession()
        session.load(noteID: first, pageID: store.note(first)!.pages[0].id, store: store)
        session.canvas.drawingPolicy = .anyInput
        session.canvas.panGestureRecognizer.minimumNumberOfTouches = 2
        session.load(noteID: second, pageID: store.note(second)!.pages[0].id, store: store)
        XCTAssertEqual(session.canvas.drawingPolicy, .anyInput)
        XCTAssertEqual(session.canvas.panGestureRecognizer.minimumNumberOfTouches, 2)
    }
    func testInfiniteBackgroundExpandsPartialBoundaryTiles() {
        let paper=PaperView(), viewport=CGRect(x:0,y:0,width:500,height:500)
        paper.render = { context in context.setFillColor(UIColor.white.cgColor);context.fill(context.boundingBoxOfClipPath) }
        paper.documentBounds=CGRect(x:0,y:0,width:100,height:100)
        paper.updateViewport(.identity,viewport:viewport,interacting:false)
        let before=paper.rasterizationCount
        paper.documentBounds=viewport
        paper.updateViewport(.identity,viewport:viewport,interacting:false)
        let copy=CALayer();paper.copyCachedTiles(to:copy,fill:nil)
        XCTAssertEqual(copy.sublayers!.reduce(CGRect.null){$0.union($1.frame)},viewport)
        XCTAssertGreaterThan(paper.rasterizationCount,before)
        let after=paper.rasterizationCount
        paper.updateViewport(.identity,viewport:viewport,interacting:false)
        XCTAssertEqual(paper.rasterizationCount,after,"unchanged tiles must remain cached")
    }
    func testInfiniteCoordinatesCaptureExportAndPersistence() throws {
        let store=try store()
        let id=try XCTUnwrap(store.createNote(title:"infinite",paper:.grid,cover:.blue,folderID:nil,infinite:true))
        let page=store.note(id)!.pages[0]
        let points=[CGPoint(x:-2500,y:-3500),CGPoint(x:-2380,y:-3450),CGPoint(x:5200,y:6600)]
        func line(_ a:CGPoint,_ b:CGPoint)->PKStroke {
            stroke((0..<60).map { i in let t=Double(i)/59;return CGPoint(x:a.x+(b.x-a.x)*t,y:a.y+(b.y-a.y)*t) })
        }
        let drawing=PKDrawing(strokes:[line(points[0],points[1]),line(points[2],CGPoint(x:5280,y:6680))])
        store.queueDrawing(drawing,noteID:id,pageID:page.id);XCTAssertTrue(store.flushDrawings())
        XCTAssertEqual(try store.drawing(noteID:id,pageID:page.id),drawing)
        let eraser = StrokeEraserTransaction(drawing:drawing,width:12)
        eraser.extend(to:CGPoint(x:-2440,y:-3475))
        XCTAssertEqual(eraser.erasedIndices,[0])
        XCTAssertEqual(eraser.remainingDrawing.strokes.count,1)
        let session=DrawingSession();session.load(noteID:id,pageID:page.id,store:store)
        let host=CanvasHostView(session:session);host.frame=CGRect(x:0,y:0,width:800,height:900)
        host.configure(note:store.note(id)!,page:page,store:store,fingerDrawing:false,editingObjects:false,toolsVisible:true,onSelect:{_ in},onMove:{_,_,_ in},onTurnPage:{_ in false})
        host.layoutIfNeeded()
        for point in [CGPoint(x:-4000,y:-4000),CGPoint(x:6000,y:7000),CGPoint(x:-7000,y:7000)] {
            session.canvas.setContentOffset(point,animated:false);host.canvasDidScroll()
            let p=CGPoint(x:15,y:20).applying(host.documentToViewport).applying(host.documentToViewport.inverted())
            XCTAssertEqual(p.x,15,accuracy:0.0001);XCTAssertEqual(p.y,20,accuracy:0.0001)
            XCTAssertEqual(session.drawing,drawing)
        }
        host.selectInk(in:CGRect(x:-2600,y:-3600,width:400,height:300))
        XCTAssertEqual(session.selectedStrokeCount,1)
        host.transformSelectedInk(CGAffineTransform(translationX:-500,y:-600),action:"move")
        XCTAssertLessThan(session.drawing.bounds.minX,-2900)
        let moved = session.drawing
        session.canvasViewDrawingDidChange(session.canvas)
        XCTAssertEqual(session.drawing,moved,"native commit echoes must retain the logical snapshot used by preview handoffs")
        session.setCanvasOrigin(CGPoint(x:16384,y:16384))
        XCTAssertEqual(session.drawing,moved)
        session.undo()
        XCTAssertEqual(session.drawing.strokes.count,drawing.strokes.count)
        XCTAssertTrue(zip(session.drawing.strokes,drawing.strokes).allSatisfy(InkStrokeAppearance.matches), "Undo must restore every original point, transform, mask and ink attribute")
        XCTAssertEqual(session.drawing,drawing)
        session.redo()
        XCTAssertTrue(zip(session.drawing.strokes,moved.strokes).allSatisfy(InkStrokeAppearance.matches), "Redo must preserve logical geometry after a native-origin change")
        XCTAssertEqual(session.drawing,moved)
        host.saveViewport();session.stop()
        XCTAssertNotNil(store.note(id)!.pages[0].viewport)
        let capture=try RegionContextService.capture(note:store.note(id)!,page:page,drawing:drawing,store:store,rect:CGRect(x:-2600,y:-3600,width:400,height:300))
        XCTAssertEqual(capture.rect.minX,-2600)
        XCTAssertEqual(drawing.strokes[0].path.first!.location,points[0])
        XCTAssertEqual(drawing.strokes[0].transform,.identity)
        let attachment=XCTAttachment(image:UIImage(data:capture.imageData)!);attachment.name="Negative-coordinate-capture";attachment.lifetime = .keepAlways;add(attachment)
        let captured=try XCTUnwrap(UIImage(data:capture.imageData)?.cgImage)
        var pixels=[UInt8](repeating:0,count:captured.width*captured.height*4)
        let context=CGContext(data:&pixels,width:captured.width,height:captured.height,bitsPerComponent:8,bytesPerRow:captured.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(captured,in:CGRect(x:0,y:0,width:captured.width,height:captured.height))
        XCTAssertGreaterThan(stride(from:0,to:pixels.count,by:4).filter{pixels[$0]<170 && pixels[$0+1]<170 && pixels[$0+2]<170}.count,40)
        let image=PageRenderer.snapshot(page:page,note:store.note(id)!,drawing:drawing,store:store,width:1000)
        XCTAssertLessThanOrEqual(max(image.size.width,image.size.height),4096)
        let pdf=try ExportService.exportPDF(note:store.note(id)!,store:store)
        XCTAssertGreaterThan(PDFDocument(url:pdf)!.pageCount,1)
        let encoded=try JSONEncoder().encode(store.note(id)!)
        let reopened=try JSONDecoder().decode(Notebook.self,from:encoded)
        XCTAssertTrue(reopened.pages[0].isInfinite)
        XCTAssertEqual(reopened.pages[0].viewport,store.note(id)!.pages[0].viewport)
    }
}
