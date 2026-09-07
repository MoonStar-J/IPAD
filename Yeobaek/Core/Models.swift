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

struct NotePage: Codable, Identifiable, Equatable {
    var id = UUID()
    var paper: PaperStyle = .plain
    var width: Double = 768
    var height: Double = 1024
    var pdfPageIndex: Int?
    var elements: [PageElement] = []
}

struct Notebook: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var cover: CoverColor = .blue
    var folderID: UUID?
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

struct Library: Codable, Equatable {
    var version = 1
    var folders: [NoteFolder] = []
    var notebooks: [Notebook] = []

    mutating func removeFolder(_ id: UUID) {
        folders.removeAll { $0.id == id }
        for index in notebooks.indices where notebooks[index].folderID == id {
            notebooks[index].folderID = nil
        }
    }
}

enum LibraryFilter: Hashable {
    case all, favorites, trash, folder(UUID)
    func includes(_ note: Notebook) -> Bool {
        switch self {
        case .all: return note.deletedAt == nil
        case .favorites: return note.deletedAt == nil && note.isFavorite
        case .trash: return note.deletedAt != nil
        case .folder(let id): return note.deletedAt == nil && note.folderID == id
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
