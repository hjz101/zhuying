# 竹影阅读 3.0 兼容原型验证

实现分支：`codex/legado-compatibility`。集成提交：`b9f10ff`。独立工作区保留主目录正在进行的全局主题改动，未将它们带入本轮。

## 结果

2026-11-06，Xcode／iOS 26.5 模拟器：

| 验证 | 结果 |
| --- | --- |
| `npm run check` | 通过 |
| `npm test` | 82 项全部通过 |
| `ZhuyingTests` | 全量 428 项全部通过，其中本轮增加 47 项 |
| `LegadoSourceFlowTests` | 2 项全部通过：普通 HTML 和同步脚本规则分别导入、搜索、读取详情目录、读两章、重启恢复 |
| `SourcePackageFlowTests` | 2 项全部通过：旧规则保留、粘贴入口、原生 JSON 文件导入和保存重启 |
| `Zhuying Production`／Release／generic iOS | arm64 真机架构无签名编译通过，`BUILD SUCCEEDED` |
| 第三方声明 | Release 应用资源已包含 QuickJS MIT 声明 |
| `git diff --check` | 通过 |

新增单元测试包括 19 项原版书源请求及端到端测试、11 项规则语义测试、3 项配置测试、10 项真实 QuickJS 测试、3 项生产服务与持久化集成测试、1 项浏览器 Cookie 覆盖顺序回归。

覆盖了同步网络调用、共享脚本函数、变量和原版字段、HTML／JSON 行类型、组合替换顺序、分页去重、下一章边界和重定向、适配器重建、相对 URL、Header 大小写覆盖、Cookie 来源隔离、宿主重入、累计内存预算、取消和独立超时。前期发现的选择器误判、Fuzi 临时文档生命周期和测试服务器章节编码误判均已修正，最终整轮验证无失败。

## 执行命令

在该工作区根目录执行：

```sh
xcodegen generate --spec ios/project.yml
xcodebuild -project ios/Zhuying.xcodeproj -scheme Zhuying \
  -destination 'platform=iOS Simulator,id=4038B360-1687-474F-BEC3-D5B1A898BC11' \
  -derivedDataPath /tmp/zhuying-legado-derived \
  -only-testing:ZhuyingTests \
  -only-testing:ZhuyingUITests/LegadoSourceFlowTests \
  -only-testing:ZhuyingUITests/SourcePackageFlowTests \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- test
xcodebuild -project ios/Zhuying.xcodeproj -scheme 'Zhuying Production' \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/zhuying-legado-release CODE_SIGNING_ALLOWED=NO build
```

本机证据：`/tmp/zhuying-legado-validation-final.log`、`/tmp/zhuying-legado-web.log`、`/tmp/zhuying-legado-release.log`。Xcode 结果包为 `/tmp/zhuying-legado-derived/Logs/Test/Test-Zhuying-2026.11.06_22-17-37-+0800.xcresult`。

## 界面留档与实际边界

已人工查看[HTML 规则正文](../screenshots/legado-html-reader-2026-11-06.png)和[同步脚本正文](../screenshots/legado-script-reader-2026-11-06.png)。两者均使用现有阅读器布局和入口，截图处于第二章；正文来自规则和真实 QuickJS 执行，不由模拟 `BookSource` 直接返回。

界面测试注入的是原创固定 HTTP 文档传输，验证生产解析、脚本、缓存和存储链路；没有声称已验证任意网络站点，也未运行 Android APK 差分。真机架构构建通过不代表已经完成签名安装、真机浏览器登录或 App Store 验收。

本轮交付为阶段一基础兼容原型。大灰狼包依赖的不透明来源主机配置、跨站请求、登录 UI、设备／Java 扩展接口仍待后续阶段，不标为已完整可读。完整范围见[兼容说明](../LEGADO-COMPATIBILITY.md)。
