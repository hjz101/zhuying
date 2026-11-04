# 阅山 for iOS

原生 SwiftUI 交互 Demo。最低系统 iOS 17，面向 iPhone；无真实后端、无第三方依赖。内置原创模拟书库，所有操作在设备本地完成。

## 打开与运行

1. 使用 Xcode 打开 `Yueshan.xcodeproj`。
2. 选择 `Yueshan` scheme 和已安装运行时的 iPhone 模拟器。
3. 按 ⌘R 运行；模拟器不需要开发者账号。安装到真实 iPhone 时需在 Signing & Capabilities 选择你的开发团队。

项目已提交，可直接打开。若修改了文件结构或项目配置，可在仓库根目录运行 `xcodegen generate --spec ios/project.yml` 重新生成工程；日常运行不需要 XcodeGen。

## 界面和体验路径

- **书架**：继续阅读卡片、全部／正在阅读／未读筛选、双列封面与列表、收藏菜单及移除撤销。
- **发现**：iOS 原生搜索框、题材筛选、书籍列表，按书名或作者实时检索。
- **详情**：封面、作者、简介、标签、样章目录、收藏与开始／继续阅读。
- **阅读器**：全屏阅读、原生滚动、目录底部面板、字号、行距与纸色、点击正文收起工具栏。
- **我的**：本机阅读概况、阅读偏好与 Demo 说明；无需注册。

建议路径：书架 → 继续阅读 → 目录 → 跳章 → 设置 → 返回书架 → 发现 → 搜索“云海” → 详情 → 加入书架 → 开始阅读。

首次运行预置 6 本收藏与 3 条阅读记录。书架、各书章节与段落位置、阅读偏好保存至 UserDefaults；不会同步至其他设备。卸载或清除 App 数据可重置。示例字数与连载状态仅作展示，正文为短篇样章，多个章节包含复用段落。

## 测试

在 Xcode 按 ⌘U，或从仓库根目录运行：

```sh
xcodebuild -project ios/Yueshan.xcodeproj -scheme Yueshan \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=NO test
```

选择的模拟器名称需与本机实际安装的设备一致。`YueshanTests` 验证模型和持久化，`YueshanUITests` 验证原生 App 操作流程；界面测试使用独立测试数据，不重置正常运行的收藏。

当前验收情况见 `QA.md`。真实书源、云同步、完整小说、付费及离线下载均未实现。
