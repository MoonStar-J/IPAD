import SwiftUI
import PencilKit
import Combine

@MainActor final class NoteSummaryService: ObservableObject {
    @Published private(set) var activeID: UUID?
    @Published private(set) var message = ""
    @Published private(set) var failure: String?
    @Published private(set) var unsaved = false
    private weak var store: NoteStore?
    private let connection: ChatGPTPlanConnection
    private let http: PlanHTTP
    private var task: Task<Void, Never>?
    private var observation: AnyCancellable?
    private var generation: UUID?
    private var retained: (id: UUID, work: SummaryWork, state: NoteSummary.State)?
    private var work: SummaryWork?
    private var lastSave = Date.distantPast

    init(store: NoteStore, connection: ChatGPTPlanConnection? = nil, http: PlanHTTP = .shared) {
        self.store = store; self.connection = connection ?? .shared; self.http = http
        observation = self.connection.objectWillChange.sink { [weak self] in
            Task { @MainActor in
                guard let self, let generation = self.generation, generation != self.connection.generation else { return }
                self.cancel()
            }
        }
    }
    var busy: Bool { task != nil }
    var retainedID: UUID? { retained?.id }
    func checkpoint(_ id: UUID) throws -> SummaryWork {
        if let retained, retained.id == id { return retained.work }
        if activeID == id, let work { return work }
        guard let store else { throw CocoaError(.fileReadNoSuchFile) }
        return try store.summaryWork(id)
    }

    static func pageChoices(_ note: Notebook) -> [SummarySource] {
        note.pages.enumerated().flatMap { index, page in
            if page.isContinuousPDF {
                return page.pdfRegions.enumerated().map { offset, region in
                    SummarySource(id: "\(page.id)-\(offset)", pageID: page.id, label: "PDF \(region.pageIndex + 1)페이지",
                                  rect: CGRect(x: 0, y: region.y, width: page.width, height: region.height))
                }
            }
            return [SummarySource(id: page.id.uuidString, pageID: page.id, label: "\(index + 1)페이지",
                                  rect: CGRect(x: 0, y: 0, width: page.width, height: page.height))]
        }
    }

