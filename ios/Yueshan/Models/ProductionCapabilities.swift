import Foundation
enum ProductionCapabilities {
    static let live: Set<String> = ["sources", "sourceImport", "sourceEdit", "sourceDebug", "sourceBatch", "sourceSwitch", "search", "discover", "chapterCache", "import", "epub", "txt", "fulltext", "statistics", "shelf", "bookmarks", "themes", "fonts", "typography", "pageStyle", "titleDesign", "highlight", "progress", "backup", "files", "cache"]
    static func badge(for id: String) -> String? {
        if ["onlineTTS","aiRoles"].contains(id) { return "需配置服务" }
        if id == "icloud" { return "需 iCloud 权限" }
        if id == "comments" { return "书山·番茄只读" }
        if id == "engine" { return "原生 v1 子集" }
        if ["systemTTS","backgroundAudio","aiConfig","links","pdf","comic","archive","covers"].contains(id) { return nil }
        if live.contains(id) { return nil }
        if ["sources", "sourceEdit", "sourceLogin", "search"].contains(id) { return "固定书源" }
        if id == "chapterCache" { return "近期缓存" }
        return "暂不可用"
    }
}
