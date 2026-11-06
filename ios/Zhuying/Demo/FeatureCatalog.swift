import Foundation

/// The layout prototype is data-driven: one catalogue, shared forms, and a few reusable previews.
enum DemoGroup: String, CaseIterable {
    case library = "书库与检索", reading = "阅读与排版", files = "本地内容", sources = "书源与调试"
    case audio = "朗读与 AI", style = "外观与规则", system = "数据与连接"
    var icon: String {
        switch self {
        case .library: "books.vertical"; case .reading: "book"; case .files: "folder"
        case .sources: "externaldrive.connected.to.line.below"; case .audio: "headphones"
        case .style: "paintpalette"; case .system: "slider.horizontal.3"
        }
    }
}

/// Home categories are independent of the detailed catalogue groups.
enum ToolCategory: String, CaseIterable, Identifiable {
    case reading, files, sources, audio, style, data, advanced
    var id: String { rawValue }
    var title: String {
        switch self {
        case .reading: "阅读辅助"; case .files: "导入与文件"; case .sources: "书源管理"; case .audio: "朗读与声音"
        case .style: "主题与外观"; case .data: "数据管理"; case .advanced: "高级设置"
        }
    }
    var icon: String {
        switch self {
        case .reading: "book"; case .files: "square.and.arrow.down"; case .sources: "externaldrive"; case .audio: "headphones"
        case .style: "paintpalette"; case .data: "externaldrive"; case .advanced: "slider.horizontal.3"
        }
    }
    var summary: String {
        switch self {
        case .reading: "检索 · 书签 · 排版"; case .files: "本地文件 · 导入 · 格式支持"; case .sources: "书源 · 登录 · 检测"
        case .audio: "声音 · 角色 · 播放"; case .style: "主题 · 字体 · 规则"
        case .data: "备份 · 缓存 · 足迹"; case .advanced: "规则引擎 · 网络 · 服务"
        }
    }
    var features: [DemoFeature] {
        let dataIDs: Set<String> = ["backup", "icloud", "statistics", "cache"]
        return FeatureCatalog.all.filter { feature in
            switch self {
            case .reading: return feature.group == .library || feature.group == .reading || ["purify", "highlight"].contains(feature.id)
            case .files: return feature.group == .files || feature.id == "files"
            case .sources: return feature.group == .sources && feature.id != "engine"
            case .audio: return feature.group == .audio
            case .style: return (feature.group == .style && !["purify", "highlight"].contains(feature.id)) || feature.id == "covers"
            case .data: return dataIDs.contains(feature.id)
            case .advanced: return feature.id == "engine" || (feature.group == .system && !dataIDs.contains(feature.id) && !["covers", "files"].contains(feature.id))
            }
        }
    }
    func search(_ query: String) -> [DemoFeature] {
        let ids = Set(features.map(\.id))
        return FeatureCatalog.search(query).filter { ids.contains($0.id) }
    }
    var primaryFeatures: [DemoFeature] {
        let ids: [String]
        switch self {
        case .reading: ids = ["fulltext", "bookmarks", "typography", "purify", "highlight"]
        case .files: ids = ["import", "files"]
        case .sources: ids = ["sources", "sourceImport", "sourceBatch"]
        case .audio: ids = ["systemTTS", "onlineTTS", "backgroundAudio", "aiRoles", "aiConfig"]
        case .style: ids = ["themes", "fonts", "covers", "titleDesign", "comments"]
        case .data: ids = ["backup", "icloud", "cache", "statistics"]
        case .advanced: ids = ["engine", "network", "backend", "browser", "links"]
        }
        return ids.map { FeatureCatalog.feature($0) }
    }
    var secondaryFeatures: [DemoFeature] {
        let primaryIDs = Set(primaryFeatures.map(\.id))
        return features.filter { !primaryIDs.contains($0.id) }
    }
    var shortTitle: String {
        switch self { case .reading: "阅读"; case .files: "导入"; case .sources: "书源"; case .audio: "朗读"; case .style: "外观"; case .data: "数据"; case .advanced: "高级" }
    }
}

enum DemoPreview { case books, search, fulltext, sources, sourceSwitch, contents, bookmarks, paper, files, player, roles, rules, canvas, comments, backup, stats, cache, browser, covers }

