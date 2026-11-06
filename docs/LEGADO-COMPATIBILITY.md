# 竹影阅读 3.0 基础兼容原型

本阶段实现端侧兼容引擎，并接入已有书源导入、搜索、详情、目录、阅读、缓存和生产书库。用户继续导入原版格式 JSON，无须改写成竹影 `json-v1`。导入与预览不执行脚本；用户发起搜索、阅读或书源调试时才执行规则。

这是阶段一的可运行原型，不代表任意阅读 3.0 书源已兼容。参考语义固定为 `gedoor/legado` 的 `fd026e0`；规则和宿主接口独立实现，没有复制 Android 应用代码。QuickJS 固定为官方 2026-06-04 版本，归档校验值见 `ios/Vendor/QuickJS/UPSTREAM.md`，MIT 声明随应用分发。

## 接入与结构

- `LegadoSourceDefinition` 读取原版 `searchUrl`、`ruleSearch`、`ruleBookInfo`、`ruleToc`、`ruleContent`、`header`、`jsLib` 等字段，并验证搜索到正文所需的必要配置。
- `LegadoRuleEngine` 解析规则、模板、组合、替换和脚本片段。引号、嵌套括号和脚本运算符不按普通分隔符拆开；不对 `java.ajax` 做 `await` 文本替换。
- `QuickJSScriptRuntime` 在后台执行同步脚本和受限宿主接口，支持最后表达式返回值。源码、变量和返回值通过结构化桥传递，当前不装载文件系统、进程或动态模块接口。
- `LegadoBookSource` 实现现有 `BookSource` 协议，保持来源身份、章节 ID、书签和缓存约定。`LibraryStore.configuredBookSource` 同时供搜索和书源调试使用。
- 书源列表显示“阅读 3.0 · 基础兼容 · 待实测”。这表示已识别配置并提供执行器，站点可读性仍需实际完整链路验证。

## 当前范围

| 能力 | 阶段一行为 |
| --- | --- |
| 原版规则字段 | 接受原版单源、数组及竹影导出包；小说书源使用新适配器。未知字段保留供导出；凭据字段仍剔除。 |
| 基础选择器 | CSS；jsoup 风格 `class`／`id`／`tag`、每父节点整数索引；文字、HTML 和属性投影。XPath／JSONPath 沿用已声明的原生子集。 |
| 组合与处理 | `&&`、`\|\|`、`%%`、`##` 替换、`@get`／`@put`、`{{...}}` 模板。 |
| JavaScript | `@js:`、`<js>...</js>`、共享 `jsLib`、`result`／`src`／`baseUrl`／`key`／`page`／`source`／`book`／`chapter`。HTTP 响应是字符串，JSON 行字段保留对象类型。 |
| 常用宿主 | 同步 `java.ajax`／`connect`／网络 `get`／`post`／`head`、规则提取、变量、UTF-8 Base64、URL 编码、MD5、十六进制文字；已实现方法以代码和测试为准。 |
| 请求 | 同源 HTTPS，GET／POST／HEAD、静态非凭据请求头、body、UTF-8／UTF-16／GB18030 等已验证编码。`{{key}}` 在 URL 查询中百分号编码；表单 body 保持规则字面值，特殊字符需规则自行 `encodeURIComponent`。 |
| 分页 | 搜索页码与 `nextPageUrl` 游标；有界目录分页、正文分页及边界重叠段落去重。正文分页不吞入目录里已知的其他章节，重建适配器后仍使用非凭据的前后章 URL 边界。 |
| 会话 | 每源独立 Cookie 和变量，来源之间隔离。浏览器复用 Cookie 不覆盖适配器已明确提供或由响应刷新的 Cookie。适配器重建后不保留其内存会话。 |

## 明确边界

- 当前不运行 Android 界面、任意 Java／Rhino 对象或 `Packages.*`，不伪造设备 ID；依赖这些接口的规则需要逐项适配。
- 当前不自动运行 `loginUi`／浏览器等待接口、跨主机聚合、HTTP 明文源、音频或漫画书源；原入口和原配置保留。
- 章节／书籍／目录链接中的非空 fragment、提取链接后附带请求选项等尚未建模的行为会明确拒绝，避免静默合并章节或把 POST 变为 GET。
- 依赖 `webJs`、正文 `replaceRegex` 等单独高级处理字段的配置，在对应步骤明确报未支持。已经支持的 `##` 规则内替换继续可用。
- 当前不等同于完整 jsoup、Java 正则、XPath 或 JSONPath；不支持的语法会报错。
- `jsLib` 在每次脚本求值中初始化；当前不保持跨规则的 JavaScript 全局对象。需要跨调用保存的数据使用已实现的来源／书籍变量；完整共享脚本作用域仍需后续适配。
- 不承诺任意网上书源都有效。站点改版、账号权限和网络可达性与规则语义兼容分开验证。

## 运行限额

单次脚本默认 5 秒、16 MiB JS 堆、512 KiB 栈、128 次宿主调用、4 MiB 桥数据、2 MiB 输出；宿主重入最多 4 层、每操作最多 128 次脚本求值。网络操作独立超时和取消，不能仅依赖解释器中断。单操作最多 64 请求／8 MiB 总响应，目录与正文默认最多 8 页，单字段最多 256 KiB。每源变量总量最多 512 KiB、Cookie 总量最多 128 KiB。所有等待都在后台队列，主线程保持可用。

## 验证与后续阶段

已有原创 HTML 规则源和同步脚本源样本，覆盖原版 JSON 导入、真实 QuickJS 执行和四步内容链路。测试传输返回固定的原创 HTTP 文档；它验证兼容引擎，不冒充真实站点验收，也不宣称已与 Android APK 做差分执行。最终测试数量、命令和结果见[本轮验证记录](verification/2026-11-06-legado-prototype.md)。

后续按已提出的路线推进：先扩充代表性书源样本并与固定参考阅读版本做差分；再补登录 UI、浏览器验证、跨主机请求和常用加密／Java 对象接口；最后评估需要服务端补充的特殊源。每类功能以完整搜索、详情、目录、连续正文和重启恢复为验收依据。

用户提供的大灰狼包使用不透明来源标识、多个请求主机、登录 UI、设备及 Java 扩展接口，是高级阶段样本。当前仍保留导入和导出，不能声称该包已完整搜索阅读。冻结样本为先前 HTTP 200 获取的 157,920 字节，SHA-256 `e5e81f26de9b39d87d6ebde860ddecef373be78860b65c58101825b6f026f0ae`；未将原包及其中潜在账号数据提交到仓库。

参考：[阅读规则基线](https://raw.githubusercontent.com/gedoor/legado/fd026e0/app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeRule.kt)、[宿主接口基线](https://raw.githubusercontent.com/gedoor/legado/fd026e0/app/src/main/java/io/legado/app/help/JsExtensions.kt)、[QuickJS 文档](https://bellard.org/quickjs/quickjs.html)。
