import Foundation

struct DownloadedBookFile: Sendable {
    let data: Data
    let suggestedName: String?
}

protocol BookImportDownloading: Sendable {
    func fetch(_ url: URL) async throws -> DownloadedBookFile
}

private final class HTTPSImportRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme?.lowercased() == "https" ? request : nil)
    }
}

/// Stream a bounded response. Cancelling parsing also cancels its network
/// session; no unbounded download or abandoned temporary file is left behind.
struct BoundedBookDownloader: BookImportDownloading {
    let maximumBytes: Int
    let configuration: @Sendable () -> URLSessionConfiguration
    init(maximumBytes: Int = BookImporter.maximumBytes, configuration: @escaping @Sendable () -> URLSessionConfiguration = { .ephemeral }) {
        self.maximumBytes = maximumBytes; self.configuration = configuration
    }
    func fetch(_ url: URL) async throws -> DownloadedBookFile {
        _ = try BookImporter.remoteURL(url.absoluteString)
        try Task.checkCancellation()
        let session = URLSession(configuration: configuration(), delegate: HTTPSImportRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("text/plain, application/pdf", forHTTPHeaderField: "Accept")
        let (bytes, rawResponse) = try await session.bytes(for: request)
        guard let response = rawResponse as? HTTPURLResponse, response.url?.scheme?.lowercased() == "https",
              (200..<300).contains(response.statusCode) else { throw BookImportError.message("下载失败，请检查链接后重试。") }
        if let mime = response.mimeType?.lowercased(), !["text/plain", "text/txt", "application/pdf", "application/octet-stream", "binary/octet-stream"].contains(mime) {
            throw BookImportError.message("链接未返回 TXT 或 PDF 文件，请使用文件直链。")
        }
        guard response.expectedContentLength <= maximumBytes else { throw sizeError }
        var data = Data()
        if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
        for try await byte in bytes {
            if data.count >= maximumBytes { throw sizeError }
            data.append(byte)
        }
        try Task.checkCancellation()
        return .init(data: data, suggestedName: response.suggestedFilename)
    }
    private var sizeError: BookImportError {
        .message("下载文件超过 \(ByteCountFormatter.string(fromByteCount: Int64(maximumBytes), countStyle: .file))，请拆分后导入。")
    }
}

protocol BookImportLoading: Sendable {
    func load(_ input: BookImportInput, encoding: ImportEncoding) async throws -> PreparedBookImport
}
struct NativeBookImportLoader: BookImportLoading {
    func load(_ input: BookImportInput, encoding: ImportEncoding) async throws -> PreparedBookImport {
        try await BookImporter.load(input, encoding: encoding)
    }
}
