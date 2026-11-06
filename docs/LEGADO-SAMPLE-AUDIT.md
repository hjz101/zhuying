# Legado 冻结样本审计与差分记录

本页记录可复现的审计方法与未验证边界。扫描通过、宿主方法存在、离线库初始化、公开根路径可达、真实账号阅读、Android APK 差分，是不同证据，不能互相替代。完整兼容状态见 [兼容说明](LEGADO-COMPATIBILITY.md) 与 [阶段二验证](verification/2026-11-06-legado-advanced.md)。

## 固定输入与只读审计

本地冻结文件 `/tmp/zhuying-user-sources.json` 为单书源包，157,920 字节，SHA-256 为 `e5e81f26de9b39d87d6ebde860ddecef373be78860b65c58101825b6f026f0ae`。原文件、脚本内容、账号、请求参数不进入仓库。新下载文件即便同名，也必须重新核对哈希。

```sh
node ios/scripts/audit-legado-source.mjs audit /tmp/zhuying-user-sources.json --android-environment > /tmp/zhuying-legado-audit.json
node --test tests/legado-audit-script.test.js
```

工具不执行任何源 JavaScript，不访问 Keychain、应用数据库或账号状态。报告仅包含文件哈希、固定 schema 字段的类型与长度、已知宿主方法名称及其字段内行号、字面量 URL 的 origin、扫描限制和设备状态计数。不会输出源名称、source identity、URL query、请求 body、脚本、登录字段值、未知方法名称或设备序列号；输入错误也只输出固定错误码。

报告中的 `native-dispatch-present` 表示当前 Swift 文件存在对应分发，不能证明该宿主完整遵循参考语义或该分支执行过。词法扫描跳过注释、普通字符串与正则表达式，进入模板的 `${}` 表达式；动态成员与词法错误会显式记录。嵌入 HTML 的完整脚本块单列为 `page-bridge-not-proven`；被模板切开的 HTML 只记 `embeddedPageFragments`，不能据完整脚本块数量为零断言没有页面桥需求。别名、动态生成脚本、变量值与分支可达性需要运行时证据。

URL origin 列表是字符串内的保守候选，可能含页面 CDN、SVG namespace、下载链接及已经过期的备站；它不是运行路线列表，也不会自动扩大网络白名单。HTTP 候选会标记不支持。实际请求仍由来源的网络策略校验，凭据按来源、账号、资料库及 origin 隔离。

## 主链路审计结论与最小优先序

冻结样本包含搜索、详情、目录、正文所需的基础字段。主链路依赖如下：

| 阶段 | 关键依赖 | 最小验收 |
| --- | --- | --- |
| 搜索 | source 变量、cookie、模板 URL、共享 jsLib、JSON 列表 | 新会话实际搜索，得到可打开的两本不同书；记录独立网络证据，不使用预置结果 |
| 详情 | `data:;base64` 描述、hex 解码、同步 ajax、POST、浏览器挑战、`book.setUseReplaceRule` | 两本书分别打开详情；书籍身份不随登录或路线变化；净化开关按书保存 |
| 目录 | 同步 ajax、每书 `java.get/put`、book 变量、设备标识、qingtian 内部引用 | 两书交错取目录后章节仍属于各自书籍；重启、登出后再登录可恢复引用 |
| 正文 | 目录 payload、cookie、同步 ajax、设备标识、手动浏览器挑战、环境探测 | 每书连续三章非重复有效正文；无缓存替代；取消/登出后旧回包不复活凭据 |

