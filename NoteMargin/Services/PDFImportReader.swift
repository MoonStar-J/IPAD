import Foundation

struct PDFImportContents: Sendable {
    let title: String
    let data: Data
}

/// Own the selected bytes before a provider URL or security scope expires.
/// Reading a cloud document is coordinated off the main thread and never moves
/// or modifies the original. The document picker also requests a local copy.
enum PDFImportReader {
    static func read(_ url: URL) async throws -> PDFImportContents {
        try Task.checkCancellation()
        guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        let coordination = PDFReadCoordination()
        let work = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            var coordinationError: NSError?
            var result: Result<Data, Error>?
            coordination.coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { coordinatedURL in
                result = Result {
                    try Task.checkCancellation()
                    // Do not memory-map: the imported bytes must survive provider eviction.
                    return try Data(contentsOf: coordinatedURL)
                }
            }
            try Task.checkCancellation()
            if let coordinationError { throw coordinationError }
            guard let result else { throw CocoaError(.fileReadUnknown) }
            return PDFImportContents(title: url.deletingPathExtension().lastPathComponent, data: try result.get())
        }
        return try await withTaskCancellationHandler {
            let contents = try await work.value
            try Task.checkCancellation()
            return contents
        } onCancel: {
            work.cancel()
            coordination.coordinator.cancel()
        }
    }
}

// NSFileCoordinator.cancel() is explicitly thread-safe; all coordination and
// file access happen on the single worker task above.
private final class PDFReadCoordination: @unchecked Sendable {
    let coordinator = NSFileCoordinator(filePresenter: nil)
}
