#if DEBUG
import Foundation

/// Original acceptance documents, intentionally separate from live evidence.
enum SourceDiagnosticDevelopmentFixtures {
    static let origin = "https://diagnostic.fixture"
    static func isEnabled(_ source: DemoSource) -> Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-testing") &&
        ProcessInfo.processInfo.arguments.contains("--source-diagnostic-fixtures") && source.url == origin
    }
    static var package: Data {
        get throws {
            try JSONSerialization.data(withJSONObject: [
                "bookSourceName": "竹影诊断原创夹具", "bookSourceUrl": origin,
                "bookSourceType": 0, "enabled": true, "searchUrl": "/search?q={{key}}",
                "loginUi": [["name": "原创账号", "type": "text"]],
                "ruleSearch": ["bookList": "$.books[*]", "name": "$.name", "bookUrl": "$.url"],
                "ruleBookInfo": ["name": "$.name", "intro": "$.intro", "tocUrl": "$.toc"],
                "ruleToc": ["chapterList": "$.chapters[*]", "chapterName": "$.name", "chapterUrl": "$.url"],
                "ruleContent": ["content": "@js:JSON.parse(java.ajax(chapter.url + '?native=1')).text"]
            ], options: [.prettyPrinted, .sortedKeys])
        }
    }
    static func transport() -> any HTTPTransport { SourceDiagnosticDevelopmentTransport() }
    static func write(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try package.write(to: directory.appendingPathComponent("竹影诊断原创夹具.json"))
    }
}

struct SourceDiagnosticDevelopmentTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        guard let url = request.url else { throw ContentFailure.invalidResponse }
        try await Task.sleep(for: .milliseconds(5))
        let parts = url.path.split(separator: "/"), query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        let needsLogin = query?.contains { $0.name == "q" && $0.value == "登录" } == true
        let object: [String: Any]
        switch parts.first {
        case "search": object = ["books": [["name": "竹林来信", "url": "/book/a"], ["name": "山谷回声", "url": "/book/b"]]]
        case "book": object = ["name": parts.last == "a" ? "竹林来信" : "山谷回声", "intro": "竹影原创诊断作品", "toc": "/toc/" + String(parts.last!)]
        case "toc": object = ["chapters": (1...3).map { ["name": "第\($0)章 原创", "url": "/chapter/\(parts.last!)/\($0)"] }]
        case "chapter": object = ["text": "\(parts.dropFirst().joined(separator: "-"))：竹影原创正文。\n山间来信记录了独立的故事。"]
        default: throw ContentFailure.invalidResponse
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
        return (data, HTTPURLResponse(url: url, statusCode: needsLogin ? 401 : 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
    }
}
#endif
