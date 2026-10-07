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

/// Public PencilKit identifiers that remain unchanged by transforms and masks.
/// Kept outside the drawing bytes so grouping never flattens editable strokes.
struct InkStrokeID: Codable, Hashable {
    var creationDate: Date
    var randomSeed: UInt32
}

struct InkGroup: Codable, Identifiable, Equatable {
    var id = UUID()
    var strokeIDs: [InkStrokeID]
}

struct NotePage: Codable, Identifiable, Equatable {
    var id = UUID()
    var paper: PaperStyle = .plain
    var width: Double = 768
    var height: Double = 1024
    var pdfPageIndex: Int?
    var elements: [PageElement] = []
    // Older pages decode without a migration. Erased members can remain here so
    // undo restores their group; selection only expands to currently live ink.
    var inkGroups: [InkGroup]?
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
    var parentID: UUID?
    // Older project libraries did not store a color; nil keeps the blue default.
    var cover: CoverColor?
    var preferredProvider: String?
    var preferredModel: String?
}

struct Library: Codable, Equatable {
    var version = 1
    var projectsMigrated: Bool?
    var folders: [NoteFolder] = []
    var projects: [NoteProject] = []
    var notebooks: [Notebook] = []

    init(version: Int = 1, folders: [NoteFolder] = [], projects: [NoteProject] = [], notebooks: [Notebook] = []) {
        self.version = version
        self.folders = folders
        self.projects = projects
        self.notebooks = notebooks
    }

    private enum CodingKeys: String, CodingKey { case version, folders, projects, notebooks, projectsMigrated }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        projectsMigrated = try values.decodeIfPresent(Bool.self, forKey: .projectsMigrated)
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
        guard let removed = projects.first(where: { $0.id == id }) else { return }
        projects.removeAll { $0.id == id }
        for index in projects.indices where projects[index].parentID == id {
            projects[index].parentID = removed.parentID
        }
        for index in notebooks.indices where notebooks[index].projectID == id {
            notebooks[index].projectID = removed.parentID
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


/// Local drag payloads carry typed IDs only; every destination is validated before saving.
enum LibraryItem: Hashable, Identifiable {
    case project(UUID), note(UUID)
    var id: String {
        switch self {
        case .project(let id): return "notemargin:project:" + id.uuidString
        case .note(let id): return "notemargin:note:" + id.uuidString
        }
    }
    init?(payload: String) {
        let parts = payload.split(separator: ":")
        guard parts.count == 3, parts[0] == "notemargin", let id = UUID(uuidString: String(parts[2])) else { return nil }
        switch parts[1] {
        case "project": self = .project(id)
        case "note": self = .note(id)
        default: return nil
        }
    }
}

extension Library {
    func projectPath(_ id: UUID) -> [NoteProject] {
        var result: [NoteProject] = [], seen = Set<UUID>(), next: UUID? = id
        while let id = next, seen.insert(id).inserted, let project = projects.first(where: { $0.id == id }) {
            result.insert(project, at: 0); next = project.parentID
        }
        return result
    }
    func canMove(_ item: LibraryItem, to parent: UUID?) -> Bool {
        guard parent == nil || projects.contains(where: { $0.id == parent }) else { return false }
        switch item {
        case .project(let id):
            return projects.contains(where: { $0.id == id }) &&
                !(parent.map { projectPath($0).contains(where: { $0.id == id }) } ?? false)
        case .note(let id): return notebooks.contains { $0.id == id && $0.deletedAt == nil }
        }
    }
    @discardableResult mutating func move(_ item: LibraryItem, to parent: UUID?) -> Bool {
        guard canMove(item, to: parent) else { return false }
        switch item {
        case .project(let id): projects[projects.firstIndex(where: { $0.id == id })!].parentID = parent
        case .note(let id): assignProject(noteID: id, projectID: parent)
        }
        return true
    }
    /// Keep original folder metadata for recovery. Existing project IDs (and chat links) remain stable.
    @discardableResult mutating func migrateFoldersToProjects() -> Bool {
        guard projectsMigrated != true else { return false }
        let originalProjects = projects
        var mapping: [UUID: UUID] = [:]
        for folder in folders {
            let id = projects.contains(where: { $0.id == folder.id }) ? UUID() : folder.id
            projects.append(NoteProject(id: id, title: folder.title))
            mapping[folder.id] = id
        }
        for project in originalProjects where project.parentID == nil {
            let members = notebooks.filter { $0.projectID == project.id }
            if let folder = members.first?.folderID, members.allSatisfy({ $0.folderID == folder }),
               let parent = mapping[folder], canMove(.project(project.id), to: parent) {
                move(.project(project.id), to: parent)
            }
        }
        for index in notebooks.indices where notebooks[index].projectID == nil {
            if let folder = notebooks[index].folderID { notebooks[index].projectID = mapping[folder] }
        }
        projectsMigrated = true
        return true
    }
}


struct ProjectTreeEntry: Identifiable {
    let project: NoteProject
    let depth: Int
    var id: UUID { project.id }
}

extension Library {
    func projectTree(collapsed: Set<UUID> = []) -> [ProjectTreeEntry] {
        let children = Dictionary(grouping: projects, by: \.parentID)
        var result: [ProjectTreeEntry] = [], visited = Set<UUID>()
        func appendChildren(of parent: UUID?, depth: Int) {
            for project in (children[parent] ?? []).sorted(by: { $0.title.localizedStandardCompare($1.title) == .orderedAscending }) {
                guard visited.insert(project.id).inserted else { continue }
                result.append(ProjectTreeEntry(project: project, depth: depth))
                if !collapsed.contains(project.id) { appendChildren(of: project.id, depth: depth + 1) }
            }
        }
        appendChildren(of: nil, depth: 0)
        return result
    }
}
