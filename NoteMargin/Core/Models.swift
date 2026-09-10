import Foundation

enum PaperStyle: String, Codable, CaseIterable, Identifiable {
    case plain, ruled, grid, dotted
    var id: String { rawValue }
    var title: String {
        switch self {
        case .plain: return "무지"
        case .ruled: return "줄 노트"
        case .grid: return "격자"
        case .dotted: return "도트"
        }
    }
}

enum CoverColor: String, Codable, CaseIterable, Identifiable {
    case blue, sage, sand, rose, graphite
    var id: String { rawValue }
    var title: String {
        switch self {
        case .blue: return "블루"
        case .sage: return "세이지"
        case .sand: return "샌드"
        case .rose: return "로즈"
        case .graphite: return "그라파이트"
        }
    }
}

struct PageElement: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case text, image }
    var id = UUID()
    var kind: Kind
    var text = ""
    var assetName: String?
    var x: Double = 80
    var y: Double = 100
    var width: Double = 400
    var height: Double = 160
    var fontSize: Double = 24
}

enum PDFImportLayout: String, CaseIterable, Identifiable {
    case continuous, paged
    var id: String { rawValue }
    var title: String { self == .continuous ? "하나로 이어 붙이기" : "페이지별로 보기" }
}

struct PDFSegment: Codable, Equatable {
    let pageIndex: Int
    let y: Double
    let height: Double
}

struct NotePage: Codable, Identifiable, Equatable {
    var id = UUID()
    var paper: PaperStyle = .plain
    var width: Double = 768
    var height: Double = 1024
    var pdfPageIndex: Int?
    var elements: [PageElement] = []
    // Optional for compatibility with notebooks saved before continuous import.
    var pdfSegments: [PDFSegment]?
    var pdfFitToPage: Bool?
    var isContinuousPDF: Bool { pdfSegments != nil }
    var pdfRegions: [PDFSegment] {
        pdfSegments ?? pdfPageIndex.map { [PDFSegment(pageIndex: $0, y: 0, height: height)] } ?? []
    }

    static func importedPDFPages(_ pages: [NotePage], layout: PDFImportLayout) throws -> [NotePage] {
        guard !pages.isEmpty, pages.allSatisfy({ $0.pdfPageIndex != nil && $0.width == 768 && $0.height.isFinite && $0.height > 0 }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard layout == .continuous, pages.count > 1 else { return pages }
        var y = 0.0
        let segments = pages.map { page -> PDFSegment in
            defer { y += page.height }
            return PDFSegment(pageIndex: page.pdfPageIndex!, y: y, height: page.height)
        }
        guard y.isFinite else { throw CocoaError(.fileReadCorruptFile) }
        return [NotePage(width: 768, height: y, pdfSegments: segments, pdfFitToPage: true)]
    }
}

struct Notebook: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var cover: CoverColor = .blue
    var folderID: UUID?
    var projectID: UUID?
    var isFavorite = false
    var createdAt = Date()
    var updatedAt = Date()
    var deletedAt: Date?
    var pages: [NotePage] = [NotePage()]
    var pdfAssetName: String?
}

struct NoteFolder: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
}

struct NoteProject: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var agentInstructions = ""
    var preferredProvider: String?
    var preferredModel: String?
}

struct Library: Codable, Equatable {
    var version = 1
    var folders: [NoteFolder] = []
    var projects: [NoteProject] = []
    var notebooks: [Notebook] = []

    init(version: Int = 1, folders: [NoteFolder] = [], projects: [NoteProject] = [], notebooks: [Notebook] = []) {
        self.version = version
        self.folders = folders
        self.projects = projects
        self.notebooks = notebooks
    }

    private enum CodingKeys: String, CodingKey { case version, folders, projects, notebooks }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        folders = try values.decode([NoteFolder].self, forKey: .folders)
        projects = try values.decodeIfPresent([NoteProject].self, forKey: .projects) ?? []
        notebooks = try values.decode([Notebook].self, forKey: .notebooks)
    }

    mutating func removeFolder(_ id: UUID) {
        folders.removeAll { $0.id == id }
        for index in notebooks.indices where notebooks[index].folderID == id {
            notebooks[index].folderID = nil
        }
    }

    mutating func removeProject(_ id: UUID) {
        projects.removeAll { $0.id == id }
        for index in notebooks.indices where notebooks[index].projectID == id {
            notebooks[index].projectID = nil
        }
    }

    @discardableResult
    mutating func assignProject(noteID: UUID, projectID: UUID?) -> Bool {
        guard projectID == nil || projects.contains(where: { $0.id == projectID }),
              let index = notebooks.firstIndex(where: { $0.id == noteID }) else { return false }
        notebooks[index].projectID = projectID
        notebooks[index].updatedAt = Date()
        return true
    }
}

enum LibraryFilter: Hashable {
    case all, favorites, trash, folder(UUID), project(UUID), unassigned
    func includes(_ note: Notebook) -> Bool {
        switch self {
        case .all: return note.deletedAt == nil
        case .favorites: return note.deletedAt == nil && note.isFavorite
        case .trash: return note.deletedAt != nil
        case .folder(let id): return note.deletedAt == nil && note.folderID == id
        case .project(let id): return note.deletedAt == nil && note.projectID == id
        case .unassigned: return note.deletedAt == nil && note.projectID == nil
        }
    }
}

enum NoteSort: String, CaseIterable, Identifiable {
    case modified, created, title
    var id: String { rawValue }
    var label: String {
        switch self {
        case .modified: return "최근 수정순"
        case .created: return "최근 생성순"
        case .title: return "이름순"
        }
    }
}

extension Library {
    func notes(in filter: LibraryFilter, query: String, sort: NoteSort) -> [Notebook] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return notebooks.filter {
            filter.includes($0) && (query.isEmpty || $0.title.localizedStandardContains(query) ||
                $0.pages.contains { $0.elements.contains { $0.text.localizedStandardContains(query) } })
        }.sorted {
            switch sort {
            case .modified: return $0.updatedAt > $1.updatedAt
            case .created: return $0.createdAt > $1.createdAt
            case .title: return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        }
    }
}
