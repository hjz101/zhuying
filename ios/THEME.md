# 界面主题统一

## 全局换肤

应用现已通过统一环境主题解析颜色、图标、背景及点击反馈。默认使用竹影原色；可在「我的 → 主题管理」选择清透青绿、幻想夜航，或制作和导入主题。原页面结构与导航行为保留，阅读器纸色继续独立，完整主题包可选择同时应用阅读外观。

全局主题支持 `.zhuyingtheme` 导入导出、个人混搭、完整应用与恢复，以及 AI 制作资料导出。实现位于 `GlobalThemePackage.swift`、`GlobalThemeStore.swift`、`GlobalThemeRendering.swift`、`GlobalThemeManagerView.swift`。详细格式和范围见 `THEME_PACKAGES.md`。

应用界面沿用首页的米白底色、苔绿色文字、衬线标题和圆角卡片。阅读纸色由阅读偏好控制，在正文、手势提示和排版预览中显示；配置页使用应用主题，方便从书架和正文进入时获得一致的界面。

| 检查位置 | 原有不一致 | 本次调整 |
| --- | --- | --- |
| 阅读偏好（正文设置、我的） | 分散的演示配置和正文设置，标题等入口重复 | 偏好总览分为主题与字体、排版与页面、翻页与手势、正文与段评；共用本机设置、实时预览和统一标题卡片 |
| 章节目录（正文、详情） | 系统 List 样式，当前章与其他卡片风格不同 | 米白背景、圆角章节列表、浅绿当前章标记，保留搜索、正倒序和跳章 |
| 47 个共享功能页 | 独立的标题／配置样式，从夜读打开时会继承系统深色外观 | 共用页面标题、配置卡片和应用主题，覆盖书源、换源、朗读、皮肤、备份等入口 |
| 文件预览弹层 | 导航与系统控件随入口继承不同外观 | 统一应用主题、完成按钮配色、弹层背景和圆角 |
| 追更小报弹层 | 弹层材质与导航外观由入口决定 | 接入统一弹层背景、配色和圆角 |

书架、发现、我的、阅读历史已有对应配色和卡片布局。阅读器的悬浮工具栏与手势提示已随正文纸色设计。

阅读偏好中的纸色、主题与本地字体用于实际正文。字号、行段距、四边留白、标题和页眉页脚参与原生排版；左右留白可解除联动，页眉页脚元素可拖动及精调。标题统一在“排版与页面”中管理，可跟随主题或单独自建／导入 CSS，不在主题与字体中重复设置。

主题详情区分网页完整 CSS／SVG 预览与正文兼容效果。正文使用原生标题 CSS 白名单和栅格化 SVG 气泡；不支持的网页装饰会提示，个人标题、气泡和神评皮肤可覆盖主题。评论数据仍为本地示例，液态玻璃为半透明绘制外观。

## 后续调整位置

- `Views/Components.swift`：`Palette.card`、`Palette.soft`、`appPageStyle()`、`AppPageHeader`、`AppSettingsCard`。
- `Views/ProfileView.swift`：个人页及阅读偏好入口。
- `Views/ReadingPreferencesView.swift`：偏好总览、文字与边距、翻页与手势、共享阅读预览。
- `Views/ReadingAppearanceView.swift`：内置纸色、主题库入口、本地字体管理与样张。
- `Views/ReadingPageEditors.swift`：章节标题 CSS／可视设置、页眉页脚的区域和元素编辑。
- `Views/ReadingContentPreferences.swift`：样式规则、段尾气泡及段下神评皮肤。
- `Models/ReaderPreferences.swift`、`Models/ReaderEngine.swift`：持久化设置、标题／规则解析、真实正文排版与分页。
- `Models/ReadingFontLibrary.swift`、`Models/ThemeReadingBridge.swift`：字体注册与保存、主题应用、原生 SVG 气泡生成。
- `Views/ThemeLibraryView.swift`：主题／资源筛选、导入、网页与原生效果对照、套装及混搭。
- `Views/ReaderPageFurniture.swift`：真实阅读页的页眉页脚位置和内容。
- `Views/ReaderView.swift`：章节目录的列表与当前章状态。
- `Demo/FeatureDemoView.swift`：47 个功能页的共用布局。

界面主题与阅读纸色分别管理；阅读偏好、字体和主题库在本机保存。书源、朗读、同步等服务仍使用本地演示状态。