struct DemoField: Identifiable {
    enum Kind { case text, secret, code, toggle, choice([String]), slider(Double, Double, String) }
    let id: String
    let title: String
    let kind: Kind
    let initial: String
    static func text(_ id: String, _ title: String, _ value: String = "") -> Self { .init(id: id, title: title, kind: .text, initial: value) }
    static func secret(_ id: String, _ title: String) -> Self { .init(id: id, title: title, kind: .secret, initial: "") }
    static func code(_ id: String, _ title: String, _ value: String) -> Self { .init(id: id, title: title, kind: .code, initial: value) }
    static func toggle(_ id: String, _ title: String, _ value: Bool = true) -> Self { .init(id: id, title: title, kind: .toggle, initial: String(value)) }
    static func choice(_ id: String, _ title: String, _ options: [String]) -> Self { .init(id: id, title: title, kind: .choice(options), initial: options[0]) }
    static func slider(_ id: String, _ title: String, _ value: Double, _ min: Double, _ max: Double, _ unit: String = "") -> Self { .init(id: id, title: title, kind: .slider(min, max, unit), initial: String(value)) }
}

struct DemoFeature: Identifiable {
    let id: String
    let title: String
    let icon: String
    let group: DemoGroup
    let summary: String
    let preview: DemoPreview
    var fields: [DemoField] = []
    var actions: [String] = []
    var related: [String] = []
    var capabilityBadge: String? {
        if ["import", "fulltext", "contents", "progress", "details", "reading", "pageStyle", "typography", "highlight", "fonts", "titleDesign", "themes"].contains(id) { return nil }
        if ["shelf", "sources", "sourceImport", "sourceEdit", "bookmarks", "comments"].contains(id) { return "部分演示" }
        return "演示"
    }
}

enum FeatureCatalog {
    static let commonToolIDs = ["import", "fulltext", "themes", "sources"]
    static var commonTools: [DemoFeature] { commonToolIDs.map { feature($0) } }

