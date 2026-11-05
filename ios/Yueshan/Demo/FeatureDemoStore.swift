import Foundation
import Combine

enum DemoLoginStatus: String {
    case signedOut, signedIn, expired
    var title: String { switch self { case .signedOut: "未登录"; case .signedIn: "已登录"; case .expired: "登录已过期" } }
    var action: String { switch self { case .signedOut: "登录"; case .signedIn: "管理登录"; case .expired: "重新登录" } }
}

struct DemoSource: Identifiable, Equatable {
    let id: String
    var name: String
    var group = "小说"
    var enabled = true
    var detail: String
    var url = "https://books.example"
    var loginStatus: DemoLoginStatus = .signedOut
}
struct DemoFile: Identifiable {
    let id: UUID = UUID()
    var name: String
    let detail: String
}
struct DemoBookmark: Identifiable {
    let id = UUID()
    let bookID: String
    let chapter: Int
    let paragraph: Int
    let offset: Int
}
struct DemoTextHit: Identifiable {
    var id: String { "\(bookID):\(chapter):\(paragraph)" }
    let bookID: String
    let chapter: Int
    let paragraph: Int
    let offset: Int
    let text: String
}
struct DemoOutcome {
    let success: Bool
    let title: String
    let detail: String
}

@MainActor
final class FeatureDemoStore: ObservableObject {
    @Published var values: [String: String] = [:]
    @Published var sources = [
        DemoSource(id: "shanhai", name: "山海书库", detail: "143 ms · 搜索 / 详情 / 正文"),
        DemoSource(id: "yunjian", name: "云间小说", detail: "216 ms · 章节更新及时", url: "https://yunjian.example", loginStatus: .expired),
        DemoSource(id: "paper", name: "纸上漫游", group: "漫画", detail: "超时 · 演示失败状态", url: "https://paper.example", loginStatus: .signedIn),
    ]
    @Published var groups = ["追更中", "待读", "已读完"]
    @Published var bookGroups: [String: String] = ["changfeng": "追更中", "stars": "追更中", "sunset": "已读完"]
    @Published var bookSources: [String: String] = [:]
    @Published var bookmarks: [DemoBookmark] = [.init(bookID: "changfeng", chapter: 2, paragraph: 3, offset: 0)]
    @Published var files = [DemoFile(name: "长风渡山海.txt", detail: "UTF-8 · 1.8 MB"), DemoFile(name: "日落之前.epub", detail: "8 章 · 4.2 MB"), DemoFile(name: "山海图志.pdf", detail: "12 页 · 8.6 MB"), DemoFile(name: "山间来信.zip", detail: "3 个文件 · 12.4 MB")]
    @Published var backups = ["阅山_2026-11-03.qibackup", "阅山_2026-11-01.qibackup"]
    @Published var cacheMB = ["章节": 12.4, "图片": 48.6, "音频": 36.2]
    @Published var outcomes: [String: DemoOutcome] = [:]
    @Published var playerVisible = false
    @Published var isPlaying = false
    @Published var audioPosition = 0.28
    @Published var selectedCover = "changfeng"
    @Published var downloadProgress = 0.35
    @Published var downloadPaused = true

