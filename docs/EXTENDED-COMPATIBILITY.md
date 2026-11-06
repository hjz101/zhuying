# 阅山 0.8 功能与兼容范围

本表对应冻结 Demo 的47项入口。正式版复用页面、导航和阅读组件，显示真实或空数据。实现不等同于所有外部环境已验收：iCloud 账号与两台设备、签名／真机／iOS17、用户自配语音／AI和远程后端仍需实际环境；冻结RSS门槛单列。禁止以扩大阈值、示例数据或测试替身代替这些条件。

| 功能 | 当前实现与边界 | 验证入口 |
| --- | --- | --- |
| F01 书架管理 | 真实收藏、分组、批量、历史独立、删除和撤销 | ProductionManagement／ProductionLibraryStore tests |
| F02 书籍搜索 | 书山四接口、兼容源并发、独立分页、去重与部分错误 | MultiSource／OnlineReading tests；真实两书报告 |
| F03 全文搜索 | 本地、已缓存／下载正文与净化版本；不爬未缓存章 | EPUBAndSearch／ContentProcessing tests |
| F04 发现与订阅 | 声明支持的分类／订阅与前台更新检查 | SourceManagement／Discovery tests |
| F05 书籍详情 | 实际详情、可读目录、收藏与阅读；工具入口选真实作品 | OnlineReading／ExtensionTools UI |
| F06 换源 | 候选来源与章节／上下文映射，低置信人工确认 | SourceManagement tests／UI |
| F07 章节目录 | 实际目录、搜索／排序／受限项、选章阅读 | OnlineReading／ExtensionTools UI |
| F08 阅读进度 | 稳定章段与Unicode偏移，失败不推进 | ContentContracts／ReadingSession tests；真实重启报告 |
| F09 书签 | 文本稳定位置、媒体页坐标，持久化和去重 | ProductionManagement／ArchiveAndMedia tests |
| F10 正文阅读 | 按章加载、滚动／分页共用位置、错误显式重试 | ReaderEngine／ReaderNativeInteraction tests／UI |
| F11 翻页方式 | 现有三种方向、原生翻页效果与无障碍动作 | ReaderInteraction tests／UI |
| F12 阅读排版 | 字号／间距／页眉脚、主题字体与个人覆盖 | ReaderRenderingPreferences tests／UI |
| F13 章节缓存 | 近期缓存＋一章预取、主动范围队列、256MiB、后台暂停 | OfflineDownload／OnlineReading tests |
| F14 TXT | 编码检测、分章、20MiB输入、预览后入库 | BookImport tests／系统文件UI |
| F15 EPUB | 未加密可重排spine正文及本地图；不复刻出版物CSS | EPUBAndSearch tests／UI |
| F16 PDF | 文字提取与独立PDFKit原版式，≤20MiB／2000页 | ArchiveAndMedia tests／PDF旋转与重启UI |
| F17 漫画 | 本地归档图片自然排序、页漫／条漫、页级位置与书签 | ArchiveAndMedia tests／漫画UI |
| F18 压缩包 | ZIP、RAR4 stored／RAR5 compressed、7z LZMA受控提取 | ArchiveAndMedia tests；上游样本许可 |
| F19 智能导入 | 文件／剪贴板／HTTPS，流式上限、取消与确认，不自动执行规则 | BookImport／ImportDownload tests／UI |
| F20 书源管理 | SQLite配置、启停／增删、已有书与记录保留 | SourceManagement tests／UI |
| F21 书源导入导出 | json-v1／extract-v1版本包，文件／链接预览确认、重导入 | SourcePackages tests／UI |
| F22 书源编辑 | 已支持版本的四接口与提取规则；未知方言拒绝 | SourcePackages／RuleExtraction tests |
| F23 书源登录 | 书山原生登录与Keychain；通用每源浏览器Cookie明确启用 | ShushanAccount／SourceBrowser tests |
| F24 书源调试 | 实际四步探测、提取测试与受限脚本宿主 | SourceDiagnostics／NativeScriptHost tests／UI |
| F25 批量测试 | 真实请求、逐源状态与脱敏报告 | SourceDiagnostics tests／UI |
| F26 兼容引擎 | Fuzi CSS／受限XPath、JSONPath v1、限时ICU正则；Worker宿主 | RuleExtraction／ExtractionBookSource／NativeScriptHost tests |
| F27 系统朗读 | 系统声音、暂停／续读／跨章、实际播放后计时 | Narration tests／原生PCM报告／UI；真机待验 |
| F28 在线朗读 | 自定义HTTPS WAV片段及约定WSS帧协议、限额和一次续接 | CompatibleAudio tests；用户服务待配置 |
| F29 后台音频 | 系统音频会话、系统播放信息、远控与中断状态 | Narration tests；锁屏／来电／路由真机待验 |
| F30 AI多角色 | 自定义分析接口、版本缓存、角色编辑／声线映射、预算 | RoleAnalysis tests；用户模型待配置 |
| F31 AI服务配置 | HTTPS／WSS校验、应用内连接测试、设备Keychain | AudioServiceConfiguration tests／UI |
| F32 正文净化 | 原文不变、版本化正则／纯JS、顺序作用域、失败回退 | ContentProcessing tests／编辑与重启UI |
| F33 高亮规则 | 书籍→书源→全局优先，原文与偏移不变 | ScopedRulesAndShare tests |
| F34 主题 | 真实导入／应用／删除、资源校验、个人覆盖 | Theme tests／UI |
| F35 字体 | 受控本地字体、校验、重启和缺失回退 | ReadingFontLibrary tests／UI |
| F36 章节标题 | 字号／对齐／颜色／字重／字距／背景／留白／下划线子集 | ReaderRenderingPreferences tests／长标题UI |
| F37 段评与皮肤 | 书山番茄真实只读分页／最多两段精选、引用核对、缓存；无数据不造评论 | SourceComment tests／真实App分页报告 |
| F38 本地备份 | 完整校验、确认后新代恢复、原件与失败回滚 | LibraryBackup／Workspace tests／UI |
| F39 iCloud | Drive备份列表／下载／恢复；记录因果版本、删除标记、冲突选择 | CloudRecord／LibraryRecordSync tests／无权限UI；真实账号两设备待验 |
| F40 阅读统计 | 真实阅读与朗读分计，前后台／空闲／跨日边界 | ReadingActivity tests／UI |
| F41 文件管理 | 本地浏览／重命名／删除／分享，与书库一致 | ProductionManagement tests／UI |
| F42 缓存管理 | 实际正文／下载／图片／音频／评论／脚本缓存清理和配额 | Cache／OfflineDownload／AudioCache tests／UI |
| F43 内置浏览器 | 每源与主机持久会话、临时外站确认、导航／DOM／下载预览 | SourceBrowser tests／真实TXT下载报告／UI |
| F44 封面搜索 | Open Library真实搜索与选图，确认保存≤800px PNG，失败保留 | CoverSearch tests／服务可用性报告 |
| F45 网络配置 | 每源CONNECT、固定IP、UDP DNS，无TLS放宽或自动回退 | SourceNetwork tests／实际HTTPS隧道与证书拒绝报告 |
| F46 远程后端 | 附带自建Node网关，书源／路径白名单、Keychain令牌、明确回退 | RemoteBackend tests／Node真实HTTP tests／设置UI |
| F47 外部链接 | yueshan://import file／source／theme，预览确认，拒绝敏感链接与未知方言 | ScopedRulesAndShare tests／系统实际路由 |

## 格式与资源限制

归档压缩输入20MiB，展开64MiB，4000项／单项20MiB；不导入加密、分卷、链接或越界路径，损坏／校验失败明确拒绝，原件不修改。RAR与7z仅以上固定真实样本覆盖的变体；非所有压缩算法承诺。libarchive许可随 App 的 ThirdPartyNotices 提供。

漫画最多2000页，单图8MiB／3200万像素；ImageIO缩略图最大2048px，图片缓存8项／16MiB，内存警告清理。漫画恢复页级位置；PDF原版式使用实际页面坐标。两者不将页面索引当作全文或朗读正文。扫描PDF可看原页，未实现OCR。

EPUB输入20MiB、展开64MiB／4000项，单项12MiB，内嵌图2MiB／1600万像素；只导入实际spine正文和本地位图，拒绝加密／固定版式。CSS／SVG、脚本、网络／浏览器、音频、云和后端的详细支持分别见相关说明，不承诺任意阅读器规则／网页CSS／TTS协议兼容。
