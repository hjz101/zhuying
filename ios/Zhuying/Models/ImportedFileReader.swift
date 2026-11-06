import Foundation

/// All local import paths use coordinated, scoped, bounded reads. This also
/// handles files handed to the app directly by Files or another file provider.
enum ImportedFileReader {
    static func read(_ url: URL, maximumBytes: Int) throws -> Data {
        guard url.isFileURL, maximumBytes > 0 else { throw CocoaError(.fileReadUnsupportedScheme) }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { file in
            result = Result {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true else { throw BookImportError.message("请选择文件，文件夹暂不支持导入。") }
                if let size = values.fileSize, size > maximumBytes { throw sizeError(maximumBytes) }
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                var data = Data()
                while true {
                    try Task.checkCancellation()
                    let chunk = try handle.read(upToCount: min(64 * 1024, maximumBytes - data.count + 1)) ?? Data()
                    if chunk.isEmpty { break }
                    guard chunk.count <= maximumBytes - data.count else { throw sizeError(maximumBytes) }
                    data.append(chunk)
                }
                guard !data.isEmpty else { throw BookImportError.message("文件为空，请选择有内容的文件。") }
                return data
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }

    private static func sizeError(_ maximumBytes: Int) -> BookImportError {
        .message("文件超过大小限制（\(ByteCountFormatter.string(fromByteCount: Int64(maximumBytes), countStyle: .file))），请选择较小的文件。")
    }
}