    #if DEBUG
    static let sampleJSON = """
    {
      "bookSourceName": "山海书库（演示）",
      "bookSourceUrl": "https://books.example",
      "enabled": true,
      "ruleSearch": { "bookList": ".book", "name": "h3@text" }
    }
    """
    private static let sampleSourceName = "山海书库"
    private static let sampleSearchRule = ".book-list .book"
    private static let sampleSubscriptionTitle = "订竹影海书库"
    private static let sampleBookURL = "https://books.example"
    private static let sampleBookFileURL = "https://books.example/library.epub"
    private static let samplePackageURL = "https://sources.example/list.json"
    private static let sampleTTSURL = "https://tts.example/speak"
    private static let sampleAIURL = "https://ai.example/v1"
    private static let sampleBackendURL = "https://reader.example/api"
    private static let sampleShareURL = "qireader://import?url=https://sources.example/list.json"
    #else
    static let sampleJSON = "{}"
    private static let sampleSourceName = ""
    private static let sampleSearchRule = ""
    private static let sampleSubscriptionTitle = "订阅书源"
    private static let sampleBookURL = ""
    private static let sampleBookFileURL = ""
    private static let samplePackageURL = ""
    private static let sampleTTSURL = ""
    private static let sampleAIURL = ""
    private static let sampleBackendURL = ""
    private static let sampleShareURL = ""
    #endif
    static let all: [DemoFeature] = [
        .init(id: "shelf", title: "书架管理", icon: "books.vertical", group: .library, summary: "添加移除 · 分组 · 最近阅读 · 继续阅读", preview: .books,
              fields: [.choice("group", "当前分组", ["全部", "追更中", "待读", "已读完"]), .text("newGroup", "新分组名称")], actions: ["新建分组"], related: ["details", "progress"]),
        .init(id: "search", title: "书籍搜索", icon: "magnifyingglass", group: .library, summary: "多源并发 · 同书聚合去重 · 查看多个来源", preview: .search,
              fields: [.text("query", "书名或作者", "长风"), .toggle("merge", "同书聚合去重"), .toggle("concurrent", "并发搜索")], actions: ["模拟搜索"], related: ["sourceSwitch", "sources"]),
        .init(id: "fulltext", title: "全文搜索", icon: "doc.text.magnifyingglass", group: .library, summary: "正文全文检索 · 本地书检索 · 跳转命中位置", preview: .fulltext,
              fields: [.text("query", "正文关键词", "地图"), .choice("scope", "搜索范围", ["全部示例书", "当前书籍", "本地示例书"])], actions: ["检索示例正文"]),
        .init(id: "discover", title: "发现与订阅", icon: "safari", group: .library, summary: "书源分类 · 书籍流 · 发现筛选 · 源订阅", preview: .books,
              fields: [.choice("category", "发现分类", ["全部", "奇幻", "都市", "科幻", "古风"]), .toggle("subscription", sampleSubscriptionTitle), .choice("sort", "书籍流", ["最近更新", "人气精选", "新书入库"])], related: ["sources"]),
        .init(id: "details", title: "书籍详情", icon: "book.closed", group: .library, summary: "封面 · 作者 · 简介 · 加入书架 · 开始阅读", preview: .books, related: ["sourceSwitch", "covers"]),
        .init(id: "sourceSwitch", title: "换源", icon: "arrow.triangle.swap", group: .library, summary: "候选来源 · 切换来源 · 保留章节与正文位置", preview: .sourceSwitch, actions: ["切换并继续阅读"]),
        .init(id: "contents", title: "章节目录", icon: "list.bullet", group: .reading, summary: "目录浏览 · 章节搜索 · 正倒序 · 当前章标记", preview: .contents,
              fields: [.text("query", "章节关键词"), .choice("order", "排列", ["正序", "倒序"])]),
        .init(id: "progress", title: "阅读进度", icon: "clock.arrow.circlepath", group: .reading, summary: "保存章节与文字位置 · 断点续读", preview: .books, related: ["reading", "bookmarks"]),
        .init(id: "bookmarks", title: "书签", icon: "bookmark", group: .reading, summary: "位置列表 · 跳转书签 · 删除书签", preview: .bookmarks, actions: ["添加当前进度书签"]),
        .init(id: "reading", title: "正文阅读", icon: "book", group: .reading, summary: "原生分页 · 连续滚动 · 上下章 · 按需加载", preview: .paper, actions: ["打开原生阅读器"], related: ["pageStyle", "typography", "chapterCache"]),
        .init(id: "pageStyle", title: "翻页方式", icon: "rectangle.on.rectangle", group: .reading, summary: "左右／上下翻页 · 平移／覆盖／仿真／无动画 · 连续滚动", preview: .paper),
        .init(id: "typography", title: "阅读排版", icon: "textformat.size", group: .reading, summary: "字号与字重 · 行距／段距 · 独立四边留白 · 首行缩进", preview: .paper),
        .init(id: "chapterCache", title: "章节缓存", icon: "arrow.down.circle", group: .reading, summary: "缓存章节 · 预下载 · 下载队列", preview: .cache,
              fields: [.choice("range", "缓存范围", ["后续 10 章", "后续 50 章", "全部章节"]), .toggle("wifi", "仅 Wi-Fi 下载")], actions: ["模拟预下载", "暂停下载"], related: ["cache"]),
        .init(id: "txt", title: "TXT 阅读", icon: "doc.plaintext", group: .files, summary: "文件导入 · 编码识别 · 章节分割", preview: .files,
              fields: [.choice("encoding", "编码", ["自动识别", "UTF-8", "GB18030", "UTF-16"]), .text("chapterRule", "章节分割", "第[一二三四五六七八九十百千0-9]+章.*")], actions: ["选择示例文件", "预览章节分割"], related: ["import"]),
        .init(id: "epub", title: "EPUB 阅读", icon: "book.closed.fill", group: .files, summary: "文件导入 · 解包目录 · 章节阅读", preview: .files,
              fields: [.toggle("publisher", "保留出版社样式"), .toggle("cover", "提取封面")], actions: ["选择示例文件", "预览解包目录"]),
        .init(id: "pdf", title: "PDF 阅读", icon: "doc.richtext", group: .files, summary: "内置阅读布局 · 连续浏览 · 跳页", preview: .files,
              fields: [.choice("mode", "浏览方式", ["连续浏览", "单页"]), .slider("page", "页码", 1, 1, 12, "页")], actions: ["打开示例 PDF"]),
        .init(id: "comic", title: "漫画阅读", icon: "square.stack", group: .files, summary: "页漫 · 条漫 · 翻页 · 图片缓存", preview: .files,
              fields: [.choice("mode", "阅读方式", ["页漫", "条漫"]), .choice("direction", "阅读方向", ["从左到右", "从右到左"]), .toggle("cache", "缓存图片")], actions: ["打开示例漫画"]),
        .init(id: "archive", title: "压缩包支持", icon: "doc.zipper", group: .files, summary: "ZIP · RAR · 7z · 内容导入", preview: .files,
              fields: [.choice("format", "文件格式", ["ZIP", "RAR", "7z"]), .toggle("nested", "扫描子文件夹")], actions: ["预览解压内容", "导入选中内容"]),
        .init(id: "import", title: "智能导入", icon: "square.and.arrow.down", group: .files, summary: "本地文件 · 链接 · 剪贴板 · 预览确认", preview: .files,
              fields: [.choice("method", "内容来源", ["文件", "URL", "剪贴板示例"]), .text("input", "待识别内容", sampleBookFileURL)], actions: ["识别内容", "确认模拟导入"], related: ["txt", "epub", "archive", "links"]),
        .init(id: "sources", title: "书源管理", icon: "externaldrive", group: .sources, summary: "新建编辑删除 · 分组 · 启停 · 批量管理", preview: .sources,
              fields: [.choice("group", "书源分组", ["全部", "小说", "漫画", "个人收藏"])], actions: ["新建示例书源", "全部启用", "全部停用"], related: ["sourceImport", "sourceEdit", "sourceBatch"]),
        .init(id: "sourceImport", title: "书源导入导出", icon: "arrow.up.arrow.down.circle", group: .sources, summary: "URL／文件导入 · JSON 导出 · 阅读 3.0 链接", preview: .sources,
              fields: [.choice("method", "导入方式", ["URL", "JSON 文件", "阅读 3.0 链接"]), .text("url", "导入地址", samplePackageURL), .code("json", "导出内容示例", sampleJSON)], actions: ["预览导入", "模拟导出 JSON"]),
        .init(id: "sourceEdit", title: "书源编辑", icon: "square.and.pencil", group: .sources, summary: "基本信息 · 规则编辑 · JSON 源码校验", preview: .sources,
              fields: [.text("name", "书源名称", sampleSourceName), .text("url", "站点地址", sampleBookURL), .choice("syntax", "规则类型", ["CSS", "XPath", "JSONPath", "正则", "JavaScript"]), .text("rule", "搜索结果规则", sampleSearchRule), .code("json", "JSON 源码", sampleJSON)], actions: ["校验 JSON", "保存演示配置"], related: ["sourceDebug", "sourceLogin"]),
        .init(id: "sourceLogin", title: "书源登录", icon: "person.badge.key", group: .sources, summary: "网页／表单登录 · Cookie 保存与复用", preview: .browser,
              fields: [.choice("method", "登录方式", ["网页登录", "表单登录"]), .text("account", "演示账号", "demo-reader"), .secret("password", "演示密码"), .toggle("cookie", "复用演示 Cookie")], actions: ["模拟登录", "清除演示 Cookie"]),
        .init(id: "sourceDebug", title: "书源调试", icon: "ladybug", group: .sources, summary: "搜索 → 详情 → 目录 → 正文分步测试", preview: .sources,
              fields: [.choice("step", "调试步骤", ["搜索", "详情", "目录", "正文"]), .text("query", "测试关键词", "长风")], actions: ["运行模拟测试"], related: ["sourceEdit", "engine"]),
        .init(id: "sourceBatch", title: "批量测试", icon: "checklist", group: .sources, summary: "书源校验 · 成功／失败／超时 · 测试报告", preview: .sources,
              fields: [.slider("timeout", "超时", 15, 5, 60, "秒"), .choice("parallel", "并发数量", ["3", "5", "10"])], actions: ["生成演示报告"]),
        .init(id: "engine", title: "书源兼容引擎", icon: "curlybraces", group: .sources, summary: "legado · CSS／XPath／JSONPath／正则／JS · jsoup", preview: .rules,
              fields: [.choice("engine", "规则引擎", ["CSS", "XPath", "JSONPath", "正则", "JavaScript", "jsoup"]), .code("rule", "规则示例", "$.data[*].title"), .code("input", "输入示例", "{\"data\":[{\"title\":\"长风渡山海\"}]}")], actions: ["预览规则结果"]),
        .init(id: "systemTTS", title: "系统朗读", icon: "speaker.wave.2", group: .audio, summary: "系统声音 · 播放／暂停 · 语速与进度", preview: .player,
              fields: [.choice("voice", "声音", ["晓晓 · 普通话", "婷婷 · 普通话", "粤语"]), .slider("speed", "语速", 1, 0.5, 2, "×")], actions: ["打开模拟播放器"], related: ["backgroundAudio", "aiRoles"]),
        .init(id: "onlineTTS", title: "在线朗读", icon: "waveform", group: .audio, summary: "HTTP TTS · WebSocket 流式 · 朗读源管理", preview: .player,
              fields: [.choice("transport", "协议", ["HTTP TTS", "WebSocket"]), .text("url", "服务地址", sampleTTSURL), .choice("voice", "朗读源", ["云端女声", "云端男声", "自定义"]), .toggle("stream", "流式朗读")], actions: ["模拟连接", "打开模拟播放器"]),
        .init(id: "backgroundAudio", title: "后台音频", icon: "play.rectangle", group: .audio, summary: "后台播放 · 系统播放信息 · 音频缓存", preview: .player,
              fields: [.toggle("background", "后台播放"), .toggle("lockscreen", "锁屏控制"), .toggle("cache", "音频缓存")], actions: ["预览锁屏播放卡片"], related: ["cache"]),
        .init(id: "aiRoles", title: "AI 多角色朗读", icon: "person.2.wave.2", group: .audio, summary: "正文角色分析 · 角色管理 · 不同声音映射", preview: .roles,
              fields: [.choice("narrator", "旁白", ["温柔女声", "沉稳男声"]), .choice("hero", "陆青崖", ["少年男声", "沉稳男声"]), .choice("elder", "老掌柜", ["长者男声", "沉稳男声"])], actions: ["模拟角色分析", "试听布局预览"], related: ["aiConfig", "onlineTTS"]),
        .init(id: "aiConfig", title: "AI 服务配置", icon: "sparkles", group: .audio, summary: "服务商 · 模型 · API Key · 安全存储入口", preview: .roles,
              fields: [.choice("provider", "服务商", ["自定义兼容服务", "本地服务"]), .text("url", "Base URL", sampleAIURL), .text("model", "模型", "demo-model"), .secret("key", "API Key（仅占位）"), .toggle("secure", "使用钥匙串（界面示意）")], actions: ["模拟连接测试"]),
        .init(id: "purify", title: "正文净化", icon: "line.3.horizontal.decrease", group: .style, summary: "正则／JS 替换 · 分组启停 · 导入导出 · 作用域", preview: .rules,
              fields: [.choice("scope", "作用域", ["全部书籍", "当前书籍", "当前书源"]), .choice("type", "规则类型", ["正则", "JavaScript"]), .text("pattern", "匹配内容", "\\(本章完\\)"), .text("replacement", "替换为"), .toggle("enabled", "启用规则")], actions: ["预览净化结果", "模拟导入导出"]),
        .init(id: "highlight", title: "高亮规则", icon: "highlighter", group: .style, summary: "正文样式规则 · 对话／系统／诗词模板 · 正则与关键词 · 首字下沉", preview: .rules),
        .init(id: "themes", title: "主题管理", icon: "paintpalette", group: .style, summary: "本地套装导入 · 配色／标题／气泡 · 搭配预览与应用", preview: .paper),
        .init(id: "fonts", title: "字体管理", icon: "textformat", group: .style, summary: "本地 TTF／OTF／TTC 导入 · 试字预览 · 应用于正文", preview: .paper),
        .init(id: "titleDesign", title: "章节标题设计", icon: "square.on.circle", group: .style, summary: "自定义标题 · 字号／对齐／颜色 · CSS 子集导入 · 实时预览", preview: .canvas),
        .init(id: "comments", title: "段评与皮肤", icon: "bubble.left.and.bubble.right", group: .style, summary: "段尾气泡 · 神人评论示例 · 个人皮肤创建与导入", preview: .comments),
        .init(id: "backup", title: "本地备份", icon: "externaldrive.badge.timemachine", group: .system, summary: "创建备份 · 恢复 .qibackup", preview: .backup,
              fields: [.toggle("sources", "包含书源"), .toggle("progress", "包含阅读进度"), .toggle("settings", "包含偏好")], actions: ["创建演示备份", "模拟恢复所选备份"]),
        .init(id: "icloud", title: "iCloud", icon: "icloud", group: .system, summary: "云端备份 · 同步状态 · 冲突处理", preview: .backup,
              fields: [.toggle("sync", "启用同步（模拟）"), .choice("conflict", "冲突策略", ["询问我", "保留本机", "使用云端"])], actions: ["模拟立即同步"]),
        .init(id: "statistics", title: "阅读统计", icon: "chart.bar", group: .system, summary: "阅读时长 · 按时间／书籍查看图表", preview: .stats,
              fields: [.choice("period", "统计周期", ["本周", "本月", "本年"]), .choice("dimension", "统计维度", ["按时间", "按书籍"])], related: ["progress"]),
        .init(id: "files", title: "文件管理", icon: "folder", group: .system, summary: "目录浏览 · 文件整理 · 重命名 · 删除 · 分享", preview: .files,
              fields: [.text("rename", "新文件名", "山海阅读笔记.txt")], actions: ["重命名示例", "模拟分享"], related: ["import", "archive"]),
        .init(id: "cache", title: "缓存管理", icon: "internaldrive", group: .system, summary: "章节 · 图片 · 音频 · 空间清理", preview: .cache,
              fields: [.choice("type", "缓存类型", ["全部", "章节", "图片", "音频"])], actions: ["清理演示缓存"]),
        .init(id: "browser", title: "内置浏览器", icon: "globe", group: .system, summary: "网页浏览 · 书源登录 · 调试与网页交互", preview: .browser,
              fields: [.text("url", "地址", sampleBookURL), .toggle("script", "网页交互（模拟）")], actions: ["预览示例网页"], related: ["sourceLogin", "sourceDebug"]),
        .init(id: "covers", title: "封面搜索", icon: "photo.on.rectangle", group: .system, summary: "Bing 图片搜索入口 · 封面选择", preview: .covers,
              fields: [.text("query", "封面关键词", "长风渡山海"), .choice("ratio", "图片比例", ["竖版", "全部"])], actions: ["模拟搜索封面"]),
        .init(id: "network", title: "网络配置", icon: "network", group: .system, summary: "书源级代理 · 自定义 DNS／IP", preview: .sources,
              fields: [.toggle("proxy", "为此书源启用代理", false), .text("host", "代理地址", "127.0.0.1:7890"), .text("dns", "DNS", "1.1.1.1"), .text("ip", "指定 IP（可选）")], actions: ["模拟网络诊断"]),
        .init(id: "backend", title: "远程后端", icon: "server.rack", group: .system, summary: "将选定书源请求转发至自建服务", preview: .sources,
              fields: [.toggle("enabled", "启用转发（模拟）", false), .text("url", "后端地址", sampleBackendURL), .secret("token", "访问令牌（占位）"), .choice("scope", "转发范围", ["选定书源", "全部书源"])], actions: ["模拟连接测试"]),
        .init(id: "links", title: "外部链接接入", icon: "link", group: .system, summary: "qireader:// · yuedu:// · 识别与导入确认", preview: .files,
              fields: [.text("input", "待识别链接", sampleShareURL)], actions: ["识别链接", "确认模拟导入"]),
    ]
    static func feature(_ id: String) -> DemoFeature { all.first { $0.id == id }! }
    static func search(_ query: String, group: DemoGroup? = nil) -> [DemoFeature] {
        let key = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return all.filter { feature in
            let fields = feature.fields.map { field in
                if case .choice(let options) = field.kind { return field.title + options.joined() }
                return field.title + field.initial
            }.joined()
            return (group == nil || feature.group == group) && (key.isEmpty || (feature.title + feature.summary + fields).localizedCaseInsensitiveContains(key))
        }
    }
}
