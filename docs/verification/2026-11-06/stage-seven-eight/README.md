# 步骤七、八开发记录

## 基础与 P1 工具

2026-11-06：303 项原生单元测试通过，日志 `/tmp/yueshan-stage-seven-foundation-final.log`。新增书籍／书源／全局高亮作用域，书籍优先，原文与 UTF-16 范围不变；已绑定规则重启保留，旧未绑定规则保持停用。共享入口注册 `yueshan://import`，分 file／source／theme；有凭据、重复参数及未知阅读器方言拒绝，不自动保存或执行。模拟器实际通过系统打开确认后进入书源预览入口，尚未发送下载请求，截图在本机 `artifacts/0.8.0/validation/share-import-preview.png`。

iCloud Drive 传输与备份／记录合并基础已加入，尚未接入完整界面和实际账号验收。受控传输测试覆盖两设备合并、离线修改、删除标记不复活、回读位置与最远位置分开、时钟差、增量拉取和账号切换停止；未启用权限的构建返回明确状态，不建立默认 CloudKit 容器。当前无开发团队／真机，不能将该模型验证记为云同步实机完成。

新增依赖固定为 Fuzi 3.1.3 与 libarchive-for-swift 1.0.0。后者的远端二进制下载受本机连接影响；经 IPv4 下载并按上游 SHA-256 `1db0e56d929358547d3d5cc37646d53bc8c26ff8b54071ed06d2a7eda8f6d416` 校验后，放入标准 SwiftPM 缓存，保持远端包和校验配置不变。第三方许可原文随工程资源保存。

用户选择真实段评优先探测现有书山聚合。参考 v5.61 配置提供 `/para` 数量及各平台评论路由；接口、段落身份映射、分页和真实内容验证继续推进，不把发现接口字符串视为联调通过。

## 首批功能实现与复验

321 项原生单元测试通过：`/tmp/yueshan-stage-seven-first-feature-pack.log`。同次通过 3 项界面流程：未授权 iCloud 状态与本地备份导航、空书库封面入口、真实用户输入的规则解析。此前 `/tmp/yueshan-stage-seven-media-cover-comments-final.log` 中 315 项单元测试及 PDF／漫画 2 项界面流程通过，覆盖系统文件选择、原版式 PDF、分页／条漫、页面书签、重启续读及 PDF 横屏。68 项 Node 测试、语法检查与冻结 Demo 的 7 项哈希验证通过。失败的早期测试日志保留；上述后续结果对应修复后版本。

- PDF 原版式、ZIP／RAR4 stored／RAR5 compressed／7z LZMA、漫画自然排序、真实资源备份恢复已实现。加密与分卷不支持；加密 RAR 和损坏／路径越界归档拒绝。原始归档不修改，不执行内部 JS。RAR5／加密 RAR 的上游样本出处与许可随测试固定；不把一个压缩变体通过扩大为全部格式兼容。
- PDF 使用 PDFKit，页面坐标来自实际视图转换；修复了 `currentDestination` 取到页底导致重启跳到下一页的问题。漫画切换条漫等待图片高度布局，避免覆盖已保存页码。图片缓存 8 项／16 MiB，内存警告清理；原版式页面索引不进入全文搜索或朗读。
- 封面使用已验证的 Open Library 搜索／图片服务，英文书名搜索和实际图片 HTTP 200，《西游记》返回带封面的候选；只在用户选择后保存。失败保留旧封面，本地重启、备份、重命名与失败回滚通过，见 `cover-service-probe.json`。
- iCloud 页面已接入原生完整备份的列表、下载、校验、恢复确认、删除及取消；当前未配置权限时清晰阻止写入。原生账号实际验收与完整记录同步继续推进，不宣称已通过 T055／T056 外部门槛。
- extract-v1 的 CSS／XPath／JSONPath／正则接入四项真实请求流程；原创 HTML 样本覆盖搜索、详情、目录、正文和稳定章节身份，不运行其他阅读器脚本。ICU 病态正则的限时中止通过。范围见 `docs/COMPATIBLE-SOURCES.md`。

