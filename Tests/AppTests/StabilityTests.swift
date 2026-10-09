import XCTest
import PencilKit
import PDFKit
import Security
@testable import NoteMargin

@MainActor final class StabilityTests: XCTestCase {
    func store() throws -> NoteStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Stability-"+UUID().uuidString)
        return try NoteStore(repository: LibraryRepository(root: root))
    }
    func stroke(_ points: [CGPoint], color: UIColor = .black, date: Date = Date()) -> PKStroke {
        PKStroke(ink: PKInk(.pen, color: color), path: PKStrokePath(controlPoints: points.enumerated().map { i,p in
            PKStrokePoint(location: p, timeOffset: Double(i)*0.01, size: CGSize(width: 2,height: 2), opacity: 1, force: 1, azimuth: 0, altitude: .pi/2)
        }, creationDate: date))
    }
    func testSelectedPDFOrderFrozenInputsAndFailureCleanup() async throws {
        let store = try store()
        let id = try XCTUnwrap(store.createNote(title: "Selected", paper: .plain, cover: .blue, folderID: nil))
        store.updateNote(id) { $0.pages = (1...3).map { number in
            NotePage(width: 300 + Double(number), height: 400, elements: [PageElement(kind: .text, text: "Page \(number)", x: 20, y: 20, width: 200, height: 60)])
        } }
        let note = store.note(id)!, choices = try ExportService.pageChoices(note: note, store: store)
        let corrupt = try XCTUnwrap(store.assetURL(noteID: id, name: "\(note.pages[1].id).drawing"))
        try FileManager.default.createDirectory(at: corrupt.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0, 1, 2]).write(to: corrupt)
        let url = try await ExportService.exportPDF(note: note, store: store, selection: Set([choices[2].id, choices[0].id, choices[2].id])) { done, _ in
            if done == 0 { store.updateNote(id) { $0.pages[2].elements[0].text = "Changed" } }
        }
        let pdf = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(pdf.pageCount, 2)
        XCTAssertTrue(pdf.page(at: 0)!.string!.contains("Page 1"))
        XCTAssertTrue(pdf.page(at: 1)!.string!.contains("Page 3"))
        XCTAssertEqual(pdf.page(at: 1)!.bounds(for: .mediaBox).width, 303)
        do { _ = try await ExportService.exportPDF(note: note, store: store); XCTFail("corrupt selected input must fail") } catch { }
        do { _ = try await ExportService.exportPDF(note: note, store: store, selection: []); XCTFail("empty selection") } catch { }
        let directory = url.deletingLastPathComponent().deletingLastPathComponent()
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        let task = Task { @MainActor in try await ExportService.exportPDF(note: note, store: store, selection: [choices[0].id, choices[2].id]) { done, _ in
            if done == 1 { withUnsafeCurrentTask { $0?.cancel() } }
        } }
        do { _ = try await task.value; XCTFail("cancelled result must not be shared") } catch is CancellationError { }
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)), before)
    }

    func testContinuousPDFExportUsesOriginalSegmentsAndCompositeRenderer() async throws {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 240, height: 320))
        let data = renderer.pdfData { output in
            for index in 1...3 {
                output.beginPage()
                UIColor.blue.setFill(); output.cgContext.fill(CGRect(x: 10, y: 10, width: 40, height: 50))
                ("Original \(index)" as NSString).draw(at: CGPoint(x: 70, y: 20), withAttributes: [.font: UIFont.systemFont(ofSize: 14)])
            }
        }
        let original = try XCTUnwrap(PDFDocument(data: data)); original.page(at: 2)?.rotation = 90
        let store = try store()
        let prepared = try XCTUnwrap(store.preparePDF(data: original.dataRepresentation()!, title: "Continuous", folderID: nil))
        let id = try XCTUnwrap(store.importPDF(prepared, layout: .continuous))
        let page = store.note(id)!.pages[0]
        let choices = try ExportService.pageChoices(note: store.note(id)!, store: store)
        let rect = choices[2].rect
        store.queueDrawing(PKDrawing(strokes: [stroke([CGPoint(x: 50, y: rect.minY + 100), CGPoint(x: 300, y: rect.minY + 100)], color: .red)]), noteID: id, pageID: page.id)
        store.updatePage(noteID: id, pageID: page.id) { $0.elements.append(PageElement(kind: .text, text: "Inserted", x: 50, y: rect.minY + 180, width: 250, height: 80)) }
        let note = store.note(id)!
        let url = try await ExportService.exportPDF(note: note, store: store, selection: [choices[2].id, choices[0].id])
        let exported = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(exported.pageCount, 2)
        XCTAssertEqual(exported.page(at: 1)!.bounds(for: .mediaBox).size, rect.size)
        XCTAssertTrue(exported.page(at: 0)!.string!.contains("Original 1"))
        XCTAssertTrue(exported.page(at: 1)!.string!.contains("Original 3"))
        XCTAssertTrue(exported.page(at: 1)!.string!.contains("Inserted"))
        let expected = PageRenderer.snapshot(page: note.pages[0], note: note, drawing: try store.drawing(noteID: id, pageID: page.id), store: store, width: rect.width, rect: rect)
        let actual = exported.page(at: 1)!.thumbnail(of: rect.size, for: .mediaBox)
        func pixels(_ image: UIImage) -> [UInt8] {
            var bytes = [UInt8](repeating: 255, count: 192 * 192 * 4)
            bytes.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: 192, height: 192, bitsPerComponent: 8, bytesPerRow: 192 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(image.cgImage!, in: CGRect(x: 0, y: 0, width: 192, height: 192))
            }
            return bytes
        }
        let reference = pixels(expected), rendered = pixels(actual)
        let difference = zip(reference, rendered).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        XCTAssertLessThan(Double(difference) / Double(reference.count), 3, "PDF rotation, clipping and ink coordinates must match the existing renderer")
        add(XCTAttachment(image: expected)); add(XCTAttachment(image: actual))
        let whole = try await ExportService.exportPDF(note: note, store: store)
        XCTAssertEqual(PDFDocument(url: whole)?.pageCount, 3)
    }

    func testPDFExportPerformance() async throws {
        let store = try store()
        let id = try XCTUnwrap(store.createNote(title: "Export measurement", paper: .grid, cover: .blue, folderID: nil))
        for _ in 1..<20 { _ = store.addPage(noteID: id, after: store.note(id)!.pages.last!.id, paper: .grid) }
        let ink = PKDrawing(strokes: (0..<300).map { row in
            stroke((0..<40).map { CGPoint(x: 40 + $0 * 16, y: 50 + row % 100 * 8) })
        })
        for page in store.note(id)!.pages { store.queueDrawing(ink, noteID: id, pageID: page.id) }
        XCTAssertTrue(store.flushDrawings())
        var last = Date(), maxGap = 0.0, ticks = 0
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                let now = Date(); maxGap = max(maxGap, now.timeIntervalSince(last)); last = now; ticks += 1
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        await Task.yield()
        let start = Date()
        let url = try await ExportService.exportPDF(note: store.note(id)!, store: store)
        let elapsed = Date().timeIntervalSince(start)
        maxGap = max(maxGap, Date().timeIntervalSince(last)); heartbeat.cancel()
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        print("EXPORT_METRIC seconds=\(elapsed) peakMB=\(Double(usage.ru_maxrss)/1048576) maxMainGap=\(maxGap) ticks=\(ticks)")
        XCTAssertEqual(PDFDocument(url: url)?.pageCount, 20)
        try FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
    func testTrashBatchValidationFailureAndRetry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let files = CleanupFailureFileManager()
        let repository = try LibraryRepository(root: root, files: files)
        let store = try NoteStore(repository: repository)
        defer { try? FileManager.default.removeItem(at: root) }
        let active = try XCTUnwrap(store.createNote(title: "active", paper: .plain, cover: .blue, folderID: nil))
        let restored = try XCTUnwrap(store.createNote(title: "restored", paper: .plain, cover: .blue, folderID: nil))
        let deleted = try XCTUnwrap(store.createNote(title: "deleted", paper: .plain, cover: .blue, folderID: nil))
        let failed = try XCTUnwrap(store.createNote(title: "retry", paper: .plain, cover: .blue, folderID: nil))
        for id in [active, restored, deleted, failed] {
            try repository.writeAsset(Data([1,2,3]), noteID: id, name: "attachment.bin")
        }
        store.trash(restored); store.trash(deleted); store.trash(failed)
        let confirmation = Set([active, restored, deleted, failed])
        store.restore(restored)
        files.blocked = repository.noteDirectory(failed)
        XCTAssertFalse(store.permanentlyDelete(confirmation))
        XCTAssertNotNil(store.errorMessage)
        XCTAssertNotNil(store.note(active)); XCTAssertNotNil(store.note(restored))
        XCTAssertTrue(FileManager.default.fileExists(atPath: repository.noteDirectory(active).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: repository.noteDirectory(restored).path))
        XCTAssertNil(store.note(deleted)); XCTAssertNil(store.note(failed))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.noteDirectory(deleted).path))
        XCTAssertEqual(Set(store.library.pendingAssetDeletions ?? []), [failed])
        let reopened = try NoteStore(repository: repository)
        files.blocked = nil
        XCTAssertTrue(reopened.finishPermanentDeletion())
        XCTAssertNil(reopened.library.pendingAssetDeletions)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.noteDirectory(failed).path))
        XCTAssertTrue(reopened.permanentlyDelete(confirmation), "repeated taps cannot delete restored notes")
        XCTAssertEqual(reopened.library.notebooks.count, 2)
    }
    func testTrashSaveFailurePreservesAllFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repository = try LibraryRepository(root: root)
        let store = try NoteStore(repository: repository)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(store.permanentlyDelete(Set<UUID>()))
        let id = try XCTUnwrap(store.createNote(title: "safe", paper: .plain, cover: .blue, folderID: nil))
        try repository.writeAsset(Data([4,5,6]), noteID: id, name: "keep.bin")
        store.trash(id)
        let manifest = root.appendingPathComponent("library.json")
        try FileManager.default.moveItem(at: manifest, to: root.appendingPathComponent("library.backup"))
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
        XCTAssertFalse(store.permanentlyDelete(id))
        XCTAssertNotNil(store.note(id)?.deletedAt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: repository.noteDirectory(id).appendingPathComponent("keep.bin").path))
    }
    func testDriveCredentialRestoreRefreshAndDisconnect() async throws {
        let service = "DriveTest-" + UUID().uuidString
        let client = "123.apps.googleusercontent.com"
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "selected-account"]
        defer { SecItemDelete(query as CFDictionary) }
        let tokens = GoogleDriveImport.Tokens(access_token: "fixture-expired", refresh_token: "fixture-refresh", expires_in: 1, token_type: "Bearer", scope: GoogleDriveOAuth.scope)
        let credential = GoogleDriveImport.Credential(clientID: client, tokens: tokens, expires: .distantPast)
        var add = query; add[kSecValueData as String] = try JSONEncoder().encode(credential)
        XCTAssertEqual(SecItemAdd(add as CFDictionary, nil), errSecSuccess)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [DriveFixtureProtocol.self]
        let http = URLSession(configuration: config)
        defer { http.invalidateAndCancel() }
        let drive = GoogleDriveImport(configuration: (client, "com.googleusercontent.apps.123"), service: service, session: http)
        XCTAssertTrue(drive.isConnected)
        await drive.restoreConnection()
        XCTAssertNil(drive.errorMessage)
        XCTAssertEqual(drive.account, "fixture@example.invalid")
        let restored = GoogleDriveImport(configuration: (client, "com.googleusercontent.apps.123"), service: service, session: http)
        XCTAssertTrue(restored.isConnected)
        XCTAssertEqual(restored.account, drive.account)
        try restored.disconnect()
        XCTAssertFalse(restored.isConnected)
        XCTAssertFalse(GoogleDriveImport(configuration: (client, "com.googleusercontent.apps.123"), service: service, session: http).isConnected)
    }
    func testDriveConnectAndPickerScopeIsolation() throws {
        let oauth = try GoogleDriveOAuth(clientID: "123.apps.googleusercontent.com", scheme: "com.googleusercontent.apps.123")
        let connect = URLComponents(url: oauth.authorization(selectAccount: true, picking: false), resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertNil(connect.first { $0.name == "trigger_onepick" })
        XCTAssertEqual(connect.first { $0.name == "scope" }?.value, GoogleDriveOAuth.scope)
        XCTAssertEqual(connect.first { $0.name == "include_granted_scopes" }?.value, "false")
        let callback = URL(string: oauth.redirect.absoluteString + "?state=\(oauth.state)&code=fixture")!
        XCTAssertEqual(try oauth.callback(callback, picking: false).code, "fixture")
        XCTAssertThrowsError(try oauth.callback(callback))
        XCTAssertThrowsError(try oauth.callback(URL(string: oauth.redirect.absoluteString + "?state=\(oauth.state)&error=access_denied")!, picking: false))
    }
    func testDriveRevokedAndOfflineRefresh() async throws {
        for revoked in [false, true] {
            let service = "DriveFailure-" + UUID().uuidString
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service, kSecAttrAccount as String: "selected-account"]
            defer { SecItemDelete(query as CFDictionary) }
            let tokens = GoogleDriveImport.Tokens(access_token: "fixture", refresh_token: "fixture", expires_in: 1, token_type: "Bearer", scope: GoogleDriveOAuth.scope)
            let credential = GoogleDriveImport.Credential(clientID: "123.apps.googleusercontent.com", tokens: tokens, expires: .distantPast)
            var item = query; item[kSecValueData as String] = try JSONEncoder().encode(credential)
            XCTAssertEqual(SecItemAdd(item as CFDictionary, nil), errSecSuccess)
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = revoked ? [RevokedDriveProtocol.self] : [OfflineDriveProtocol.self]
            let http = URLSession(configuration: config)
            defer { http.invalidateAndCancel() }
            let drive = GoogleDriveImport(configuration: (credential.clientID, "com.googleusercontent.apps.123"), service: service, session: http)
            await drive.restoreConnection()
            XCTAssertNotNil(drive.errorMessage)
            XCTAssertEqual(drive.isConnected, !revoked, "network failure preserves the account; revoked access requires login")
            XCTAssertEqual(GoogleDriveImport(configuration: (credential.clientID, "com.googleusercontent.apps.123"), service: service, session: http).isConnected, !revoked)
        }
    }
    func testEditingBoundaryPerformance() async throws {
        var reports = [[String: Any]]()
        for count in [60, 1500] { for shaped in [false, true] { for zoom in [1.0, 2.5] {
            let store = try store()
            let id = try XCTUnwrap(store.createNote(title: "Performance fixture", paper: .ruled, cover: .blue, folderID: nil))
            let note = store.note(id)!, page = note.pages[0]
            var now = 0.0; var fire: (@MainActor () -> Void)?
            let scheduler = ShapeHoldScheduler(now: { now }, schedule: { _, action in fire = action; return { fire = nil } })
            let preferences = UserDefaults(suiteName: "Performance-" + UUID().uuidString)!
            let session = DrawingSession(preferences: preferences, shapeHoldScheduler: scheduler)
            session.load(noteID: id, pageID: page.id, store: store)
            let host = CanvasHostView(session: session); session.host = host
            host.frame = CGRect(x: 0, y: 0, width: 800, height: 1000)
            let window = UIWindow(frame: host.frame); let vc = UIViewController(); window.rootViewController = vc
            vc.view.addSubview(host); window.makeKeyAndVisible()
            host.configure(note: note, page: page, store: store, fingerDrawing: false, editingObjects: false, toolsVisible: true, onSelect: { _ in }, onMove: { _,_,_ in }, onTurnPage: { _ in false })
            host.layoutIfNeeded(); session.canvas.zoomScale = zoom
            session.canvas.contentOffset = CGPoint(x: 0, y: 100 * zoom)
            host.canvasDidScroll()
            let strokes = (0..<count).map { i in
                stroke((0..<24).map { j in CGPoint(x: 50 + Double(i % 30) * 22 + Double(j) * 0.35, y: 160 + Double(i / 30) * 14 + sin(Double(j) * 0.2)) }, date: Date(timeIntervalSince1970: Double(i)))
            }
            session.commitDrawing(PKDrawing(strokes: strokes), action: "fixture")
            XCTAssertTrue(store.flushDrawings())
            DrawingEngineMetrics.reset()
            let paperBefore = host.backgroundRasterizationCount
            var creationMilliseconds = 0.0
            if shaped {
                let points = (0...100).map { i in CGPoint(x: 280 + 50 * cos(Double(i) * .pi / 50), y: 260 + 50 * sin(Double(i) * .pi / 50)) }
                let controller = session.shapeCompletionForTesting
                controller.inputBegan(.init(documentPoint: points[0], timestamp: 0, expectingUpdates: 0), zoom: zoom, offset: session.canvas.contentOffset)
                controller.nativeBegan(previousStrokeCount: count)
                for i in 1..<points.count { now = Double(i) * 0.01; controller.inputMoved(.init(documentPoint: points[i], timestamp: now, expectingUpdates: 0)) }
                let started = CACurrentMediaTime(); now = 1.6; fire?()
                for _ in 0..<500 where controller.phase != .snapped { try await Task.sleep(for: .milliseconds(2)) }
                XCTAssertEqual(controller.phase, .snapped)
                creationMilliseconds = (CACurrentMediaTime() - started) * 1000
                let original = PKDrawing(strokes: strokes + [stroke(points)])
                session.canvas.drawing = original
                controller.nativeEnded(drawing: original, revision: session.drawingRevision)
                controller.inputEnded(.init(documentPoint: points.last!, timestamp: 1.7, expectingUpdates: 0))
                for _ in 0..<100 where controller.phase == .snapped { await Task.yield() }
                XCTAssertTrue(host.hasAutomaticShapeSelection)
                let updated = store.note(id)!
                host.configure(note: updated, page: updated.pages[0], store: store, fingerDrawing: false, editingObjects: false, toolsVisible: true, onSelect: { _ in }, onMove: { _,_,_ in }, onTurnPage: { _ in false })
            }
            for contact in 0..<4 {
                DrawingEngineMetrics.measure(.toolSwitch) { session.selectTool(.eraser) }
                host.beginStrokeErasing()
                for step in 0..<16 { host.extendStrokeErasing(along: [CGPoint(x: 50 + Double(contact) * 22 + Double(step) * 0.3, y: 160)]) }
                host.endStrokeErasing()
            }
            DrawingEngineMetrics.measure(.save) { XCTAssertTrue(store.flushDrawings()) }
            var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
            reports.append(["strokes": count, "shape": shaped, "zoom": zoom,
                "shapeHoldToPreviewMs": creationMilliseconds, "phaseMs": DrawingEngineMetrics.phaseMilliseconds,
                "eraseBatches": DrawingEngineMetrics.eraseBatches, "eraseBatchTotalMs": DrawingEngineMetrics.eraseMilliseconds,
                "paperRasters": host.backgroundRasterizationCount - paperBefore,
                "inkRasters": DrawingEngineMetrics.inkTileRasters, "inkCacheBytes": host.cachedInkBytes,
                "processPeakResidentBytes": usage.ru_maxrss])
            session.stop(); window.isHidden = true
        } } }
        let data = try JSONSerialization.data(withJSONObject: reports, options: [.sortedKeys, .prettyPrinted])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "editing-boundary-performance"; attachment.lifetime = .keepAlways; add(attachment)
        print("EDITING_PERFORMANCE " + String(data: try JSONSerialization.data(withJSONObject: reports, options: [.sortedKeys]), encoding: .utf8)!)
    }
    func testCompositeTilesPreserveOverlapMasksAndFade() throws {
        let viewport = CGRect(x: 0, y: 0, width: 384, height: 384)
        var strokes = [PKStroke]()
        for i in 0..<5 {
            let points = (0..<40).map { j in PKStrokePoint(location: CGPoint(x: 25 + Double(j) * 8, y: 165 + sin(Double(j) * 0.18 + Double(i)) * 30), timeOffset: Double(j) * 0.01, size: CGSize(width: 12, height: 7), opacity: 1.4, force: 0.7, azimuth: 0.4, altitude: 1) }
            var value = PKStroke(ink: PKInk(i % 2 == 0 ? .marker : .pencil, color: i % 2 == 0 ? .systemBlue : .black), path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: Double(i))), randomSeed: UInt32(40 + i))
            if i == 2 { value.mask = UIBezierPath(rect: CGRect(x: 85, y: 100, width: 210, height: 170)) }
            strokes.append(value)
        }
        let drawing = PKDrawing(strokes: strokes), paper = PaperView()
        paper.documentBounds = viewport
        paper.render = { $0.setFillColor(UIColor.white.cgColor); $0.fill(viewport) }
        paper.updateViewport(.identity, viewport: viewport, interacting: false)
        let format = UIGraphicsImageRendererFormat(); format.scale = 2; format.opaque = true; format.preferredRange = .standard
        func image(_ body: (UIGraphicsImageRendererContext) -> Void) -> UIImage {
            UIGraphicsImageRenderer(bounds: viewport, format: format).image { c in UIColor.white.setFill(); c.fill(viewport); body(c) }
        }
        func difference(_ expected: UIImage, _ actual: UIImage) -> Double {
            func bytes(_ value: UIImage) -> [UInt8] {
                let cg = value.cgImage!, width = cg.width, height = cg.height
                var data = [UInt8](repeating: 0, count: width * height * 4)
                data.withUnsafeMutableBytes { b in
                    CGContext(data: b.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
                }
                return data
            }
            let a = bytes(expected), b = bytes(actual)
            return Double(zip(a,b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(a.count)
        }
        for style in [UIUserInterfaceStyle.light, .dark] {
            let selection = RectangularInkSelection(drawing: drawing, indices: [1,3])
            let preview = InkTransformPreview(frame: viewport); preview.overrideUserInterfaceStyle = style
            preview.prepare(selection: selection, paper: paper, viewport: viewport, transform: .identity)
            let expected = image { _ in drawing.image(from: viewport, scale: 2).draw(in: viewport) }
            XCTAssertLessThan(difference(expected, image { preview.layer.render(in: $0.cgContext) }), 0.5)
            let transform = CGAffineTransform(translationX: 12, y: 8)
            preview.moveSelection(transform, viewportTransform: .identity)
            let moved = image { _ in selection.transformed(transform).image(from: viewport, scale: 2).draw(in: viewport) }
            XCTAssertLessThan(difference(moved, image { preview.layer.render(in: $0.cgContext) }), 0.5)
            var distant = strokes
            for i in [1,3] { distant[i].transform = CGAffineTransform(translationX: 900, y: 0) }
            let distantSelection = RectangularInkSelection(drawing: PKDrawing(strokes: distant), indices: [1,3])
            preview.prepare(selection: distantSelection, paper: paper, viewport: viewport, transform: .identity)
            let bringIntoView = CGAffineTransform(translationX: -888, y: 8)
            preview.moveSelection(bringIntoView, viewportTransform: .identity)
            let brought = image { _ in distantSelection.transformed(bringIntoView).image(from: viewport, scale: 2).draw(in: viewport) }
            XCTAssertLessThan(difference(brought, image { preview.layer.render(in: $0.cgContext) }), 0.5, "moving from another tile retains stroke stacking and clears the previous preview")
            let erase = StrokeEraserPreviewView(frame: viewport); erase.overrideUserInterfaceStyle = style
            erase.begin(transaction: StrokeEraserTransaction(drawing: drawing, width: 12), paper: paper, viewport: viewport, transform: .identity)
            erase.setErased([1,3])
            let faded = image { _ in
                for (i, stroke) in strokes.enumerated() { PKDrawing(strokes: [stroke]).image(from: viewport, scale: 2).draw(in: viewport, blendMode: .normal, alpha: [1,3].contains(i) ? 0.35 : 1) }
            }
            XCTAssertLessThan(difference(faded, image { erase.layer.render(in: $0.cgContext) }), 0.5)
            erase.setErased([1,3], committed: true)
            let removed = image { _ in PKDrawing(strokes: [strokes[0],strokes[2],strokes[4]]).image(from: viewport, scale: 2).draw(in: viewport) }
            XCTAssertLessThan(difference(removed, image { erase.layer.render(in: $0.cgContext) }), 0.5)
        }
        let cache = InkGeometryCache(drawing: drawing)
        let remaining = cache.removing([1,3])
        XCTAssertEqual(remaining.drawing.strokes.count, 3)
        XCTAssertTrue(remaining.hasBalancedIndex)
        XCTAssertEqual(remaining.candidates(intersecting: viewport).count, 3)
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
        let host=CanvasHostView(session:session);session.host=host;host.frame=CGRect(x:0,y:0,width:800,height:1000)
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
    func testFractionalShapeFingerprintSurvivesArchive() throws {
        let source = stroke((0...64).map { i in CGPoint(x: 350 + 90 * cos(Double(i) * .pi / 32), y: 410 + 90 * sin(Double(i) * .pi / 32)) })
        let moved = PKDrawing(strokes: [source]).transformed(using: CGAffineTransform(a: 1.251337, b: 0, c: 0, d: 1.251337, tx: 68.424934, ty: -16.777331))
        let reopened = try PKDrawing(data: moved.dataRepresentation())
        XCTAssertEqual(DrawingSession.fingerprint(moved.strokes[0]), DrawingSession.fingerprint(reopened.strokes[0]))
    }
    func testShapeMetadataSaveFailurePreservesDrawing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NoteStore(repository: LibraryRepository(root: root))
        let id = try XCTUnwrap(store.createNote(title: "Save failure", paper: .plain, cover: .blue, folderID: nil))
        let page = store.note(id)!.pages[0]
        let session = DrawingSession(); session.load(noteID: id, pageID: page.id, store: store)
        let original = PKDrawing(strokes: [stroke([CGPoint(x: 40, y: 40), CGPoint(x: 140, y: 80)])])
        XCTAssertTrue(session.commitDrawing(original, action: "Original")); XCTAssertTrue(store.flushDrawings())
        let manifest = root.appendingPathComponent("library.json")
        try FileManager.default.moveItem(at: manifest, to: root.appendingPathComponent("library.backup"))
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
        XCTAssertFalse(session.commitDrawing(original.transformed(using: CGAffineTransform(translationX: 100, y: 40)), action: "Move", shapes: []))
        XCTAssertEqual(session.drawing, original)
        XCTAssertEqual(try store.drawing(noteID: id, pageID: page.id), original)
        XCTAssertNotNil(store.errorMessage)
    }
    func testMetadataChangesReusePaperTiles() throws {
        let store = try store()
        let id = try XCTUnwrap(store.createNote(title: "tiles", paper: .ruled, cover: .blue, folderID: nil))
        let note = store.note(id)!, page = note.pages[0]
        let session = DrawingSession(); session.load(noteID: id, pageID: page.id, store: store)
        let host = CanvasHostView(session: session); host.frame = CGRect(x: 0, y: 0, width: 800, height: 1000)
        func configure(_ value: NotePage) {
            host.configure(note: note, page: value, store: store, fingerDrawing: false, editingObjects: false, toolsVisible: true, onSelect: { _ in }, onMove: { _,_,_ in }, onTurnPage: { _ in false })
            host.layoutIfNeeded()
        }
        configure(page)
        let count = host.backgroundRasterizationCount
        XCTAssertGreaterThan(count, 0)
        var updated = page
        updated.inkShapes = []; updated.inkGroups = []; updated.viewport = CanvasViewport(center: CGPoint(x: 400, y: 500), zoom: 1)
        configure(updated)
        XCTAssertEqual(host.backgroundRasterizationCount, count)
        updated.paper = .grid; configure(updated)
        XCTAssertGreaterThan(host.backgroundRasterizationCount, count)
    }
    func testUncommittedShapePreviewClearsOnOriginChange() throws {
        let store = try store()
        let id = try XCTUnwrap(store.createNote(title: "Pending shape", paper: .plain, cover: .blue, folderID: nil, infinite: true))
        let note = store.note(id)!, page = note.pages[0]
        let session = DrawingSession(); session.load(noteID: id, pageID: page.id, store: store)
        let host = CanvasHostView(session: session); session.host = host
        host.frame = CGRect(x: 0, y: 0, width: 800, height: 1000)
        host.configure(note: note, page: page, store: store, fingerDrawing: false, editingObjects: false, toolsVisible: true, onSelect: { _ in }, onMove: { _,_,_ in }, onTurnPage: { _ in false })
        host.layoutIfNeeded()
        let points = (0...64).map { i in CGPoint(x: 350 + 90 * cos(Double(i) * .pi / 32), y: 410 + 90 * sin(Double(i) * .pi / 32)) }
        host.showAutomaticShape(try XCTUnwrap(ShapeRecognizer().recognize(documentPoints: points)))
        let outline = try XCTUnwrap(host.layer.sublayers?.compactMap { $0 as? CAShapeLayer }.first { $0.lineDashPattern != nil && $0.path != nil })
        XCTAssertNotNil(outline.path)
        session.setCanvasOrigin(CGPoint(x: 8192, y: 8192))
        XCTAssertNil(outline.path, "only committed selections survive an origin change")
        XCTAssertTrue(session.canvas.drawingGestureRecognizer.isEnabled)
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
    func testInfiniteCoordinatesCaptureExportAndPersistence() async throws {
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
        let host=CanvasHostView(session:session);session.host=host;host.frame=CGRect(x:0,y:0,width:800,height:900)
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
        let pdf=try await ExportService.exportPDF(note:store.note(id)!,store:store)
        XCTAssertGreaterThan(PDFDocument(url:pdf)!.pageCount,1)
        let encoded=try JSONEncoder().encode(store.note(id)!)
        let reopened=try JSONDecoder().decode(Notebook.self,from:encoded)
        XCTAssertTrue(reopened.pages[0].isInfinite)
        XCTAssertEqual(reopened.pages[0].viewport,store.note(id)!.pages[0].viewport)
    }
}

private final class CleanupFailureFileManager: FileManager, @unchecked Sendable {
    var blocked: URL?
    override func removeItem(at URL: URL) throws {
        if URL == blocked { throw CocoaError(.fileWriteNoPermission) }
        try super.removeItem(at: URL)
    }
}
private final class DriveFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let text: String
        if request.url!.host == "oauth2.googleapis.com" {
            text = #"{"access_token":"fixture-new","expires_in":3600,"token_type":"Bearer","scope":"https://www.googleapis.com/auth/drive.file"}"#
        } else { text = #"{"user":{"emailAddress":"fixture@example.invalid"}}"# }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private final class RevokedDriveProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"error":"invalid_grant"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private final class OfflineDriveProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}
