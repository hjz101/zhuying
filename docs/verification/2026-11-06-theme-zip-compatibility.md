# 竹影主题 ZIP 读取兼容修复

用户真机截图显示「归档损坏、格式变体不受支持或包含不安全路径，原包未改动」。该文案来自原主题解码调用的通用 `BoundedArchive`，尚未进入 manifest、字体或样式校验。原实现依赖 libarchive 和 POSIX UTF-8 locale；模拟器测试不能证明这条依赖在用户真机环境可用。本机没有已连接的用户真机，无法取得该设备的底层错误码，因此不把 locale 判断写成已证实的单一根因。

## 改动

主题 v1 只要求标准 Store／Deflate ZIP。改为使用已有 ZIPFoundation 依赖直接读取内存，不再经过 libarchive 的 locale／iconv 初始化。RAR、7z 和其他书籍归档流程保持原实现。

读取前检查完整 EOCD、分卷字段、中央目录与本地文件头、条目数量、加密标志、压缩方式、文件类型、数据范围与重叠。读取时检查逐项大小、实际累计解包量、CRC、路径与规范化后的重复名称；读取后继续进行原有 SHA-256、资源闭包、原生 CSS／SVG、字体许可与字形验证。

细分错误为目录未完整下载、加密、压缩方法不支持、文件头不一致、CRC／大小校验等，便于后续反馈；没有放开不安全路径或跳过校验。

## 验证

- `npm run check` 通过；脚本测试 86 项通过。
- 原生单元全量 **408 项通过**。新增回归覆盖 POSIX C locale 下的中文资源路径、原有浅深水墨包、线程 locale 保持、截断目录、加密尾条目、本地／中央文件头名称不一致、伪造条目数量、真实 CRC 校验和不支持的压缩方法。
- **2 个界面流程通过**：实际水墨浅深两包的 Files 导入、应用、书架与正文；既有完整主题的预览、仅保存、再应用。
- 结果包 `/tmp/zhuying-theme-zip-compatibility.xcresult`；原生日志 `/tmp/zhuying-theme-zip-compatibility.log`；脚本日志 `/tmp/zhuying-theme-zip-compatibility-web.log`。
- `git diff --check` 通过。

以上是 iPhone 17 Pro / iOS 26.5 模拟器验证；用户设备仍需用新构建验收，不宣称已完成该真机验证。

## 交付

未签名 **0.8.0 build 13**，替换旧构建后重新导入。两个水墨主题包字节保持不变：

- 浅色 SHA-256：`ac4545e65830c7d9429fbdca4cc75cbf37a3798d8b25e9a42455c7555f204382`
- 深色 SHA-256：`f17d41b888ba7bf6bf41090a5ee2971191de7af9db8fc70c4647ac19ea8a0112`

入口仍为「我的 → 主题管理 → 导入主题包」。不需要重新转换或重新下载主题文件。