## 书山原生标识与真实段评

参考配置的章节 URL 可以是 `item_id=...` 这样的裸查询片段。修复后提取上游章节 ID，不再丢失番茄／晋江的请求参数。`source-feasibility-after-native-id-fix.json` 中最终 App 的原生探测状态为 passed：《西游记》《红楼梦》各连续 3 个目录条目可读，搜索分页、受限与失败来源保留脱敏记录。此结果满足来源可行性 G1；T030 还需要真实书籍入库和应用重启续读，不能仅用探测报告代替。

真实段评数量、无评论章节、正文匹配与番茄只读内容已验证。评论 JSON 的真实根结构没有 `code`，由 `data.data_list` 与 `common_list_info` 判定，并拒绝异常错误形状。`source-comments-page-probe.json` 记录首屏 20 条、次屏 20 条、ID 不重叠与原文存在。数量映射采用稳定段落 ID；正文版本／账号分离缓存（最多 128 文件／16 MiB、离线保留 7 日），登录变化或无数据不展示示例。评论打开后核对原文，不匹配就报错，不展示错段评论。当前仅番茄只读接口启用，晋江数量接口未通过；回复、图片／视频、点赞和发表评论未实现。

后续只读复验增加 `quoteMatchesMappedParagraph:true`，已确认接口原文与所映射的本地段落一致，见同一 `source-comments-page-probe.json`。

## 记录同步实际书库接入

记录同步控制器和原生配置页已接入，默认关闭、首次合并需确认、账号变化停用。在前台退出阅读后自动检查；数据应用为实际 SQLite 事务，正文与资源继续由完整备份负责。新增当前／最远位置的独立持久化，读取旧章不会把最远位置退回；新设备未修改的默认设置不覆盖已有云端偏好。冲突保留可选版本，显式选择生成新的因果版本。发布前保留设备时钟，避免上传后应用失败再重试复用同一版本号。

`/tmp/yueshan-record-sync-final.log` 中 326 项单元测试及 1 项记录同步权限界面流程通过；`/tmp/yueshan-record-sync-complete-retest.log` 中 327 项单元测试通过，含 5001 条目录的多日志往返、损坏状态拒绝、实际双库元数据同步及 SQL 故障回滚。随后 `/tmp/yueshan-record-sync-farthest-final.log` 的 11 项云记录测试通过，新增验证“在下一次同步前回读旧章”及重启，当前位置留在旧章、最远位置保留。真实 iCloud 账号、签名和物理设备验证仍未完成，不勾选外部验收门槛。

## JavaScript 宿主

真实 Web Worker 宿主、受限网络／缓存桥接、编码／哈希和解析器已实现。无限循环能超时终止，取消后新任务可正常运行。不自动执行其他阅读器导入脚本，不宣称 legado／jsoup 完整兼容。范围见 `docs/NATIVE-SCRIPT-HOST.md`。`/tmp/yueshan-script-host-feature.log` 中 332 项单元测试与 1 项应用内实际脚本执行界面流程通过，默认网络关闭。

## 正文净化与原文定位

正则／受限 JS 的版本化净化、顺序和作用域、真实配置界面及导入导出已接阅读、朗读、全文搜索。原文不改写，规则随完整备份保存；处理结果含来源版本与段落对应，段评继续核对原文。`/tmp/yueshan-purification-feature.log` 的 338 项单元测试通过；界面测试发现首次打开章节失败时空 ZStack 导致错误按钮零宽，补齐阅读容器尺寸后，`/tmp/yueshan-purification-ui-retest.log` 的编辑／启用／显式重定位／重启续读流程通过。支持与边界见 `docs/CONTENT-PROCESSING.md`。

