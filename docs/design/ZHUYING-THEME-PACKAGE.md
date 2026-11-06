# 竹影主题包：可分享、可还原的外观方案

状态：设计提案，尚未实现 `.zhuyingtheme` 导入、导出或全局换肤。本文不代表当前 App 已支持这些能力。

配套文稿：[给 AI 的主题制作提示词](ZHUYING-THEME-AI-PROMPT.md)。当前可导入的示例：[阅读主题 JSON](theme-examples/竹影-青竹阅读.json)。

## 1. 格式建议

用户分享一个文件，例如 `竹影-幻想夜航-1.0.0.zhuyingtheme`。文件内容是标准 ZIP，配置使用 UTF-8 JSON，图片、CSS、SVG、字体作为独立文件保存。开发和排查时可以将其副本改为 `.zip` 解压查看。

这比把图片、字体全部转成 JSON 内的 Base64 更适合资源分享：文件结构易检查，资源可以独立校验，通用 ZIP 工具即可打包。ZIP 使用 Store 或 Deflate，不加密、不分卷，不要求专用压缩器。

JSON、CSS 或一张背景图单独分享，不能表达“完整主题”。主题包要同时保存外观配置、当前搭配、阅读排版、资源内容及渲染兼容要求。

包根目录直接包含 `manifest.json` 和 `theme.json`，不要再套一层同名文件夹：

```text
竹影-幻想夜航-1.0.0.zhuyingtheme
├── manifest.json             # 格式、身份、兼容能力、所有文件的校验清单
├── theme.json                # 全局外观与阅读配置；引用以下本地资源
├── assets/
│   ├── icons/                # 应用内图标及其状态资源
│   ├── backgrounds/          # 应用、页面、阅读背景
│   ├── reader/title.css      # 原生阅读器兼容的章节标题 CSS
│   ├── reader/bubble.svg     # 段末气泡
│   └── fonts/                # 可分发字体，可选
├── preview/                  # 可选；声明为预览，不作为实际效果证明
└── licenses/                 # 所附字体和素材的分发许可
```

