# JavaScript 宿主 v1

本页介绍手动运行的 Worker 工具。导入阅读 3.0 书源后，在搜索和阅读中运行的独立 QuickJS 兼容层见[阅读 3.0 端侧兼容（阶段三）](LEGADO-COMPATIBILITY.md)，实际覆盖范围见[阶段三验证记录](verification/2026-11-07-legado-stage-three.md)；两个执行入口保留各自的接口与隔离规则。

QuickJS 的 96 MiB 配置预留总预算、操作租约、空闲回收，以及排除受控 HTTP 等待的 5 秒脚本执行预算均属于该兼容层。本页 Worker 工具继续采用下述 WebContent、网络与计时边界，不能套用 QuickJS 的限额或把它们解释为进程 RSS 保证。原书源调试中的结构化恢复和两书六章跨进程复核也不等于一次手动 Worker 脚本执行。

入口为“书源兼容引擎 → JavaScript 宿主与兼容报告”，也可从书源调试进入。导入的其他阅读器脚本不会自动执行；用户填写函数体与 JSON 输入，点击运行后才执行。

示例：`return input.map(value => value.trim());`。函数体在 async function 中执行，以 `input` 和冻结的 `host` 作为参数，返回可 JSON 序列化数据。错误、超时、取消或 WebContent 进程退出不会修改正文和书库。

| API | v1 行为 |
| --- | --- |
| `await host.fetch({url,method,body})` | 显式允许网络后，仅所选 HTTPS 来源；GET／POST，POST 字符串使用 JSON Content-Type；不读取 Cookie、应用登录头或钥匙串；成功返回 status／body／mime，失败抛错 |
| `await host.cacheGet(key)`／`cachePut(key,value)` | 字符串，来源＋主机＋账号隔离；持久可重建，不进入备份 |
| `await host.extract(rule,input)` | 已声明的解析器 v1；version／projection／capture 可省略默认项 |
| `await host.sha256(text)` | UTF-8 SHA-256 |
| `host.base64Encode`／`base64Decode` | UTF-8，支持中文与 emoji，无效 UTF-8 报错 |
| `host.urlEncode`／`urlDecode` | encodeURIComponent／decodeURIComponent |

用户代码仅在 Web Worker 中运行。原生页面的固定脚本只转发消息。CSP 禁止直接联网，Worker 关闭 fetch、XHR、WebSocket、EventSource、importScripts 和子 Worker。使用公开 worker.terminate() 取消循环，不使用私有 JavaScriptCore 限时接口。

脚本 ≤ 64 KiB，输入／输出 ≤ 1 MiB，宿主调用 ≤ 128 次／参数合计 ≤ 2 MiB；网络 ≤ 8 次／响应合计 ≤ 2 MiB。执行上限 0.1–5 秒，页面初始化另有 8 秒超时。缓存每作用域 ≤ 64 项、单值 ≤ 16 KiB、文件 ≤ 512 KiB，最多 32 个作用域。系统管理 WebContent 内存，没有公开的每 Worker 硬堆额度；系统终止按失败处理。

不支持 java.ajax 同步语义、jsoup、任意阅读器完整宿主、跨站 Cookie、无限后台运行。不能把一段脚本成功推导为完整 legado 兼容。原生单测运行实际 WKWebView／Worker，覆盖编码、原生解析、缓存隔离、网络关闭、跨源拒绝、循环终止、取消及新执行。