- `network-browser-probe.json`：App内真实HTTPS经指定IP CONNECT隧道、无效证书拒绝及Gutenberg公开TXT下载预览通过；不修改正常书库，不使用用户凭据。
- 来源段评最终契约和只读范围见 `../../../SOURCE-COMMENTS.md`；早期失败探测文件保留用于追溯，以 `source-comments-page-probe.json` 为最终分页证据。

## 最终功能组合与真实界面

- iPhone 17 Pro／iOS26.5全量83条普通UI流程零失败：`/tmp/yueshan-stage-eight-final-ui.log`、`ui-summary.json`。后来新增的扩展缓存清理在同设备独立通过，`final-closure-summary.json`；共84条不同普通流程。覆盖47个Demo入口及原有排版／字体／CSS／SVG／系统文件／音频／存储／迁移。
- 最新357项完整原生单元及封面入口复验通过：`/tmp/yueshan-stage-eight-delivery-check.log`、`delivery-summary.json`。正式工具摘要显示实际Open Library服务，Demo原始Bing文案保留，布局与导航未改。
- iPhone SE第三代／iOS26.5：352项当时完整单元与12条扩展、PDF／漫画UI均通过，`small-screen-summary.json`；后续原生单元补至357项并在主设备全量复验。不是物理设备或iOS17运行记录。
- `Yueshan Live Acceptance`专用scheme实际点击《西游记》《红楼梦》的搜索结果、详情、目录、各前三回、未收藏退出重启和“我的→继续阅读”；重启完整渲染文本一致，`live-ui-summary.json`、`live-app-acceptance.json`。首轮测试误选只面向收藏书的书架续读入口，已改为既有正确路径，最终103.40秒通过；保留首次失败日志`/tmp/yueshan-stage-eight-live-ui.log`。
- 两书真实正式存储诊断另见`live-library-prepare.json`／`live-library-restart.json`，验证六章缓存、收藏／书签／排版与同段UTF16偏移恢复。真实正常用户书库未改，凭据由App读取，报告无原文、密码或API Key。
- 当前74项Node与语法检查通过，日志`/tmp/yueshan-stage-eight-last-node.log`；7项冻结Demo完整性检查通过，Demo子模块仍保持冻结提交。旧证据测试曾强制T003永久未通过，现改为同时核对保留的失败历史与后续真实成功，不放宽预算或发布门槛。

## 冻结性能

最新3项测量／正确性测试通过，见`performance-summary.json`、`performance.json`、`launch.json`。预算SHA-256仍为`269f789b9de7889d7f56fc76caabe0775752727ba105475b60871af67dffc28e`，10项中9项达标：启动最大2507.05ms，分页462.20ms，重排495.50ms；测试宿主RSS389.75MiB仍超256MiB。没有修改阈值或删掉失败指标。

正常Debug App未注入XCTest的补充测量见`native-app.json`：117997 UTF16单元、164页，内容完整，RSS290.66MiB；初始化到就绪308.31ms排除了dyld，不替代完整启动或冻结宿主口径，更不替代真机。

T003／G1与T030现已通过。iCloud真实账号／双设备、真实多源与用户自配语音／AI／后端长期组合、iOS17／真机、签名／内测，以及冻结RSS仍按各任务保留待验，G3／G4／G5不宣布批准。当前交付为可构建的0.8.0开发候选。

## Release与外部链接

模拟器arm64 Release及未签名iPhoneOS Release均构建成功，版本0.8.0／构建8，最低iOS17。已安装到正常QA模拟器，原有登录与正常书库保留。设备构建仍有上游libarchive预编译库的部分符号化警告与原有方向配置提示；构建成功不作为真机运行证明，不扩大归档变体支持。

Release通过实际系统`yueshan://import`冷启动进入书源预览，运行中主题链接切换到主题预览，均显示正确类型；未触发下载或保存。结果见`share-routing-release.json`，截图在本机`artifacts/0.8.0/validation/share-*-release.png`。验证后恢复正常正式启动。
