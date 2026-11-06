# 原生兼容书源 v1

正式版可导入 HTTPS 链接或 JSON 文件，预览确认后保存；也可编辑和导出。未知规则保留但不运行。支持原生 JSON v1、下述 extract-v1 和[阅读 3.0 阶段二兼容原型](LEGADO-COMPATIBILITY.md)。CSS／XPath／JSONPath／正则及脚本宿主均按明确范围执行，不将 JSON 语法通过视为任意阅读 3.0 书源已验证可读。

## 阅读 3.0 原版规则

原版 JSON 使用独立的 Legado 兼容适配器，不需要改为下方的 `json-v1` 接口格式。阶段二支持共享 `jsLib`／登录程序作用域、原生 `loginUi` 子集、受限网页等待、声明或用户明确允许的多个 HTTPS 主机，以及有界的 `data:;base64` 内部请求引用。同步 `java.ajax` 保持同步返回语义，没有用文本替换改成 `await`。

来源字符串标识与请求主机分开保存。Cookie 和会话按来源、账号、书库配置及主机隔离；变量和缓存整体加密，登录信息、Cookie 与完整请求描述保存在钥匙串。带载荷、查询或请求选项的书籍／章节引用使用不透明键；兼容保留的普通 HTTPS 直链可直接保存。包含 POST body／私有请求头的完整描述不直接写入书籍／章节元数据。网页登录结果、收到 Cookie 或脚本提示成功都不自动确认账号已验证。

常用加密接口覆盖 AES ECB／CBC 和 Android Base64；空 `JavaImporter` 仅能导入已实现的 Base64 对象，不提供任意 Java 环境。HTTP 明文、网页内同步 Android 宿主桥及其他高级规则仍有明确限制。限额、头继承策略和注销行为见[详细兼容说明](LEGADO-COMPATIBILITY.md)，结果见[阶段二验证记录](verification/2026-11-06-legado-advanced.md)。原包离线初始化通过，不代替真实大灰狼登录、多书阅读或参考 APK 差分验收。

## json-v1

单个来源示例（域名仅为占位，不能用于可读性验收）：

```json
{
  "bookSourceName": "我的兼容书源",
  "bookSourceUrl": "https://books.example",
  "enabled": true,
  "adapter": "json-v1",
  "endpoints": {
    "version": 1,
    "search": "search?q={query}&page={page}",
    "details": "books/{bookID}",
    "catalog": "books/{bookID}/chapters",
    "content": "books/{bookID}/chapters/{chapterID}",
    "discover": "discover?category={category}&page={page}",
    "categories": ["全部", "原创"]
  }
}
```

所有接口为 GET，参数替换采用 URL 编码，仅允许同源路径。本节 `json-v1` 为公开接口，不接受配置中的凭据或自定义鉴权头；需登录的书山仍用其原生登录和钥匙串。`discover` 和 `categories` 可省略，省略后关闭分类发现。

| 接口 | 返回 JSON |
| --- | --- |
| 搜索／发现 | `{"books":[{"id":"b1","title":"作品","author":"作者","summary":"简介"}],"nextPage":null}` |
| 详情 | `{"id":"b1","title":"作品","author":"作者","summary":"简介"}` |
| 目录 | `[{"id":"c1","title":"第一章","access":"readable"}]` |
| 正文 | `{"chapterID":"c1","paragraphs":["真实段落一","真实段落二"]}` |

`id` 在来源内稳定；正文 ID 必须与请求章节一致。`access` 可为 `readable`、`restricted`、`volume`；受限项和分卷不读取正文。`nextPage` 必须为大于当前页的整数，末页使用 `null`。单个响应最多 4 MiB，目录最多 50000 项。书源包上限 5 MiB／1000 项。

导出外层为 `{"format":"zhuying-sources","version":1,"sources":[...]}`，也接受单个对象或对象数组。凭据字段会剔除。书山可用 `adapter: "shushan"` 和对应 HTTPS 主机表示，恢复后需重新登录。

搜索默认最多并发 3 个来源。一源失败保留其他结果；同名同作者仅分组为候选，保留各版本的独立身份。换源必须取得新正文并确认位置，无法唯一定位时用户明确选章／同意章首；原来源的历史和书签保留。主动下载独立于近期缓存，最大 256 MiB、最多同时下载 2 章；后台暂停，不承诺 iOS 无限后台下载。

## extract-v1

将 `adapter` 设为 `extract-v1`，保留相同的 `endpoints` 路由，并添加 `endpoints.extraction`。该对象的 `version` 为 1，包含 `search`、`catalog`、`detailTitle`、`paragraphs`，可选 `nextPage`、`detailAuthor`、`detailSummary`。`search` 和 `catalog` 均有 `rows`、`id`、`title` 规则，可选 `author`。先对响应执行 `rows`，再对每项执行字段规则。搜索条目最多 500，解析输出最多 2000 项。

规则示例：`{"version":1,"kind":"css","expression":"article","projection":"html","capture":0}`。提取属性使用 `projection:"attribute"` 和 `attribute:"data-id"`。默认输出 `text`；JSON 对象／数组条目序列化为 JSON，再供字段规则处理。正则捕获使用 `capture:0...20`。

| 类型 | v1 支持 | 显式不支持 |
| --- | --- | --- |
| CSS | 元素、class、id、属性及后代／子代／相邻／兄弟选择 | 伪类、转义选择器 |
| XPath | 元素路径、属性／位置谓词；属性通过 projection 提取 | 函数、轴、联合和外部文档 |
| JSONPath | `$`、`.key`、`[数字]`、`[*]`、`["键名"]` | 递归、过滤脚本、切片 |
| 正则 | ICU 表达式、UTF-16 捕获；0.2 秒进度中止、取消 | 无限执行和无上限输出 |

输入仅接受 UTF-8，单响应 ≤ 2 MiB、标记树 ≤ 8000 个标记；合计输出 ≤ 2 MiB。不解析外部实体，不执行网页或导入规则中的 JavaScript、Cookie、自定义鉴权。其他编码和宿主 API 需独立适配。内置“书源调试 → 规则兼容测试”可直接验证用户输入，测试过程不联网。
