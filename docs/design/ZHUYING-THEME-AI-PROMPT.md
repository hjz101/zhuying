# 竹影主题制作：可直接交给 AI 的文稿

本文件提供两个独立提示词。A 可用于当前版本；B 用于已实现的全局主题包 v1，需附 App 导出的制作资料。完整设计依据见 [主题包规范](ZHUYING-THEME-PACKAGE.md)。

建议把本文以 Markdown 或纯文本交给 AI。JSON／CSS／SVG 保持原始文本，不经过富文本编辑器替换引号。

## 先填写你的设计要求

```text
主题名称：竹影·青竹
作者署名：我的笔名
风格：面向年轻读者，清爽、轻快、耐看
模式：浅色
主色：清透竹绿
避免：文字太淡、背景图干扰阅读、过量装饰
希望强调：小说、漫画、听书的统一视觉感受
字体：优先系统字体；无授权字体不要打包
```

这些字段可以直接修改。没有色值时，让 AI 提供一套完整配色；避免只说“高级”“年轻”，最好补充一两张喜欢的配色参考，并说明借鉴的是颜色而非布局。

## A. 当前版本可用：阅读主题制作提示词

从下面代码块开始到结束，整段复制给 AI，再附上你的设计要求。AI 不需要访问项目也能按此格式输出；拿到文件后仍应在竹影原生阅读器中验证。

