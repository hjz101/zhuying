#if DEBUG
import Foundation

/// Original, deterministic HTTP documents. The app still imports the package,
/// configures LegadoBookSource, runs QuickJS and uses the normal reader/cache.
enum LegadoDevelopmentFixtures {
    static func isEnabled(_ source: DemoSource) -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--ui-testing") && arguments.contains("--legado-fixtures") &&
            ["https://legado-html.fixture", "https://legado-js.fixture"].contains(source.url)
    }
    static func package(scripted: Bool) throws -> Data {
        let host = scripted ? "https://legado-js.fixture" : "https://legado-html.fixture"
        var row: [String: Any] = [
            "bookSourceName": scripted ? "竹影阅读3.0脚本原型" : "竹影阅读3.0规则原型",
            "bookSourceUrl": host, "bookSourceType": 0, "enabled": true,
            "searchUrl": "/search?q={{key}}&page={{page}}",
            "loginUi": [
                ["name": "测试账号", "type": "text"], ["name": "测试密码", "type": "password"],
                ["name": "保存测试登录", "type": "button", "action": "saveFixtureLogin()"],
                ["name": "打开测试网页登录", "type": "button", "action": "openFixtureBrowser()"]
            ],
            "loginUrl": "function saveFixtureLogin(){source.putLoginInfo(JSON.stringify(result));java.toast('测试信息已保存，尚未验证');} function openFixtureBrowser(){java.showBrowser('" + host + "/login','<html><head><title>竹影原创网页登录</title></head><body><h1>竹影原创网页登录</h1><p>完成后返回原登录表单。</p></body></html>',\"document.body.dataset.ready='yes';document.querySelector('h1').textContent='网页登录脚本已就绪'\");}",
            "ruleSearch": ["bookList": "class.book", "name": "class.title@text", "author": "class.author@text", "bookUrl": "tag.a@href"],
            "ruleBookInfo": ["name": "tag.h1@text", "author": "class.author@text", "intro": "class.intro@text", "tocUrl": "id.toc@href"],
            "ruleToc": ["chapterList": "class.chapter", "chapterName": "tag.a@text", "chapterUrl": "tag.a@href"],
            "ruleContent": ["content": "class.content@html"]
        ]
        if scripted {
            row["jsLib"] = "function cleanTitle(value) { return value.trim(); }"
            row["ruleSearch"] = ["bookList": "@js:JSON.parse(java.ajax('" + host + "/api/catalog')).books",
                                 "name": "@js:cleanTitle(result.name)", "author": "$.author", "bookUrl": "$.url"]
            row["ruleContent"] = ["content": "@js:JSON.parse(java.ajax('" + host + "/api/body?chapter=' + encodeURIComponent(chapter.url))).paragraphs"]
        }
        return try JSONSerialization.data(withJSONObject: row, options: [.prettyPrinted, .sortedKeys])
    }
    static func write(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try package(scripted: false).write(to: directory.appendingPathComponent("竹影阅读3.0规则源.json"))
        try package(scripted: true).write(to: directory.appendingPathComponent("竹影阅读3.0脚本源.json"))
    }
}

struct LegadoDevelopmentTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        guard let url = request.url else { throw ContentFailure.invalidResponse }
        let requestedChapter = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "chapter" })?.value
        let chapterPath = requestedChapter.flatMap(URL.init(string:))?.path ?? url.path
        let chapter = chapterPath.hasSuffix("/2") ? 2 : 1
        let title = "山间来信"
        let text: String
        var mime = "text/html; charset=utf-8"
        switch url.path {
        case "/search":
            let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "page" })?.value
            text = page == "2" ? "<html><body></body></html>" : "<html><body><article class='book'><a href='/book/a'><span class='title'>\(title)</span></a><span class='author'>竹影原创</span></article></body></html>"
        case "/api/catalog":
            mime = "application/json"
            text = "{\"books\":[{\"name\":\" 山间来信 \",\"author\":\"竹影原创\",\"url\":\"/book/a\"}]}"
        case "/book/a": text = "<html><body><h1>\(title)</h1><span class='author'>竹影原创</span><p class='intro'>原创兼容测试作品，正文来自规则实际提取。</p><a id='toc' href='/toc/a'>目录</a></body></html>"
        case "/toc/a": text = "<html><body><ul><li class='chapter'><a href='/chapter/1'>第一章 来信</a></li><li class='chapter'><a href='/chapter/2'>第二章 回声</a></li></ul></body></html>"
        case "/api/body":
            mime = "application/json"
            text = "{\"paragraphs\":[\"第\(chapter)章通过同步脚本取得的真实测试正文。\",\"山间的来信写着不同的故事，读者记下这段文字。\"]}"
        default: text = "<html><body><div class='content'><p>第\(chapter)章通过阅读规则取得的真实测试正文。</p><p>山间的来信写着不同的故事，读者记下这段文字。</p></div></body></html>"
        }
        return (Data(text.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": mime])!)
    }
}
#endif
