# 原生兼容书源 v1

正式版可导入 HTTPS 链接或 JSON 文件，预览确认后保存；也可编辑和导出。未知规则保留但不运行。当前没有通用 CSS、XPath、JavaScript 或任意阅读 3.0 宿主，不将 JSON 语法通过视为兼容。

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

所有接口为 GET，参数替换采用 URL 编码，仅允许同源路径。当前兼容 JSON 源为公开接口，不接受配置中的凭据或自定义鉴权头；需登录的书山仍用其原生登录和钥匙串。`discover` 和 `categories` 可省略，省略后关闭分类发现。

| 接口 | 返回 JSON |
| --- | --- |
| 搜索／发现 | `{"books":[{"id":"b1","title":"作品","author":"作者","summary":"简介"}],"nextPage":null}` |
| 详情 | `{"id":"b1","title":"作品","author":"作者","summary":"简介"}` |
| 目录 | `[{"id":"c1","title":"第一章","access":"readable"}]` |
| 正文 | `{"chapterID":"c1","paragraphs":["真实段落一","真实段落二"]}` |

`id` 在来源内稳定；正文 ID 必须与请求章节一致。`access` 可为 `readable`、`restricted`、`volume`；受限项和分卷不读取正文。`nextPage` 必须为大于当前页的整数，末页使用 `null`。单个响应最多 4 MiB，目录最多 50000 项。书源包上限 5 MiB／1000 项。

导出外层为 `{"format":"yueshan-sources","version":1,"sources":[...]}`，也接受单个对象或对象数组。凭据字段会剔除。书山可用 `adapter: "shushan"` 和对应 HTTPS 主机表示，恢复后需重新登录。

搜索默认最多并发 3 个来源。一源失败保留其他结果；同名同作者仅分组为候选，保留各版本的独立身份。换源必须取得新正文并确认位置，无法唯一定位时用户明确选章／同意章首；原来源的历史和书签保留。主动下载独立于近期缓存，最大 256 MiB、最多同时下载 2 章；后台暂停，不承诺 iOS 无限后台下载。
