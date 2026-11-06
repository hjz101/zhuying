# 竹影阅读 3.0 第二阶段验证记录

日期：2026-11-06（Asia/Shanghai）。代码提交：`43ec0d7`，分支 `codex/legado-compatibility`。本记录补充[第一阶段验证](2026-11-06-legado-prototype.md)；能力与边界见[兼容说明](../LEGADO-COMPATIBILITY.md)。

## 实现与验证范围

- 原版规则使用持久 QuickJS 会话，共享 `jsLib` 与登录函数；规则局部变量不跨求值泄漏。账号变化、异常、取消、超时后按约定重建运行环境。
- 书源身份、实际 HTTPS 主机与书籍／章节身份分开处理。原创测试源覆盖两个主机、两本书、每本两章、交错阅读、切换线路及重新创建状态后的阅读恢复。
- 原版 `data:;base64` 内部引用向规则提供原始十六进制内容，完整请求描述符进入受保护注册表。普通书籍／章节元数据不存带凭据的请求选项。query／POST 选项引用也保留章节分页边界。
- 原版 `loginUi` 从现有入口显示，实际 QuickJS 登录动作与 WebKit 网页等待衔接；网页完成不自动视为认证成功。网页等待暂停操作与脚本预算，取消、重置、过期及退出会终止旧操作。
- 变量、登录资料、缓存、Cookie 和内部引用按书源、账号、书库隔离；WebKit 同样使用完整作用域。登录资料与引用放在 Keychain，磁盘快照用 Keychain 密钥加密。Cookie 回包提交校验账号版本，退出后的旧回包不能恢复登录 Cookie。
- 多主机请求按实际主机复用现有代理／DNS／后端配置。Cookie 不跨主机自动携带；默认请求头跨主机仅继承公开协商字段，本次请求选项显式设置的头保持有效。
- AES 使用系统 CommonCrypto，测试包含 FIPS 197 三种密钥长度、NIST SP 800-38A CBC 四块向量及 Android Base64 flags。窄范围 `JavaImporter` 仅导入已经实现的 Base64 对象。

## 自动验证

模拟器：`4038B360-1687-474F-BEC3-D5B1A898BC11`，iOS 26.5。最终验证命令：

```sh
xcodegen generate --spec ios/project.yml
xcodebuild -project ios/Zhuying.xcodeproj -scheme Zhuying \
  -destination 'platform=iOS Simulator,id=4038B360-1687-474F-BEC3-D5B1A898BC11' \
  -derivedDataPath /tmp/zhuying-legado-derived \
  -only-testing:ZhuyingTests \
  -only-testing:ZhuyingUITests/LegadoSourceFlowTests \
  -only-testing:ZhuyingUITests/LegadoLoginFlowTests \
  -only-testing:ZhuyingUITests/SourcePackageFlowTests \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- test
```

界面回归实际使用系统文件选择器导入原版 JSON，并经过现有登录、搜索与阅读入口。登录流程覆盖安全输入、运行原始按钮动作、网页 DOM 注入完成、返回表单、重启恢复与退出清理。规则源与同步脚本源均验证正文、下一章和重启恢复。

Web 验证使用 `npm test` 与 `npm run check`。设备构建使用：

```sh
xcodebuild -project ios/Zhuying.xcodeproj -scheme 'Zhuying Production' \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/zhuying-legado-release CODE_SIGNING_ALLOWED=NO build
```

最终结果：

- iOS 单元测试 **488 项通过**；相关 UI 流程 **5 项通过**，`TEST SUCCEEDED`。
- Web 测试 **82 项通过**，语法检查通过。
- arm64 iOS Release 设备构建 `BUILD SUCCEEDED`（未签名，不等同于已导出 IPA）。
- `git diff --check` 与本轮文档相对链接检查通过。

本机日志（不提交构建产物）：

- `/tmp/zhuying-legado-upload-validation.log`
- `/tmp/zhuying-legado-derived/Logs/Test/Test-Zhuying-2026.11.06_23-37-24-+0800.xcresult`
- `/tmp/zhuying-legado-upload-release.log`
- `/tmp/zhuying-legado-phase2-web.log`

## 真实样本的证据边界

冻结大灰狼包为先前获得的 157,920 字节原文件，SHA-256 为 `e5e81f26de9b39d87d6ebde860ddecef373be78860b65c58101825b6f026f0ae`。未将原包、可能包含的账号资料或副本提交到仓库。

本轮仅对该原包验证：保留不透明来源标识、识别静态 HTTPS 候选主机，以及在真实 QuickJS 中加载其原始 `jsLib` 与登录函数库。离线初始化成功，只调用一次 `source.getVariable`，没有网络请求和认证写入。

尚未完成该包真实账号的登录、两本书连续正文及重启验收，也未与固定 Android 阅读版本做差分执行。HTTP 明文主机、任意 Java 类、网页中的同步 Android 宿主和未实现的高级正文处理仍在明确边界内。当前验证使用少量来源，尚未实现跨全部来源的常驻 VM 总内存预算与压力回收。
