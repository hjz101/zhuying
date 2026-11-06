# 竹影全局主题 v1 实现与验证

入口：**我的 → 主题管理 → 全局主题、制作与分享**。沿用现有页面布局、Tab、导航路径和操作。

## 已实现

- 内置「竹影原色」「清透青绿」「幻想夜航」，全局语义配色作用于现有原生页面、弹层、导航和操作控件。
- 制作主题：编辑配色、应用内图标和状态图片、页面／卡片／阅读／默认封面背景，设置填充、适应、平铺、透明度、遮罩与按下反馈。
- `.zhuyingtheme`：标准 ZIP，包含版本化 JSON、独立资源、真实字节数与 SHA-256。可预览、仅加入主题库、完整应用或选择范围混搭。
- 分享当前实际生效的阅读配色、字体、排版、页眉页脚、标题 CSS、气泡 SVG、段评卡片样式及全书范围显示规则。翻页模式、点击翻页和震动需要单独勾选。
- 完整应用会替换旧的个人标题和气泡覆盖，保存恢复点；设置与主题选择作为同一个书库快照保存，重启后恢复。生产书库备份包含主题目录与资源。
- 系统字体角色可移植；自定义字体须携带可分发的字体文件、准确 PostScript 名称与许可，不依赖作者沙盒路径。
- 导出「给 AI 的制作资料」：有效基础主题包、能力合同、两份 JSON Schema、制作提示词。原有阅读 JSON 入口继续保留。

## 验证结果

环境：iPhone 17 Pro / iOS 26.5 模拟器，独立模拟器「竹影全局主题验证」。

- `npm run check` 通过；`npm test` **83 项全部通过**，包含合同生成一致性、文稿示例与生产 CSS／SVG 解析验证。
- `ZhuyingTests` **402 项全部通过**，其中 `GlobalThemeTests` 新增 **21 项**。覆盖资源闭包、哈希、重复／缺失／越界条目、版本和能力、CSS／SVG、字体许可、实际字体安装、各背景铺放参数、混搭、个人覆盖替换、重启、备份与恢复、持久化失败、预览任务稳定性。
- 新增 `GlobalThemeFlowTests` **4 项全部通过**：夜间主题跨原有导航／重启／恢复、编辑保存、AI 制作资料调起系统保存、真实文件选择后预览／仅保存／完整应用。
- 相关原有 UI 回归 **12 项全部通过**：`NavigationFlowTests` 4 项、`ReadingPreferencesFlowTests` 5 项、`ThemeAssetsFlowTests` 3 项。相关界面验证合计 16 个不同流程，未声称执行全部 UI suite。
- 已查看原生截图，检查夜间主题文字对比度、保留的书架布局，以及导入主题的实际阅读气泡预览。
- `git diff --check` 通过。

最终原生单元与新增 UI 结果：`/tmp/zhuying-global-theme-delivery.xcresult`；日志：`/tmp/zhuying-global-theme-delivery.log`。原有 UI 回归结果位于 `/tmp/zhuying-global-theme-derived/Logs/Test/`，对应日志 `/tmp/zhuying-global-theme-final.log`。脚本结果：`/tmp/zhuying-global-theme-delivery-web.log`。

过程中发现的预览任务反复重启，已用有序序列化生成稳定标识修复，并加入 100 次指纹一致性回归。系统导出由主题管理页面接管弹层交接，验证能打开实际 Files 保存界面。

截图：[夜航书架](../screenshots/global-theme-night-shelf-2026-11-06.png)、[收到主题包后的原生预览](../screenshots/global-theme-import-preview-2026-11-06.png)。

## v1 范围

主题替换应用内配色、图标、背景和支持的阅读外观。系统键盘、权限面板和系统控件的内部绘制继续遵循 iOS；书籍真实封面与正文内容保留其内容含义。v1 动效支持有界的按下透明度和过渡，不执行任意脚本或动画文件。

每包为一个浅色或深色变体；应用图标／背景使用 PNG、JPEG 或系统符号，气泡使用被动 SVG，标题 CSS 使用现有原生白名单。跨机型、字体和系统版本不承诺分页或像素一致。以上是模拟器验证结果。

协议和作者文稿：[主题包规范](../design/ZHUYING-THEME-PACKAGE.md)、[给 AI 的提示词](../design/ZHUYING-THEME-AI-PROMPT.md)。