    /// Uses native stroke bounds and element bounds; distant empty space is never tiled.
    static func sources(note: Notebook, choices: Set<String>?, region: CGRect?, store: NoteStore) throws -> [SummarySource] {
        var result: [SummarySource] = [], hasContent = false
        let size = CGSize(width: 768, height: 900)
        for choice in pageChoices(note) where choices == nil || choices!.contains(choice.id) {
            guard let page = note.pages.first(where: { $0.id == choice.pageID }) else { throw CocoaError(.fileReadCorruptFile) }
            let drawing = try store.drawing(noteID: note.id, pageID: page.id)
            let content = drawing.strokes.map(\.renderBounds) + page.elements.filter { $0.kind == .image || !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map {
                CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
            }
            var rectangles: [CGRect]
            if page.isInfinite {
                struct Cell: Hashable { let x: Int; let y: Int }
                var cells = Set<Cell>()
                for bounds in content {
                    let clipped = region.map { bounds.intersection($0) } ?? bounds
                    guard !clipped.isNull, !clipped.isEmpty else { continue }
                    guard clipped.minX.isFinite, clipped.minY.isFinite, clipped.maxX.isFinite, clipped.maxY.isFinite,
                          abs(clipped.minX) < 1e9, abs(clipped.minY) < 1e9, abs(clipped.maxX) < 1e9, abs(clipped.maxY) < 1e9 else { throw CocoaError(.fileReadCorruptFile) }
                    let x0 = Int(floor(clipped.minX / size.width)), x1 = Int(floor(clipped.maxX / size.width))
                    let y0 = Int(floor(clipped.minY / size.height)), y1 = Int(floor(clipped.maxY / size.height))
                    guard (x1-x0+1) * (y1-y0+1) <= 10_000 else { throw SummaryError.message("요약 영역이 너무 넓습니다. 사각형으로 범위를 나눠 주세요.") }
                    for y in y0...y1 { for x in x0...x1 { cells.insert(Cell(x: x, y: y)) } }
                }
                guard cells.count <= 10_000 else { throw SummaryError.message("요약 영역이 너무 많습니다. 범위를 나눠 주세요.") }
                rectangles = cells.sorted { $0.y == $1.y ? $0.x < $1.x : $0.y < $1.y }.map {
                    let tile = CGRect(x: Double($0.x)*size.width, y: Double($0.y)*size.height, width: size.width, height: size.height).insetBy(dx: -12, dy: -12)
                    return region.map { tile.intersection($0) } ?? tile
                }
                hasContent = hasContent || !rectangles.isEmpty
            } else {
                hasContent = hasContent || !page.pdfRegions.isEmpty || content.contains { $0.intersects(choice.rect) }
                rectangles = try CanvasExtent.exportPages(choice.rect, size: size).map { $0.insetBy(dx: -12, dy: -12).intersection(choice.rect) }
            }
            for (index, rect) in rectangles.enumerated() {
                guard rect.width >= 8, rect.height >= 8 else { continue }
                let label = page.isInfinite ? "영역 \(result.count + 1) (x: \(Int(rect.minX)), y: \(Int(rect.minY)))" : choice.label + (rectangles.count > 1 ? " · 구간 \(index + 1)" : "")
                result.append(SummarySource(id: "S\(result.count + 1)", pageID: page.id, label: label, rect: rect))
            }
        }
        guard hasContent, !result.isEmpty else { throw SummaryError.message("선택 범위에 요약할 내용이 없습니다.") }
        return result
    }

    private func verifyConnection(summary: NoteSummary? = nil) throws -> (String, String) {
        guard connection.state == .ready, let account = connection.selected,
              connection.models.contains(where: { $0.slug == connection.model }) else {
            throw SummaryError.message("ChatGPT 연결과 사용할 모델을 확인해 주세요.")
        }
        guard PlanModelSupport.acceptsImage(connection.model) else { throw SummaryError.message("선택 모델의 이미지 읽기 지원이 확인되지 않았습니다. 이미지 지원 모델을 선택해 주세요.") }
        if let summary, summary.account != account || summary.model != connection.model {
            throw SummaryError.message("생성 당시 계정과 모델(\(summary.model))을 선택한 뒤 다시 시도해 주세요.")
        }
        return (account, connection.model)
    }

    @discardableResult func start(sourceID: UUID, title: String, choices: Set<String>?, region: CGRect?) -> UUID? {
        guard !busy, !unsaved, let store else { return nil }
        failure = nil
        do {
            let (account, model) = try verifyConnection()
            guard store.flushDrawings(), let source = store.note(sourceID) else { throw SummaryError.message(store.errorMessage ?? "원본 저장에 실패했습니다.") }
            let sources = try Self.sources(note: source, choices: choices, region: region, store: store)
            let id = try store.createSummary(source: source, sources: sources, title: title, model: model, account: account)
            resume(id)
            return id
        } catch { failure = error.localizedDescription; return nil }
    }
    func cancel() { task?.cancel() }
    func saveAgain() {
        guard !busy, let retained, let store else { return }
        do {
            var saved = retained.work
            if saved.final != nil { saved.failure = nil }
            try store.saveSummary(retained.id, work: saved, state: retained.state)
            self.retained = nil; unsaved = false; failure = nil
        } catch { failure = "받은 결과를 저장하지 못했습니다. 다시 저장해 주세요. " + error.localizedDescription }
    }
    func resume(_ id: UUID) {
        guard !busy, !unsaved, let store, let summary = store.note(id)?.summary else { return }
        do {
            var saved = try checkpoint(id)
            saved.snapshot.id = id
            if saved.final != nil {
                saved.failure = nil
                try store.saveSummary(id, work: saved, state: .completed)
                failure = nil; return
            }
            _ = try verifyConnection(summary: summary)
            if saved.contextRejected {
                let index = saved.fragments.count
                if index < saved.batches.count, saved.batches[index].count > 1 {
                    let batch = saved.batches[index], middle = batch.count / 2
                    saved.batches.replaceSubrange(index...index, with: [Array(batch[..<middle]), Array(batch[middle...])])
                } else if !saved.mergeInputs.isEmpty {
                    saved.policy.inputTokens = max(4000, saved.policy.inputTokens / 2)
                } else { throw SummaryError.message("한 영역도 요청 한도를 넘었습니다. 보존된 부분 결과를 확인하고 더 작은 범위로 새 요약을 만들어 주세요.") }
                saved.contextRejected = false
            }
            saved.failure = nil
            work = saved; activeID = id; failure = nil; generation = connection.generation
            task = Task { [weak self] in await self?.run(id, summary: summary) }
        } catch { failure = error.localizedDescription }
    }

    private func save(_ id: UUID, state: NoteSummary.State) throws {
        guard let work, let store else { throw CocoaError(.fileNoSuchFile) }
        do { try store.saveSummary(id, work: work, state: state); lastSave = Date() }
        catch {
            retained = (id, work, state); unsaved = true
            throw SummaryError.message("결과를 저장하지 못했습니다. GPT 재요청 없이 ‘다시 저장’을 눌러 주세요. " + error.localizedDescription)
        }
    }
    private func check(_ id: UUID) throws {
        try Task.checkCancellation()
        guard activeID == id, generation == connection.generation,
              store?.note(id)?.deletedAt == nil, store?.note(id) != nil else { throw CancellationError() }
    }

    private func run(_ id: UUID, summary: NoteSummary) async {
        defer { task = nil; generation = nil; activeID = nil; work = nil }
        do {
            guard let store else { return }
            try save(id, state: .preparing)
            while let current = work, current.inputs.count < current.sources.count {
                try check(id)
                let index = current.inputs.count, source = current.sources[index]
                message = "준비 중 · \(index) / \(current.sources.count)영역"
                let input: SummaryInput = try autoreleasepool {
                    guard let page = current.snapshot.pages.first(where: { $0.id == source.pageID }) else { throw CocoaError(.fileReadCorruptFile) }
                    for element in page.elements where element.kind == .image && source.rect.intersects(CGRect(x: element.x, y: element.y, width: element.width, height: element.height)) {
                        guard let name = element.assetName, PageRenderer.image(noteID: id, name: name, store: store) != nil else { throw CocoaError(.fileReadCorruptFile) }
                    }
                    let drawing = try store.drawing(noteID: id, pageID: page.id)
                    let region = try RegionContextService.capture(note: current.snapshot, page: page, drawing: drawing, store: store, rect: source.rect)
                    let name = "summary-input-\(source.id).png"
                    try store.writeSummaryAsset(region.imageData, id: id, name: name)
                    let scale = min(2, 1800 / max(source.rect.width, source.rect.height))
                    let nativeContent = drawing.strokes.contains { $0.renderBounds.intersects(source.rect) } || page.elements.contains {
                        ($0.kind == .image || !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) && source.rect.intersects(CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height))
                    }
                    var contentPresent = nativeContent
                    if !contentPresent && !page.pdfRegions.isEmpty { contentPresent = try Self.hasVisiblePixels(region.imageData) }
                    let imageTokens = 1024 + 256 * Int(ceil(source.rect.width*scale/512)) * Int(ceil(source.rect.height*scale/512))
                    return SummaryInput(source: source, imageAsset: name, text: region.extractedText, imageBytes: region.imageData.count, imageHash: MemoryHash.data(region.imageData), contentPresent: contentPresent, imageTokens: imageTokens)
                }
                work?.inputs.append(input)
                try save(id, state: .preparing)
                await Task.yield()
            }
            guard work!.inputs.contains(where: \.contentPresent) else { throw SummaryError.message("선택 범위에 요약할 내용이 없습니다. GPT 요청을 보내지 않았습니다.") }
            if work!.batches.isEmpty { work!.batches = try SummaryPrompt.batches(work!.inputs, policy: work!.policy) }
            try save(id, state: .summarizing)
            while work!.fragments.count < work!.batches.count {
                try check(id)
                let index = work!.fragments.count, batch = work!.batches[index]
                message = "요약 중 · \(index) / \(work!.batches.count)묶음"
                let inputs = batch.map { work!.inputs[$0] }
                let body = try imageRequest(id: id, inputs: inputs, model: summary.model)
                let result = try await request(body, id: id, account: summary.account)
                try SummaryPrompt.validate(result, sources: inputs.map { $0.source.id })
                work!.fragments.append(SummaryFragment(sources: inputs.map { $0.source.id }, text: result))
                work!.partial = ""
                if work!.batches.count == 1 { work!.final = result }
                try save(id, state: .summarizing)
            }
            if work!.fragments.count == 1 { work!.final = work!.fragments[0].text }
            else { try await merge(id: id, summary: summary) }
            try check(id)
            message = "저장 중"
            try save(id, state: .completed)
            message = "완료"
        } catch {
            if store?.note(id) == nil {
                retained = nil; unsaved = false; failure = "요약 노트가 삭제되어 작업을 중단했습니다."
                return
            }
            let cancelled = Task.isCancelled || error is CancellationError
            let state: NoteSummary.State = cancelled ? .cancelled : .failed
            let text = cancelled ? "중단했습니다. 완료된 묶음은 보존되며 다시 시도할 수 있습니다." : error.localizedDescription
            work?.failure = text
            if let error = error as? PlanFailure {
                work?.contextRejected = error.kind == .context
                if generation == connection.generation { connection.handle(error, duringInference: true) }
            }
            failure = text
            if !unsaved {
                do { try save(id, state: state) } catch { failure = error.localizedDescription }
            } else if let work { retained = (id, work, work.final == nil ? state : .completed) }
        }
    }

