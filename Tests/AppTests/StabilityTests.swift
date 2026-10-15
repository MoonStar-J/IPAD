import XCTest
import PencilKit
import PDFKit
import Security
import Combine
import SwiftUI
import WebKit
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
    func testLanguageRefreshPreservesCanvasDrawingUndoAndViewport() throws {
        let previous = UserDefaults.standard.object(forKey: AppLanguage.key)
        defer { UserDefaults.standard.set(previous, forKey: AppLanguage.key) }
        let store = try store()
        let id = try XCTUnwrap(store.createNote(title: "보존할 노트", paper: .grid, cover: .blue, folderID: nil, infinite: true))
        let note = store.note(id)!, page = note.pages[0]
        let session = DrawingSession(); session.load(noteID: id, pageID: page.id, store: store)
        let host = CanvasHostView(session: session); session.host = host
        host.frame = CGRect(x: 0, y: 0, width: 800, height: 1000)
        func configure() {
            host.updateAccessibilityLanguage()
            host.configure(note: note, page: page, store: store, fingerDrawing: false, editingObjects: false,
                           toolsVisible: true, onSelect: { _ in }, onMove: { _, _, _ in }, onTurnPage: { _ in false })
            host.layoutIfNeeded()
        }
        configure()
        let drawing = PKDrawing(strokes: [stroke([CGPoint(x: 50, y: 80), CGPoint(x: 190, y: 160)])])
        XCTAssertTrue(session.commitDrawing(drawing, action: "필기"))
        session.canvas.setContentOffset(CGPoint(x: 200, y: 300), animated: false)
        host.canvasDidScroll()
        let canvas = session.canvas, origin = session.canvasOrigin, offset = canvas.contentOffset, zoom = canvas.zoomScale
        for language in ["en", "ko", "en"] {
            UserDefaults.standard.set(language, forKey: AppLanguage.key); configure()
            XCTAssertTrue(session.canvas === canvas)
            XCTAssertEqual(session.drawing, drawing)
            XCTAssertEqual(session.canvasOrigin, origin)
            XCTAssertEqual(canvas.contentOffset, offset)
            XCTAssertEqual(canvas.zoomScale, zoom)
            XCTAssertEqual(canvas.accessibilityLabel, language == "en" ? "Writing canvas" : "필기 용지")
        }
        session.undo(); XCTAssertTrue(session.drawing.strokes.isEmpty)
        session.redo(); XCTAssertEqual(session.drawing, drawing)
        XCTAssertTrue(store.flushDrawings())
        XCTAssertEqual(try store.drawing(noteID: id, pageID: page.id), drawing)
        XCTAssertEqual(store.note(id)?.title, "보존할 노트")
        session.stop()
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
        let imported = await store.importPDF(prepared, layout: .continuous)
        let id = try XCTUnwrap(imported)
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
    func testSummaryCanvasPreservesMarkdownInkAndVectorExport() async throws {
        let store = try store()
        let sourceID = try XCTUnwrap(store.createNote(title: "Source", paper: .plain, cover: .blue, folderID: nil))
        let source = store.note(sourceID)!
        let id = try store.createSummary(source: source, sources: NoteSummaryService.pageChoices(source), title: "Summary", model: "fixture", account: "fixture")
        var work = try store.summaryWork(id)
        work.final = (1...80).map { "## Section \($0)\n\nThe condition is $x > 0$, and \\(x^2+1\\) follows.\n\n" }.joined()
        try store.saveSummary(id, work: work, state: .completed)
        try await store.prepareSummaryCanvas(id)
        let note = store.note(id)!, page = try XCTUnwrap(note.pages.first), element = try XCTUnwrap(page.elements.first)
        XCTAssertEqual(element.text, work.markdown)
        XCTAssertTrue(page.isContinuousNote); XCTAssertGreaterThan(page.height, 2048)
        let asset = try XCTUnwrap(store.assetURL(noteID: id, name: element.assetName!))
        let rendered = try XCTUnwrap(PDFDocument(url: asset))
        XCTAssertGreaterThan(rendered.pageCount, 2)
        XCTAssertTrue(rendered.string?.contains("Section 80") == true)
        let capture = try RegionContextService.capture(note: note, page: page, drawing: PKDrawing(), store: store,
                                                       rect: CGRect(x: 0, y: 0, width: 768, height: 600))
        XCTAssertTrue(capture.extractedText.contains("Section 1"))
        XCTAssertFalse(capture.extractedText.contains("Section 80"), "a question crop must not include the rest of a long summary")
        let session = DrawingSession(); session.load(noteID: id, pageID: page.id, store: store)
        let ink = PKDrawing(strokes: [stroke([CGPoint(x: 70,y: 70),CGPoint(x: 180,y: 120)])])
        XCTAssertTrue(session.commitDrawing(ink, action: "test"))
        session.undo(); XCTAssertTrue(session.drawing.strokes.isEmpty)
        session.redo(); XCTAssertEqual(session.drawing, ink)
        XCTAssertTrue(store.flushDrawings())
        let url = try await ExportService.exportPDF(note: note, store: store)
        let exported = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(exported.pageCount, NoteSummaryService.pageChoices(note).count)
        XCTAssertTrue(exported.string?.contains("Section 80") == true)
        try await store.prepareSummaryCanvas(id)
        XCTAssertEqual(store.note(id)?.pages[0].elements[0].id, element.id)
        XCTAssertEqual(try store.drawing(noteID: id, pageID: page.id), ink)
        session.stop()
    }

    func testAnswerCaptureUsesLiveRenderedBounds() async throws {
        let controller = UIHostingController(rootView: MathAnswerView(text: "## Selected answer\n\nA rendered equation: $a^2+b^2=c^2$.\n\n$$\\sum_{k=1}^{n} k=\\frac{n(n+1)}{2}$$\n\nKeep the surrounding UI out."))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 500, height: 650)
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        func find(_ view: UIView) -> AnswerCaptureWebView? {
            if let web = view as? AnswerCaptureWebView { return web }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        var web: AnswerCaptureWebView?
        for _ in 0..<300 {
            controller.view.layoutIfNeeded()
            web = find(controller.view)
            if let web, !web.isLoading, web.bounds.height > 100,
               (try? await web.evaluateJavaScript("document.querySelectorAll('.katex').length")) as? Int == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let view = try XCTUnwrap(web)
        let formulaCount = try await view.evaluateJavaScript("document.querySelectorAll('.katex').length")
        XCTAssertEqual(formulaCount as? Int, 2)
        view.selecting = true
        let region = try XCTUnwrap(view.subviews.compactMap { $0 as? RegionSelectionView }.first)
        let image = try await view.captureSelection()
        XCTAssertEqual(Double(image.cgImage!.width), region.selection.width * 3, accuracy: 3)
        XCTAssertEqual(Double(image.cgImage!.height), region.selection.height * 3, accuracy: 3)
        XCTAssertFalse(region.selection.isEmpty)
        let attachment = XCTAttachment(image: image); attachment.name = "Live-answer-selected-snapshot"; attachment.lifetime = .keepAlways; add(attachment)
        view.selecting = false
        do { _ = try await view.captureSelection(); XCTFail("cancelled selection must not capture") } catch { }
    }

    func testContinuousScrollPreparationCost() async throws {
        let store = try store(), id = try XCTUnwrap(store.createNote(title: "Scroll measurement", paper: .ruled, cover: .blue, folderID: nil))
        let pageID = store.note(id)!.pages[0].id
        let session = DrawingSession(preferences: UserDefaults(suiteName: UUID().uuidString)!)
        session.load(noteID: id, pageID: pageID, store: store)
        let host = CanvasHostView(session: session); session.host = host
        host.frame = CGRect(x: 0, y: 0, width: 800, height: 1000)
        func configure() {
            let note = store.note(id)!
            host.configure(note: note, page: note.pages[0], store: store, fingerDrawing: true, editingObjects: false, toolsVisible: true,
                           onSelect: { _ in }, onMove: { _,_,_ in }, onTurnPage: { _ in false })
            host.layoutIfNeeded()
        }
        configure(); session.canvas.zoomScale = 1
        var saves = 0
        let observation = store.$library.dropFirst().sink { _ in saves += 1 }
        let start = CACurrentMediaTime()
        for step in 1...80 {
            session.canvas.setContentOffset(CGPoint(x: 0, y: step * 700), animated: false)
            host.canvasDidScroll()
            await Task.yield()
            configure(); host.canvasDidScroll(); configure()
        }
        let elapsed = (CACurrentMediaTime() - start) * 1000
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        print("CONTINUOUS_SCROLL_PERFORMANCE saves=\(saves) elapsedMs=\(elapsed) peakBytes=\(usage.ru_maxrss) storedHeight=\(store.note(id)!.pages[0].height)")
        XCTAssertEqual(store.note(id)?.pages[0].id, pageID)
        XCTAssertTrue(session.drawing.strokes.isEmpty)
        XCTAssertEqual(saves, 0, "Blank scroll space is not saved as note content")
        XCTAssertEqual(store.note(id)?.pages[0].height, 1024)
        let prepared = host.preparedHeight
        for _ in 0..<20 { configure(); host.canvasDidScroll() }
        XCTAssertEqual(host.preparedHeight, prepared)
        observation.cancel(); session.stop()
    }

    func testCanvasTeardownDoesNotPublishAndContinuousInkReopens() throws {
        let store = try store(), id = try XCTUnwrap(store.createNote(title: "Saved continuation", paper: .plain, cover: .blue, folderID: nil))
        let session = DrawingSession(preferences: UserDefaults(suiteName: UUID().uuidString)!)
        let pageID = store.note(id)!.pages[0].id
        session.load(noteID: id, pageID: pageID, store: store)
        let host = CanvasHostView(session: session); session.host = host
        host.frame = CGRect(x: 0, y: 0, width: 800, height: 1000)
        func configure(_ host: CanvasHostView) {
            let note = store.note(id)!
            host.configure(note: note, page: note.pages[0], store: store, fingerDrawing: true, editingObjects: false, toolsVisible: true,
                           onSelect: { _ in }, onMove: { _,_,_ in }, onTurnPage: { _ in false })
            host.layoutIfNeeded()
        }
        configure(host)
        session.canvas.zoomScale = 1
        session.canvas.setContentOffset(CGPoint(x: 0, y: 12000), animated: false); host.canvasDidScroll()
        let ink = PKDrawing(strokes: [stroke([CGPoint(x: 100, y: 12600), CGPoint(x: 400, y: 12700)])])
        XCTAssertTrue(session.commitDrawing(ink, action: "Ink"))
        session.stop() // EditorView's onDisappear / explicit back action owns persistence.
        let saved = store.note(id)!.pages[0], viewport = try XCTUnwrap(saved.viewport)
        XCTAssertEqual(saved.height, 13312)
        XCTAssertEqual(try store.drawing(noteID: id, pageID: pageID), ink)
        var publications = 0
        let document = store.objectWillChange.sink { publications += 1 }
        let tools = session.objectWillChange.sink { publications += 1 }
        // UIKit can change the viewport as the presentation is being destroyed.
        session.canvas.contentOffset.y += 20
        NotebookCanvas.dismantleUIView(host, coordinator: ())
        XCTAssertEqual(publications, 0)
        XCTAssertNil(session.host); XCTAssertNil(session.canvas.delegate)
        XCTAssertEqual(store.note(id)?.pages[0].viewport, viewport)
        document.cancel(); tools.cancel()
        let reopened = DrawingSession(preferences: UserDefaults(suiteName: UUID().uuidString)!)
        reopened.load(noteID: id, pageID: pageID, store: store)
        let next = CanvasHostView(session: reopened); reopened.host = next; next.frame = host.frame
        configure(next)
        XCTAssertEqual(reopened.drawing, ink)
        XCTAssertGreaterThanOrEqual(next.preparedHeight, saved.height)
        XCTAssertEqual(next.visibleDocumentCenter.y, viewport.center.y, accuracy: 2)
        reopened.stop()
    }

    func testErasersPreserveOtherInkKindsAndNativeAttributes() throws {
        let kinds: [PKInk.InkType] = [.pen, .monoline, .pencil, .marker]
        let strokes = kinds.enumerated().map { index, kind in
            var value = stroke([CGPoint(x: 80, y: 250), CGPoint(x: 380, y: 250)], color: .systemBlue, date: Date(timeIntervalSince1970: Double(index)))
            value.ink = PKInk(kind, color: index % 2 == 0 ? .systemBlue : .systemRed)
            value.transform = CGAffineTransform(translationX: 10, y: 20)
            value.mask = UIBezierPath(rect: CGRect(x: 80, y: 230, width: 280, height: 40))
            return value
        }
        let drawing = PKDrawing(strokes: strokes)
        for tool in [InkTool.pen, .pencil, .marker] {
            let session = DrawingSession(preferences: UserDefaults(suiteName: UUID().uuidString)!)
            session.selectTool(tool); session.selectTool(.rectangle); session.selectTool(.eraser)
            XCTAssertEqual(session.eraserTarget, tool)
            for partial in [false, true] {
                let transaction = StrokeEraserTransaction(drawing: drawing, width: 20, target: session.eraserTarget, partial: partial)
                transaction.extend(to: CGPoint(x: 210, y: 270))
                let targets = Set(strokes.indices.filter { tool.matches(kinds[$0]) })
                XCTAssertEqual(transaction.erasedIndices, targets)
                let result = transaction.remainingDrawing
                for index in strokes.indices where !targets.contains(index) {
                    XCTAssertTrue(result.strokes.contains { InkStrokeAppearance.matches($0, strokes[index]) })
                }
                if partial {
                    XCTAssertEqual(result.strokes.count, strokes.count)
                    for index in targets {
                        let changed = result.strokes[index]
                        XCTAssertTrue((changed.path as PKStrokePathReference) === (strokes[index].path as PKStrokePathReference))
                        XCTAssertEqual(changed.ink.inkType, strokes[index].ink.inkType)
                        XCTAssertEqual(changed.ink.color, strokes[index].ink.color)
                        XCTAssertEqual(changed.transform, strokes[index].transform)
                        XCTAssertFalse(changed.mask!.contains(CGPoint(x: 200, y: 250)))
                        XCTAssertTrue(changed.mask!.contains(CGPoint(x: 100, y: 250)))
                    }
                    let restored = try PKDrawing(data: result.dataRepresentation())
                    XCTAssertEqual(restored.strokes.count, strokes.count)
                } else { XCTAssertEqual(result.strokes.count, strokes.count - targets.count) }
            }
            session.finishErasing(); XCTAssertEqual(session.selectedTool, tool)
        }
    }

    func testContinuousExtensionPreservesDrawingAndViewport() async throws {
        let store = try store()
        let id = try XCTUnwrap(store.createNote(title: "Continuous", paper: .ruled, cover: .blue, folderID: nil))
        let pageID = store.note(id)!.pages[0].id
        let session = DrawingSession(); session.load(noteID: id, pageID: pageID, store: store)
        let host = CanvasHostView(session: session); session.host = host
        host.frame = CGRect(x: 0, y: 0, width: 800, height: 1000)
        func configure() {
            let note = store.note(id)!
            host.configure(note: note, page: note.pages[0], store: store, fingerDrawing: false, editingObjects: false, toolsVisible: true,
                           onSelect: { _ in }, onMove: { _,_,_ in }, onTurnPage: { _ in false })
            host.layoutIfNeeded()
        }
        configure()
        let canvas = session.canvas
        let ink = PKDrawing(strokes: [stroke([CGPoint(x: 70, y: 900), CGPoint(x: 180,y: 920)])])
        XCTAssertTrue(session.commitDrawing(ink, action: "test"))
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: 650), animated: false)
        host.canvasDidScroll()
        await Task.yield()
        let offset = canvas.contentOffset
        configure(); host.saveViewport()
        XCTAssertTrue(canvas === session.canvas)
        XCTAssertEqual(canvas.contentOffset, offset)
        XCTAssertEqual(store.note(id)!.pages[0].height, 1024)
        XCTAssertGreaterThan(host.preparedHeight, 1024)
        XCTAssertEqual(session.drawing, ink)
        session.undo(); XCTAssertTrue(session.drawing.strokes.isEmpty)
        session.redo(); XCTAssertEqual(session.drawing, ink)
        XCTAssertTrue(store.flushDrawings())
        XCTAssertNotNil(store.note(id)!.pages[0].viewport)
        session.stop()
    }

    func testMarkerLayerCapsOverlapAndPreservesOriginalInk() throws {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        for color in [UIColor.black, .systemBlue, .systemRed, .systemYellow, .systemGreen] {
            for count in [1, 4, 20] {
                let strokes = (0..<count).map { index in
                    PKStroke(ink: PKInk(.marker, color: color), path: PKStrokePath(controlPoints: [20.0,80.0].map {
                        PKStrokePoint(location: CGPoint(x: $0, y: 50), timeOffset: $0/100, size: CGSize(width: 40, height: 40), opacity: 1, force: 1, azimuth: 0, altitude: 1)
                    }, creationDate: Date(timeIntervalSince1970: Double(index))))
                }
                let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
                let drawing = PKDrawing(strokes: strokes)
                let image = UIGraphicsImageRenderer(bounds: rect, format: format).image { _ in PageRenderer.drawInk(drawing, in: rect, scale: 1) }.cgImage!
                var pixel = [UInt8](repeating: 0, count: 4)
                pixel.withUnsafeMutableBytes { bytes in
                    let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                    context.translateBy(x: -50, y: -50); context.draw(image, in: rect)
                }
                XCTAssertLessThanOrEqual(pixel[3], 154, "overlap has one shared opacity cap")
                XCTAssertGreaterThan(pixel[3], 70, "single highlights retain visible color")
                let store = try store(), id = try XCTUnwrap(store.createNote(title: "Marker", paper: .plain, cover: .blue, folderID: nil))
                let session = DrawingSession(); let pageID = store.note(id)!.pages[0].id
                session.load(noteID: id, pageID: pageID, store: store)
                XCTAssertTrue(session.commitDrawing(drawing, action: "test"))
                XCTAssertEqual(session.drawing, drawing)
                XCTAssertEqual(session.canvas.drawing.strokes[0].ink.color.cgColor.alpha, 0)
                session.undo(); XCTAssertTrue(session.drawing.strokes.isEmpty)
                session.redo(); XCTAssertEqual(session.drawing, drawing)
                XCTAssertTrue(store.flushDrawings())
                XCTAssertEqual(try store.drawing(noteID: id, pageID: pageID), drawing)
                session.stop()
            }
        }
    }

    func testOverlappingMarkerErasingPerformance() throws {
        let store = try store()
        let id = try XCTUnwrap(store.createNote(title: "Marker measurement", paper: .plain, cover: .blue, folderID: nil))
        let note = store.note(id)!, page = note.pages[0]
        let session = DrawingSession(preferences: UserDefaults(suiteName: UUID().uuidString)!)
        session.load(noteID: id, pageID: page.id, store: store)
        let host = CanvasHostView(session: session); session.host = host
        host.frame = CGRect(x: 0, y: 0, width: 800, height: 1000)
        let window = UIWindow(frame: host.frame), controller = UIViewController()
        window.rootViewController = controller; controller.view.addSubview(host); window.makeKeyAndVisible()
        defer { session.stop(); window.isHidden = true }
        host.configure(note: note, page: page, store: store, fingerDrawing: false, editingObjects: false, toolsVisible: true,
                       onSelect: { _ in }, onMove: { _,_,_ in }, onTurnPage: { _ in false })
        host.layoutIfNeeded(); session.canvas.zoomScale = 1
        let colors: [UIColor] = [.black, .systemBlue, .systemRed, .systemYellow, .systemGreen]
        let strokes = (0..<600).map { i in
            PKStroke(ink: PKInk(.marker, color: colors[i % colors.count]), path: PKStrokePath(controlPoints: (0..<24).map { j in
                PKStrokePoint(location: CGPoint(x: 40 + Double(j) * 26, y: 120 + Double(i % 80) * 8), timeOffset: Double(j) * 0.01,
                              size: CGSize(width: 24, height: 16), opacity: 1, force: 0.7, azimuth: 0.4, altitude: 1)
            }, creationDate: Date(timeIntervalSince1970: Double(i))), randomSeed: UInt32(i))
        }
        XCTAssertTrue(session.commitDrawing(PKDrawing(strokes: strokes), action: "fixture"))
        session.selectTool(.marker); session.selectTool(.eraser); DrawingEngineMetrics.reset()
        for contact in 0..<4 {
            session.selectTool(.eraser)
            host.beginStrokeErasing()
            for step in 0..<16 { host.extendStrokeErasing(along: [CGPoint(x: 70 + Double(step)*30, y: 120 + Double(contact)*48)]) }
            host.endStrokeErasing()
        }
        XCTAssertLessThan(session.drawing.strokes.count, strokes.count)
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        let report: [String: Any] = ["phaseMs": DrawingEngineMetrics.phaseMilliseconds,
            "moveTotalMs": DrawingEngineMetrics.eraseMilliseconds, "moveSamples": DrawingEngineMetrics.eraseBatches,
            "inkRasters": DrawingEngineMetrics.inkTileRasters, "cacheBytes": host.cachedInkBytes, "peakBytes": usage.ru_maxrss]
        print("MARKER_PERFORMANCE " + String(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), encoding: .utf8)!)
    }

    func testCopiedMarkerIDsKeepDistinctColorsAndAlphasAfterNativeErasing() throws {
        let store = try store(), id = try XCTUnwrap(store.createNote(title: "copies", paper: .plain, cover: .blue, folderID: nil))
        let pageID = store.note(id)!.pages[0].id
        let session = DrawingSession(); session.load(noteID: id, pageID: pageID, store: store)
        session.undoManager?.groupsByEvent = false
        var first = stroke([CGPoint(x: 20, y: 80), CGPoint(x: 300, y: 80)])
        first.ink = PKInk(.marker, color: UIColor.red.withAlphaComponent(0.4))
        var second = first; second.ink = PKInk(.marker, color: UIColor.red.withAlphaComponent(0.9))
        var third = first; third.ink = PKInk(.marker, color: .blue)
        let original = PKDrawing(strokes: [first, second, third])
        session.commitDrawing(original, action: "copies")
        session.selectTool(.pixelEraser)
        session.canvasViewDidBeginUsingTool(session.canvas)
        let changed = session.canvas.drawing.strokes.map { stroke in
            var stroke = stroke; stroke.mask = UIBezierPath(rect: CGRect(x: 50, y: 60, width: 100, height: 40)); return stroke
        }
        session.canvas.drawing = PKDrawing(strokes: changed)
        session.canvasViewDrawingDidChange(session.canvas)
        session.canvasViewDidEndUsingTool(session.canvas)
        XCTAssertEqual(session.drawing.strokes.map { $0.ink.color }, original.strokes.map { $0.ink.color })
        XCTAssertTrue(session.drawing.strokes.allSatisfy { $0.mask != nil })
        session.undo(); XCTAssertEqual(session.drawing, original)
        session.redo(); XCTAssertEqual(session.drawing.strokes.map { $0.ink.color }, original.strokes.map { $0.ink.color })
        session.stop()
        let archivedOriginal = try PKDrawing(data: original.dataRepresentation())
        XCTAssertEqual(try store.drawing(noteID: id, pageID: pageID).strokes.map { $0.ink.color }, archivedOriginal.strokes.map { $0.ink.color })
    }

    func testPageSlideCancellationCommitAndRepeatedInput() async throws {
        let store = try store(), id = try XCTUnwrap(store.createNote(title: "Legacy pages", paper: .plain, cover: .blue, folderID: nil))
        store.updateNote(id) { $0.pages = [NotePage(), NotePage(), NotePage()] }
        let note = store.note(id)!, session = DrawingSession()
        var index = 0, changes = 0
        session.load(noteID: id, pageID: note.pages[0].id, store: store)
        let host = CanvasHostView(session: session); session.host = host; host.frame = CGRect(x: 0, y: 0, width: 800, height: 1000)
        func configure() {
            host.configure(note: note, page: note.pages[index], store: store, fingerDrawing: true, editingObjects: false,
                           toolsVisible: true, onSelect: { _ in }, onMove: { _,_,_ in }, onTurnPage: { direction in
                guard note.pages.indices.contains(index + direction) else { return false }
                changes += 1; index += direction
                session.load(noteID: id, pageID: note.pages[index].id, store: store)
                configure(); return true
            })
            host.layoutIfNeeded()
        }
        configure()
        XCTAssertFalse(host.beginPageTransition(direction: -1))
        XCTAssertTrue(host.beginPageTransition(direction: 1))
        host.updatePageTransition(translation: -150); host.endPageTransition(commit: false)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(index, 0); XCTAssertEqual(changes, 0); XCTAssertTrue(session.canvas.isUserInteractionEnabled)
        XCTAssertTrue(host.beginPageTransition(direction: 1))
        host.updatePageTransition(translation: -450); host.endPageTransition(commit: true)
        host.endPageTransition(commit: true); host.turnPage(direction: 1)
        host.pageFinishedRendering()
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(index, 1); XCTAssertEqual(changes, 1); XCTAssertTrue(session.canvas.isUserInteractionEnabled)
        host.turnPage(direction: -1); host.pageFinishedRendering()
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(index, 0); XCTAssertEqual(changes, 2)
        session.stop()
    }

    func testMultiImportFailureAndCancelDoNotCreateEmptyOrDuplicateNotes() async throws {
        let store = try store(), flow = PDFImportFlow()
        let files = try ["good", "missing"].map { name in
            try PDFImportContents(title: name, data: UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 400)).pdfData { $0.beginPage() })
        }
        flow.start(store: store, folderID: nil, projectID: nil) { PDFImportSelection(files: files) }
        for _ in 0..<400 where flow.preparing { try await Task.sleep(for: .milliseconds(5)) }
        try FileManager.default.removeItem(at: files[1].url)
        flow.chooseOptions(); flow.create(layout: .paged, separate: true, title: "", store: store) { _ in XCTFail("partial failure must show its result") }
        flow.create(layout: .paged, separate: true, title: "duplicate", store: store) { _ in XCTFail() }
        for _ in 0..<400 where flow.preparing { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(flow.created.count, 1); XCTAssertEqual(flow.failures.count, 1)
        XCTAssertEqual(store.library.notebooks.map(\.title), ["good"])
        flow.reset()
        flow.start(store: store, folderID: nil, projectID: nil) { PDFImportSelection(files: [files[0]]) }
        for _ in 0..<400 where flow.preparing { try await Task.sleep(for: .milliseconds(5)) }
        flow.chooseOptions(); flow.create(layout: .continuous, separate: false, title: "cancelled", store: store) { _ in XCTFail() }
        flow.cancel(); try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(store.library.notebooks.count, 1)
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
            let expected = image { _ in PageRenderer.drawInk(drawing, in: viewport, scale: 2) }
            XCTAssertLessThan(difference(expected, image { preview.layer.render(in: $0.cgContext) }), 0.5)
            let transform = CGAffineTransform(translationX: 12, y: 8)
            preview.moveSelection(transform, viewportTransform: .identity)
            let moved = image { _ in PageRenderer.drawInk(selection.transformed(transform), in: viewport, scale: 2) }
            XCTAssertLessThan(difference(moved, image { preview.layer.render(in: $0.cgContext) }), 0.5)
            var distant = strokes
            for i in [1,3] { distant[i].transform = CGAffineTransform(translationX: 900, y: 0) }
            let distantSelection = RectangularInkSelection(drawing: PKDrawing(strokes: distant), indices: [1,3])
            preview.prepare(selection: distantSelection, paper: paper, viewport: viewport, transform: .identity)
            let bringIntoView = CGAffineTransform(translationX: -888, y: 8)
            preview.moveSelection(bringIntoView, viewportTransform: .identity)
            let brought = image { _ in PageRenderer.drawInk(distantSelection.transformed(bringIntoView), in: viewport, scale: 2) }
            XCTAssertLessThan(difference(brought, image { preview.layer.render(in: $0.cgContext) }), 0.5, "moving from another tile retains stroke stacking and clears the previous preview")
            let erase = StrokeEraserPreviewView(frame: viewport); erase.overrideUserInterfaceStyle = style
            erase.begin(transaction: StrokeEraserTransaction(drawing: drawing, width: 12), paper: paper, viewport: viewport, transform: .identity)
            erase.setErased([1,3])
            let faded = image { _ in
                PageRenderer.drawInk(PKDrawing(strokes: [strokes[0], strokes[2], strokes[4]]), in: viewport, scale: 2)
                UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                    PKDrawing(strokes: [strokes[1], strokes[3]]).image(from: viewport, scale: 2).draw(in: viewport, blendMode: .normal, alpha: 0.35)
                }
            }
            XCTAssertLessThan(difference(faded, image { erase.layer.render(in: $0.cgContext) }), 0.5)
            erase.setErased([1,3], committed: true)
            let removed = image { _ in PageRenderer.drawInk(PKDrawing(strokes: [strokes[0],strokes[2],strokes[4]]), in: viewport, scale: 2) }
            XCTAssertLessThan(difference(removed, image { erase.layer.render(in: $0.cgContext) }), 0.5)
            let partial = StrokeEraserTransaction(drawing: drawing, width: 16, target: .marker, partial: true)
            erase.begin(transaction: partial, paper: paper, viewport: viewport, transform: .identity)
            for point in [CGPoint(x: 170, y: 140), CGPoint(x: 170, y: 210)] {
                partial.extend(to: point); erase.updatePartialMasks(partial)
                let expected = image { _ in PageRenderer.drawInk(partial.remainingDrawing, in: viewport, scale: 2) }
                let actual = image { erase.layer.render(in: $0.cgContext) }
                let band = CGRect(x: 0, y: 240, width: 768, height: 200)
                XCTAssertLessThan(difference(UIImage(cgImage: expected.cgImage!.cropping(to: band)!),
                                             UIImage(cgImage: actual.cgImage!.cropping(to: band)!)), 0.5)
            }
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
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0,y: 0,width: 300,height: 400))
        let data = renderer.pdfData { output in output.beginPage(); output.beginPage() }
        flow.start(store: store, folderID: nil, projectID: nil) { PDFImportSelection(files: [try PDFImportContents(title: "one selection", data: data)]) }
        for _ in 0..<400 where flow.preparing { try await Task.sleep(for: .milliseconds(5)) }
        guard case .selection = flow.stage else { return XCTFail("selection must wait for explicit import") }
        XCTAssertEqual(flow.files.first?.pages.count, 2)
        XCTAssertTrue(store.library.notebooks.isEmpty)
        flow.chooseOptions()
        flow.create(layout: .continuous, separate: false, title: "combined", store: store) { _ in }
        flow.create(layout: .continuous, separate: false, title: "duplicate", store: store) { _ in }
        for _ in 0..<400 where flow.preparing { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(store.library.notebooks.count, 1)
        flow.reset()
        flow.start(store: store, folderID: nil, projectID: nil) {
            try await Task.sleep(for: .milliseconds(20))
            return PDFImportSelection(files: [try PDFImportContents(title: "cancelled", data: data)])
        }
        flow.cancel(); try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(flow.files.isEmpty)
        XCTAssertEqual(store.library.notebooks.count, 1)
        flow.start(store: store, folderID: nil, projectID: nil) { throw URLError(.notConnectedToInternet) }
        for _ in 0..<400 where flow.preparing { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(flow.failures.count, 1)
    }
    func testMultiplePDFLayoutsPreserveFileAndPageOrder() async throws {
        for layout in PDFImportLayout.allCases { for separate in [false, true] {
            let store = try store(), flow = PDFImportFlow()
            let files = try ["A", "B"].map { name in
                try PDFImportContents(title: name, data: UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 400)).pdfData { output in
                    for page in 1...2 { output.beginPage(); ("\(name)\(page)" as NSString).draw(at: CGPoint(x: 10,y: 20), withAttributes: [.font: UIFont.systemFont(ofSize: 20)]) }
                })
            }
            flow.start(store: store, folderID: nil, projectID: nil) { PDFImportSelection(files: files) }
            for _ in 0..<400 where flow.preparing { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertEqual(flow.files.count, 2, flow.failures.map(\.text).joined(separator: "; "))
            flow.files.reverse(); flow.chooseOptions()
            flow.create(layout: layout, separate: separate, title: "BA", store: store) { _ in }
            for _ in 0..<400 where flow.preparing { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertEqual(flow.created.count, separate ? 2 : 1)
            var text: [String] = []
            for id in flow.created {
                let note = store.note(id)!
                XCTAssertEqual(note.pages.count, layout == .continuous ? 1 : (separate ? 2 : 4))
                let url = try await ExportService.exportPDF(note: note, store: store)
                let document = try XCTUnwrap(PDFDocument(url: url))
                text += (0..<document.pageCount).map { document.page(at: $0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
            }
            XCTAssertEqual(text, ["B1", "B2", "A1", "A2"])
        } }
    }
    func testDriveRequestAndCallbackValidation() throws {
        let oauth = try GoogleDriveOAuth(clientID:"123.apps.googleusercontent.com",scheme:"com.googleusercontent.apps.123")
        let query = URLComponents(url:oauth.authorization(selectAccount:true),resolvingAgainstBaseURL:false)!.queryItems!
        let values = Dictionary(uniqueKeysWithValues:query.map{($0.name,$0.value!)})
        XCTAssertEqual(values["scope"],GoogleDriveOAuth.scope)
        XCTAssertEqual(values["trigger_onepick"],"true")
        XCTAssertEqual(values["code_challenge_method"],"S256")
        XCTAssertEqual(values["mimetypes"],"application/pdf")
        XCTAssertEqual(values["allow_multiple"], "true")
        let valid = URL(string:oauth.redirect.absoluteString+"?state=\(oauth.state)&code=single-use&picked_file_ids=pdf_123")!
        XCTAssertEqual(try oauth.callback(valid).fileIDs,["pdf_123"])
        let multiple = valid.absoluteString.replacingOccurrences(of: "picked_file_ids=pdf_123", with: "picked_file_ids=pdf_123,pdf_456,pdf_123")
        XCTAssertEqual(try oauth.callback(URL(string: multiple)!).fileIDs, ["pdf_123", "pdf_456"])
        XCTAssertThrowsError(try oauth.callback(URL(string: multiple.replacingOccurrences(of: "pdf_456", with: ""))!))
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
