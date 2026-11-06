# 竹影 · iOS 阅读器

竹影（Zhuying）使用 SwiftUI 开发，当前版本为 0.8.0（build 15），支持正式阅读与独立 Demo 模式。用 Xcode 打开 `ios/Zhuying.xcodeproj`，选择 `Zhuying` scheme 和 iPhone 模拟器运行；正式模式使用 `Zhuying Production` scheme。IPA 的生成方式见 [IPA 导出说明](docs/release/IPA-EXPORT.md)。

原生版使用与测试方式见 [iOS 说明](ios/README.md)，47 个模块的覆盖与模拟边界见 [功能清单](ios/FEATURES.md)。下方保留的是之前的网页草稿，仅供历史设计参考。

阅读 3.0 端侧兼容原型已推进到阶段三：原版 JSON 经现有入口导入，继续复用登录、搜索与阅读页面；共享脚本会话增加全进程预留额度、空闲回收和操作租约，书源调试增加安全分类、恢复入口及两部不同作品各三章的实际请求与真实重启复核。持久会话使用稳定资料库 UUID，书籍的替换开关只控制用户净化规则。范围、计时和迁移边界见 [兼容说明](docs/LEGADO-COMPATIBILITY.md)，证据见 [阶段三验证记录](docs/verification/2026-11-07-legado-stage-three.md)。96 MiB 是 QuickJS 配置堆上限的预留总预算，不是进程 RSS 上限；真实大灰狼原包已通过搜索、详情、目录、两部作品各三章及实际进程重启复核；其他线路、付费权限与复杂媒体路径仍需独立验收，参考 APK 差分尚未运行。

正式版的功能优先级、72 项任务、前置依赖、可并行工作线和阶段验收见 [完整开发流程与任务清单](docs/DEVELOPMENT-PLAN.md)。

正式开发的当前状态与验证证据见 [实施记录](docs/IMPLEMENTATION-STATUS.md)，书山聚合的接口子集及待联调范围见 [接入记录](docs/SHUSHAN-INTEGRATION.md)。界面与交互一致性按 `AGENTS.md` 执行。

步骤五、六的 0.6.0 开发版本新增 EPUB、多源与下载工具、真实全文搜索／统计、系统朗读及用户自配在线／AI 服务；范围与待验收条件见 [候选说明](docs/release/2026-11-06-stage-five-six.md)。服务在 App 内配置，密钥不经聊天。

## 冻结 Demo

原 Demo 的完整源码、截图和保存清单位于 [保存分支](https://github.com/hjz101/zhuying/tree/codex/saved-demo-2026-11-05)，固定提交为 `ea3b91c9b6cfcdbc411567ac4c7a7c0ae70a70e4`。主分支通过 `竹影Demo-2026-11-05/` 子模块引用该版本，保留独立历史。

克隆时使用 `git clone --recurse-submodules https://github.com/hjz101/zhuying.git`；已有仓库运行 `git submodule update --init --recursive` 取回 Demo。在该目录运行 `python3 verification/verify_snapshot.py` 可校验快照，打开其 `ios/Yueshan.xcodeproj` 可运行原 Demo。该子模块与 `docs/verification/`、带日期的发布记录是原始历史证据，保留当时名称和路径；当前工程与网页 Demo 已统一使用竹影。

## 旧网页草稿启动

需要 Node.js 18 或更新版本。在仓库目录运行：

```sh
npm run dev
```

打开 <http://127.0.0.1:4173>。其他端口可用 `PORT=4174 npm run dev` 指定。服务仅监听本机。

## 建议体验路径

1. 在书架点击“继续阅读”，滚动正文，试试目录与上下章。
2. 在阅读设置中调整字号、行距和主题，返回书架后再进入，检查进度恢复。
3. 打开发现页，搜索“长风”或作者“林间渡”，查看书籍详情。
4. 找到尚未收藏的《云海问道》或《明日回声》，加入书架并开始阅读。
5. 在书架切换“正在阅读／尚未开始”及网格／列表布局，使用封面右上角菜单移除收藏，或点击提示中的“撤销”。
6. 缩窄窗口至手机尺寸，查看底部导航和阅读工具栏。

首次访问会预置 6 本收藏和 3 条阅读记录，便于体验已有内容的界面。收藏、进度和偏好保存在当前浏览器的 `zhuying-demo-v1` localStorage 项；清除该项再刷新可重置演示。

示例标注的字数与连载状态用于界面展示，实际只包含短篇样章。没有接入真实书源、登录、云同步、整本下载或离线缓存。

## 验证

```sh
npm run check
npm test
```

测试覆盖检索、题材过滤、书架去重与排序、移除后保留进度、未收藏阅读、章节边界、持久化、存储异常及非法路由。界面验收记录见 `docs/DEMO-QA.md`，产品方向见 `docs/PRD.md`。