    private static func hasVisiblePixels(_ data: Data) throws -> Bool {
        guard let image = UIImage(data: data)?.cgImage else { throw CocoaError(.fileReadCorruptFile) }
        var pixels = [UInt8](repeating: 255, count: image.width * image.height * 4)
        guard let context = CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CocoaError(.fileReadCorruptFile) }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return stride(from: 0, to: pixels.count, by: 4).contains { pixels[$0] < 255 || pixels[$0+1] < 255 || pixels[$0+2] < 255 }
    }

    private func imageRequest(id: UUID, inputs: [SummaryInput], model: String) throws -> PlanRequest {
        guard let store else { throw CocoaError(.fileNoSuchFile) }
        let content = try inputs.flatMap { input -> [PlanRequest.Content] in
            let data = try store.summaryAsset(id, name: input.imageAsset)
            guard data.count == input.imageBytes, MemoryHash.data(data) == input.imageHash, UIImage(data: data) != nil else { throw SummaryError.message("보존된 입력을 읽을 수 없습니다. 원본으로 새 요약을 만들어 주세요.") }
            return [.init(type: "input_text", text: "[\(input.source.id)] \(input.source.label)\n보조 추출 텍스트:\n" + input.text),
                    .init(type: "input_image", image_url: "data:image/png;base64," + data.base64EncodedString())]
        }
        return PlanRequest(model: model, instructions: SummaryPrompt.instructions, input: [.init(role: "user", content: content)])
    }
    private func request(_ body: PlanRequest, id: UUID, account: String) async throws -> String {
        try check(id)
        let textBytes = body.instructions.utf8.count + body.input.flatMap(\.content).reduce(0) { $0 + ($1.text?.utf8.count ?? 0) }
        guard textBytes <= work!.policy.usable, try JSONEncoder().encode(body).count <= work!.policy.maxHTTPBytes else { throw ContextAction.payloadOverflow }
        let tokens = try await connection.credentials.credentials(client: account)
        try check(id)
        // The previous partial response remains on disk until a new response arrives.
        let result = try await ChatGPTPlanTransport.stream(request: body, token: tokens.access_token, http: http) { [weak self] result in
            guard let self, self.activeID == id, self.generation == self.connection.generation, !self.unsaved else { return }
            if !result.text.isEmpty { self.work?.partial = result.text }
            if result.status == .streaming && Date().timeIntervalSince(self.lastSave) >= 1 {
                do { try self.save(id, state: .summarizing) } catch { self.failure = error.localizedDescription; self.task?.cancel() }
            }
        }
        try check(id)
        if let failure = result.failure { throw failure }
        guard result.status == .completed else { throw SummaryError.message("응답이 완료되지 않았습니다. 부분 결과를 보존했습니다.") }
        return result.text
    }

    private func merge(id: UUID, summary: NoteSummary) async throws {
        if work!.mergeInputs.isEmpty { work!.mergeInputs = work!.fragments }
        while work!.final == nil {
            try check(id)
            let inputs = work!.mergeInputs
            if work!.mergeCursor == inputs.count {
                let outputs = work!.mergeOutputs
                if outputs.count == 1 { work!.final = outputs[0].text; break }
                guard outputs.reduce(0, { $0 + $1.text.utf8.count }) < inputs.reduce(0, { $0 + $1.text.utf8.count }) else {
                    throw SummaryError.message("통합 결과가 충분히 줄어들지 않았습니다. 중간 결과를 보존했습니다.")
                }
                work!.mergeInputs = outputs; work!.mergeOutputs = []; work!.mergeCursor = 0
                try save(id, state: .summarizing)
                continue
            }
            var end = work!.mergeCursor
            var selected: [SummaryFragment] = [], tokens = SummaryPrompt.instructions.utf8.count + 1024
            while end < inputs.count && tokens + inputs[end].text.utf8.count <= work!.policy.usable {
                selected.append(inputs[end]); tokens += inputs[end].text.utf8.count; end += 1
            }
            if selected.isEmpty {
                // Split an unusually long answer without dropping characters. The
                // next stage merges these pieces again, retaining the same sources.
                let fragment = inputs[end]
                let limit = work!.policy.usable - SummaryPrompt.instructions.utf8.count - 2048
                guard limit >= 1000 else { throw SummaryError.message("통합 요청 한도가 너무 작습니다. 보존된 결과를 확인해 주세요.") }
                var pieces: [SummaryFragment] = [], text = "", size = 0
                for character in fragment.text {
                    let count = String(character).utf8.count
                    if size + count > limit && !text.isEmpty { pieces.append(.init(sources: fragment.sources, text: text)); text = ""; size = 0 }
                    text.append(character); size += count
                }
                if !text.isEmpty { pieces.append(.init(sources: fragment.sources, text: text)) }
                let originals = pieces
                pieces = originals.enumerated().map { index, piece in
                    let before = index > 0 ? "[앞 경계 문맥]\n" + String(originals[index-1].text.suffix(100)) + "\n" : ""
                    let after = index+1 < originals.count ? "\n[뒤 경계 문맥]\n" + String(originals[index+1].text.prefix(100)) : ""
                    return SummaryFragment(sources: piece.sources, text: before + piece.text + after)
                }
                work!.mergeInputs.replaceSubrange(end...end, with: pieces)
                try save(id, state: .summarizing)
                continue
            }
            message = "통합 중 · \(work!.mergeCursor) / \(inputs.count)묶음"
            let sources = Array(Set(selected.flatMap(\.sources))).sorted()
            let text = "다음 중간 요약을 하나로 통합하세요. 출처·핵심 조건·수식·불확실성을 보존하세요. 기존 출처 식별자를 유지하세요.\n\n" + selected.map(\.text).joined(separator: "\n\n---\n\n")
            let body = PlanRequest(model: summary.model, instructions: SummaryPrompt.instructions, input: [.init(role: "user", content: [.init(type: "input_text", text: text)])])
            let result = try await request(body, id: id, account: summary.account)
            try SummaryPrompt.validate(result, sources: sources)
            work!.mergeOutputs.append(.init(sources: sources, text: result)); work!.mergeCursor = end; work!.partial = ""
            try save(id, state: .summarizing)
        }
    }
}