    func prepareSource(_ feature: DemoFeature, scope: String) {
        guard let source = sources.first(where: { $0.id == scope }), feature.id == "sourceEdit" else { return }
        for (id, value) in [("name", source.name), ("url", source.url)] {
            let key = "\(feature.id):\(scope):\(id)"
            if values[key] == nil { values[key] = value }
        }
    }
    func setSourceLogin(_ id: String, status: DemoLoginStatus) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[index].loginStatus = status
    }
    func removeSource(_ id: String) {
        sources.removeAll { $0.id == id }
        bookSources = bookSources.filter { $0.value != id }
        for feature in FeatureCatalog.all { reset(feature, scope: id) }
    }

    func value(_ feature: DemoFeature, _ field: DemoField, scope: String = "main") -> String {
        values["\(feature.id):\(scope):\(field.id)"] ?? field.initial
    }
    func set(_ value: String, feature: DemoFeature, field: DemoField, scope: String = "main") {
        values["\(feature.id):\(scope):\(field.id)"] = value
    }
    func text(_ feature: DemoFeature, _ id: String, scope: String = "main") -> String {
        guard let field = feature.fields.first(where: { $0.id == id }) else { return "" }
        return value(feature, field, scope: scope)
    }
    func reset(_ feature: DemoFeature, scope: String) {
        let prefix = "\(feature.id):\(scope):"
        values = values.filter { !$0.key.hasPrefix(prefix) }
        outcomes.removeValue(forKey: "\(feature.id):\(scope)")
    }
    func addBookmark(book: Book, progress: ReadingProgress?) {
        let chapter = progress?.chapter ?? 0, paragraph = progress?.paragraph ?? 0
        guard !bookmarks.contains(where: { $0.bookID == book.id && $0.chapter == chapter && $0.paragraph == paragraph }) else { return }
        bookmarks.insert(.init(bookID: book.id, chapter: chapter, paragraph: paragraph, offset: progress?.characterOffset ?? 0), at: 0)
    }
    func switchSource(_ sourceID: String, book: Book) {
        guard sources.contains(where: { $0.id == sourceID && $0.enabled }) else { return }
        bookSources[book.id] = sourceID
    }
    func fulltext(_ query: String, books: [Book]) -> [DemoTextHit] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return books.flatMap { book in
            book.content.enumerated().flatMap { chapter, paragraphs in
                paragraphs.enumerated().compactMap { paragraph, text -> DemoTextHit? in
                    let range = (text as NSString).range(of: query, options: .caseInsensitive)
                    return range.location == NSNotFound ? nil : .init(bookID: book.id, chapter: chapter, paragraph: paragraph, offset: range.location, text: text)
                }
            }
        }
    }
    func execute(_ action: String, feature: DemoFeature, scope: String, book: Book?, library: LibraryStore) {
        let key = "\(feature.id):\(scope)"
        var detail = "操作已完成演示，结果仅保存在本次预览中。"
        var success = true
        switch action {
        case "校验 JSON":
            do { _ = try JSONSerialization.jsonObject(with: Data(text(feature, "json", scope: scope).utf8)); detail = "JSON 格式正确。这里只校验语法，不执行书源规则。" }
            catch { success = false; detail = "JSON 格式有误，请检查引号、逗号与括号。" }
        case "选择示例文件": detail = "已选中：长风渡山海.txt / 日落之前.epub\n编码：UTF-8（模拟识别）\n可预览章节，再确认导入。"
        case "预览章节分割": detail = "章节分割预览（模拟）\n第一章 旧巷听风 · 位置 0\n第二章 一纸山河 · 位置 1240\n第三章 山雨欲来 · 位置 2680"
        case "预览解包目录", "预览解压内容": detail = "内容目录预览（模拟）\n📁 EPUB / OEBPS\n  content.opf\n  toc.ncx\n  chapter01.xhtml\n📄 长风渡山海.txt\n📄 山海图志.pdf"
        case "保存演示配置":
            if let index = sources.firstIndex(where: { $0.id == scope }) {
                let name = text(feature, "name", scope: scope).trimmingCharacters(in: .whitespacesAndNewlines)
                if name.isEmpty { success = false; detail = "请填写书源名称。" } else { sources[index].name = name; sources[index].url = text(feature, "url", scope: scope) }
            }
        case "新建示例书源": sources.append(.init(id: UUID().uuidString, name: "自定义书源 \(sources.count + 1)", detail: "待调试 · 演示配置"))
        case "全部启用", "全部停用":
            for index in sources.indices { sources[index].enabled = action == "全部启用" }
        case "新建分组":
            let name = text(feature, "newGroup", scope: scope).trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty || groups.contains(name) { success = false; detail = "请输入一个未使用的分组名称。" } else { groups.append(name); detail = "已创建“\(name)”，可使用书籍右侧菜单移动分组。" }
        case "添加当前进度书签":
            if let book { addBookmark(book: book, progress: library.progress[book.id]); detail = "已记录当前章节和正文位置，点击书签可继续阅读。" }
        case "模拟预下载": downloadPaused = false; downloadProgress = 1; cacheMB["章节"] = 24.8; detail = "已模拟完成章节预下载。未访问网络。"
        case "暂停下载": downloadPaused.toggle(); detail = downloadPaused ? "下载队列已暂停（模拟）。" : "下载队列已恢复（模拟）。"
        case "清理演示缓存":
            let type = text(feature, "type", scope: scope)
            for cache in Array(cacheMB.keys) where type == "全部" || type == cache { cacheMB[cache] = 0 }
            detail = "演示缓存已清零，真实书架与阅读数据不受影响。"
        case "创建演示备份": backups.insert("阅山_演示_\(backups.count + 1).qibackup", at: 0); detail = "已生成备份列表占位，不创建真实备份文件。"
        case "模拟恢复所选备份": detail = "恢复流程预览完成，未覆盖本机阅读记录。"
        case "模拟立即同步": detail = "模拟状态：同步完成 · 3 本书的进度已对齐。未连接 iCloud。"
        case "生成演示报告": detail = "测试完成（模拟）\n成功 2 个 · 失败 1 个 · 超时 1 个\n山海书库：143 ms，四步通过\n云间小说：216 ms，正文通过\n示例失效源：规则未命中\n纸上漫游：请求超时"
        case "运行模拟测试": detail = "\(text(feature, "step", scope: scope))步骤通过（模拟）\n命中 8 条结果 · 耗时 143 ms\n标题：长风渡山海\n正文：雨是在午后停的……"
        case "识别链接", "识别内容", "预览导入":
            let input = text(feature, feature.id == "sourceImport" ? "url" : "input", scope: scope)
            detail = input.hasPrefix("qireader://") || input.hasPrefix("yuedu://") ? "识别到兼容导入链接 · 内容类型：书源列表\n待导入 3 个示例书源。" : "识别到示例内容，可在确认后查看导入结果。"
        case "模拟导出 JSON": detail = text(feature, "json", scope: scope) + "\n\n仅展示导出内容，不写入真实文件。"
        case "模拟角色分析": detail = "角色识别（模拟）\n旁白：8 段\n陆青崖：3 段 · 少年男声\n老掌柜：2 段 · 长者男声\n可在上方调整声音映射。"
        case "预览规则结果": detail = "规则输出（固定演示结果）\n[\"长风渡山海\"]\n不执行 JavaScript 或 legado 兼容规则。"
        case "模拟导出样式", "模拟导出主题", "模拟导入主题", "模拟导入字体", "模拟导入皮肤", "模拟导入导出", "模拟分享": detail = "已完成格式与确认流程预览。未读写或分享真实文件。"
        case "确认模拟导入", "导入选中内容":
            files.insert(.init(name: "新导入的故事.epub", detail: "模拟导入 · 8 章"), at: 0)
            if let book = library.books.first(where: { $0.id == "cloud" }), !library.isFavorite(book) { library.toggleFavorite(book) }
            detail = "已将示例作品加入书架，并更新演示文件列表。没有读取实际文件或剪贴板。"
        case "重命名示例":
            let name = text(feature, "rename", scope: scope).trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { success = false; detail = "文件名不能为空。" } else if !files.isEmpty { files[0].name = name }
        case "打开模拟播放器", "试听布局预览", "预览锁屏播放卡片": playerVisible = true; isPlaying.toggle(); detail = "播放器状态已更新。当前为无音频的界面演示。"
        case "模拟登录": setSourceLogin(scope, status: .signedIn); detail = "模拟登录成功 · 演示 Cookie 可复用；未发送账号或密码。"
        case "清除演示 Cookie": setSourceLogin(scope, status: .signedOut); detail = "演示会话已清除。"
        case "模拟连接", "模拟连接测试", "模拟网络诊断": detail = "连接流程演示通过。没有发起请求，输入内容不会发送或保存。"
        case "恢复排版默认值": reset(feature, scope: scope)
        case "翻到下一页":
            let value = Int(values["previewPage"] ?? "1") ?? 1
            values["previewPage"] = String(value % 12 + 1)
            detail = "当前预览第 \(value % 12 + 1) 页；\(text(feature, "effect", scope: scope))为样式选项演示。"
        default: break
        }
        outcomes[key] = .init(success: success, title: success ? "演示结果" : "请检查输入", detail: detail)
    }
}