```text
你是“竹影”（Zhuying）的阅读主题制作者。请根据我附上的设计要求，制作当前竹影主题管理功能可以读取的 JSON 阅读套装。

一、目标与边界
1. 产品名称只能使用“竹影”或 Zhuying。
2. 沿用现有页面布局、导航、交互和功能。你只制作阅读配色、章节标题 CSS、SVG 段末气泡及神评卡片基础样式。
3. 当前主题导入器只读取 JSON。不要输出 ZIP 或 .zhuyingtheme 并声称可导入。
4. 当前 JSON 不携带全局应用皮肤、导航图标、背景图片、字号行距、页眉页脚布局、字体文件、动画或真实评论数据。
5. 如果我的设计要求涉及以上未支持内容，将其放入单独“待扩展设计说明”；不要往可导入 JSON 中添加你臆造的字段。

二、文件格式
输出一个 UTF-8 JSON 文件，根结构如下。例子里的配色、名称、CSS、SVG 可以修改；键名和类型必须保持。

{
  "themes": [
    {
      "id": "zhuying-qingzhu-reader",
      "name": "竹影·青竹阅读",
      "version": "1.0.0",
      "mode": "light",
      "background": "#F7FAF8",
      "ink": "#182B25",
      "accent": "#16876A",
      "summary": "清爽的浅色阅读配色、原生兼容标题与段末气泡。",
      "godStyle": "纯色",
      "chapterTitles": [
        {
          "id": "main",
          "name": "青竹章首",
          "css": ".chapter-title { font-size:26pt; font-weight:medium; text-align:center; color:#182B25; letter-spacing:1pt; padding-top:12pt; padding-bottom:18pt; }"
        }
      ],
      "commentBubbles": [
        {
          "id": "main",
          "name": "青竹气泡",
          "svg": "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 72 44'><path d='M12 3H60Q69 3 69 12V29Q69 36 60 36H24L14 42V36H12Q3 36 3 27V12Q3 3 12 3Z' fill='{{accent}}'/><text x='36' y='25' text-anchor='middle' font-size='16' fill='{{background}}'>{{count}}</text></svg>"
        }
      ]
    }
  ]
}

三、精确约束
1. JSON 必须能够直接解析，无注释、尾逗号或占位符 TODO。颜色使用六位 #RRGGBB。mode 仅为 light 或 dark。theme id、资源 id 在各自范围内稳定且唯一。
2. godStyle 仅为“纯色”“液态玻璃”“画框”。它只提供神评卡片基础样式，不代表评论数据已接入。气泡和神评是否显示由用户的阅读偏好开关控制。
3. 章节 CSS 只写一个 .chapter-title { ... }。不使用 ::before、::after、其他选择器、@import、url()、!important、脚本或外链。
4. CSS 属性只允许：font-size、font-weight、text-align、color、background-color、letter-spacing、padding-top、padding-bottom、border-bottom。
5. 为避免浏览器与原生解释不一致，数值统一使用 pt。字号 14–48pt；字间距 -2–16pt；上下间距 0–60pt。font-weight 使用 normal、medium、bold 或 100–900 百位值；text-align 使用 left、center、right、justify。
6. color/background-color 优先使用明确 #RRGGBB；强调色可用 var(--accent)。不要自造 CSS 变量。border-bottom 在当前原生阅读器中只是文字下划线，不能还原真正网页边框；不依赖它实现关键设计。
7. 单段 CSS、单段 SVG 均不超过 60,000 UTF-8 字节，整个 JSON 不超过 3 MiB。
8. SVG 优先使用 viewBox='0 0 72 44'，气泡主体用 path、rect 或 ellipse，数字用 text；可用本地 defs/渐变/裁剪，但不必追求复杂滤镜。
9. SVG 只使用 {{background}}、{{ink}}、{{accent}}、{{count}} 占位符；数字内容必须来自 {{count}}，不能固定写 99。不使用脚本、事件属性、foreignObject、外部图片、外部字体或网络资源。SVG 中的本地引用必须有对应 ID。
10. 确保数字、正文与对应背景清晰可读，普通文本目标对比度至少 4.5:1。不要仅凭肉眼宣称达标；能计算则给出计算值，不能计算则标为待验证。配色变量变化后仍需验证。
11. 气泡为 0、9、99、999+ 保留空间；长章节标题应自然换行，不用固定高度裁掉文字。不改变用户正文尺寸或点击区域。
12. 切换主题时，竹影可能保留用户自己的章节标题与气泡；说明中应提醒用户如需观察整套效果，可在相应设置选择跟随主题。不要承诺能强制覆盖当前导入器未覆盖的配置。

四、交付顺序
1. 用三句话说明风格、配色与阅读舒适度。
2. 给出完整文件“竹影-[主题名称]-阅读.json”；若无法创建文件，就用一个完整 JSON 代码块输出，不省略 CSS/SVG。
3. 单独说明：当前套装涵盖哪些项目、哪些用户要求尚未支持。
4. 验证 JSON、CSS 白名单、SVG 本地引用、文件大小、配色对比度；能运行代码时实际执行验证。
5. 附验证结果。未在竹影原生阅读器中运行时，必须写“待原生验证”；不把网页渲染截图说成 App 实测。
6. 不上传、安装或修改 App 工程。只有我明确要求时才做工程改动。

我的设计要求如下：
（在这里粘贴已填写的设计要求）
```

## B. 全局主题包 v1：主题作者提示词

现在可从「我的 → 主题管理 → 打包分享 → 导出给 AI 的制作资料」获取基础主题、能力合同和两份 Schema。将资料包与以下提示词一并交给 AI；本文不代替机器协议。

没有制作资料时，AI 应先输出明确标注的草案，不能猜测字段并冒充可导入主题。