iOS 通过自定义文档类型识别该后缀，并接入现有文件导入、导出和系统分享。UTType 标识应使用竹影实际控制的反向域名，并符合 ZIP 文档类型；不能把示例域名当作正式标识。参见 [Apple：定义应用文件类型](https://developer.apple.com/documentation/uniformtypeidentifiers/defining-file-and-data-types-for-your-app)。

## 2. 当前能力与新增能力

当前能力以 `ios/THEME_PACKAGES.md`、`ThemeAssets.swift`、`ThemeReadingBridge.swift`、`ReaderPreferences.swift` 为准。

| 范围 | 当前实际能力 | 本提案增加的能力 |
| --- | --- | --- |
| 阅读主题 | JSON 配色、章节标题 CSS、SVG 气泡及评论卡片基础样式 | 将实际生效搭配打包，不只导出主题原始定义 |
| 阅读排版 | 本机保存字号、行段距、留白、页眉页脚等 | 在主题包中完整携带并可选择应用 |
| 字体 | 本机单独导入管理 | 携带有分发许可的字体，并重新建立本机引用 |
| 应用界面 | 固定 Palette 和分散图标 | 颜色、图标、背景、交互视觉状态统一由主题提供 |
| 分享 | 当前主题导入器读取 JSON；不读取 ZIP 和外部资源路径 | `.zhuyingtheme` 文件导入、导出、预览与系统分享 |

旧 JSON 导入仍保留；旧 JSON 没有的布局、字体和资源，不得伪装为已完整迁移。

## 3. “完整继承”的明确含义

### 3.1 导出实际生效的结果

导出器应读取应用当前的**有效外观快照**，而不只读取所选主题 ID：

- 展开基础主题、内置默认值与个人覆盖，得到确定值。包内不依赖另一款主题或制作者设备上的配置。
- 章节标题以 `effectiveTitleCSS` 为准；气泡以当前是否跟随主题及个人覆盖为准；评论卡片以 `effectiveGodStyle` 为准。
- 包内资源引用必须闭合：引用的字体、SVG、CSS、图片全部存在，不能只保存本地路径、资源 ID 或制作者设备上的哈希引用。
- 同时保留可编辑的源资源与包内资源标识。渲染缓存重新生成，不导出临时 PNG 缓存、数据库内部引用或沙盒绝对路径。
- 当前版本不支持的作者原始 CSS 可作为独立来源附件保存，但不能作为生效样式，也不能据此宣称能够还原网页装饰。
- 导出前显示内容清单和缺失项。严格完整导出遇到缺失必需资源必须停止；用户可以选择移除缺失部分并另存为明确标注的部分主题。

### 3.2 保存阅读外观，而非私人阅读数据

必须覆盖以下阅读外观设置：

| 类别 | 应携带的设置 |
| --- | --- |
| 正文 | 字号、附加行距、段距、字重、首行缩进、字体角色、纸色、文字色、强调色 |
| 留白 | 上下左右留白、左右联动、背景图的铺放方式及遮罩 |
| 页眉页脚 | 启用状态、高度、间隔，所有元素的类型、区域、相对位置、宽度、字号和颜色 |
| 章节标题 | 当前生效 CSS、来源说明；不要让接收者旧的个人标题覆盖完整主题 |
| 气泡 | 显示开关、样式、圆角、颜色、SVG、跟随主题或个人覆盖的有效结果 |
| 段评／神评 | 显示开关、有效卡片样式、背景、边框、圆角；资源引用如适用 |
| 内容样式规则 | 可移植的全书范围显示规则、启用状态、匹配方式、呈现方式和颜色 |
| 翻页视觉 | 水平和垂直翻页的视觉效果设置；读取模式另列为可选阅读行为 |

不携带书籍正文、真实段评内容、登录信息、阅读进度、书源密钥、个人书籍／书源 ID。段评分享的是外观，不是评论数据库。

书名、章节名、时间、进度等页眉页脚元素保存“元素类型”，接收者打开自己的书时动态生成。自定义文字必须在导出确认页展示，允许删除，避免把个人信息随皮肤传播。

当前书籍／当前书源范围的规则不自动转换为“全部书籍”；默认排除并列入导出说明。只有用户明确选中后，才允许转换成可移植规则，并单独记录转换结果。

### 3.3 区分外观、排版和行为

应用整体页面结构、Tab 数量与顺序、入口、点击区域及导航路径不随主题改变。阅读排版属于主题可以携带的配置，但与应用页面改版不同。

`mode`（滚动／左右／上下翻页）、`tapToTurn`、`haptics` 等属于接收者的阅读行为。主题可以提供 `optionalReadingBehavior`，应用时单独选择，默认保留接收者设置；不能用导入皮肤的动作悄悄改掉手势和震动。

### 3.4 一致性标准

“完整继承”指所有支持的参数、搭配关系和资源得到无损传递，并由相同兼容级别的渲染器解释。跨屏幕大小、系统字体版本、动态字体和系统版本，行数、分页与像素位置可能不同；相同内容、设备、字体文件和渲染器条件下才进行截图一致性比较。

字号和留白使用原生逻辑点；页眉页脚元素继续使用区域内的百分比坐标，不能把一个机型的截图坐标直接用于其他设备。

系统字体引用要声明具体字体角色，并标明它随系统版本变化。若要固定字形，需附带允许再分发的实际字体文件；只写字体名称不足以固定版式。无许可字体不能随包分享，导出时必须提示替代方案及可能的版式变化。

## 4. 文件协议草案 v1

以下为**未来协议**；当前导入器不认识这些字段。完整字段约束需在开发导入器时发布 JSON Schema 和 App 导出的 `theme-contract.json`，并锁定为同一版本。

### 4.1 manifest.json

`format` 固定为 `zhuying-theme`，`formatVersion` 为独立主题包版本，不与旧阅读 JSON 或 App 版本混用。`themeVersion` 使用语义版本；`themeID` 是稳定、可共享的标识，不能含设备标识。

```json
{
  "format": "zhuying-theme",
  "formatVersion": 1,
  "themeID": "org.example.zhuying.qingzhu",
  "themeVersion": "1.0.0",
  "name": "竹影·青竹",
  "author": "示例作者",
  "packageKind": "component",
  "scopes": ["reader"],
  "appearanceModes": ["light"],
  "requiredCapabilities": ["reader.native-title-css.v1", "reader.comment-bubble-svg.v1"],
  "optionalCapabilities": [],
  "entry": "theme.json",
  "files": []
}
```

上例是字段说明，不是可分发成品；`files` 必须由打包工具实际计算并填满。每条记录为 `path`、`bytes`、`sha256`、`mediaType`、`role`，列出除 `manifest.json` 自身以外的所有文件，包含 `theme.json`、预览和许可。校验使用真实文件字节；不要先计算摘要再格式化文件。manifest 不自我计算摘要，整包 SHA-256 可在分享信息或旁置报告中记录。

角色为 `configuration`、`icon`、`background`、`title-css`、`bubble-svg`、`font`、`preview`、`license`、`source`。哈希只能检测完整性，不能证明作者身份。

`packageKind`：

- `full`：必须同时覆盖 `app` 与 `reader`，显式记录全部有效外观。完整性按指定 `theme-contract.json` 中的必需角色检查，不能自称 full 却只提供几个图标。
- `component`：仅包含声明范围。可以制作阅读套装、图标包、背景包。导入时不能覆盖未声明范围，也不能标为“完整继承整款软件”。

### 4.2 theme.json 的分区

| 字段 | 约定 |
| --- | --- |
| `contractVersion` | 对应 App 发布的主题角色与范围清单版本；不是制作者任意填写的 App 版本号 |
| `app` | 全局语义颜色、按角色引用的图标、背景、控件各状态、装饰资源及内置动效预设 |
| `reader.appearance` | 对应原生外观字段的完整快照，详见第 5 节 |
| `reader.resources` | 已解析的标题 CSS、气泡 SVG、字体与阅读背景，引用包内路径或声明的内置资源 |
| `reader.optionalReadingBehavior` | 可选 `mode`、`tapToTurn`、`haptics`；独立于默认外观应用 |
| `fontBindings` | 字体角色到包内文件、SHA-256、PostScript 名称与许可文件的映射；系统字体则使用明确的内置角色 |

颜色使用 `#RRGGBB`，透明度单独用 `opacity: 0...1`，避免八位颜色的 ARGB/RGBA 歧义。转换到现有原生整数色值由适配器负责。

每个资源引用必须使用下列两种形态之一，不能混用：

```json
{
  "packageResource": {"path": "assets/reader/title.css"},
  "builtinResource": {"builtin": "reader.title.default", "version": 1}
}
```

上例展示两种独立引用，不是同一资源同时具有两个来源。内置资源 ID 和版本必须被接收端精确支持；制作者不能自造内置 ID。要求零外部素材依赖时，优先使用包内资源。使用内置资源时也要记录能力版本，否则默认资源更新后会改变结果。

`app` 中的颜色角色用 `background.page`、`background.card`、`text.primary`、`text.secondary`、`action.primary.background`、`action.primary.foreground` 等语义名称。图标角色用 `navigation.shelf`、`action.search` 等名称；完整清单以 App 的合同为准，不在提示词里臆造全部角色。

控件状态至少定义 normal、pressed、selected、disabled、focused、loading 的解析规则。可以由基础样式按确定算法派生，不强制每个状态都附一张图片，但最终导出需记录算法及版本。图片背景同时记录铺放、对齐、透明度、遮罩；图标记录画布、对齐及模板着色方式。装饰图片不得携带按钮动作。

v1 动效使用有版本的内置预设和有界参数，减少动态效果开启时有静态替代；不执行 JavaScript，不包含任意可执行代码。任意动画文件属于后续能力，不应在第一版提示词中假定已经支持。

同一主题可以有 light、dark 两套变体；每个声明变体都要通过完整性校验。应用可单独保存用户选择的外观模式，不能因包缺少暗色就悄悄生成一套未验证的暗色。

## 5. 原生阅读配置映射

`reader.appearance` 不是把整个 `ReadingSettings` 和本机数据库序列化出去，而是下列允许导出的字段投影。打包工具展开全部有效值后写入。

```json
{
  "fontSize": 20,
  "lineSpacing": 12,
  "preferences": {
    "paragraphSpacing": 22,
    "leftMargin": 25,
    "rightMargin": 25,
    "topMargin": 24,
    "bottomMargin": 20,
    "marginsLinked": true,
    "firstLineIndent": true,
    "fontWeight": "常规",
    "colors": {"background": "#F7FAF8", "ink": "#182B25", "accent": "#16876A", "name": "青竹", "dark": false},
    "headerEnabled": false,
    "footerEnabled": false,
    "headerHeight": 64,
    "footerHeight": 64,
    "headerGap": 12,
    "footerGap": 12,
    "pageElements": [
      {"id": "header-book", "zone": "header", "kind": "书名", "text": "", "x": 28, "y": 45, "width": 46, "fontSize": 11, "color": null},
      {"id": "header-time", "zone": "header", "kind": "时间", "text": "", "x": 82, "y": 45, "width": 26, "fontSize": 11, "color": null},
      {"id": "footer-chapter", "zone": "footer", "kind": "章节", "text": "", "x": 23, "y": 50, "width": 36, "fontSize": 11, "color": null},
      {"id": "footer-progress", "zone": "footer", "kind": "进度", "text": "", "x": 68, "y": 50, "width": 54, "fontSize": 11, "color": null}
    ],
    "horizontalEffect": "平移",
    "verticalEffect": "平移",
    "rules": [],
    "showCommentBubbles": true,
    "showGodComments": true,
    "bubbleStyle": "胶囊",
    "godStyle": "纯色",
    "bubbleRadius": 12,
    "bubbleColor": null,
    "godRadius": 10,
    "godBackground": null,
    "godBorder": null
  }
}
```

`fontName`、`fontResourceHash` 改由 `fontBindings` 和字体角色解决，导入后重新注册并生成本机引用。标题／气泡来源分支合并为 `reader.resources` 中的有效资源，导入时再建立跟随主题关系。`themeTitleCSS`、`titleCSS`、`bubbleFollowsTheme` 等不能和一份已展开的有效快照互相冲突。

不导出 `bubbleImageData`、`customBubbleImageData` 等缓存。上例仅示范阅读投影，不包含字体绑定和资源定义，不能直接作为完整 `theme.json`。

当前 `ReaderPreferences.normalize()` 的约束必须用于作者预检：段距 0–48 pt；四边留白 0–80 pt；页眉页脚高度 48–140 pt、间隔 0–48 pt；圆角 0–30 pt；最多 32 个页面元素、64 条显示规则。元素宽 15–90%，字号 9–22 pt；中心坐标须满足原生 `constrained()`，不能只校验 0–100。正则／关键词规则最长 512 UTF-16 单元，导入仍需匹配预算。正文字号和行距的完整范围待合同发布，AI 应使用 App 导出的有效模板，不自行猜测。

## 6. CSS、SVG 与预览的兼容要求

当前标题 CSS 只允许一个 `.chapter-title { ... }` 规则。支持 `font-size`、`font-weight`、`text-align`、`color`、`background-color`、`letter-spacing`、`padding-top`、`padding-bottom`、`border-bottom`。

禁止伪元素、额外选择器、外部资源、脚本、`@import`、`!important`。`border-bottom` 当前只转换成文字下划线，不保留真实边框的宽度、颜色和线型；要精确还原，优先不用该属性。只使用 `pt` 数值以贴合当前原生解析器；当前实现把相同数值的 px、pt 同等处理，这不是浏览器 CSS 的换算行为，不能拿浏览器截图作为原生效果验收。标准 CSS 单位关系见 [W3C：绝对长度](https://www.w3.org/TR/css-values-4/#absolute-lengths)。

当前解析范围：标题字号 14–48 pt，字间距 -2–16 pt，上下间距 0–60 pt；字重接受 normal、medium、bold 及 100–900 百位值；对齐接受 left、center、right、justify。变量仅使用已验证的 `var(--accent)` 等已知变量，不新增任意变量。主题配色选择普通六位颜色，便于预览与原生统一。

气泡 SVG 使用现有被动 SVG 白名单和占位符 `{{background}}`、`{{ink}}`、`{{accent}}`、`{{count}}`。不得引用外部文件、字体、网络地址，不含事件处理器或脚本。仅有文本的 SVG 也可能通过当前校验，但设计验收应包含清晰的气泡主体。预览至少覆盖 0、9、99、999+ 四种计数和长标题；当前真实段评数据支持情况必须据实标注。

必须分别验证 WebKit 资源预览与原生正文结果；“网页预览正常”不能代替“原生能够完整继承”。AI 未实际运行 App 时，交付状态写“待原生验证”。

## 7. 导入、应用与覆盖规则

1. 读取 manifest，检查格式、版本、声明能力、文件清单、大小和 SHA-256，然后解析所有必需资源；任何失败都不改变当前主题。
2. 将资源放入暂存区，在原生书架、设置、阅读器中预览，显示缺失、字体替代、CSS 不兼容等差异。
3. **完整应用**：在用户选择范围内，用包中快照覆盖接收者旧的个人外观覆盖；先保存可恢复的旧快照。应用页明确说明会覆盖排版、气泡和标题的个人设置。行为设置另选。
4. **混搭应用**：用户只勾选配色、图标、背景、阅读排版等部分，保留其他设置；标为“混搭”，不宣称完整还原。
5. 一次提交主题及全部资源引用，失败整体回滚，重启后保持一致。缺少必需能力不允许以“成功”掩盖降级；可以另存用户确认过的兼容副本，并保留原包。
6. 相同 themeID 与版本且内容相同视为重复；同 ID 同版本但内容不同提示冲突，不能静默覆盖。新版本先另存并预览，仍可恢复旧版本。

默认导入只加入库，不自动应用；也不在接收者打开分享文件时自动改变界面。包内不能指定导航、网络请求、账号动作或任意代码。

## 8. 资源限制与兼容

建议 v1：压缩文件不超过 20 MiB；实际解压总量不超过 64 MiB；最多 512 个文件；CSS／SVG 每个不超过现有 60,000 字节。图片采用 PNG／JPEG，单图不超过 4 MiB、2048×2048，解码内存另行设限；字体 TTF／OTF 单个不超过 10 MiB。WebP、复杂动画、完整网页 CSS 在能力合同中另行声明后支持，不先承诺。

只接受普通文件，路径为包内相对路径；拒绝绝对路径、`..`、反斜线、符号链接、加密文件、大小写／Unicode 归一化冲突、重复文件和实际解压超限。必须对流式解压后的实际字节计数，不能只信任 ZIP 文件头。生成端应只收录必要素材，接收端对清单外文件拒绝处理。

桌面 App 图标、系统键盘、权限弹窗不属于任意资源替换范围。主题仅能选择 App 已支持的桌面候选图标，不能把任意包内图片安装成桌面图标。系统保留的无障碍与减少动态效果选择应始终有效。

## 9. 开发与验收顺序

1. 发布主题能力合同：先盘点全部应用内颜色、图标、背景和状态角色，输出带版本、类型、单位、默认值、范围的 `theme-contract.json`，并发布 JSON Schema。本文是开发输入，不代替机器协议。
2. 接入现有组件和阅读器；保持原布局、功能入口和点击行为。用现有原生视图提供所见即所得预览。
3. 开发快照导出、资源收集、合法打包、原子导入和恢复。沿用现有资源仓库与备份的事务经验，不直接分享整个书库备份。
4. 再增加 AI 制作校验器、导出模板、主题分享入口和完整度报告。

验收至少包含：导出→导入→再导出的有效配置与资源哈希一致；清空接收端缓存并断网仍可还原；接收者已有个人 CSS／气泡时“完整应用”与“混搭应用”分别正确；页眉页脚／规则／显示开关／字体恢复；删除主题时引用资源不丢失；损坏包和缺少能力时不影响原主题；相同条件截图比较与不同屏幕自适应验证；原有页面路径和交互回归。

本次文稿的自动检查仅覆盖示例与原生能力的一致性；以上 App 运行时验收均属于后续实现工作。