1. 先补齐实际调用并验证语义。固定参考的 `book.setUseReplaceRule(Boolean)` 只设置当前书籍的阅读净化配置；它控制用户全局/书籍/来源净化规则，不关闭源的内容提取、JavaScript 或 `##` 替换。竹影现已新增独立书籍标记及净化处理入口；运行集成由对应验证记录确认。[固定参考 Book.kt](https://github.com/gedoor/legado/blob/fd026e0/app/src/main/java/io/legado/app/data/entities/Book.kt#L189-L202)
2. 优先验证登录后真正的多书链路。源的 `java.put/get` 与 qingtian2/qingtian3 payload 相互依赖；只验证一书或只导入 JSON，无法排除串书、登录 epoch 失效、POST 描述丢失或章节内容重复。
3. 将环境探测与缺失能力分开。`java.qread` 在共享库/正文的环境探测分支出现，不能为了消除异常伪装成另一客户端。`java.refreshExplore` 在共享库与登录动作出现；当前静态扫描仍可报告缺口。固定 `JsExtensions`/`AnalyzeRule` 中未确认其实现，不据名称凭空实现成功语义，需核对具体 Android 分支或实际运行结果。[固定参考 JsExtensions](https://github.com/gedoor/legado/blob/fd026e0/app/src/main/java/io/legado/app/help/JsExtensions.kt)、[AnalyzeRule](https://github.com/gedoor/legado/blob/fd026e0/app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeRule.kt)
4. 仅在实际分支触发时补页面桥或 Java 能力。样本登录脚本可生成 HTML 设置页，正文/详情可发起浏览器挑战；页面 JavaScript 与 QuickJS 中可调用的宿主并非同一个环境。仅支持已核对的 Base64、AES、安装标识与浏览器返回契约，不把任意 `Packages`/Android 同步对象或网页调用假装为可用。该包的 `ruleContent` 未设置 `webJs/sourceRegex/replaceRegex/payAction`，暂不据通用字段清单扩大实现范围。

上述顺序是基于静态使用关系的推断。它不是服务当前可用性、账户权限或所有分支可达性的结论。标准 AES 重载的参考是 [JsEncodeUtils.kt](https://github.com/gedoor/legado/blob/fd026e0/app/src/main/java/io/legado/app/help/JsEncodeUtils.kt)，并不等于提供任意 Java 安全提供者。

## 匿名公开路径连通性

经任务负责人确认后，可执行：

```sh
node ios/scripts/audit-legado-source.mjs public-smoke > /tmp/zhuying-legado-connectivity.json
```

命令只对代码中固定的 `https://v5.langge.uk/` 与 `https://v4.langge.uk/` 各发一次 GET，最多两次并发、各 10 秒；无 query、body、Cookie、Authorization，也不读取账号或原包。重定向不跟随，响应 body 取消读取。输出只保留固定 origin、`/`、HTTP status、是否重定向、耗时和固定错误码。命令不接受 URL 参数，因此不能将其变成带凭据的通用请求工具。

2026-11-06 23:59 左右（Asia/Shanghai）执行时，两处根路径均返回 502，无重定向。这个结果只说明当时公开根路径响应，不能证明搜索接口或账号失败，也不能计为成功阅读。后续真实账号验证应在独立验收应用中完成，保留脱敏的新请求证据。

## Android 差分环境与记录格式

本次环境检查发现 `adb` 可用，已连接设备计数为零，`emulator/sdkmanager/avdmanager` 不在 PATH，未发现本地 Android SDK/AVD。未执行 Android APK，不存在 APK 差分通过结果。仅有 adb 不能建立参考运行环境。

有真实 Android 环境后，将同一冻结源、同一组无凭据离线响应 fixture 分别送入固定参考 APK 与竹影。采集器需要对 APK/竹影构建文件、完整 fixture 包与源分别计算 SHA-256。四阶段每项输出按约定规范化后哈希，不能用平台生成的书籍 ID 直接比较：字符串仅统一 CRLF 为 LF；JSON 对象键排序、数组保序；文本不 trim、不折叠空格、不删段落。相同 fixture 中必须使用相同匿名参数、固定时间与安装标识，禁止嵌入真实账户数据。

两侧各自导出以下脱敏 JSON（以下为格式示意，所有哈希均需采集器实际计算；不提供伪造的完成记录）：

```text
schemaVersion: 1
implementation: legado-android | zhuying-ios
sourceSHA256: 64 位小写 SHA-256
referenceRevision: fd026e0
binarySHA256: 对应实际安装构建的 SHA-256
fixtureSHA256: 同一响应 fixture 包的 SHA-256
captureMode: offline-fixture
capturedAt: ISO-8601 时间
scenarios:
  fixtureID: 固定且不含个人数据的 a-z/0-9/- 标识
  stage: search | details | catalog | content
  outputSHA256: 规范化语义输出的 SHA-256
  itemCount: 列表项或正文段落数量
  utf16Count: 语义输出的 UTF-16 长度
```

```sh
node ios/scripts/audit-legado-source.mjs compare /tmp/android-record.json /tmp/zhuying-record.json
```

比较器要求两种实现、相同 source/fixture 哈希、四阶段齐全、场景唯一且字段受限；不接收 URL、正文、额外成功标记或 live/cache 模式。不同输出返回退出码 2，无效记录返回 1，相符返回 0。结果始终标记 `provenance: caller-supplied-not-attested`、`runtimeVerification: not-performed-by-this-tool` 和 `liveVerification: not-performed`。它检查记录一致性，不负责认证记录是否来自实际 APK；真实运行仍需采集命令、安装构建和脱敏日志共同支持。离线差分不能替代真实网络和用户账号的验收。