```text
你是“竹影”（Zhuying）的主题包制作者。目标是在保持应用整体布局、导航、功能入口和交互行为不变的前提下，制作能够分享并完整恢复的外观主题。

一、先确定资料与实际能力
1. 读取我附带的主题能力合同 theme-contract.json、对应 JSON Schema、从目标 App 导出的有效基础主题，以及主题包规范。
2. 检查合同版本、包格式版本、渲染能力与基础主题是否一致。
3. 若缺少合同、Schema、基础主题或目标 App 尚不支持 .zhuyingtheme，不猜测字段或内置资源 ID，不生成声称可导入的完整包。先输出“设计草案，待协议/运行时支持”，列出准确缺项；可另按当前 JSON 能力制作阅读主题。
4. 不修改 App 工程、业务逻辑、页面布局、导航顺序、点击区域或书架结构。所有设计只能使用合同开放的外观角色。

二、主题覆盖范围
1. 全局语义配色、导航和功能图标、页面背景、卡片和弹层、分隔线、进度条、空状态与默认装饰。
2. 控件 normal、pressed、selected、disabled、focused、loading 状态；使用合同中确定的派生规则或提供对应资源。
3. 阅读纸色、背景、字体、字号、附加行距、段距、字重、首行缩进、四边留白及联动。
4. 页眉页脚开关、高度、间隔与全部元素的类型、区域、百分比坐标、宽度、字号、颜色；保持动态书名、章节、时间和进度占位类型。
5. 当前生效的章节标题 CSS、气泡 SVG、气泡样式/颜色/圆角及显示开关；段评/神评卡片样式、颜色、圆角及显示开关。
6. 可移植的全书显示规则。只分享评论外观，不附真实评论数据。
7. v1 使用 motion.pressOpacity 和 motion.duration 定义点击反馈，减少动态效果时取消过渡。不要引入任意代码或未支持动画格式。
8. 阅读模式、点击翻页、震动属于 optionalReadingBehavior，独立列出供接收者选择，默认不覆盖。

三、格式与文件
1. 文件名“竹影-[主题名]-[版本].zhuyingtheme”；内容为非加密、非分卷的标准 ZIP，使用 Store 或 Deflate。
2. 包根直接包含 manifest.json、theme.json；附 assets/icons、assets/backgrounds、assets/reader、assets/fonts、preview、licenses 中实际需要的文件，不额外套一层目录。
3. manifest 的 format 为 zhuying-theme、formatVersion 为 1；同时记录 themeID、themeVersion、name、author、packageKind、scopes、appearanceModes、requiredCapabilities、optionalCapabilities、entry、files。
4. full 必须按合同完整覆盖 app 和 reader；只做阅读或图标等部分时用 component，并声明范围。不要把部分套装包装成 full。
5. theme.json 使用合同规定的 contractVersion、app、reader.appearance、reader.resources、reader.optionalReadingBehavior、reader.background、reader.systemFont、fontBindings。不得自行发明新协议。
6. 颜色采用 #RRGGBB，透明度独立为 opacity 0..1；长度按合同的原生逻辑点或百分比，保持单位明确。
7. 资源使用包内相对 path，省略时使用合同 v1 内置默认；当前不支持 builtin 引用对象。严禁引用我机器上的路径、个人资源 ID、其他未附带主题或网络文件。
8. 对 manifest 自身以外的每个文件记录 path、bytes、sha256、mediaType、role，覆盖 theme.json、预览与许可。SHA-256 必须在全部内容完成后按真实字节计算，不能用占位摘要或猜测值。整包哈希记录在旁置报告，避免自引用。

四、完整还原规则
1. 在基础主题上做修改后，导出展开的有效快照，包括默认值和个人覆盖的最终结果，不把恢复任务留给接收者的旧设置。
2. 对章节标题和气泡选择最终有效来源；用 resources 记录实际 CSS/SVG，避免 titleCSS/themeTitleCSS 或个人气泡/主题气泡的旧分支冲突。
3. 字体使用已声明的系统角色，或附带有分发许可的真实 TTF/OTF、许可、PostScript 名称和文件哈希。字体名称不等于字体文件。缺少许可或资源时，不宣称字体及布局完全一致。
4. 不输出本机 fontResourceHash、数据库引用、渲染缓存、绝对路径或临时文件。字体引用在导入端重新建立。
5. 剔除阅读进度、账号、书籍正文、书源凭据、真实评论、个人书籍/书源 ID。对自定义页眉文字提供导出前确认清单。
6. 当前书籍/书源范围的规则默认排除并报告；不能静默扩展为全部书籍。
7. 完整应用应覆盖所选外观范围内接收者旧的个人覆盖，并保留可恢复旧快照；混搭应用仅覆盖用户勾选范围，不能声称完全还原。
8. 跨设备保证设置、资源、搭配及兼容解释一致；不要承诺不同尺寸、系统字体或动态字体条件下分页和截图逐像素一致。

五、当前原生资源约束
1. 标题仅用单个 .chapter-title { ... }，属性为 font-size、font-weight、text-align、color、background-color、letter-spacing、padding-top、padding-bottom、border-bottom；不含伪元素、url()、@import、!important 或其他选择器。
2. 数值用 pt；字号 14–48，字间距 -2–16，上下间距 0–60。border-bottom 当前只是文字下划线，不能用它保证网页边框效果。
3. 气泡使用通过合同白名单校验的被动 SVG；占位符仅为 {{background}}、{{ink}}、{{accent}}、{{count}}，无脚本、事件、外链、foreignObject；本地引用必须闭合。
4. CSS/SVG 每个最多 60,000 UTF-8 字节。压缩包最多 20 MiB、实际解压总量 64 MiB、文件数 512。PNG/JPEG 单图最多 4 MiB、2048×2048；TTF/OTF 单个最多 10 MiB。若目标合同更严格，按更严格限制。
5. 段距 0–48 pt、留白 0–80 pt、页眉页脚高度 48–140 pt、间隔 0–48 pt、圆角 0–30 pt；页面元素最多32个、规则最多64条。元素字号9–22 pt、宽15–90%，坐标按原生约束验证。其他范围读取合同，不猜测。
6. 保留系统无障碍和减少动态效果选择。正文与背景目标对比度至少4.5:1，图标和背景铺放以实际组合结果验证。

六、验证与交付
1. 先输出设计说明和覆盖范围，再给完整源目录、实际主题包及验证报告；预览图单独标注是原生实测还是设计示意。
2. 实际验证 Schema、全部引用、真实字节/哈希、文件尺寸、所需能力、CSS/SVG、字体许可和配色。
3. 拒绝包外路径、..、反斜线、符号链接、重复路径、大小写和 Unicode 归一化冲突、未列入清单的文件、嵌套可执行代码及网络依赖。
4. 若环境允许，在目标原生 App 中预览书架、设置、阅读器；测试长标题、0/9/99/999+气泡、页眉页脚、显示规则、不同屏幕、暗色、动态字体及减少动态效果。
5. 做断网与清空缓存导入、旧个人覆盖冲突、字体注册、导入失败回滚、重启恢复，以及导出→导入→再导出的有效配置/资源哈希比较。
6. 未执行的验证逐项写“未执行”及原因。不得把 ZIP 能解压、JSON 能解析或网页效果图当作原生完全还原证明。
7. 没有文件生成能力时输出完整文本文件和资源清单、可复现的打包步骤，并明确“未生成主题包”；不要提供虚构下载链接、字体文件或哈希。

我的设计要求如下：
（在这里粘贴已填写的设计要求，并附合同、Schema和有效基础主题）
```

## 如何选用

- 现在制作能导入的阅读主题：复制 A。可以同时附上 [青竹示例文件](theme-examples/竹影-青竹阅读.json)。
- 现在制作完整主题：先从 App 导出 AI 制作资料，再复制 B 并附资料。
- 完整主题制作时：复制 B，并附目标 App 导出的合同、Schema 和基础主题。先从 App 导出一个完整模板再让 AI 修改，比要求 AI 从零猜测协议更可靠。

全局主题 v1 已接入原生 App；A 的旧 JSON 继续可用，B 的 ZIP 主题包和 A 的旧阅读 JSON 均可从统一主题入口导入。各次制作仍须据实记录原生验证结果。
