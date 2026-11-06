import Foundation

/// Presentation names and examples are available to the development Demo only.
/// Distribution keeps protocol adapters but contains no configured source.
enum SourceDistributionPolicy {
    #if DEBUG
    static let nativeServiceName = "书山聚合"
    static let unselectedSourceName = "山海书库"
    static let unselectedLoginAddress = "https://books.example/login"
    static let searchHelp = "搜索已启用的可运行书源；书山聚合需先登录。不同来源版本分别保留。"
    static let aboutDescription = "原生文字阅读器，支持 TXT／文字 PDF、书山聚合固定接口、书架与稳定位置、本地备份。"
    #else
    static let nativeServiceName = "自定义接口"
    static let unselectedSourceName = "未选择书源"
    static let unselectedLoginAddress = "请先导入书源"
    static let searchHelp = "搜索用户导入且已启用的可运行书源。不同来源版本分别保留。"
    static let aboutDescription = "原生文字阅读器，支持本地文件、用户导入书源、书架与稳定位置、本地备份。"
    #endif
    static var serviceAddressPrompt: String { "请输入完整 HTTPS 服务地址" }
}
